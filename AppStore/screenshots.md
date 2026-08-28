# Screenshots: what to capture, and at what size

The project builds for iPhone, iPad and Mac (`TARGETED_DEVICE_FAMILY = "1,2"`, plus a native macOS
target — not Catalyst), so App Store Connect asks for three separate sets. There is no sharing
between them.

> **Check the sizes against App Store Connect before you spend an afternoon capturing.** Apple has
> changed these requirements repeatedly — most recently by cutting the number of required iPhone
> and iPad sizes down to one each — and the authoritative list is the one App Store Connect shows
> you on the day. The dimensions below are correct as far as I know; the *shot list* is the part
> of this document that will not go stale.

## Required sizes

### iPhone — required

| Display | Portrait | Landscape | Device to capture on |
| --- | --- | --- | --- |
| 6.9" | **1320 × 2868** | 2868 × 1320 | iPhone 16 Pro Max |
| 6.9" (alt) | **1290 × 2796** | 2796 × 1290 | iPhone 15 Pro Max / 16 Plus |

Either 6.9" size is accepted. You need **one** iPhone set; Apple scales it down for smaller
devices, so there is no longer any reason to capture 6.5" or 5.5" separately.

### iPad — required, because the app ships for iPad

| Display | Portrait | Landscape | Device to capture on |
| --- | --- | --- | --- |
| 13" | **2064 × 2752** | 2752 × 2064 | iPad Pro 13" (M4) |
| 13" (alt) | **2048 × 2732** | 2732 × 2048 | iPad Pro 12.9" (older) |

If you would rather not maintain an iPad set, the alternative is to drop iPad support —
`TARGETED_DEVICE_FAMILY = "1"` — not to skip the screenshots. An iPad-capable app with no iPad
screenshots is rejected.

### Mac — required

| Accepted sizes | Notes |
| --- | --- |
| **2880 × 1800** | Best choice: a Retina capture, 16:10 |
| 2560 × 1600 | Also Retina |
| 1440 × 900 | Non-Retina |
| 1280 × 800 | Non-Retina |

Mac screenshots must be exactly 16:10. A raw `⌘⇧4`-window capture will not be, so either capture
full screen at a 16:10 resolution or compose the window onto a 2880 × 1800 canvas. The window
should include its title bar and rounded corners.

### App icon

**1024 × 1024 PNG**, no alpha channel, no rounded corners, no drop shadow — Apple applies the mask
itself. Xcode generates this from `Apps/Searchister/Application.icon` when you archive, so it
should not need capturing separately.

### Counts and format

- 1–10 per set. Apple shows the first three in search results, so the first three carry the app.
- PNG or JPEG, RGB, no alpha, no transparency.
- The order you upload is the order shown. Lead with the strongest.

## The shot list

Eight shots per platform is more than enough; six is plenty. Ordered by how much they earn their
place — cut from the bottom.

| # | Shot | Why it earns the slot | Caption |
| --- | --- | --- | --- |
| 1 | **Spotlight showing Hister results** — the system Spotlight panel, a query typed, your saved pages among the results | This is the thing no other Hister client does, and it is instantly legible. Nothing else explains the app faster. | "Your index, in Spotlight" |
| 2 | **Search results with a hit highlighted** — a real query, several results, the matched terms emphasised in the snippets | Shows the app doing its main job, and shows it matching *body text* rather than titles | "Search everything you have read" |
| 3 | **The share sheet saving a page** — Safari open, share sheet up, Searchister selected | The second reason to install. Recognisable at thumbnail size. | "Save anything from any app" |
| 4 | **A document open, with labels** — detail pane, title, domain, body text, label chips | Shows there is a real reading surface, not just a result list | "Read it, label it, find it later" |
| 5 | **The query syntax reference** — the empty detail pane, or the panel scrolled to it | Signals depth to exactly the audience that self-hosts a search engine | "The full Hister query language" |
| 6 | **Siri or a Shortcut** — the Shortcuts app with "Search Hister" in a shortcut, or the Siri response | Rounds out system integration | "Ask Siri. Build a Shortcut." |
| 7 | **Settings, connected** — server set, "Documents cached 1,942 of 1,946" visible | Reassures on the "does this actually sync" question | "One setup, every device" |
| 8 | **Airplane mode, still searching** — control centre or the status bar showing offline, results on screen | The offline promise, made concrete | "Works with no signal" |

Per-platform notes:

- **iPhone**: portrait throughout. Shots 1–4 are the essential four. Spotlight on iPhone is pulled
  down from the home screen — capture it there, not in the app.
- **iPad**: landscape reads better, because the split view with sidebar and detail is the whole
  point of the iPad layout. Shot 4 is the strongest opener here.
- **Mac**: shot 1 should be macOS Spotlight (⌘Space) with results, which is the most persuasive
  frame in the whole set. Shot 2 should show the sidebar and detail pane together.

## Capturing them

**Simulator, for iPhone and iPad.** `⌘S` in Simulator saves a screenshot at exactly the device's
native resolution, which is the required size with no scaling. Command line equivalent:

```sh
xcrun simctl list devices                                    # find the device UDID
xcrun simctl io <UDID> screenshot AppStore/screenshots/ios-6.9-01-spotlight.png
```

Simulator will not give you a real Spotlight panel with your own data, so shot 1 has to come from
a device. Everything else can be staged in Simulator against a real server.

**Device, for Spotlight.** Capture on the phone, then AirDrop. A device screenshot is already at
native resolution.

**Mac.** `⌘⇧5` → *Capture Entire Screen*, on a display set to a 16:10 scaled resolution. Or capture
the window with `⌘⇧4` then Space, and compose it onto a 2880 × 1800 background.

## Before you capture

The content in the frames is what sells the app, and it is the easiest thing to get wrong.

- **Use a real index with real pages.** Lorem ipsum reads as a mock-up. Your own reading list is
  more convincing than anything you could invent.
- **Check every visible title and URL.** These go on the public internet. Anything private,
  embarrassing, or belonging to someone else has to go before you press the shutter — this is the
  single most common thing people regret about App Store screenshots.
- **No other companies' logos or trademarks** in a prominent position. Pages from a site are fine;
  a screenshot that reads as an advert for a brand you do not own is not.
- **Full status bar** — full signal, full battery, a sensible time. Simulator's status bar is
  already idealised; a device's is not.
- **Light mode for the set, or dark for the set.** Mixing them makes the set look unfinished.
  Dark suits this app, and suits the audience.

## The stubs in `screenshots/`

`screenshots/` holds an SVG placeholder per shot, each at the exact pixel dimensions of its target
size and labelled with what belongs in it. They are there to hold the slots and to let you check
the set reads well before capturing anything — they are **not** submittable. App Store Connect
takes PNG and JPEG only, and would reject a placeholder anyway.

Replace each one with a real capture of the same name and extension `.png`, then delete the SVG.
