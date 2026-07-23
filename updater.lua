local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local meta = require("_meta")

local CHECK_INTERVAL = 86400 -- 24 hours

local Updater = {}

-- === Pure functions (tested standalone) ===

function Updater.parseVersion(tag_name)
    if not tag_name or tag_name == "" then return "" end
    return tag_name:gsub("^plugin%-v", ""):gsub("^v", "")
end

function Updater.isNewer(remote_version, local_version)
    if not remote_version or remote_version == "" then return false end
    if not local_version or local_version == "" then return false end

    local function split(v)
        local parts = {}
        for num in v:gmatch("(%d+)") do
            table.insert(parts, tonumber(num))
        end
        return parts
    end

    local r = split(remote_version)
    local l = split(local_version)
    if #r < 3 or #l < 3 then return false end

    for i = 1, 3 do
        if r[i] > l[i] then return true end
        if r[i] < l[i] then return false end
    end
    return false
end

function Updater.parseReleaseInfo(release)
    if not release or not release.tag_name then return nil end

    local version = Updater.parseVersion(release.tag_name)
    if version == "" then return nil end

    local download_url = nil
    if release.assets then
        for _, asset in ipairs(release.assets) do
            if asset.content_type == "application/zip" then
                download_url = asset.browser_download_url
                break
            end
        end
    end
    if not download_url then
        download_url = release.zipball_url
    end
    if not download_url then return nil end

    local notes = release.body or ""
    notes = notes:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1")
    if #notes > 200 then
        notes = notes:sub(1, 200) .. "..."
    end

    return {
        version = version,
        download_url = download_url,
        release_notes = notes,
    }
end

-- === Instance methods (require KOReader runtime) ===

function Updater:new(settings)
    local o = {}
    setmetatable(o, { __index = self })
    o._settings = settings
    o._update_url = meta.update_url
    o._local_version = meta.version or "0.0.0"
    return o
end

function Updater:currentVersion()
    return self._local_version
end

function Updater:checkIfDue()
    if not NetworkMgr:isOnline() then return end

    local last_check = self._settings:get("last_update_check") or 0
    if os.time() - last_check < CHECK_INTERVAL then return end

    self:_doCheck(false)
end

function Updater:checkNow()
    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{
            text = _("No WiFi connection. Please connect and try again."),
        })
        return
    end
    self:_doCheck(true)
end

function Updater:_doCheck(manual)
    self._settings:set("last_update_check", os.time())
    self._settings:flush()

    local release_info = self:_fetchLatestRelease()
    if not release_info then
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("Could not check for updates. Please try again later."),
            })
        end
        return
    end

    if not Updater.isNewer(release_info.version, self._local_version) then
        if manual then
            UIManager:show(InfoMessage:new{
                text = T(_("You're up to date (v%1)."), self._local_version),
            })
        end
        return
    end

    local skipped = self._settings:get("skipped_version")
    if not manual and skipped == release_info.version then
        return
    end

    self:_promptUpdate(release_info)
end

function Updater:_fetchLatestRelease()
    if not self._update_url or self._update_url == "" then return nil end

    local response_chunks = {}
    socketutil:set_timeout(5, 15)
    local code = socket.skip(1, https.request{
        url = self._update_url,
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["User-Agent"] = "bookstreak.koplugin/" .. self._local_version,
        },
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.warn("BookStreak updater: GitHub API returned", code)
        return nil
    end

    local ok, release = pcall(rapidjson.decode, table.concat(response_chunks))
    if not ok or not release then
        logger.warn("BookStreak updater: Failed to parse release JSON")
        return nil
    end

    return Updater.parseReleaseInfo(release)
end

function Updater:_promptUpdate(release_info)
    local notes = ""
    if release_info.release_notes and release_info.release_notes ~= "" then
        notes = "\n\n" .. release_info.release_notes
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("BookStreak Sync v%1 is available (you have v%2).%3"),
            release_info.version, self._local_version, notes),
        ok_text = _("Update"),
        ok_callback = function()
            self:_doUpdate(release_info)
        end,
        other_buttons = {{
            {
                text = T(_("Skip v%1"), release_info.version),
                callback = function()
                    self._settings:set("skipped_version", release_info.version)
                    self._settings:flush()
                end,
            },
        }},
    })
end

function Updater:_doUpdate(release_info)
    local msg = InfoMessage:new{ text = _("Downloading update..."), timeout = 120 }
    UIManager:show(msg)
    UIManager:forceRePaint()

    UIManager:nextTick(function()
        local ok, err = self:_downloadAndInstall(release_info)
        UIManager:close(msg)

        if ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Updated to v%1. Please restart KOReader to apply."), release_info.version),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Update failed: %1\n\nPlease try again later."), err or "unknown error"),
            })
        end
    end)
end

