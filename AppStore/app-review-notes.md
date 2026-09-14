# App Review

## The rejection this app is most likely to get

Searchister does nothing at all without a Hister server. A reviewer who installs it, opens it, and
finds an empty screen asking for a server address and an access token has an app that does not
work — and **Guideline 2.1 (App Completeness)** rejections for exactly this are routine.

You have to give them a working server. There is no way around it, and "it's self-hosted, the user
brings their own" is not an answer App Review accepts; they have to be able to see the app do the
thing the listing claims.

**Stand up a demo instance before you submit.** A small Hister server on a VPS, seeded with a few
hundred innocuous public pages — documentation, Wikipedia, blog posts — and left running for the
duration of review. Give it its own access token that you rotate afterwards.

## Notes for the reviewer

Paste this into the App Review Notes field, filling in the two blanks.

```
Searchister is a client for Hister (hister.org), a self-hosted search engine that users run on
their own hardware. The app has no backend of its own and no accounts; it talks only to the server
the user configures.

To review the app you will need a server, so we have set one up for you:

  Server URL:    https://______________________
  Access token:  ______________________

To get started:

1. Open the app. On iPhone, tap the gear icon; on Mac, use Searchister > Settings.
2. Enter the server URL and access token above, tap Test connection, then Save.
3. The app will sync a copy of the index. This takes about a minute for the demo index.
4. Search from the field at the top. Try: pascal, or domain:wikipedia.org, or sort:date

Features that need a moment to appear:

- SPOTLIGHT: after the first sync completes, the indexed pages become searchable in system
  Spotlight. Allow a minute or two after syncing, then search Spotlight for a word from one of the
  cached pages. Tapping a result opens the page in the default browser, which is intended — the
  result is the web page, not a screen in our app.
- SHARE EXTENSION: open a page in Safari, tap Share, choose Searchister. The page is queued and
  uploaded to the configured server.
- SIRI / SHORTCUTS: the Shortcuts app lists "Search Hister" and "Save to Hister" under Searchister.

The demo token is read-write, so anything you save during review will be added to the demo index.
Please do not save anything you would not want visible to us.

The app collects no analytics and contains no third-party SDKs. The only network destination is
the server entered in Settings.
```

## Other guidelines worth a look before submitting

**2.1 — no demo account.** Covered above. This is the one.

**4.2 — Minimum Functionality.** A thin client for a web service can be read as "a repackaged
website". Searchister has a reasonable defence — an offline index, Spotlight integration, a share
extension, App Intents — but the *listing and screenshots* have to make that visible. Lead the
screenshot set with Spotlight, not with a list of search results that could be a web page.

**5.2.1 — Intellectual Property.** The app is named after and built for a third-party project. You
do not have Hister's trademark. Keep the "unofficial client, not affiliated with the Hister
project" line in the description, and do not use Hister's logo or icon anywhere in the app,
listing, or screenshots.

**2.5.1 — Private API.** Nothing here uses one, but note that Core Spotlight indexing means the
app declares no unusual entitlements — worth mentioning if a reviewer queries the App Group.

**3.1.1 — In-App Purchase.** The app links to Hister's donation page. Apple's rules on donations:
links to charitable donations to a *third party* are permitted outside IAP, and a link that opens
in the browser is safer than an in-app flow. This is a link out to hister.org/support, which
should be fine — but it is a third-party project rather than a registered charity, so if review
queries it, be prepared either to argue it (a link to an open-source project's funding page, not a
purchase, unlocking nothing in the app) or to remove it for the first submission and add it later.

## Before you submit

- [ ] Demo server up, seeded, token in the review notes
- [ ] Support URL resolves
- [ ] Privacy Policy URL resolves
- [ ] Privacy nutrition labels filled in (see `privacy.md`)
- [ ] Screenshots for iPhone, iPad **and** Mac — all three are required
- [ ] `ITSAppUsesNonExemptEncryption` set, so upload does not stall on the question
- [x] A LICENSE file in the repository — AGPL-3.0; see the licensing note in `README.md`
- [ ] `DEVELOPMENT_TEAM` set in `Config/Local.xcconfig`, App Group and Keychain group registered
- [ ] Archive validates for both platforms
