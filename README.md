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

## How much of a page gets sent

Hister only extracts a title and body text when it is handed HTML — `Process` gates extraction on
`d.HTML != ""` and the server never fetches a URL itself — so the app sends markup. It does not
send all of it.

A hydrated single-page app keeps a second copy of its whole content as JSON inside `<script>`
tags, so `documentElement.outerHTML` for a busy Reddit thread runs to tens of megabytes for an
article of a few thousand words. `HTMLReducer` drops the elements Hister has no use for — script,
style, noscript, svg, template, iframe, canvas, map, picture — along with comments and inline
`data:` URIs, and caps the result at 600 KB. The share extension does the same reduction *in the
page*, before the string crosses the extension boundary, which is where it is cheapest.

If the markup is still too large after that, the page is sent as text instead: a web document
submitted with `text` and no `html` is accepted and indexed with that text, because `Process`
runs `finalizeDocument` either way and only skips the extraction step.

The 600 KB ceiling is well under Hister's own default of 40 MiB, for two reasons the app cannot
see from where it stands. The body is JSON, so every `"` and `\` in the markup costs two bytes.
And a reverse proxy in front of Hister enforces a limit of its own — nginx's
`client_max_body_size` defaults to 1 MiB — so a page Hister would accept can be refused before it
arrives. That is also why a 413 now reports whatever the responder said rather than naming
Hister's limit: the app does not know which of them answered.

## Re-reading one document

Pull down on a document (or press **Re-read**) and the app fetches the live page, hands the markup
to the server, and caches what comes back.

The client has to do the fetching. `Document.Process` gates extraction on `d.HTML != ""` and
Hister never fetches a URL itself, so submitting a bare link produces a document with a
placeholder title and no text — which is also why the share extension captures HTML rather than
sending the link. "Reindex this page" therefore means: fetch it here, `POST /api/add` with the
markup, then read back what the server made of it.

`DocumentRefresher` runs those as two stages, and the second happens whether or not the first
does. A page that has gone offline, sits behind a login, or is refused by the server's rules still
refreshes from the index — and the outcome says which of the two happened, so the UI never implies
a stale page was re-read when it was not. The fetcher is injected, which is what keeps the
sequencing testable; `DocumentRefresher+Web` supplies the real one.

Two things worth knowing: re-adding a document increments its visit count, because `/api/add`
always does (`addDocument(ctx, d, true, …)`) and Hister exposes no per-document reindex that
doesn't. And on a read-only server — the demo — the write is refused and the refresh degrades to
the server's copy rather than failing.

## The query language, and where the offline copy differs

Online, the query goes to the server untouched, so the whole of Hister's language works. Offline,
`FTSQueryTranslator` maps it onto FTS5, and the rule it follows is that a difference is *reported*
rather than quietly applied — a narrower result set presented as the whole answer is worse than no
answer.

- **Quoted means the whole thing.** `"privacy policy"` matches only where those words are adjacent
  and in that order; `privacy policy` matches documents holding both, anywhere, in any order, and
  is an AND rather than an OR. That holds inside a field too — `label:"read later"` is one phrase,
  which is the form `Labels.searchQuery(for:)` produces. `LocalIndexTests` pins all of this against
  a corpus where the two readings give different answers.
- **Honoured offline:** bare terms, quoted phrases, `-negation` (bare, field-scoped, and inside a
  field as `title:-tutorial`), alternation `(a|b)` including `domain:(a|b)`, trailing `*` prefixes,
  and the fields `title:`, `text:`, `url:`, `domain:`, `label:`, `language:`.
- **Reported, not applied:** `sort:`, `url_re:`, `type:`, `visits:`, `added:`, `updated:`,
  `user_id:`, `metadata.*`, and wildcards FTS5 cannot express (`*privacy*`, `f*o` — it has prefix
  queries and nothing else). The results list says which parts were dropped.
- **An unknown field is a search term**, because that is what the server does with it:
  `fieldFilterValue` finds no match and the token falls through to an ordinary term query. `site:`
  used to be treated as a filter here and as text there, so the same query meant two things.
- Ranking still differs slightly: for a multi-word query the server adds a phrase disjunct that
  boosts exact matches, which bm25 does not replicate. The matches are the same; the order can
  differ.

## Around the app

Command-F puts the cursor in the search field, on macOS and on iPadOS with a hardware keyboard.
Command-R syncs. **Shift-Command-F** opens find-in-page over the document being read, with
Command-G and Shift-Command-G stepping through matches and Escape closing the bar; there is a
button in the document's action row too, since iOS has no menu to discover a shortcut from.

Find-in-page is `TextFinder`, and it is deliberately *not* the query language: it matches
characters, case- and diacritic-insensitively, in the one document on screen. Applying stemming or
field filters to a find bar would surprise anyone who has used one anywhere else. The document body
is rendered as one view per paragraph rather than a single `Text`, because SwiftUI cannot scroll to
a range inside a `Text` and stepping through matches has to move the page.

The detail pane, when nothing is selected, carries a link to
[Hister's donation page](https://hister.org/support) and a short reference for the query language —
the fields, phrases, negation, alternation, wildcards and `sort:` directives the server supports,
with a note on which of them the offline cache can honour. There is a second donation link at the
top of Settings.

New labels are lowercased as they are created. Labels already on the server keep the case they were
given; rewriting those is the user's call, not a side effect of opening a document.

## The demo server

With nothing saved, `CredentialsStore.credentials()` returns `HisterCredentials.demo` —
`https://demo.hister.org`, with no access token — so a fresh install has an index to search rather
than an empty screen and a form. Saving a server replaces it; clearing one brings it back.

