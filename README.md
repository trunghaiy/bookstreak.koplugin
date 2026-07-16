# BookStreak Sync for KOReader

Sync your KOReader reading sessions, highlights, and notes to [BookStreak](https://bookstreak.quest) automatically. Your e-reader's reading data appears on your phone without manual file transfer.

## Requirements

- [BookStreak](https://bookstreak.quest) account (free)
- KOReader on any supported device

## Installation

1. Download the latest `bookstreak.koplugin.zip` from [Releases](https://github.com/trunghaiy/bookstreak.koplugin/releases)
2. Unzip and copy the `bookstreak.koplugin` folder to your device's KOReader plugins directory:

| Device | Path |
|--------|------|
| Kobo | `/.adds/koreader/plugins/` |
| Kindle | `/koreader/plugins/` |
| PocketBook | `/applications/koreader/plugins/` |
| reMarkable | `/home/root/.adds/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |

3. Restart KOReader

## Setup

1. In the BookStreak app, go to **Settings > KOReader Sync** to find your username and password
2. In KOReader, open the hamburger menu (top bar) > **BookStreak Sync** > enter your **Username** and **Password**
3. That's it! Every time you close a book, your reading data syncs to BookStreak

## What Syncs

- Reading sessions with real timestamps and durations
- Page-level reading data (which pages, how long per page)
- Highlights and notes (from KOReader's annotation system)
- Book metadata (title, author, page count, series)

## How It Works

The plugin reads KOReader's `statistics.sqlite3` database (the same data that powers KOReader's built-in reading statistics) and sends new reading sessions to your BookStreak account. It only reads the database, never writes to it.

- **Automatic sync** when you close a book (configurable)
- **Offline support** -- if WiFi is unavailable, data is queued and sent when you reconnect
- **Incremental** -- only new data since the last sync is sent
- **Battery-friendly** -- never activates WiFi, never interrupts reading

## Privacy

- The plugin sends reading data only to your BookStreak account
- All communication uses HTTPS
- No telemetry, no tracking, no third-party services
- Your credentials are stored locally on your e-reader

## License

MIT
