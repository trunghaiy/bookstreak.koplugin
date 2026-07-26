local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Settings = require("settings")
local Api = require("api")
local Queue = require("queue")
local SidecarReader = require("sidecar_reader")
local Sync = require("sync")
local PluginUpdater = require("updater")

local PAGES_BEFORE_SYNC = 10
local AUTO_SYNC_DEBOUNCE_SECONDS = 30

local BookStreakSync = WidgetContainer:extend{
    name = "bookstreaksync",
    is_doc_only = false,
    _page_turn_counter = 0,
    _periodic_sync_scheduled = false,
}

function BookStreakSync:init()
    self._settings = Settings:new()
    self._api = Api:new(self._settings)
    self._queue = Queue:new(self._api)
    self._sidecar_reader = SidecarReader:new()
    self._sync = Sync:new(self._settings, self._api, self._queue, self._sidecar_reader)
    self._updater = PluginUpdater:new(self._settings)

    self._page_turn_counter = 0
    self._periodic_sync_scheduled = false
    self._periodic_sync_task = function()
        self._periodic_sync_scheduled = false
        self._page_turn_counter = 0
        self:_doAutoSync()
    end

    UIManager:nextTick(function()
        self._updater:checkIfDue()
    end)

    self.ui.menu:registerToMainMenu(self)
end

function BookStreakSync:addToMainMenu(menu_items)
    menu_items.bookstreak_sync = {
        text = _("BookStreak Sync"),
        sorting_hint = "tools",
        sub_item_table = self:_buildMenu(),
    }
end

function BookStreakSync:_buildMenu()
    return {
        {
            text_func = function()
                if self._settings:isConfigured() then
                    return _("Setup with code (connected)")
                end
                return _("Setup with code")
            end,
            keep_menu_open = true,
            callback = function()
                self:_setupWithCode()
            end,
            separator = true,
        },
        {
            text_func = function()
                if not self._settings:isConfigured() then
                    return _("Sync now")
                end
                local failed_time = self._settings:getLastSyncFailedTime()
                local success_time = self._settings:getLastSyncTime()

                if failed_time > success_time and failed_time > 0 then
                    local ago = self:_formatAgo(failed_time)
                    if ago then
                        return T(_("Sync now (failed %1)"), ago)
                    end
                end

                if success_time > 0 then
                    local ago = self:_formatAgo(success_time)
                    if ago then
                        return T(_("Sync now (synced %1)"), ago)
                    end
                end

                return _("Sync now")
            end,
            enabled_func = function()
                return self._settings:isConfigured()
            end,
            callback = function()
                self:_doSyncAll()
            end,
            separator = true,
        },
        {
            text = _("Sync when closing a book"),
            checked_func = function()
                return self._settings:get("sync_on_close")
            end,
            callback = function()
                self._settings:set("sync_on_close", not self._settings:get("sync_on_close"))
                self._settings:flush()
            end,
        },
        {
            text = _("Sync highlights & notes"),
            checked_func = function()
                return self._settings:get("sync_annotations")
            end,
            callback = function()
                self._settings:set("sync_annotations", not self._settings:get("sync_annotations"))
                self._settings:flush()
            end,
            separator = true,
        },
        {
            text_func = function()
                local url = self._settings:getServerUrl() or ""
                local host = url:match("//([^/]+)") or url
                if host == "" then host = "(not set)" end
                return "Server: " .. host
            end,
            keep_menu_open = true,
            callback = function()
                self:_editSetting("server_url", _("Server URL"), self._settings:getServerUrl() or "")
            end,
        },
        {
            text_func = function()
                local u = self._settings:getUsername()
                if not u or u == "" then return "Username: (not set)" end
                return "Username: " .. u
            end,
            keep_menu_open = true,
            callback = function()
                self:_editSetting("username", _("Username"), self._settings:getUsername())
            end,
        },
        {
            text_func = function()
                local p = self._settings:getPassword()
                if not p or p == "" then return "Password: (not set)" end
                return "Password: ********"
            end,
            keep_menu_open = true,
            callback = function()
                self:_editSetting("password", _("Password"), "")
            end,
            separator = true,
        },
        {
            text_func = function()
                return T(_("Check for updates (v%1)"), self._updater:currentVersion())
            end,
            keep_menu_open = true,
            callback = function()
                self._updater:checkNow()
            end,
        },
        {
            text = _("About"),
            keep_menu_open = true,
            callback = function()
                local plugin_meta = require("_meta")
                UIManager:show(InfoMessage:new{
                    text = T(_("BookStreak Sync v%1\n\nSync your KOReader reading sessions to BookStreak automatically.\n\ngithub.com/trunghaiy/bookstreak.koplugin"), plugin_meta.version),
                })
            end,
        },
    }
end

