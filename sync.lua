local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")

local Sync = {}

local MAX_BOOKS_PER_PAYLOAD = 50
local MAX_PAGES_PER_PAYLOAD = 10000

function Sync:new(settings, api, queue, sidecar_reader)
    local o = {}
    setmetatable(o, { __index = self })
    o.settings = settings
    o.api = api
    o.queue = queue
    o.sidecar_reader = sidecar_reader
    return o
end

function Sync:_getDbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

function Sync:_getDeviceInfo()
    local Device = require("device")
    local device_name = Device:info() or "unknown"
    local device_id = self.settings:get("device_id")
    if not device_id or device_id == "" then
        device_id = ("%s-%08x"):format(device_name:gsub("%s+", ""), math.random(0, 0xFFFFFFFF))
        self.settings:set("device_id", device_id)
        self.settings:flush()
    end
    return device_name, device_id
end

function Sync:_queryNewPageStats(since_timestamp)
    local db_path = self:_getDbPath()

    local ok_open, conn = pcall(SQ3.open, db_path, "rw")
    if not ok_open or not conn then
        logger.warn("BookStreak: Cannot open statistics.sqlite3")
        return nil
    end

    local ok_query, rows = pcall(function()
        local results = {}
        local stmt = conn:prepare([[
            SELECT psd.id_book, psd.page, psd.start_time, psd.duration, psd.total_pages,
                   b.title, b.authors, b.pages, b.series, b.md5
            FROM page_stat_data psd
            JOIN book b ON b.id = psd.id_book
            WHERE psd.start_time > ?
            ORDER BY psd.id_book, psd.start_time
        ]])
        stmt:bind(since_timestamp)
        for row in stmt:rows() do
            table.insert(results, {
                id_book = tonumber(row[1]),
                page = tonumber(row[2]),
                start_time = tonumber(row[3]),
                duration = tonumber(row[4]),
                total_pages = tonumber(row[5]),
                title = tostring(row[6] or ""),
                authors = tostring(row[7] or ""),
                pages = tonumber(row[8]),
                series = row[9] and tostring(row[9]) or nil,
                md5 = row[10] and tostring(row[10]) or nil,
            })
        end
        return results
    end)

    conn:close()

    if not ok_query then
        logger.warn("BookStreak: Query failed:", rows)
        return nil
    end

    return rows
end

function Sync:_groupByBook(rows)
    local books = {}
    local book_order = {}

    for _, row in ipairs(rows) do
        local md5 = row.md5
        if not md5 or md5 == "" then goto continue end

        if not books[md5] then
            books[md5] = {
                md5 = md5,
                title = row.title or "Unknown",
                authors = row.authors or "Unknown",
                pages = row.pages,
                series = row.series,
                page_stats = {},
            }
            table.insert(book_order, md5)
        end

        -- Prefer psd.total_pages (reflow-accurate) over book.pages (static)
        if row.total_pages and row.total_pages > 0 then
            books[md5].pages = row.total_pages
        end

        table.insert(books[md5].page_stats, {
            page = row.page,
            start_time = row.start_time,
            duration = row.duration,
        })
        ::continue::
    end

    return books, book_order
end

function Sync:_groupByDate(page_stats)
    local dates = {}
    local date_order = {}

    for _, ps in ipairs(page_stats) do
        local date_str = os.date("%Y-%m-%d", tonumber(ps.start_time))
        if not dates[date_str] then
            dates[date_str] = {}
            table.insert(date_order, date_str)
        end
        table.insert(dates[date_str], {
            page = ps.page,
            start_time = ps.start_time,
            duration = ps.duration,
        })
    end

    local sessions = {}
    for _, date_str in ipairs(date_order) do
        table.insert(sessions, {
            date = date_str,
            pages = dates[date_str],
        })
    end

    return sessions
end

