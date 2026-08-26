# Searchister

A macOS and iOS client for a personal, self-hosted [Hister](https://hister.org) instance.

- **Search** your index from the app, online or offline.
- **Share** URLs and documents (PDF, Word, Markdown, plain text) into it from any app's share sheet.
- **Spotlight** surfaces cached documents system-wide.
- **Siri and Shortcuts** can search the index and save things to it.

## Requirements

- iOS 18 / macOS 15 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Hister instance reachable over HTTPS with `app.access_token` set in its config

## Getting started

```sh
./Scripts/bootstrap.sh          # generates Searchister.xcodeproj
echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Scripts/Local.xcconfig
open Searchister.xcodeproj
```

Register the App Group `group.app.clutchlabs.searchister` in your developer account (or change
`HISTER_APP_GROUP` in `Scripts/Shared.xcconfig` to one you own — it is read at runtime from
Info.plist, so no source changes are needed).

Then run the app, open **Settings**, enter your server URL and access token, and hit
**Test connection**.

The package itself builds and tests without Xcode:

```sh
swift build
swift test
```

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
Sources/HisterKit/     shared package: client, cache, sync, ingest, Spotlight
Apps/Searchister/      SwiftUI app and App Intents
Apps/ShareExtension/   share sheet target
Tests/HisterKitTests/  swift test — no Xcode required
```