The empty token is not an oversight, it is the mechanism. Hister exempts only its `Public`
endpoints from authentication when the instance runs in public mode, and every write is outside
that set, so a token-less client is read-only *at the server*, not merely by convention here. What
it can reach: `/search`, `/api/config`, `/api/facets`, `/api/document`, `/api/stats`. What it
cannot: `/api/history`, `/api/batch`, and every write.

Three consequences worth knowing before changing any of this:

- **Sync still works, on the search pass alone.** The match-all `/search` enumeration carries each
  document's text, so it needs none of the authenticated endpoints. The three `/api/history`
  backstops are skipped when the server refuses them *and* the search pass reached something; if
  it reached nothing, that is a real failure and still throws.
- **Nothing is uploaded to it.** `OutboxUploader` and the share extension ask
  `storedCredentials()`, not `credentials()`, so a queued page waits for the user's own server
  rather than being pushed to a public one they did not choose. Reads use `credentials()`; writes
  use `storedCredentials()`, and that split is the whole safety property.
- **The UI says so, in four places** — the status bar, the empty state, the detail pane and
  Settings. Results from a stranger's server must never be mistaken for the user's own reading,
  and that is the only thing making this defensible rather than merely convenient.

## Why there is a Spotlight index extension

`Apps/SpotlightIndexExtension` exists to answer a question the app cannot hear.

Each cached row carries a `spotlight_synced_at` marker meaning "Spotlight already has the current
version of this". Nothing clears that marker when the *system* discards the index it was published
into — after an OS index rebuild, a device migration, or a restore from backup. The rows stay
marked, the app republishes nothing, and the entire index quietly stops appearing in Spotlight
until someone thinks to rebuild the cache by hand.

Registering an extension at `com.apple.spotlight.index` is the only way to be told it
happened. The system launches it with no app running and asks for either everything
(`reindexAll()`) or specific identifiers (`reindex(identifiers:)`); both are served entirely from
the shared database, so the extension needs neither the network nor the Keychain — its
entitlements are the App Group and nothing else.

Both paths are safe to be killed halfway. A full reindex clears every per-row marker *before*
publishing, and an identifier reindex marks rows only once Spotlight has accepted them, so
whatever the extension does not finish is left looking unpublished and the app's next ordinary
sync completes it.

## Checking changes without a Mac

`Scripts/linux-check.sh` compiles and tests the portable part of `HisterKit` against a Linux Swift
toolchain — the client, the local index, sync and search, which is where nearly all the logic is.
Nothing in `Apps/` is checkable this way, the index extension included. Six library files cannot
build there either (`KeychainStore` needs Security, `SpotlightIndexer` CoreSpotlight,
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

## Licence

Searchister is licensed under the [GNU Affero General Public License, version 3](LICENSE).

    Copyright (C) 2026 Clutch Labs

AGPL §13 is what separates this from the plain GPL: modify Searchister, let other people use the
modified version over a network, and you owe them its source. Searchister is a client rather than
a server, so in practice that clause rarely bites — but Hister is AGPL, and keeping both halves of
the project on the same terms is the point.

Hister itself is a separate project by Adam Tauber, licensed independently. Searchister speaks to
it over HTTP rather than linking it, so this repository is not a derivative work of Hister and was
never obliged to match its licence; doing so is a choice.

[GRDB.swift](https://github.com/groue/GRDB.swift), the only dependency, is MIT, which imposes
nothing this licence does not already satisfy.

If you intend to redistribute a build — through the App Store or anywhere else — read the
licensing note in `AppStore/README.md` first.