function Sync:_buildPayload(books, book_order, since_timestamp)
    local device_name, device_id = self:_getDeviceInfo()
    local sync_annotations = self.settings:get("sync_annotations")

    local book_entries = {}
    local total_pages = 0

    for _, md5 in ipairs(book_order) do
        if #book_entries >= MAX_BOOKS_PER_PAYLOAD then break end
        if total_pages >= MAX_PAGES_PER_PAYLOAD then break end

        local b = books[md5]
        local sessions = self:_groupByDate(b.page_stats)

        -- Count pages in this book
        for _, s in ipairs(sessions) do
            total_pages = total_pages + #s.pages
        end

        local annotations = {}
        if sync_annotations then
            -- Try to find the book file path for sidecar reading
            -- The statistics DB doesn't store file paths, so we search
            -- using the book's md5 in KOReader's document settings
            annotations = self:_getAnnotationsForBook(b.md5, since_timestamp)
        end

        local isbn = self:_getIsbnForBook(b.md5)

        table.insert(book_entries, {
            md5 = b.md5,
            title = b.title,
            authors = b.authors,
            pages = b.pages,
            series = b.series,
            isbn = isbn,
            sessions = sessions,
            annotations = annotations,
        })
    end

    return {
        device = device_name,
        device_id = device_id,
        books = book_entries,
        last_sync_time = since_timestamp,
    }
end

function Sync:_getAnnotationsForBook(md5, since_timestamp)
    local DocSettings = require("docsettings")

    local history_path = DataStorage:getDataDir() .. "/history.lua"
    local ok_load, history = pcall(dofile, history_path)
    if not ok_load or type(history) ~= "table" then return {} end

    for _, entry in ipairs(history) do
        local file_path = entry.file
        if file_path then
            local ok, doc_sidecar = pcall(DocSettings.open, DocSettings, file_path)
            if ok and doc_sidecar then
                local doc_md5 = doc_sidecar:readSetting("partial_md5_checksum")
                if doc_md5 == md5 then
                    return self.sidecar_reader:getAnnotations(file_path, since_timestamp)
                end
            end
        end
    end

    return {}
end

function Sync:_getIsbnForBook(md5)
    local DocSettings = require("docsettings")

    local history_path = DataStorage:getDataDir() .. "/history.lua"
    local ok_load, history = pcall(dofile, history_path)
    if not ok_load or type(history) ~= "table" then return nil end

    for _, entry in ipairs(history) do
        local file_path = entry.file
        if file_path then
            local ok, doc_sidecar = pcall(DocSettings.open, DocSettings, file_path)
            if ok and doc_sidecar then
                local doc_md5 = doc_sidecar:readSetting("partial_md5_checksum")
                if doc_md5 == md5 then
                    local doc_props = doc_sidecar:readSetting("doc_props")
                    if type(doc_props) == "table" then
                        -- KOReader stores identifiers as a table: {isbn = "978...", uuid = "..."}
                        if doc_props.identifiers and type(doc_props.identifiers) == "table" then
                            local isbn_val = doc_props.identifiers.isbn or doc_props.identifiers.ISBN
                            if isbn_val and tostring(isbn_val) ~= "" then
                                return tostring(isbn_val):gsub("-", "")
                            end
                        end
                        -- Fall back to identifiers as a string (e.g. "ISBN:978-0-307-46376-0")
                        if doc_props.identifiers and type(doc_props.identifiers) == "string" then
                            local isbn = doc_props.identifiers:lower():match("isbn:(%d[%dxx-]+)")
                            if isbn then return isbn:gsub("-", "") end
                        end
                        -- Fall back to direct isbn field
                        if doc_props.isbn and doc_props.isbn ~= "" then
                            return tostring(doc_props.isbn):gsub("-", "")
                        end
                    end
                    return nil
                end
            end
        end
    end

    return nil
end