function Updater:_downloadAndInstall(release_info)
    local plugin_dir = self:_getPluginDir()
    if not plugin_dir then
        return false, "Could not determine plugin directory"
    end

    local zip_path = plugin_dir .. "_" .. release_info.version .. ".zip"
    local tmp_dir = plugin_dir .. "_" .. release_info.version .. "_tmp"
    local backup_dir = plugin_dir .. ".backup"

    -- Step 1: Download ZIP
    local ok, err = self:_downloadFile(release_info.download_url, zip_path)
    if not ok then
        os.remove(zip_path)
        return false, err
    end

    -- Step 2: Extract ZIP
    ok, err = self:_extractZip(zip_path, tmp_dir)
    if not ok then
        os.remove(zip_path)
        self:_rmdir(tmp_dir)
        return false, err
    end

    -- Step 3: Find the plugin folder inside extracted contents
    local extracted_plugin = self:_findPluginDir(tmp_dir)
    if not extracted_plugin then
        os.remove(zip_path)
        self:_rmdir(tmp_dir)
        return false, "Extracted archive does not contain a valid plugin"
    end

    -- Step 4: Validate
    ok, err = self:_validate(extracted_plugin, release_info.version)
    if not ok then
        os.remove(zip_path)
        self:_rmdir(tmp_dir)
        return false, err
    end

    -- Step 5: Swap — backup current, move new into place
    self:_rmdir(backup_dir)
    local rename_ok = os.rename(plugin_dir, backup_dir)
    if not rename_ok then
        os.remove(zip_path)
        self:_rmdir(tmp_dir)
        return false, "Failed to backup current plugin"
    end

    rename_ok = os.rename(extracted_plugin, plugin_dir)
    if not rename_ok then
        os.rename(backup_dir, plugin_dir)
        os.remove(zip_path)
        self:_rmdir(tmp_dir)
        return false, "Failed to install new plugin"
    end

    -- Step 6: Cleanup
    self:_rmdir(backup_dir)
    self:_rmdir(tmp_dir)
    os.remove(zip_path)

    logger.info("BookStreak updater: Updated to", release_info.version)
    return true
end

function Updater:_getPluginDir()
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local source_path = info.source:gsub("^@", "")
        return source_path:match("(.+/)"):gsub("/$", "")
    end
    return nil
end

function Updater:_downloadFile(url, dest_path)
    local file = io.open(dest_path, "wb")
    if not file then
        return false, "Cannot write to " .. dest_path
    end

    socketutil:set_timeout(30, 60)
    local code = socket.skip(1, https.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "bookstreak.koplugin/" .. self._local_version,
        },
        sink = ltn12.sink.file(file),
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        os.remove(dest_path)
        return false, "Download failed (HTTP " .. tostring(code) .. ")"
    end
    return true
end

function Updater:_extractZip(zip_path, dest_dir)
    self:_rmdir(dest_dir)
    os.execute("mkdir -p " .. self:_shellQuote(dest_dir))
    local cmd = "unzip -q -o " .. self:_shellQuote(zip_path) .. " -d " .. self:_shellQuote(dest_dir)
    local exit_code = os.execute(cmd)
    if exit_code ~= 0 and exit_code ~= true then
        return false, "Failed to extract ZIP archive"
    end
    return true
end

function Updater:_findPluginDir(tmp_dir)
    -- GitHub zipball wraps contents in a top-level directory like "user-repo-sha/"
    -- Look for a directory containing _meta.lua
    local meta_path = tmp_dir .. "/_meta.lua"
    local f = io.open(meta_path, "r")
    if f then
        f:close()
        return tmp_dir
    end

    -- Check one level deeper
    local handle = io.popen("ls -1 " .. self:_shellQuote(tmp_dir))
    if handle then
        for entry in handle:lines() do
            local candidate = tmp_dir .. "/" .. entry
            f = io.open(candidate .. "/_meta.lua", "r")
            if f then
                f:close()
                handle:close()
                return candidate
            end
        end
        handle:close()
    end
    return nil
end

function Updater:_validate(plugin_path, expected_version)
    local f = io.open(plugin_path .. "/_meta.lua", "r")
    if not f then
        return false, "Missing _meta.lua in update"
    end
    f:close()

    f = io.open(plugin_path .. "/main.lua", "r")
    if not f then
        return false, "Missing main.lua in update"
    end
    f:close()

    local meta_content = io.open(plugin_path .. "/_meta.lua", "r")
    if meta_content then
        local content = meta_content:read("*all")
        meta_content:close()
        local found_version = content:match('version%s*=%s*"([^"]+)"')
        if found_version and found_version ~= expected_version then
            return false, "Version mismatch: expected " .. expected_version .. ", got " .. found_version
        end
    end

    return true
end

function Updater:_rmdir(path)
    os.execute("rm -rf " .. self:_shellQuote(path))
end

function Updater:_shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

return Updater
