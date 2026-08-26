# Searchister

A macOS and iOS client for a personal, self-hosted [Hister](https://hister.org) instance.

- **Search** your index from the app, online or offline.
- **Share** URLs and documents (PDF, Word, Markdown, plain text) into it from any app's share sheet.
- **Spotlight** surfaces cached documents system-wide.
- **Siri and Shortcuts** can search the index and save things to it.

## Requirements

- iOS 18 / macOS 15 or later
- Xcode 16 or later
- A Hister instance reachable over HTTPS with `app.access_token` set in its config

## Getting started

```sh
echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Config/Local.xcconfig
open Searchister.xcodeproj
```

Register the App Group in your developer account, or change `HISTER_APP_GROUP` in
`Config/Shared.xcconfig` to one you own. It is expanded into the entitlements files and read back
at runtime through Info.plist, so nothing in the Swift sources needs editing.

Note the two identifiers are shaped differently per platform, which `Shared.xcconfig` handles:
iOS wants `group.app.clutchlabs.searchister`, macOS wants it team-prefixed as
`TEAMID.group.app.clutchlabs.searchister`. A macOS group without the prefix does not fail
loudly — the container just never resolves, and the first write to it is refused by the sandbox.

Then run the app, open **Settings**, enter your server URL and access token, and hit
**Test connection**.

The server URL and token are stored together as one item in your **iCloud Keychain**, so entering
them on one device sets up the rest. With iCloud Keychain switched off the item stays local and
everything still works on that device.

The app itself asks for no file access — only network access and its shared container. The share
extension additionally declares `files.user-selected.read-only`, which grants nothing until you
hand it a specific file through the share sheet.

`HisterKit` also builds and tests headlessly:

```sh
swift test --package-path HisterKit
```

## Project structure

`Searchister.xcodeproj` is committed and is the source of truth — there is no generator step.

`Apps/Searchister` and `Apps/ShareExtension` are **folder-backed groups**, so a Swift file dropped
into either folder is picked up on the next build with no project edit.

One multiplatform app target covers iOS and macOS (`SDKROOT = auto`); the source branches with
`#if os(...)` where the platforms genuinely differ. Entitlements are split per platform because
the sandbox keys belong on macOS only.

`HisterKit/` is a local Swift package referenced by the project. GRDB and ZIPFoundation are
declared in its manifest, so they resolve through the package rather than being listed in the
project file.

The app and extension targets ship in Swift 5 language mode with `SWIFT_STRICT_CONCURRENCY =
complete`, so concurrency issues surface as warnings rather than blocking the build; the package
itself is already Swift 6. Flip `SWIFT_VERSION` to `6.0` once the app layer is clean.

## How it talks to Hister

Every request carries two headers, and both are load-bearing:

| Header | Why |
| --- | --- |
| `Origin: hister://` | Hister's `withCSRF` middleware short-circuits for this origin. A native client has no session cookie to carry a CSRF token in, so without it every endpoint marked `CSRFRequired` — which is most write endpoints — answers 403. |
| `X-Access-Token` | Authenticates against `app.access_token`. |

Endpoints used: `/api/config`, `/search`, `/suggest`, `/api/document`, `/api/preview`,
`/api/history`, `/api/batch`, `/api/stats`, `/api/add`, `/api/add_pdf`, `/api/label`,
`/api/delete`, `/api/favicon`.

### How sync enumerates the index

`/search` cannot do it. Over HTTP it answers `400 {"error":"text query required for format=json"}`
for an empty query, and its match-all path is reachable only through the WebSocket upgrade the
same handler falls through to. So sync walks **`/api/history`**, which pages through every
document newest-first with no search term.

That feed carries metadata only — url, title, added, updated, add_count, favicon_key — so text
arrives in a second pass through **`/api/batch`** with `get` operations, 25 URLs at a time. Sync
is therefore two-stage: enumeration is fast and makes the app usable and Spotlight populated
straight away, then enrichment fills in excerpts in bounded, resumable batches, so a large index
fills in over several syncs rather than one very long one.

Two details worth knowing if you touch this code: `/api/history`'s `last` parameter is the
previous response's `page_key`, not a URL despite the name (a URL there is ignored and every page
repeats the first), and it parses `date_from` as a Unix timestamp while `/search` wants
`YYYY-MM-DD`.

## What the offline cache holds

Document metadata plus roughly the first 1,500 characters of each document's text, in a SQLite
FTS5 index. That is what offline search and Spotlight match against. Full text is fetched from
the server and cached per document as you open them.

This is a deliberate trade: mirroring the full text of a large personal index would be gigabytes
on a phone. It does mean **offline results are shallower than online ones** — matches come from
titles, addresses and the excerpt rather than the whole document. Likewise, a Spotlight hit is a
title/URL/excerpt match ranked by Spotlight's own scoring, not by Hister's.

The cache is built on first connection: entering a server URL and token in Settings starts the
seed straight away, and the status bar reports its progress. Pointing the app at a *different*
server discards the old cache first, since those documents belong to the other instance.

## How sharing works

A share is queued, not uploaded inline. The share extension writes the request body to a spool
file in the shared App Group container, records a row in the outbox, hands the upload to a
background `URLSession`, and dismisses.

That ordering is forced by the platform. A share extension is terminated as soon as its sheet
dismisses, so an in-process upload would be cut off mid-flight; and extensions run under a hard
memory limit that base64-encoding a large PDF in one shot would blow — so the `add_pdf` body is
streamed to disk in chunks instead. The same queue is what makes sharing while offline work: the
row simply waits, with exponential backoff, until the server is reachable.

Format routing:

| Shared item | Sent as |
| --- | --- |
| URL / web page | `POST /api/add` |
| PDF | `POST /api/add_pdf` — the server extracts the text and keeps the original |
| `.txt`, `.md` | `POST /api/add` with extracted text, `type = 2` |
| `.docx` | unzipped and parsed on device, then as above |

Documents extracted on device are sent with a `remote-file://<device>/<path>` URL, which is the
shape the server requires for `type = 2`. The host becomes the document's domain, so everything
shared from a given device groups under that device's name in Hister.

Scanned PDFs with no text layer are rejected by the server; that surfaces as an error on the
queued item rather than an empty document in your index.

## Layout

```
Searchister.xcodeproj/         committed project — open this
Config/                        xcconfig, Info.plists, entitlements
HisterKit/Sources/HisterKit/   shared package: client, cache, sync, ingest, Spotlight
HisterKit/Tests/               swift test --package-path HisterKit
Apps/Searchister/              SwiftUI app and App Intents
Apps/ShareExtension/           share sheet target
```
