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
| `X-Access-Token` | Authenticates the request. On a single-user server this is `app.access_token` from the Hister config; with `user_handling` enabled the server matches it against **per-user** tokens instead, so the config value will not work and a personal token from the Hister profile is required. |

### Which endpoints actually check the token

`endpointRequiresAuth` skips the check for any endpoint marked `Public` when the server itself
runs in public mode. That covers `/search`, `/api/document` and `/api/stats`; `/api/config` is
`NoAuth` outright. On a public instance every one of those answers 200 for a completely wrong
token.

`/api/history` and `/api/batch` are `Public: false`, so they are always authenticated — which is
why "Test connection" probes `/api/history`. Testing against anything else reports success for a
token that then fails on the first sync.

Endpoints used: `/api/config`, `/search`, `/suggest`, `/api/document`, `/api/preview`,
`/api/history`, `/api/batch`, `/api/stats`, `/api/add`, `/api/add_pdf`, `/api/label`,
`/api/delete`, `/api/favicon`.

### How sync enumerates the index

Sync leads with a **match-all `/search`**, because it is the only call that enumerates the index
*and* returns each document's body (`include_text`). The handler does reject an empty query with
`400 {"error":"text query required for format=json"}`, but that check is literal and comes before
it looks at `match_all` — so the request carries `*` as its `text`, which the query builder strips
as a standalone wildcard and turns into a match-all query anyway. One request per 100 documents,
text included.

Three cheaper walks run behind it as backstops, because each fails differently: `/api/history` by
narrowing `date_to`, `/api/history` on an unbounded cursor (the only one that reaches documents
indexed without an `updated` field, since a date filter is a numeric range on that field), and one
`filter`ed request per domain from `/api/facets`. They return metadata only, so anything they and
only they reach is filled in afterwards by an enrichment pass.

Details worth knowing if you touch this code:

- **`/api/batch` and `/api/document` resolve a URL to a bleve document ID built from the caller's
  user id.** A token-authenticated client is user 0, so on an instance whose documents belong to a
  real user *every* such lookup answers 404 — for documents the same instance returns happily from
  a search. So a 404 from a batch `get` is checked against a `url:` search before the document is
  recorded as having no text.
- **Every string field comes back as `""` rather than being omitted.** `document.Document`
  declares them without `omitempty`, so `/api/history` — which populates only url, title and the
  timestamps — still sends `"text": ""`, `"domain": ""` and `"label": ""`. Read at face value,
  each metadata walk overwrites what the search pass cached, and a fully enumerated index ends up
  recorded as having no body text. An empty string from the server means "not supplied": `upsert`
  keeps what it already holds wherever a field arrives empty.
- **A search response's `history` block holds real results.** `doSearch` does not annotate a hit
  the user has opened for that query before; it moves it out of `documents` and re-emits it under
  `history`. Read only `documents` and you drop exactly the pages the user returns to most.
- **`/api/stats` counts index entries, not documents.** The server searches an alias over
  per-language indexes and keeps a document in more than one when its detected language changes,
  so its count can be well above the number of distinct URLs. `diagnose()` reports raw hits
  alongside distinct URLs so the two are never confused again.
- `/api/history`'s `last` parameter is the previous response's `page_key`, not a URL despite the
  name (a URL there is ignored and every page repeats the first), and it parses `date_from` as a
  Unix timestamp while `/search`'s query-string form wants `YYYY-MM-DD` (the JSON `query` object
  takes a timestamp).

## Around the app

Command-F puts the cursor in the search field, on macOS and on iPadOS with a hardware keyboard.
Command-R syncs.

The detail pane, when nothing is selected, carries a link to
[Hister's donation page](https://hister.org/support) and a short reference for the query language —
the fields, phrases, negation, alternation, wildcards and `sort:` directives the server supports,
with a note on which of them the offline cache can honour. There is a second donation link at the
top of Settings.

New labels are lowercased as they are created. Labels already on the server keep the case they were
given; rewriting those is the user's call, not a side effect of opening a document.

## Checking changes without a Mac

`Scripts/linux-check.sh` compiles and tests the portable part of `HisterKit` against a Linux Swift
toolchain — the client, the local index, sync and search, which is where nearly all the logic is.
Six files cannot build there (`KeychainStore` needs Security, `SpotlightIndexer` CoreSpotlight,
`DocumentExtractor` UIKit, `PageFetcher` the CoreFoundation charset APIs, `OutboxUploader` a
background `URLSession`, and `IngestService` depends on those); `KeychainStore` and `AppGroup` are
replaced by stubs with identical signatures so everything downstream still typechecks against the
API it meets on a Mac.

```sh
Scripts/linux-check.sh test    # or: build
```

Sources are copied into `Scripts/LinuxCheck` and patched there — `URLRequest` and `XMLParser` live
in separate modules on Linux — so the committed sources keep Apple-shaped imports. It is a fast
correctness check, not a substitute for building the app: nothing in `Apps/` is checkable this way.

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
