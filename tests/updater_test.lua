-- Mock KOReader modules so dofile works outside KOReader
local mock_module = {}
for _, mod in ipairs({
    "ssl.https", "ltn12", "socket", "socketutil", "rapidjson",
    "ui/widget/infomessage", "ui/widget/confirmbox", "ui/uimanager",
    "ui/network/manager", "logger", "gettext", "ffi/util", "_meta",
}) do
    package.preload[mod] = function()
        if mod == "gettext" then return function(s) return s end end
        if mod == "ffi/util" then return { template = function(s, ...) return s end } end
        if mod == "_meta" then return { version = "0.1.0", update_url = "https://example.com" } end
        if mod == "logger" then return { info = function() end, warn = function() end } end
        return mock_module
    end
end

local Updater = dofile("plugins/bookstreak.koplugin/updater.lua")

-- parseVersion tests
assert(Updater.parseVersion("plugin-v0.2.0") == "0.2.0", "strip plugin-v prefix")
assert(Updater.parseVersion("v0.2.0") == "0.2.0", "strip v prefix")
assert(Updater.parseVersion("0.2.0") == "0.2.0", "no prefix passthrough")
assert(Updater.parseVersion("plugin-v1.10.3") == "1.10.3", "multi-digit segments")
assert(Updater.parseVersion("") == "", "empty string")
assert(Updater.parseVersion(nil) == "", "nil input")

-- isNewer tests
assert(Updater.isNewer("0.2.0", "0.1.0") == true, "minor bump is newer")
assert(Updater.isNewer("1.0.0", "0.9.9") == true, "major bump is newer")
assert(Updater.isNewer("0.1.1", "0.1.0") == true, "patch bump is newer")
assert(Updater.isNewer("0.1.0", "0.1.0") == false, "equal is not newer")
assert(Updater.isNewer("0.1.0", "0.2.0") == false, "older is not newer")
assert(Updater.isNewer("0.1.10", "0.1.9") == true, "numeric not lexicographic")
assert(Updater.isNewer("0.1.0", "0.1.10") == false, "numeric not lexicographic reverse")
assert(Updater.isNewer("", "0.1.0") == false, "empty remote is not newer")
assert(Updater.isNewer("0.1.0", "") == false, "empty local treated safely")
assert(Updater.isNewer("garbage", "0.1.0") == false, "malformed remote is not newer")

-- parseReleaseInfo tests
local release_with_asset = {
    tag_name = "plugin-v0.2.0",
    body = "Bug fixes and improvements. This is a longer description that should be truncated.",
    assets = {
        {
            content_type = "application/zip",
            browser_download_url = "https://github.com/trunghaiy/bookstreak.koplugin/releases/download/plugin-v0.2.0/bookstreak.koplugin.zip",
        },
    },
}
local info = Updater.parseReleaseInfo(release_with_asset)
assert(info ~= nil, "parse succeeds")
assert(info.version == "0.2.0", "version extracted and cleaned")
assert(info.download_url:match("bookstreak.koplugin.zip$"), "download_url from asset")
assert(info.release_notes ~= nil, "release_notes present")

local release_no_asset = {
    tag_name = "v0.3.0",
    body = "Notes",
    assets = {},
    zipball_url = "https://api.github.com/repos/trunghaiy/bookstreak.koplugin/zipball/v0.3.0",
}
local info2 = Updater.parseReleaseInfo(release_no_asset)
assert(info2 ~= nil, "parse succeeds with zipball fallback")
assert(info2.version == "0.3.0", "version from bare v prefix")
assert(info2.download_url == release_no_asset.zipball_url, "falls back to zipball_url")

-- Markdown link stripping in release notes
local release_with_markdown = {
    tag_name = "plugin-v0.4.0",
    body = "See [CHANGELOG.md](https://github.com/trunghaiy/bookstreak.koplugin/blob/main/CHANGELOG.md) for details.",
    assets = {
        { content_type = "application/zip", browser_download_url = "https://example.com/plugin.zip" },
    },
}
local info3 = Updater.parseReleaseInfo(release_with_markdown)
assert(info3 ~= nil, "parse with markdown succeeds")
assert(info3.release_notes == "See CHANGELOG.md for details.", "markdown links stripped: got '" .. info3.release_notes .. "'")

assert(Updater.parseReleaseInfo(nil) == nil, "nil input returns nil")
assert(Updater.parseReleaseInfo({}) == nil, "empty table returns nil")
assert(Updater.parseReleaseInfo({ tag_name = "v0.1.0" }) == nil, "no assets and no zipball returns nil")

print("All updater tests passed!")