function Sync:syncAll(full)
    if not self.settings:isConfigured() then
        return { ok = false, error = "Not configured" }
    end

    local since = full and 0 or self.settings:getLastSyncTime()
    logger.info("BookStreak: syncAll since_timestamp =", since, "full =", full or false)

    local rows = self:_queryNewPageStats(since)

    if not rows then
        logger.warn("BookStreak: syncAll — query returned nil (DB error)")
        return { ok = false, error = "Failed to read statistics database" }
    end

    logger.info("BookStreak: syncAll — found", #rows, "new page stat rows")

    if #rows == 0 then
        if NetworkMgr:isOnline() then
            self.queue:flush()
        end
        return { ok = true, books_synced = 0, sessions_created = 0, annotations_created = 0 }
    end

    local books, book_order = self:_groupByBook(rows)
    local payload = self:_buildPayload(books, book_order, since)

    logger.info("BookStreak: syncAll — payload:",
        #payload.books, "books")
    for _, b in ipairs(payload.books) do
        local session_count = 0
        local page_count = 0
        local sessions = type(b.sessions) == "table" and b.sessions or {}
        for _, s in ipairs(sessions) do
            session_count = session_count + 1
            local pages = type(s.pages) == "table" and s.pages or {}
            page_count = page_count + #pages
        end
        local ann_count = type(b.annotations) == "table" and #b.annotations or 0
        logger.info("BookStreak:   book:", b.title, "md5:", b.md5,
            "sessions:", session_count, "pages:", page_count,
            "annotations:", ann_count)
    end

    if not NetworkMgr:isOnline() then
        self.queue:enqueue(payload)
        return { ok = true, queued = true, books_synced = 0, sessions_created = 0, annotations_created = 0 }
    end

    local timeout = full and 120 or 30
    local result = self.api:post(payload, timeout)
    if result and result.status == "ok" then
        logger.info("BookStreak: syncAll — server response: books_synced =",
            result.books_synced, "sessions_created =", result.sessions_created,
            "annotations_created =", result.annotations_created)
        self.settings:recordSync(
            result.server_time or os.time(),
            result.books_synced or 0,
            result.sessions_created or 0
        )
        self.queue:flush()
        return {
            ok = true,
            books_synced = result.books_synced or 0,
            books_unlinked = result.books_unlinked or 0,
            sessions_created = result.sessions_created or 0,
            annotations_created = result.annotations_created or 0,
        }
    else
        logger.warn("BookStreak: syncAll — post failed, queuing payload")
        self.queue:enqueue(payload)
        return { ok = false, queued = true, error = "Sync failed, payload queued" }
    end
end

function Sync:syncBook(book_path)
    if not self.settings:isConfigured() then return { ok = false } end

    local since = self.settings:getLastSyncTime()
    logger.info("BookStreak: syncBook path =", book_path, "since =", since)

    local DocSettings = require("docsettings")
    local ok_open, doc_settings = pcall(DocSettings.open, DocSettings, book_path)
    if not ok_open or not doc_settings then
        logger.warn("BookStreak: syncBook — failed to open DocSettings for", book_path)
        return { ok = false }
    end

    local md5 = doc_settings:readSetting("partial_md5_checksum")
    if not md5 then
        logger.warn("BookStreak: syncBook — no partial_md5_checksum for", book_path)
        return { ok = false }
    end
    logger.info("BookStreak: syncBook md5 =", md5)

    local rows = self:_queryNewPageStats(since)
    if not rows then
        logger.warn("BookStreak: syncBook — query returned nil")
        return { ok = false }
    end

    logger.info("BookStreak: syncBook — total rows from DB:", #rows)

    -- Filter to just this book's md5
    local book_rows = {}
    for _, row in ipairs(rows) do
        if row.md5 == md5 then
            table.insert(book_rows, row)
        end
    end

    logger.info("BookStreak: syncBook — rows matching md5:", #book_rows)

    if #book_rows == 0 then
        logger.info("BookStreak: syncBook — no new data for this book")
        return { ok = true, books_synced = 0 }
    end

    local books, book_order = self:_groupByBook(book_rows)
    local payload = self:_buildPayload(books, book_order, since)

    for _, b in ipairs(payload.books) do
        local session_count = 0
        local page_count = 0
        local sessions = type(b.sessions) == "table" and b.sessions or {}
        for _, s in ipairs(sessions) do
            session_count = session_count + 1
            local pages = type(s.pages) == "table" and s.pages or {}
            page_count = page_count + #pages
        end
        local ann_count = type(b.annotations) == "table" and #b.annotations or 0
        logger.info("BookStreak: syncBook payload — book:", b.title,
            "sessions:", session_count, "page_entries:", page_count,
            "annotations:", ann_count)
    end

    if not NetworkMgr:isOnline() then
        self.queue:enqueue(payload)
        return { ok = true, queued = true }
    end

    local result = self.api:post(payload)
    if result and result.status == "ok" then
        logger.info("BookStreak: syncBook — server: books_synced =",
            result.books_synced, "sessions_created =", result.sessions_created,
            "annotations_created =", result.annotations_created)
        self.settings:recordSync(
            result.server_time or os.time(),
            result.books_synced or 0,
            result.sessions_created or 0
        )
        return { ok = true, books_synced = result.books_synced or 0 }
    else
        logger.warn("BookStreak: syncBook — post failed, queuing")
        self.queue:enqueue(payload)
        return { ok = false, queued = true }
    end
end

return Sync
