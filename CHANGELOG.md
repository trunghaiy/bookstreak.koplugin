# Changelog




## 1.0.2 (2026-09-06)

- fix false "Finished" status on reflowable eBooks — use static book.pages instead of reflow-variable psd.total_pages for page count

## 1.0.1 (2026-08-28)

- clean series names at plugin source before sync
- Correct changelog for koreader plugin

## 1.0.0 (2026-08-02)

### Performance
- Build history map once per sync instead of scanning history.lua per book — O(1) lookups for annotations and ISBN extraction, significantly faster for large libraries

### Improvements
- Raise auto-sync page threshold from 10 to 25 turns to reduce session fragmentation (fewer duplicate sessions from incremental syncs during long reading sittings)
- Support CREngine string-format identifiers for ISBN extraction (e.g. `isbn:978...` in newline-separated strings)

### Refactoring
- Extract `_buildHistoryMap()` for shared md5→file_path resolution across annotations and ISBN lookup
- Extract `_extractIsbnFromProps()` for cleaner, testable ISBN parsing from doc_props

## 0.2.0 (2026-07-26)

- merge "Sync now" and "Sync status" into one menu item showing last sync time
- auto-sync reading progress every 10 page turns with 30-second debounce
- promote BookStreak Sync to tools menu (no longer buried in "More tools")
- fix dead onOpenDocument handler (renamed to onReaderReady)
- sync current book on device suspend
- track sync failures for display in menu label

## 0.1.3 (2026-07-23)

- strip markdown link syntax from update dialog release notes
- integrate updater into main menu with auto-check on launch
- implement full self-updater module with download, validate, swap
- add version/update_url to _meta.lua, dynamic version in api.lua
- add version comparison and tag parsing with tests
- three sync correctness fixes from beta triage
- auto-paginate sync for 50+ book libraries

## 0.1.0 (2026-07-16)

- Initial release
- Sync reading sessions on book close
- Sync highlights and notes from sidecar files
- Offline queue with automatic retry on WiFi reconnect
- Settings UI for credentials and sync preferences