function BookStreakSync:_editSetting(key, title, current_value)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = current_value or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        self._settings:set(key, value)
                        self._settings:flush()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function BookStreakSync:_setupWithCode()
    local dialog
    dialog = InputDialog:new{
        title = _("Enter setup code"),
        description = _("Open BookStreak on your phone, go to Settings > KOReader Sync, and tap 'Get Setup Code'. Enter the 6-character code below."),
        input_hint = "ABC123",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Connect"),
                    is_enter_default = true,
                    callback = function()
                        local code = dialog:getInputText()
                        if not code or code == "" then return end
                        UIManager:close(dialog)
                        self:_exchangeCode(code:upper():gsub("%s", ""))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function BookStreakSync:_exchangeCode(code)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local rapidjson = require("rapidjson")

    local server_url = self._settings:getServerUrl() or Settings.DEFAULT_SERVER
    local url = server_url:gsub("/koreader%-sync$", "/koreader-sync") .. "/claim?code=" .. code
    local response_chunks = {}

    UIManager:show(InfoMessage:new{ text = _("Connecting..."), timeout = 1 })

    socketutil:set_timeout(5, 15)
    local http_code, headers, status = socket.skip(1, https.request{
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "application/json",
            ["User-Agent"] = "bookstreak.koplugin/0.1.0",
        },
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    if http_code == 200 then
        local ok, result = pcall(rapidjson.decode, table.concat(response_chunks))
        if ok and result and result.username and result.password then
            self._settings:set("username", result.username)
            self._settings:set("password", result.password)
            if result.server_url then
                self._settings:set("server_url", result.server_url)
            end
            self._settings:flush()
            UIManager:show(InfoMessage:new{
                text = T(_("Connected!\n\nUsername: %1\n\nYou can now use 'Sync now' to sync your reading data."), result.username),
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Invalid response from server. Please try again."),
            })
        end
    elseif http_code == 404 then
        UIManager:show(InfoMessage:new{
            text = _("Code not found or expired.\n\nPlease generate a new code in the BookStreak app and try again."),
        })
    else
        local err_body = table.concat(response_chunks)
        UIManager:show(InfoMessage:new{
            text = T(_("Connection failed (code %1).\n\nPlease check your WiFi and try again."), http_code or "?"),
        })
    end
end

function BookStreakSync:_formatAgo(timestamp)
    if not timestamp or timestamp == 0 then return nil end
    local ago = os.time() - timestamp
    if ago < 60 then
        return _("just now")
    elseif ago < 3600 then
        return T(_("%1 min ago"), math.floor(ago / 60))
    elseif ago < 86400 then
        return T(_("%1 hours ago"), math.floor(ago / 3600))
    else
        return T(_("%1 days ago"), math.floor(ago / 86400))
    end
end

function BookStreakSync:_showStatus()
    local last_time = self._settings:getLastSyncTime()
    local books = self._settings:get("last_sync_books") or 0
    local sessions = self._settings:get("last_sync_sessions") or 0
    local queue_size = self._queue:size()

    local status_text
    if last_time == 0 then
        status_text = _("No sync yet.\n\nSet your username and password from the BookStreak app's KOReader Sync screen, then tap 'Sync now'.")
    else
        local ago_str = self:_formatAgo(last_time) or _("unknown")
        status_text = T(_("Last sync: %1\nBooks: %2 · Sessions: %3"), ago_str, books, sessions)

        if queue_size > 0 then
            status_text = status_text .. "\n" .. T(_("\nQueued payloads: %1 (waiting for WiFi)"), queue_size)
        end
    end

    UIManager:show(InfoMessage:new{ text = status_text })
end

function BookStreakSync:_flushStats()
    local ReaderUI = require("apps/reader/readerui")
    local instance = ReaderUI.instance
    if instance and instance.statistics and instance.statistics.insertDB then
        instance.statistics:insertDB()
    end
end

function BookStreakSync:_doSyncAll()
    if not self._settings:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Please set your username and password first.\n\nYou can find these in the BookStreak app under Settings > KOReader Sync."),
        })
        return
    end

    self:_flushStats()

    local syncing_msg = InfoMessage:new{ text = _("Syncing..."), timeout = 120 }
    UIManager:show(syncing_msg)
    UIManager:forceRePaint()

    UIManager:nextTick(function()
        local result = self._sync:syncAll(true, function(synced_so_far, total)
            UIManager:close(syncing_msg)
            syncing_msg = InfoMessage:new{
                text = T(_("Syncing %1 of %2 books..."), synced_so_far, total),
                timeout = 120,
            }
            UIManager:show(syncing_msg)
            UIManager:forceRePaint()
        end)
        UIManager:close(syncing_msg)
        self:_showSyncResult(result)
    end)
end

