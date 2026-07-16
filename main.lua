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

local BookStreakSync = WidgetContainer:extend{
    name = "bookstreaksync",
    is_doc_only = false,
}

function BookStreakSync:init()
    self._settings = Settings:new()
    self._api = Api:new(self._settings)
    self._queue = Queue:new(self._api)
    self._sidecar_reader = SidecarReader:new()
    self._sync = Sync:new(self._settings, self._api, self._queue, self._sidecar_reader)

    self.ui.menu:registerToMainMenu(self)
end

function BookStreakSync:addToMainMenu(menu_items)
    menu_items.bookstreak_sync = {
        text = _("BookStreak Sync"),
        sorting_hint = "more_tools",
        sub_item_table = self:_buildMenu(),
    }
end

function BookStreakSync:_buildMenu()
    return {
        {
            text = _("Sync now"),
            enabled_func = function()
                return self._settings:isConfigured()
            end,
            callback = function()
                self:_doSyncAll()
            end,
        },
        {
            text = _("Sync status"),
            enabled_func = function()
                return self._settings:isConfigured()
            end,
            callback = function()
                self:_showStatus()
            end,
        },
        { separator = true },
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
        },
        { separator = true },
        {
            text_func = function()
                local url = self._settings:getServerUrl()
                return T(_("Server: %1"), url:match("//([^/]+)") or url)
            end,
            callback = function()
                self:_editSetting("server_url", _("Server URL"), self._settings:getServerUrl())
            end,
        },
        {
            text_func = function()
                local u = self._settings:getUsername()
                if u == "" then return _("Username: (not set)") end
                return T(_("Username: %1"), u)
            end,
            callback = function()
                self:_editSetting("username", _("Username"), self._settings:getUsername())
            end,
        },
        {
            text_func = function()
                local p = self._settings:getPassword()
                if p == "" then return _("Password: (not set)") end
                return _("Password: ********")
            end,
            callback = function()
                self:_editSetting("password", _("Password"), "")
            end,
        },
        { separator = true },
        {
            text = _("About"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("BookStreak Sync v0.1.0\n\nSync your KOReader reading sessions to BookStreak automatically.\n\ngithub.com/bookstreak/bookstreak.koplugin")),
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

function BookStreakSync:_showStatus()
    local last_time = self._settings:getLastSyncTime()
    local books = self._settings:get("last_sync_books") or 0
    local sessions = self._settings:get("last_sync_sessions") or 0
    local queue_size = self._queue:size()

    local status_text
    if last_time == 0 then
        status_text = _("No sync yet.\n\nSet your username and password from the BookStreak app's KOReader Sync screen, then tap 'Sync now'.")
    else
        local ago = os.time() - last_time
        local ago_str
        if ago < 60 then
            ago_str = _("just now")
        elseif ago < 3600 then
            ago_str = T(_("%1 min ago"), math.floor(ago / 60))
        elseif ago < 86400 then
            ago_str = T(_("%1 hours ago"), math.floor(ago / 3600))
        else
            ago_str = T(_("%1 days ago"), math.floor(ago / 86400))
        end

        status_text = T(_("Last sync: %1\nBooks: %2 · Sessions: %3"), ago_str, books, sessions)

        if queue_size > 0 then
            status_text = status_text .. "\n" .. T(_("\nQueued payloads: %1 (waiting for WiFi)"), queue_size)
        end
    end

    UIManager:show(InfoMessage:new{ text = status_text })
end

function BookStreakSync:_doSyncAll()
    if not self._settings:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Please set your username and password first.\n\nYou can find these in the BookStreak app under Settings > KOReader Sync."),
        })
        return
    end

    local result = self._sync:syncAll()
    if result.ok then
        if result.queued then
            UIManager:show(InfoMessage:new{
                text = _("No WiFi available. Reading data queued and will sync when you're online."),
            })
        elseif result.books_synced == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Already up to date. No new reading data to sync."),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Synced %1 books, %2 sessions, %3 annotations."),
                    result.books_synced, result.sessions_created, result.annotations_created),
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Sync failed: %1\n\nYour data has been queued and will retry automatically."), result.error or "unknown error"),
        })
    end
end

-- Lifecycle hooks

function BookStreakSync:onCloseDocument()
    if not self._settings:get("sync_on_close") then return end
    if not self._settings:isConfigured() then return end

    local book_path = self.ui.document and self.ui.document.file
    if not book_path then return end

    -- Run sync in background (don't block document close)
    UIManager:nextTick(function()
        local result = self._sync:syncBook(book_path)
        if result.ok and not result.queued and result.books_synced and result.books_synced > 0 then
            logger.info("BookStreak: Synced on document close")
        elseif result.queued then
            logger.info("BookStreak: Queued sync for", book_path)
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
