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

Register the App Group `group.app.clutchlabs.searchister` in your developer account, or change
`HISTER_APP_GROUP` in `Config/Shared.xcconfig` to one you own. That one setting is expanded into
the entitlements files and read back at runtime through Info.plist, so nothing in the Swift
sources needs editing.

Then run the app, open **Settings**, enter your server URL and access token, and hit
**Test connection**.

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
`/api/history`, `/api/stats`, `/api/add`, `/api/add_pdf`, `/api/label`, `/api/delete`,
`/api/favicon`.

## What the offline cache holds

Document metadata plus roughly the first 1,500 characters of each document's text, in a SQLite
FTS5 index. That is what offline search and Spotlight match against. Full text is fetched from
the server and cached per document as you open them.

This is a deliberate trade: mirroring the full text of a large personal index would be gigabytes
on a phone. It does mean **offline results are shallower than online ones**, and the app says so
with a banner rather than pretending to parity. Likewise, a Spotlight hit is a title/URL/excerpt
match ranked by Spotlight's own scoring, not by Hister's.

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
