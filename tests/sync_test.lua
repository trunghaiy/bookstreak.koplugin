-- Mock KOReader modules so dofile works outside KOReader
for _, mod in ipairs({
    "lua-ljsqlite3/init", "datastorage", "logger",
    "ui/network/manager", "docsettings", "device", "gettext",
}) do
    package.preload[mod] = function()
        if mod == "gettext" then return function(s) return s end end
        if mod == "logger" then return { info = function() end, warn = function() end } end
        return {}
    end
end

local Sync = dofile("plugins/bookstreak.koplugin/sync.lua")

-- Create a minimal Sync instance (only _groupByBook needs no deps)
local sync = Sync:new({}, {}, {}, {})

-- ============================================================
-- Test: _groupByBook must use book.pages, not psd.total_pages
-- ============================================================
-- Scenario: EPUB with 700 physical pages, user changed font size mid-read
-- causing psd.total_pages to drop to 330. Without the fix, the plugin
-- sends pages=330, server computes 321/330=97% → false "Finished".

local reflow_rows = {
    -- Early reading: reflow config had 700 pages
    { md5 = "abc123", title = "Big Book", authors = "Author", pages = 700, series = nil,
      page = 50,  start_time = 1000, duration = 60, total_pages = 700 },
    { md5 = "abc123", title = "Big Book", authors = "Author", pages = 700, series = nil,
      page = 100, start_time = 2000, duration = 60, total_pages = 700 },
    -- User changed font size → reflow to 330 total pages
    { md5 = "abc123", title = "Big Book", authors = "Author", pages = 700, series = nil,
      page = 200, start_time = 3000, duration = 60, total_pages = 330 },
    { md5 = "abc123", title = "Big Book", authors = "Author", pages = 700, series = nil,
      page = 321, start_time = 4000, duration = 60, total_pages = 330 },
}

local books, order = sync:_groupByBook(reflow_rows)
assert(books["abc123"].pages == 700,
    "FAIL: pages should be 700 (book.pages), got " .. tostring(books["abc123"].pages) ..
    " — psd.total_pages must not override book.pages")

print("PASS: reflow does not override book.pages")

-- ============================================================
-- Test: when book.pages is nil/0, fall back to psd.total_pages
-- ============================================================
-- Some KOReader installs store 0 in book.pages for certain formats.

local fallback_rows = {
    { md5 = "def456", title = "No Pages Book", authors = "Author", pages = 0, series = nil,
      page = 10, start_time = 1000, duration = 60, total_pages = 250 },
    { md5 = "def456", title = "No Pages Book", authors = "Author", pages = 0, series = nil,
      page = 20, start_time = 2000, duration = 60, total_pages = 250 },
}

local books2, order2 = sync:_groupByBook(fallback_rows)
assert(books2["def456"].pages == 250,
    "FAIL: when book.pages=0, should fall back to psd.total_pages 250, got " ..
    tostring(books2["def456"].pages))

print("PASS: fallback to psd.total_pages when book.pages is 0")

-- ============================================================
-- Test: when book.pages is nil, fall back to psd.total_pages
-- ============================================================

local nil_pages_rows = {
    { md5 = "ghi789", title = "Nil Pages Book", authors = "Author", pages = nil, series = nil,
      page = 5, start_time = 1000, duration = 60, total_pages = 180 },
}

local books3, order3 = sync:_groupByBook(nil_pages_rows)
assert(books3["ghi789"].pages == 180,
    "FAIL: when book.pages=nil, should fall back to psd.total_pages 180, got " ..
    tostring(books3["ghi789"].pages))

print("PASS: fallback to psd.total_pages when book.pages is nil")

-- ============================================================
-- Test: normal case — book.pages valid, no reflow mismatch
-- ============================================================

local normal_rows = {
    { md5 = "jkl012", title = "Normal Book", authors = "Author", pages = 300, series = nil,
      page = 150, start_time = 1000, duration = 60, total_pages = 300 },
}

local books4, order4 = sync:_groupByBook(normal_rows)
assert(books4["jkl012"].pages == 300,
    "FAIL: normal case should keep book.pages=300, got " .. tostring(books4["jkl012"].pages))

print("PASS: normal case preserves book.pages")

print("\nAll sync tests passed!")
