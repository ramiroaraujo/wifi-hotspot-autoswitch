# WifiAutoswitch

A macOS menu bar app that automatically switches your Mac between your **home
Wi-Fi** and your **iPhone Personal Hotspot**, so you stop burning cellular data
after you get home — and so you bail off a flaky home network back to 5G.

Two behaviors:

1. **Home in range → join it.** When a network you've marked as "home" stays
   visible with strong-enough signal, the Mac leaves the hotspot and joins home.
2. **Home gone bad → back to hotspot.** While on home Wi-Fi, if the signal drops
   below your threshold *or the connection stops actually reaching the internet*
   (captive portal / "full bars, no internet"), it switches back to the hotspot.

## The one hard thing (already solved)

On macOS Sonoma/Sequoia, any process that lacks Location Services gets
`<redacted>` instead of Wi-Fi network names — so a plain shell script is blind and
can't tell whether home is in range. Reading real names requires **both**:

1. The binary must run as its **own responsible process** — launched by
   LaunchServices / a login item / `launchd`, **never** as a child of a terminal
   (a terminal child inherits the terminal's unauthorized location status and stays
   redacted, even if the binary itself was granted permission).
2. A **live `CLLocationManager` session** (`startUpdatingLocation`), not merely
   authorization status.

A menu bar app satisfies both. That's why this is a real app, not a script.

## Build & install

Requirements: macOS 14+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml` (no
`.xcodeproj` to hand-maintain), and the app version comes from the latest git tag.

```bash
./make-signing-cert.sh   # once: stable self-signed identity so the Location
                         # grant survives rebuilds (ad-hoc signing would revoke it)
