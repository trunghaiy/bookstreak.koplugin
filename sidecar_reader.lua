local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local SidecarReader = {}

function SidecarReader:new()
    local o = {}
    setmetatable(o, { __index = self })
    return o
end

function SidecarReader:_getSidecarPath(book_path)
    local ext = book_path:match("%.([^%.]+)$")
    if not ext then return nil end
    local DocSettings = require("docsettings")
    local sdr_dir = DocSettings:getSidecarDir(book_path)
    if not sdr_dir or sdr_dir == "" then return nil end
    local meta_file = sdr_dir .. "/metadata." .. ext .. ".lua"
    return meta_file, sdr_dir
end

function SidecarReader:_parseTimestamp(datetime_str)
    -- Parse "YYYY-MM-DD HH:MM:SS" to Unix timestamp
    if not datetime_str then return 0 end
    local y, m, d, h, min, s = datetime_str:match(
        "(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)"
    )
    if not y then return 0 end
    return os.time({
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(h), min = tonumber(min), sec = tonumber(s),
    })
end

function SidecarReader:getAnnotations(book_path, since_timestamp)
    local meta_path = self:_getSidecarPath(book_path)
    if not meta_path then return {} end

    -- Check file exists
    local attr = lfs.attributes(meta_path)
    if not attr then return {} end

    -- Load the Lua table (standard KOReader pattern)
    local ok, metadata = pcall(dofile, meta_path)
    if not ok or type(metadata) ~= "table" then
        logger.warn("BookStreak: Failed to parse sidecar:", meta_path)
        return {}
    end

    local annotations_list = metadata.annotations
    if not annotations_list or type(annotations_list) ~= "table" then
        return {}
    end

    local results = {}
    for _, ann in ipairs(annotations_list) do
        local ts = self:_parseTimestamp(ann.datetime)
        if ts > since_timestamp then
            local drawer = ann.drawer
            local note = ann.note
            local text = ann.text

            -- Skip plain bookmarks (no highlight, no note)
            if not drawer and not note then
                goto continue
            end

            local entry_type
            if drawer then
                entry_type = "highlight"
            else
                entry_type = "note"
            end

            local body_text = text or ""
            if entry_type == "note" and note then
                body_text = note
            end

            if body_text == "" and (not note or note == "") then
                goto continue
            end

            table.insert(results, {
                type = entry_type,
                text = text or "",
                note = note,
                chapter = ann.chapter,
                page = ann.pageno,
                color = ann.color,
                created_at = ann.datetime,
            })
        end
        ::continue::
    end

    return results
end

return SidecarReader
