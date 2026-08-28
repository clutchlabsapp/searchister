# App Store listing copy

Every field App Store Connect asks for, with its character limit and the count of what is written
here. Paste as-is or edit; the counts are what matters when editing.

Bundle ID `app.clutchlabs.searchister` · version 0.1.0 · iPhone, iPad and Mac · category Utilities.

---

## App name — 30 characters max

```
Searchister
```

*11 characters.*

There is room to spare, and the temptation is to spend it on keywords ("Searchister: Hister
Search"). Don't. Apple indexes the name and the subtitle separately from the keyword field, so
padding the name buys almost nothing and costs the app a clean thing to be called.

## Subtitle — 30 characters max

```
Your Hister index, offline
```

*26 characters.*

Alternatives at the same length, if you want to lead with a different idea:

| Subtitle | Chars | Leads with |
| --- | --- | --- |
| `Your Hister index, offline` | 26 | The offline copy |
| `Search your Hister from here` | 28 | The core action |
| `Hister in Spotlight and Siri` | 28 | System integration |
| `Self-hosted search, on device` | 29 | The self-hosting audience |

## Promotional text — 170 characters max

Editable without submitting a new build, so this is the field to use for news.

```
A native client for your own Hister server. Search your index from Spotlight, save pages from any app, and keep a searchable copy on device for when you're offline.
```

*164 characters.*

## Description — 4,000 characters max

```
Searchister is a native iPhone, iPad and Mac client for Hister, the self-hosted search engine for
everything you have read.

It needs a Hister server of your own. Searchister does not host anything, does not offer an
account, and has no index of its own to sell you — it is a window onto the one you already run.

WHAT IT DOES

Search your whole index. The full Hister query language works: narrow to a field with title:,
domain:, label: or text:, exclude terms with a minus, offer alternatives with (this|that), match
prefixes with an asterisk, and order results with sort:date or sort:visits. A reference for the
whole syntax sits in the app, so you do not have to remember it.

Find your pages in Spotlight. Searchister keeps a searchable copy of your index on device and
publishes it to Spotlight, so your saved pages turn up alongside everything else on your Mac or
iPhone — matched on their contents, not only their titles. Opening one takes you straight to the
page in your browser.

Work offline. The on-device copy holds every document's title, address, labels and the opening of
its text, so a search still returns something useful on a plane or a bad connection. Full text is
fetched and kept as you open documents.

Save from anywhere. The share sheet takes web pages, PDFs, Word documents, Markdown and plain
text. Pages are captured with their title and readable text rather than filed as a bare link.
Uploads are queued and retried, so sharing works with no signal and finishes later.

Ask Siri, or build a Shortcut. "Search Hister for…" and "Save to Hister" are available to Siri
and to the Shortcuts app, so your index can be part of an automation.

Label as you go. Add and remove labels on any document, and tap one to see everything else
carrying it.

One setup, every device. Your server address and access token are stored in the iCloud Keychain,
so entering them on one device sets up the rest.

WHAT IT DOES NOT DO

It does not phone home. There is no analytics, no account, no telemetry and no third-party SDK.
The only server it talks to is the one you point it at.

It does not need access to your files. Nothing outside the app's own container is read.

It does not work without a server. If you do not run Hister, this app has nothing to search.

ABOUT HISTER

Hister is an independent, AGPL-licensed project by Adam Tauber. It indexes the pages you visit and
the files you point it at, and it runs on your own hardware. Searchister is an unofficial client
and is not affiliated with the Hister project — if you get use out of it, the app has a link to
support the people who actually build it.

Learn more about Hister at hister.org.
```

*2,663 characters — comfortably inside the limit, with room to add.*

Two things in there are deliberate and worth keeping if you rewrite:

- **The server requirement is in the second paragraph**, not buried. Anyone who installs this
  without a Hister server has a broken app and leaves a one-star review saying so.
- **"WHAT IT DOES NOT DO" is a selling point to this audience.** People who self-host search
  engines care a great deal about what an app sends where, and saying it plainly is worth more
  than another feature paragraph.

## Keywords — 100 characters max

Comma-separated, no spaces after the commas — a space costs a character and buys nothing.

```
hister,self-hosted,bookmarks,archive,offline,spotlight,selfhosted,readlater,index,siri,web,notes
```

*96 characters.*

Do not repeat "Searchister" or words already in the subtitle; Apple indexes those fields
separately and duplicating them wastes the budget.

## URLs

| Field | Value | Required |
| --- | --- | --- |
| Support URL | Where you will answer questions — a GitHub issues page is fine | Yes |
| Marketing URL | Where you host `web/index.html` | No |
| Privacy Policy URL | Where you host the policy in `privacy.md` | Yes |

A Support URL is mandatory and must resolve to a working page at review time. A repository's
issues tab counts.

## What's New — 4,000 characters max

Not required for a first submission — leave it empty for 0.1.0 and use it from 0.2.0 on. Write it
as what changed for the person reading, not as a changelog of internals.

## Category

- **Primary: Utilities.** Matches `LSApplicationCategoryType` in the project
  (`public.app-category.utilities`), which is what the Mac build ships with. Keep the two aligned.
- **Secondary: Productivity.** Optional. Reference is the other candidate, but Utilities and
  Productivity between them describe this better.

## Age rating

4+. Nothing in the app generates content. Note that it displays whatever pages your own server has
indexed, but so does a web browser, and the rating reflects the app rather than the user's data.

## Copyright

```
2026 Clutch Labs
```

The copyright field takes the year and the legal entity — no "©", App Store Connect adds it.

## Encryption compliance

The app uses HTTPS and the Keychain and nothing else, which is exempt. Add this to
`Config/Searchister-Info.plist` to stop App Store Connect asking on every upload:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Confirm the exemption applies to you before claiming it — it is a legal declaration, not a
checkbox.