./build.sh               # xcodegen generate → xcodebuild → sign → build/WifiAutoswitch.app
```

To work in Xcode instead: `xcodegen generate && open WifiAutoswitch.xcodeproj`.

Install and grant permission:

```bash
cp -R build/WifiAutoswitch.app /Applications/   # recommended (stable location)
open /Applications/WifiAutoswitch.app
```

On first launch a **Location Services prompt** appears — click **Allow**. (If it
doesn't appear, enable *WifiAutoswitch* under System Settings → Privacy & Security
→ Location Services.) The menu bar icon is `((•))` — distinct from the system
Wi-Fi fan. A ⚠︎ triangle icon means location isn't granted yet.

Then open the menu and turn on **Launch at login**.

## Using it (the menu)

- **Status line** — current network, signal, and internet check (`internet ✓/✗`).
- **Wake idle hotspot** — opt-in (default off). An *idle* iPhone Personal Hotspot
  isn't broadcasting Wi-Fi (it's advertised over Bluetooth/Continuity), so `networksetup`
  can't join it. With this on, when a hotspot join fails because the phone is asleep, the
  app wakes + joins it by pressing its row in the Control Center Wi-Fi menu for you — the
  same thing you'd do by hand. Enabling it prompts for **Accessibility** permission
  (System Settings → Privacy & Security → Accessibility). See *Waking an idle hotspot* below.
- **Minimum home signal** — slider (Strict ⟷ Lenient). This is how strong home
  Wi-Fi must be before the app uses or keeps it. Slide toward **Strict** if a
  network shows good bars but performs badly — the app will then demand a stronger
  signal before trusting it. A hysteresis gap is kept automatically so it won't flap.
- **Home networks** — check *all* the SSIDs that count as "home" (multiple places
  supported; it joins whichever is in range). Configured ones stay listed even when
  out of range, and **Add network by name…** lets you pre-register a network you're
  not currently near (e.g. the office). Lists are sorted **most-seen-first**.
- **Hotspot network** — pick which SSID is your iPhone hotspot. Filtered to
  phone-like names; everything else lives under **Other networks ▸**.
- **Switch to home now / Switch to hotspot now** — manual override. Switching to the
  hotspot **pins** it: auto-switch is paused and won't pull you back to home until you
  resume it (below), switch elsewhere yourself, or the hotspot loses internet. Switching
  to home resumes normal auto-switching. A manual switch from the **system Wi-Fi menu**
  is detected and respected the same way. If a switch fails (e.g. an asleep iPhone
  hotspot that can't be woken), you get an alert instead of silence.
- **Resume auto-switch** — appears only while paused; clears the manual pin.
- **Open log** — the decision log.

## How it decides (every ~30s, plus instantly on any Wi-Fi link/SSID change)

It only ever acts in the cases below — **a Wi-Fi network you picked yourself is left alone**:

- **On home, gone bad** — signal `< (minSignal − gap)` **or** the internet probe
  fails `netFailThreshold` times in a row → join the hotspot.
- **Home lost / disconnected** (you left and it dropped) with no home in range → join the hotspot.
- **On the hotspot and a home comes into range** `≥ minSignal` → keep checking it,
  and join home only after the same SSID stays strong across the confirmation window.
- **Disconnected and a home is in range** `≥ minSignal` → join home.
- **On any other network** → do nothing.
- **You manually switched** (the menu items or the system Wi-Fi menu) → that choice is
  *pinned* and the join-home rule above is suppressed, so you're not yanked back. The pin
  is dropped when you switch to home, resume auto-switch, or the pinned network is found
  to have no working internet (then it still rescues you).

- A `cooldownSeconds` window prevents rapid flapping.
- **Strong-home confirmation:** one good scan is not enough to leave the hotspot.
  By default, the same home SSID must be seen at least 3 times while staying above
  the minimum signal for 120 seconds. If it disappears or dips below the threshold,
  the confirmation starts over.
- **Connectivity backoff:** a network with no working internet is left and then avoided
  with **exponential backoff** — retry after 10 min, then 20, 40, 80 … capped at 6 h.
  Each failed retry doubles the wait; a passing check clears it. **Manually switching**
  (the "Switch to … now" items) resets all backoff.
- **Hotspot rescue retry:** when home Wi-Fi is weak or offline, hotspot failures are
  retried on a shorter 120-second cadence even if the regular hotspot backoff has grown
  much longer. This avoids getting stuck on bad home Wi-Fi after a transient Instant
  Hotspot discovery failure.
- Internet is verified **only on home Wi-Fi**, every cycle (it's unmetered). The hotspot
  is never probed — it's cellular, and we assume it works once joined, to spare your data.
- Suppresses App Nap so it keeps monitoring with the lid closed (as long as the
  system stays awake, e.g. via Amphetamine).

## Waking an idle hotspot (the hard problem, part two)

`networksetup` can only join Wi-Fi networks that appear in a scan. An **idle** iPhone
Personal Hotspot doesn't broadcast a beacon — macOS only knows it exists from a
Bluetooth/Continuity advertisement, and surfaces it under "Personal Hotspot" in the
Wi-Fi menu. Joining it there sends a Bluetooth command that powers the hotspot on.

The private CoreWLAN API the system uses for this
(`CWWiFiClient.startBrowsingForTetherDevices…`, `CWInterface.connectToTetherDevice…`)
is gated behind AMFI-restricted entitlements (`com.apple.wifi.tether.browse` /
`…connect`). A self-signed app that embeds them is **killed at launch** by AMFI, and
there's no way around that short of disabling SIP.

So **Wake idle hotspot** instead drives the system's *own* Control Center Wi-Fi popover
through the Accessibility API: it finds the hotspot row (`AXIdentifier` =
`wifi-network-<SSID>`) and presses it — identical to a manual click, including the
Bluetooth wake. It's used only as a fallback, when a direct `networksetup` join fails
because the phone is asleep. Trade-offs: it needs a one-time Accessibility grant, briefly
flashes the Wi-Fi menu, and relies on Control Center's layout (could need a tweak across
major macOS releases). It is off by default.

## Config / data

`~/Library/Application Support/wifi-hotspot-autoswitch/`
- `config.json` — written when you change settings in the menu (defaults are baked
  in, so it works out of the box). Editable by hand; restart the app to reload.
- `state.json` — cooldown / connectivity-backoff bookkeeping.
- `scores.json` — time-decayed sighting score per SSID (7-day half-life) used to
  sort the menu pickers by recent familiarity (display only — never affects switching).
- `switch.log` — decisions and switches.

Defaults: `minSignal -68`, `hysteresisGap 6`, `cooldown 45s`, `poll 30s`,
`netFailThreshold 2`, `weakThreshold 3`, `homeJoinConfirmations 3`,
`homeJoinWindowSeconds 120`, `hotspotRescueRetrySeconds 120`,
`backoffBase 600s`, `backoffMax 6h`.

## Dev / debugging

```bash
build/WifiAutoswitch.app/Contents/MacOS/WifiAutoswitch selftest   # pure decision-logic tests
open -a build/WifiAutoswitch.app --args read                      # writes a JSON snapshot to last-read.json
```
(Run `read` via `open`, not directly — a terminal child gets redacted names.)

**Releasing:** `git tag v0.1.2 && ./build.sh` — the tag drives `CFBundleShortVersionString`
(build number = commit count); no version is hand-edited.

**App icon:** replace `icon/AppIcon-source.png` (1024²) and run `./icon/make-appiconset.sh`
to regenerate the `Assets.xcassets` AppIcon set.

Rebuilding keeps the Location grant because signing uses the stable
`WifiAutoswitch Self-Signed` identity (Designated Requirement is identifier + cert,
not cdhash). Regenerating the cert would require re-granting.

## Uninstall

```bash
./uninstall.sh
```

## Notes / not-done

- The captive-portal probe uses Apple's `captive.apple.com` endpoint.
- Joining an **idle** iPhone hotspot relies on Instant Hotspot (Bluetooth wake) via
  `networksetup`. Joining home and joining an *active* hotspot are verified; waking a
  fully-idle hotspot while away is the one thing left to field-test — keep the phone
  with you and Bluetooth on. If it won't wake, toggling "Allow Others to Join" /
  "Maximize Compatibility" on the phone can help.
