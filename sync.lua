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
    local device = require("device")
    return device:info(), device:getDeviceId() or "unknown"
end

function Sync:_queryNewPageStats(since_timestamp)
    local db_path = self:_getDbPath()

    local ok_open, conn = pcall(SQ3.open, db_path, "ro")
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
                id_book = row[1],
                page = row[2],
                start_time = row[3],
                duration = row[4],
                total_pages = row[5],
                title = row[6],
                authors = row[7],
                pages = row[8],
                series = row[9],
                md5 = row[10],
            })
        end
        stmt:close()
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
        local date_str = os.date("%Y-%m-%d", ps.start_time)
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

        table.insert(book_entries, {
            md5 = b.md5,
            title = b.title,
            authors = b.authors,
            pages = b.pages,
            series = b.series,
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
    -- Look up file path from KOReader's doc settings via statistics DB
    local db_path = self:_getDbPath()
    local ok_open, conn = pcall(SQ3.open, db_path, "ro")
    if not ok_open or not conn then return {} end

    -- The statistics DB doesn't store file paths directly.
    -- We need to find the book's sidecar via KOReader's history/doc settings.
    -- For now, check the DocSettings registry.
    conn:close()

    local DocSettings = require("docsettings")
    local doc_path = DocSettings:getPathFromMd5(md5)
    if not doc_path then return {} end

    return self.sidecar_reader:getAnnotations(doc_path, since_timestamp)
end

function Sync:syncAll()
    if not self.settings:isConfigured() then
        return { ok = false, error = "Not configured" }
    end

    local since = self.settings:getLastSyncTime()
    local rows = self:_queryNewPageStats(since)

    if not rows then
        return { ok = false, error = "Failed to read statistics database" }
    end

    if #rows == 0 then
        -- Nothing new, but try flushing the queue
        if NetworkMgr:isOnline() then
            self.queue:flush()
        end
        return { ok = true, books_synced = 0, sessions_created = 0, annotations_created = 0 }
    end

    local books, book_order = self:_groupByBook(rows)
    local payload = self:_buildPayload(books, book_order, since)

    if not NetworkMgr:isOnline() then
        self.queue:enqueue(payload)
        return { ok = true, queued = true, books_synced = 0, sessions_created = 0, annotations_created = 0 }
    end

    local result = self.api:post(payload)
    if result and result.status == "ok" then
        self.settings:recordSync(
            result.server_time or os.time(),
            result.books_synced or 0,
            result.sessions_created or 0
        )
        -- Also flush any previously queued payloads
        self.queue:flush()
        return {
            ok = true,
            books_synced = result.books_synced or 0,
            sessions_created = result.sessions_created or 0,
            annotations_created = result.annotations_created or 0,
        }
    else
        self.queue:enqueue(payload)
        return { ok = false, queued = true, error = "Sync failed, payload queued" }
    end
end

function Sync:syncBook(book_path)
    -- Sync only the current book (used on document close)
    if not self.settings:isConfigured() then return { ok = false } end

    local since = self.settings:getLastSyncTime()

    -- Get this book's md5 from DocSettings
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(book_path)
    if not doc_settings then return { ok = false } end

    local stats = doc_settings:readSetting("stats")
    local md5 = stats and stats.md5
    if not md5 then return { ok = false } end

    local rows = self:_queryNewPageStats(since)
    if not rows then return { ok = false } end

    -- Filter to just this book's md5
    local book_rows = {}
    for _, row in ipairs(rows) do
        if row.md5 == md5 then
            table.insert(book_rows, row)
        end
    end

    if #book_rows == 0 then return { ok = true, books_synced = 0 } end

    local books, book_order = self:_groupByBook(book_rows)
    local payload = self:_buildPayload(books, book_order, since)

    if not NetworkMgr:isOnline() then
        self.queue:enqueue(payload)
        return { ok = true, queued = true }
    end

    local result = self.api:post(payload)
    if result and result.status == "ok" then
        self.settings:recordSync(
            result.server_time or os.time(),
            result.books_synced or 0,
            result.sessions_created or 0
        )
        return { ok = true, books_synced = result.books_synced or 0 }
    else
        self.queue:enqueue(payload)
        return { ok = false, queued = true }
    end
end

return Sync
