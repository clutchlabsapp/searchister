# Privacy

Two things here: the nutrition-label answers App Store Connect asks for, and a policy you can host
at the Privacy Policy URL, which is a required field.

## App privacy nutrition labels

The honest answer to every question is "no". Searchister has no backend, no accounts, no analytics
and no third-party SDKs; the only network destination is the server the user types in.

| Question | Answer |
| --- | --- |
| Does this app collect data? | **No** |

Answering "No" to that first question closes the whole section, and it is the correct answer here.
Before you commit to it, check that it stays correct:

- **No analytics or crash reporting SDK.** There is none in the project today. Adding Firebase,
  Sentry, TelemetryDeck or similar later means coming back and changing this answer.
- **Contacting your own server is not collection.** Data sent to the user's own Hister instance is
  not collected *by you*: you never see it, and Apple's definition is about data leaving the device
  to the developer or a third party. The policy below says this explicitly.
- **The iCloud Keychain is not collection either.** The server address and token sync through the
  user's own iCloud account, not through anything you operate.

If you ever add a hosted service — a sync relay, a managed Hister instance, anything with an
account — this answer changes and the app has to be resubmitted with it changed.

## Privacy policy

Host this and put the URL in App Store Connect. Plain HTML on any static host is fine; the
requirement is that it resolves and is specific to this app.

---

### Searchister Privacy Policy

*Last updated: [DATE]*

**The short version: Searchister collects nothing. There is no analytics, no account, and no
server of ours involved at any point.**

#### What Searchister sends, and where

Searchister talks to exactly one server: the Hister instance whose address you enter in Settings.
That server is yours. We do not operate it, cannot see it, and have no access to anything on it.

When you search, save a page, or sync, the app sends those requests to your server and nowhere
else. There is no intermediary, no relay and no fallback destination.

#### What Searchister stores on your device

- **A copy of your index** — the titles, addresses, labels and the opening portion of the text of
  the documents your server holds, in a database inside the app's own container. This is what
  makes search work offline. It is also published to Spotlight so your pages are findable from the
  system, which keeps a copy in Spotlight's own index on the device.
- **The full text of documents you open**, kept so they open instantly next time.
- **Your server address and access token**, in the Keychain. If you have iCloud Keychain turned on,
  these sync between your own Apple devices through your iCloud account — Apple's, not ours. If you
  have it turned off, they stay on the one device.
- **Pages waiting to upload**, when you save something with no connection. These are held until the
  upload succeeds, then deleted.

All of it is removed when you delete the app.

#### What Searchister does not do

- No analytics, telemetry, crash reporting or usage measurement of any kind.
- No advertising, and no advertising identifiers.
- No third-party SDKs.
- No accounts, and no registration.
- No access to your files, contacts, location, photos, camera or microphone.
- Nothing is sent to the developer. We receive no data about you or your use of the app,
  because there is nowhere for it to be sent.

#### Content you share into the app

When you share a web page, PDF, Word document, Markdown or text file to Searchister, its contents
are uploaded to your own Hister server so it can be indexed. That upload goes to your server
directly. A copy is held on the device until the upload succeeds.

#### Children

Searchister is not directed at children and collects no data from anyone, of any age.

#### Changes

If this policy changes, the version here is updated and the date at the top changes with it. If a
future version of the app ever collects anything, this policy will say so before that version
ships, and the App Store privacy labels will be updated to match.

#### Contact

[YOUR CONTACT EMAIL OR ISSUES URL]

---

## A note on the Spotlight index

Worth understanding even though it does not change the answers above: publishing to Core Spotlight
hands document titles and text to a system index outside your app's container. It stays on the
device, is not sent anywhere by the system, and is removed when the app is deleted — but it does
mean cached text is searchable from Spotlight by anyone who can unlock the device. That is the
feature working as intended, and the policy above says so plainly rather than leaving someone to
discover it.
