# App Store material

Everything needed to list Searchister, written against the app as it actually behaves rather than
as a wishlist. Nothing here is built or deployed by the Xcode project — it is copy and assets for
App Store Connect and for clutchlabs.app.

| File | What it is |
| --- | --- |
| `listing.md` | Every App Store Connect text field, with character counts |
| `app-review-notes.md` | The demo-server problem, notes to paste for the reviewer, and the guidelines this app brushes against |
| `privacy.md` | Privacy nutrition-label answers, and a policy to host |
| `screenshots.md` | What to capture, at what size, and how |
| `screenshots/` | 24 dimension-exact placeholders — 8 shots × iPhone, iPad, Mac |
| `web/index.html` | A one-page site for the app, built on clutchlabs.app's own stylesheet |

## The two things that will hold up a submission

**1. App Review needs a working Hister server.** The app does nothing without one, and a reviewer
who cannot use it rejects it under Guideline 2.1. Stand up a demo instance with a few hundred
innocuous public pages, put the URL and token in the review notes, and leave it running until the
app is approved. `app-review-notes.md` has the text to paste.

**2. Three screenshot sets, not one.** The project targets iPhone *and* iPad
(`TARGETED_DEVICE_FAMILY = "1,2"`) and ships a native Mac app, so App Store Connect asks for all
three independently. An iPad-capable app with no iPad screenshots is rejected. If you would rather
not maintain an iPad set, drop iPad support in the project — do not skip the screenshots.

## Deploying the web page

`web/index.html` links `/style.css` and reuses the site's own classes — `.container`, `.section`,
`.btn`, `.service-card`, `.checklist`, `.screenshots` — so it inherits changes made there rather
than forking the design. Drop it at `/searchister` on clutchlabs.app.

It expects three images that do not exist yet:

- `/img/searchister-icon.png` — the 1024×1024 app icon, exported from `Apps/Searchister/Application.icon`
- `/img/searchister-mac.png` — a Mac window capture
- `/img/searchister-ios.png` — an iPhone capture, ideally the Spotlight one

Opening the file straight off disk will look unstyled, because `/style.css` is an absolute path.
Serve it from the site root to preview it.

The page repeats the site's header and footer markup verbatim. If the real ones change, this copy
will drift — worth converting to whatever include mechanism the site uses, if it has one.

## Loose ends outside this folder

- **The repository is AGPL-3.0** (`LICENSE` at the root). Searchister is not a derivative work of
  Hister — it speaks HTTP rather than linking it — so this was a choice rather than an obligation.

  **The choice needs one more decision before the app ships.** Apple's terms restrict what someone
  who downloads an app may do with it: a limited number of devices, tied to their Apple Account.
  AGPLv3 §10 forbids imposing further restrictions on the rights the licence grants, and §7 is the
  only door out. This is the conflict that got VLC pulled from the App Store in 2011. It is not
  fatal here, because you hold the copyright and cannot infringe your own licence — but it does
  mean nobody *else* could ship this build, and a reviewer or a user reading `LICENSE` has no way
  to know that. The conventional fix is an additional permission under §7, a short App Store
  exception recorded in the README and in the covering notice, said out loud rather than left
  implicit. Ask and I will draft one.
- **`ITSAppUsesNonExemptEncryption` is not in `Config/Searchister-Info.plist`.** Adding it stops
  App Store Connect asking on every single upload. See `listing.md`.
- **Version is 0.1.0** with `CURRENT_PROJECT_VERSION = 1`. Both need bumping per upload; the build
  number has to increase every time even if the version does not.
- **The app has never been built here.** Everything in this folder describes behaviour verified by
  reading the code and by the tests that run under `Scripts/linux-check.sh`, not by using a
  shipping build. Check the screenshots match reality before you publish them.
