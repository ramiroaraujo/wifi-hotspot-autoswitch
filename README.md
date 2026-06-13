# WifiAutoswitch

A macOS menu bar app that automatically switches your Mac between your **home
Wi-Fi** and your **iPhone Personal Hotspot**, so you stop burning cellular data
after you get home — and so you bail off a flaky home network back to 5G.

Two behaviors:

1. **Home in range → join it.** When a network you've marked as "home" is visible
   with strong-enough signal, the Mac leaves the hotspot and joins home.
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

Requirements: macOS 14+, Xcode Command Line Tools (`swiftc`).

```bash
./make-signing-cert.sh   # once: stable self-signed identity so the Location
                         # grant survives rebuilds (ad-hoc signing would revoke it)
./build.sh               # compiles + bundles + signs build/WifiAutoswitch.app
```

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
- **Auto-switch** — master on/off.
- **Verify internet works** — enable the captive-portal / dead-internet probe.
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
- **Switch to home now / Switch to hotspot now** — manual override.
- **Open log** — the decision log.

## How it decides (every ~30s, plus instantly on any Wi-Fi link/SSID change)

It only ever acts in the cases below — **a Wi-Fi network you picked yourself is left alone**:

- **On home, gone bad** — signal `< (minSignal − gap)` **or** the internet probe
  fails `netFailThreshold` times in a row → join the hotspot.
- **Home lost / disconnected** (you left and it dropped) with no home in range → join the hotspot.
- **On the hotspot (or disconnected) and a home comes into range** `≥ minSignal` → join home.
- **On any other network** → do nothing.

- A `cooldownSeconds` window prevents rapid flapping.
- **Connectivity backoff:** a network with no working internet is left and then avoided
  with **exponential backoff** — retry after 10 min, then 20, 40, 80 … capped at 6 h.
  Each failed retry doubles the wait; a passing check clears it. **Manually switching**
  (the "Switch to … now" items) resets all backoff.
- Internet is verified on the network you're on: **home every cycle** (unmetered); the
  **hotspot only ~every 10 min** to spare cellular data.
- Suppresses App Nap so it keeps monitoring with the lid closed (as long as the
  system stays awake, e.g. via Amphetamine).

## Config / data

`~/Library/Application Support/wifi-hotspot-autoswitch/`
- `config.json` — written when you change settings in the menu (defaults are baked
  in, so it works out of the box). Editable by hand; restart the app to reload.
- `state.json` — cooldown / quarantine bookkeeping.
- `scores.json` — time-decayed sighting score per SSID (7-day half-life) used to
  sort the menu pickers by recent familiarity (display only — never affects switching).
- `switch.log` — decisions and switches.

Defaults: `minSignal -68`, `hysteresisGap 6`, `cooldown 45s`, `poll 30s`,
`netFailThreshold 2`, `backoffBase 600s`, `backoffMax 6h`, `hotspotProbe 600s`.

## Dev / debugging

```bash
build/WifiAutoswitch.app/Contents/MacOS/wifi-autoswitch selftest   # pure decision-logic tests
open -a build/WifiAutoswitch.app --args read                       # writes a JSON snapshot to last-read.json
```
(Run `read` via `open`, not directly — a terminal child gets redacted names.)

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
