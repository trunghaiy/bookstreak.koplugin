local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local DEFAULT_SERVER = "https://awttxrscondikadvmgua.supabase.co/functions/v1/koreader-sync"

local Settings = {}

function Settings.normalizeSyncUrl(url)
    if not url or url == "" then return DEFAULT_SERVER end
    url = url:gsub("/$", "")
    if url:match("/functions/v1/kosync$") then
        return url:gsub("/kosync$", "/koreader-sync")
    end
    if not url:match("/koreader%-sync$") then
        return url .. "/koreader-sync"
    end
    return url
end

function Settings:new()
    local o = {}
    setmetatable(o, { __index = self })
    o._settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/bookstreak.lua"
    )
    return o
end

function Settings:get(key)
    local defaults = {
        server_url = DEFAULT_SERVER,
        sync_on_close = true,
        sync_annotations = true,
        last_sync_time = 0,
        last_sync_books = 0,
        last_sync_sessions = 0,
        last_update_check = 0,
        skipped_version = "",
    }
    local val = self._settings:readSetting(key)
    if val ~= nil then return val end
    return defaults[key]
end

function Settings:set(key, value)
    self._settings:saveSetting(key, value)
end

function Settings:flush()
    self._settings:flush()
end

function Settings:isConfigured()
    local u = self:get("username")
    local p = self:get("password")
    return u ~= nil and u ~= "" and p ~= nil and p ~= ""
end

function Settings:getServerUrl()
    return Settings.normalizeSyncUrl(self:get("server_url"))
end

function Settings:getUsername()
    return self:get("username") or ""
end

function Settings:getPassword()
    return self:get("password") or ""
end

function Settings:getLastSyncTime()
    return self:get("last_sync_time") or 0
end

function Settings:recordSync(server_time, books, sessions)
    self:set("last_sync_time", server_time)
    self:set("last_sync_books", books)
    self:set("last_sync_sessions", sessions)
    self:flush()
end

return Settings
