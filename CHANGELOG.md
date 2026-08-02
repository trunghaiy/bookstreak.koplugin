# Changelog



## 1.0.0 (2026-08-02)

- pull server-side changes on cold start, reduce auto-sync noise
- wip: save in-progress plugin sync.lua changes before subagent work
- Bump a dump version to fix metadata

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