function BookStreakSync:_showSyncResult(result)
    if result.ok then
        if result.queued then
            UIManager:show(InfoMessage:new{
                text = _("No WiFi available. Reading data queued and will sync when you're online."),
            })
        elseif result.books_synced == 0 and (result.books_unlinked or 0) == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Already up to date. No new reading data to sync."),
            })
        else
            local parts = {}
            if result.books_synced > 0 then
                table.insert(parts, T(_("%1 books synced"), result.books_synced))
            end
            if result.sessions_created > 0 then
                table.insert(parts, T(_("%1 sessions"), result.sessions_created))
            end
            if result.annotations_created > 0 then
                table.insert(parts, T(_("%1 annotations"), result.annotations_created))
            end
            local msg = table.concat(parts, ", ")
            if (result.books_unlinked or 0) > 0 then
                if msg ~= "" then msg = msg .. "\n\n" end
                msg = msg .. T(_("%1 books need linking in the BookStreak app. Open Settings > KOReader Sync to match them to your library."), result.books_unlinked)
            end
            if msg == "" then msg = _("Sync complete.") end
            UIManager:show(InfoMessage:new{ text = msg })
        end
    else
        self._settings:recordSyncFailure(result.error)
        UIManager:show(InfoMessage:new{
            text = T(_("Sync failed: %1\n\nYour data has been queued and will retry automatically."), result.error or "unknown error"),
        })
    end
end

-- Lifecycle hooks

function BookStreakSync:onPageUpdate(pageno)
    if not self._settings:isConfigured() then return end
    if pageno == nil then return end

    self._page_turn_counter = self._page_turn_counter + 1

    if self._periodic_sync_scheduled or self._page_turn_counter >= PAGES_BEFORE_SYNC then
        self:schedulePeriodicSync()
    end
end

function BookStreakSync:schedulePeriodicSync()
    UIManager:unschedule(self._periodic_sync_task)
    UIManager:scheduleIn(AUTO_SYNC_DEBOUNCE_SECONDS, self._periodic_sync_task)
    self._periodic_sync_scheduled = true
end

function BookStreakSync:_doAutoSync()
    if not self._settings:isConfigured() then return end

    local book_path = self.ui and self.ui.document and self.ui.document.file
    if not book_path then return end

    self:_flushStats()

    local result = self._sync:syncBook(book_path)
    if result.ok and not result.queued and result.books_synced and result.books_synced > 0 then
        logger.info("BookStreak: Auto-synced", result.books_synced, "books")
    elseif result.queued then
        logger.info("BookStreak: Auto-sync queued (offline)")
    elseif not result.ok then
        self._settings:recordSyncFailure(result.error)
        logger.warn("BookStreak: Auto-sync failed:", result.error or "unknown")
    end
end

function BookStreakSync:onCloseWidget()
    UIManager:unschedule(self._periodic_sync_task)
    self._periodic_sync_task = nil
end

function BookStreakSync:onCloseDocument()
    -- Cancel any pending auto-sync
    UIManager:unschedule(self._periodic_sync_task)
    self._periodic_sync_scheduled = false
    self._page_turn_counter = 0

    if not self._settings:get("sync_on_close") then return end
    if not self._settings:isConfigured() then return end

    local book_path = self.ui.document and self.ui.document.file
    if not book_path then return end

    -- Force statistics plugin to flush before we read the DB.
    local stats = self.ui.statistics
    if stats and stats.insertDB then
        stats:insertDB()
    end

    UIManager:nextTick(function()
        local result = self._sync:syncBook(book_path)
        if result.ok and not result.queued and result.books_synced and result.books_synced > 0 then
            logger.info("BookStreak: Synced on document close")
        elseif result.queued then
            logger.info("BookStreak: Queued sync for", book_path)
        end
    end)
end

function BookStreakSync:onSuspend()
    if not self._settings:isConfigured() then return end

    local book_path = self.ui and self.ui.document and self.ui.document.file
    if not book_path then return end

    -- Cancel any pending auto-sync — we're syncing now
    UIManager:unschedule(self._periodic_sync_task)
    self._periodic_sync_scheduled = false
    self._page_turn_counter = 0

    self:_flushStats()

    local result = self._sync:syncBook(book_path)
    if result.ok and not result.queued and result.books_synced and result.books_synced > 0 then
        logger.info("BookStreak: Synced on suspend")
    elseif result.queued then
        logger.info("BookStreak: Queued sync on suspend")
    end
end

function BookStreakSync:onReaderReady()
    if not self._settings:isConfigured() then return end

    UIManager:nextTick(function()
        local result = self._sync:syncAll()
        if result.ok and not result.queued and result.books_synced and result.books_synced > 0 then
            logger.info("BookStreak: Synced on reader ready —", result.books_synced, "books")
        end
        if NetworkMgr:isOnline() and self._queue:size() > 0 then
            local sent = self._queue:flush()
            if sent > 0 then
                logger.info("BookStreak: Flushed", sent, "queued payloads on reader ready")
            end
        end
    end)
end

function BookStreakSync:onFlushSettings()
    if not self._settings:isConfigured() then return end

    -- Try to flush queue on app exit
    if NetworkMgr:isOnline() and self._queue:size() > 0 then
        self._queue:flush()
    end
end

function BookStreakSync:onNetworkConnected()
    if not self._settings:isConfigured() then return end

    -- Retry queued payloads when WiFi comes back
    if self._queue:size() > 0 then
        UIManager:nextTick(function()
            local sent = self._queue:flush()
            if sent > 0 then
                logger.info("BookStreak: Flushed", sent, "queued payloads on WiFi reconnect")
            end
        end)
    end
end

return BookStreakSync
