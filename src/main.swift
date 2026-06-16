import Foundation
import CoreWLAN
import CoreLocation
import AppKit
import ServiceManagement
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// WifiAutoswitch — macOS menu bar app that auto-switches between home Wi-Fi and
// the iPhone Personal Hotspot.
//
// THE HARD PART (solved): reading un-redacted SSIDs on Sequoia requires the
// binary to (1) run as its OWN responsible process — launched via LaunchServices
// / login item, never as a terminal child — and (2) hold a LIVE CLLocationManager
// session, not merely authorization. A menu bar app satisfies both. See README.
//
// Modes (argv[1]): default = run the menu bar app. "read" prints a JSON snapshot,
// "selftest" runs pure-logic assertions. Both are for development/debugging.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Config

struct Config: Codable {
    var interface = "en0"
    var homeSSIDs: [String] = []           // set via the menu (or config.json)
    var hotspotSSID: String? = nil         // set via the menu (or config.json)
    var minSignal = -68         // slider: home must be at least this strong to join/keep
    var hysteresisGap = 6       // drop = minSignal - gap (abandon home only when clearly worse)
    var cooldownSeconds: Double = 45
    var pollSeconds: Double = 30
    var enabled = true
    var netFailThreshold = 2    // consecutive failed internet probes (on home Wi-Fi) before bailing
    var weakThreshold = 3       // consecutive weak-signal reads before leaving home (anti-flap)
    var backoffBaseSeconds: Double = 600      // first retry wait after a dead-internet switch (10 min)
    var backoffMaxSeconds: Double = 6 * 3600  // cap on the exponential backoff (6 h)
    var hotspotWakeViaUI = false              // wake an idle Instant Hotspot by clicking it in the Control Center Wi-Fi menu (needs Accessibility)

    var rssiPrefer: Int { minSignal }
    var rssiDrop: Int { minSignal - hysteresisGap }

    enum CodingKeys: String, CodingKey {
        case interface, homeSSIDs, hotspotSSID, minSignal, hysteresisGap, cooldownSeconds, pollSeconds,
             enabled, netFailThreshold, weakThreshold,
             backoffBaseSeconds, backoffMaxSeconds, hotspotWakeViaUI
    }

    static func dir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/wifi-hotspot-autoswitch", isDirectory: true)
    }
    static func path() -> URL { dir().appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let d = try? Data(contentsOf: path()),
              let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }
    func save() {
        try? FileManager.default.createDirectory(at: Config.dir(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Config.path()) }
    }
}

// Lenient decode: any missing key (e.g. a config.json from an older build) falls back
// to its default, so evolving the schema never wipes the user's existing settings.
extension Config {
    init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        interface = (try? c.decode(String.self, forKey: .interface)) ?? interface
        homeSSIDs = (try? c.decode([String].self, forKey: .homeSSIDs)) ?? homeSSIDs
        hotspotSSID = (try? c.decode(String.self, forKey: .hotspotSSID)) ?? hotspotSSID
        minSignal = (try? c.decode(Int.self, forKey: .minSignal)) ?? minSignal
        hysteresisGap = (try? c.decode(Int.self, forKey: .hysteresisGap)) ?? hysteresisGap
        cooldownSeconds = (try? c.decode(Double.self, forKey: .cooldownSeconds)) ?? cooldownSeconds
        pollSeconds = (try? c.decode(Double.self, forKey: .pollSeconds)) ?? pollSeconds
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? enabled
        netFailThreshold = (try? c.decode(Int.self, forKey: .netFailThreshold)) ?? netFailThreshold
        weakThreshold = (try? c.decode(Int.self, forKey: .weakThreshold)) ?? weakThreshold
        backoffBaseSeconds = (try? c.decode(Double.self, forKey: .backoffBaseSeconds)) ?? backoffBaseSeconds
        backoffMaxSeconds = (try? c.decode(Double.self, forKey: .backoffMaxSeconds)) ?? backoffMaxSeconds
        hotspotWakeViaUI = (try? c.decode(Bool.self, forKey: .hotspotWakeViaUI)) ?? hotspotWakeViaUI
    }
}

// MARK: - Persisted state (anti-flap)

struct Backoff: Codable { var fails: Int; var until: Double }

struct PersistedState: Codable {
    var lastSwitchEpoch: Double = 0
    var lastTarget = ""
    var backoff: [String: Backoff] = [:]   // SSID → exponential backoff after a dead-internet switch
    var pinnedSSID: String? = nil          // a network the user manually chose → auto-switch leaves it alone

    static func path() -> URL { Config.dir().appendingPathComponent("state.json") }
    static func load() -> PersistedState {
        guard let d = try? Data(contentsOf: path()),
              let s = try? JSONDecoder().decode(PersistedState.self, from: d) else { return PersistedState() }
        return s
    }
    func save() {
        try? FileManager.default.createDirectory(at: Config.dir(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.path()) }
    }
}

// MARK: - Network frequency scores

/// A time-decayed sighting score per SSID (7-day half-life): networks seen recently
/// and often float to the top of the menu pickers, while places you've stopped
/// visiting fade away. Used ONLY for menu sorting — never affects switching.
struct NetworkScores: Codable {
    struct Entry: Codable { var score: Double; var lastUpdate: Double }
    var entries: [String: Entry] = [:]
    static let halfLife: Double = 7 * 86_400  // seconds

    static func path() -> URL { Config.dir().appendingPathComponent("scores.json") }
    static func load() -> NetworkScores {
        guard let d = try? Data(contentsOf: path()),
              let s = try? JSONDecoder().decode(NetworkScores.self, from: d) else { return NetworkScores() }
        return s
    }
    private static func decayed(_ e: Entry, _ now: Double) -> Double {
        e.score * pow(0.5, max(0, now - e.lastUpdate) / halfLife)
    }
    mutating func bump(_ ssids: [String], now: Double) {
        for s in ssids where !s.isEmpty {
            let base = entries[s].map { Self.decayed($0, now) } ?? 0
            entries[s] = Entry(score: base + 1, lastUpdate: now)
        }
    }
    func score(_ ssid: String, now: Double) -> Double {
        guard let e = entries[ssid] else { return 0 }
        return Self.decayed(e, now)
    }
    func save() {
        try? FileManager.default.createDirectory(at: Config.dir(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.path()) }
    }
}

// MARK: - Location gate

func authString(_ s: CLAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedAlways: return "authorizedAlways"
    @unknown default: return "unknown"
    }
}
func isAuthorized(_ s: CLAuthorizationStatus) -> Bool { s == .authorizedAlways }

/// Owns a long-lived CLLocationManager. Keeping a live session is what actually
/// un-redacts SSIDs on Sequoia (authorization status alone is insufficient).
final class LocationGate: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    func start() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined { manager.requestAlwaysAuthorization() }
        manager.startUpdatingLocation()
    }
    var status: CLAuthorizationStatus { manager.authorizationStatus }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { if isAuthorized(m.authorizationStatus) { m.startUpdatingLocation() } }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {}
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}

// MARK: - Wi-Fi reading

struct NetInfo: Codable { var ssid: String?; var bssid: String?; var rssi: Int; var channel: Int?; var band: String? }

func bandString(_ ch: CWChannel?) -> String? {
    switch ch?.channelBand {
    case .band2GHz: return "2GHz"; case .band5GHz: return "5GHz"; case .band6GHz: return "6GHz"
    default: return nil
    }
}

struct WifiState: Codable {
    var interface: String?
    var authStatus: String
    var authorized: Bool
    var redacted: Bool
    var current: NetInfo?
    var scan: [NetInfo]
    var scanError: String?
}

func readWifi(config: Config, status: CLAuthorizationStatus) -> WifiState {
    let client = CWWiFiClient.shared()
    let iface = client.interface(withName: config.interface) ?? client.interface()
    var current: NetInfo? = nil
    if let i = iface {
        let ssid = i.ssid(); let rssi = i.rssiValue()
        if ssid != nil || rssi != 0 {
            current = NetInfo(ssid: ssid, bssid: i.bssid(), rssi: rssi,
                              channel: i.wlanChannel()?.channelNumber, band: bandString(i.wlanChannel()))
        }
    }
    var scan: [NetInfo] = []; var scanError: String? = nil
    if let i = iface {
        do {
            scan = try i.scanForNetworks(withSSID: nil).map {
                NetInfo(ssid: $0.ssid, bssid: $0.bssid, rssi: $0.rssiValue,
                        channel: $0.wlanChannel?.channelNumber, band: bandString($0.wlanChannel))
            }.sorted { $0.rssi > $1.rssi }
        } catch { scanError = error.localizedDescription }
    }
    let authorized = isAuthorized(status)
    let anyName = (current?.ssid != nil) || scan.contains { $0.ssid != nil }
    return WifiState(interface: iface?.interfaceName, authStatus: authString(status),
                     authorized: authorized, redacted: !authorized && !anyName,
                     current: current, scan: scan, scanError: scanError)
}

/// Strongest RSSI per unique SSID across the scan + current network.
func uniqueNetworks(_ state: WifiState?) -> [(ssid: String, rssi: Int)] {
    var best: [String: Int] = [:]
    for n in state?.scan ?? [] { if let s = n.ssid, !s.isEmpty { best[s] = max(best[s] ?? -200, n.rssi) } }
    if let c = state?.current?.ssid, !c.isEmpty { best[c] = max(best[c] ?? -200, state?.current?.rssi ?? -200) }
    return best.map { ($0.key, $0.value) }.sorted { $0.rssi > $1.rssi }
}

// Tell a phone/Personal Hotspot from a fixed AP. There is no public CoreWLAN API
// for this (Apple's menu icon comes from Continuity/Bluetooth + private info
// elements). The locally-administered-BSSID signal proved far too noisy in the
// field — guest SSIDs, ISP routers, and even Wi-Fi-Direct printers randomize their
// MAC — so we classify by SSID name and keep an "Other networks" escape hatch.

let phoneKeywords = ["iphone", "ipad", "android", "hotspot", "mifi", "pixel", "galaxy",
                     "samsung", "oneplus", "xiaomi", "redmi", "huawei", "oppo", "vivo", "motorola", "nokia"]
func nameLooksLikePhone(_ ssid: String) -> Bool {
    let s = ssid.lowercased()
    return phoneKeywords.contains { s.contains($0) }
}

// MARK: - Decision logic (pure, testable)

enum Action: Equatable {
    case none(String)
    case join(ssid: String, reason: String, penalizeLeftNet: Bool)
}

/// Exponential backoff wait for the Nth consecutive failure (1-based), capped.
func backoffWait(fails: Int, base: Double, cap: Double) -> Double {
    min(cap, base * pow(2, Double(Swift.max(0, fails - 1))))
}

func decide(config: Config, state: WifiState, last: PersistedState, now: Double, currentInternetBad: Bool, homeSignalWeak: Bool) -> Action {
    let cur = state.current?.ssid
    let rssi = state.current?.rssi ?? 0
    let onHome = cur.map { config.homeSSIDs.contains($0) } ?? false
    let onHotspot = cur != nil && cur == config.hotspotSSID
    let disconnected = cur == nil
    let coolingDown = (now - last.lastSwitchEpoch) < config.cooldownSeconds
    func blocked(_ s: String) -> Bool { (last.backoff[s]?.until ?? 0) > now }

    // On some other network the user deliberately chose → never touch it.
    if let c = cur, !onHome, !onHotspot {
        return .none("on other network '\(c)' — leaving it alone")
    }

    // On home: leave only if the signal stayed weak (debounced) OR the internet stopped working.
    if onHome {
        if homeSignalWeak || currentInternetBad {
            guard let hs = config.hotspotSSID, !hs.isEmpty else {
                return .none("home '\(cur ?? "?")' \(homeSignalWeak ? "weak" : "no internet") but no hotspot set")
            }
            if blocked(hs) { return .none("home '\(cur ?? "?")' \(homeSignalWeak ? "weak" : "no internet"), but hotspot in backoff — staying") }
            if coolingDown { return .none("would leave home but cooling down") }
            let reason = homeSignalWeak ? "home '\(cur ?? "?")' weak (\(rssi)dBm < \(config.rssiDrop))"
                                        : "home '\(cur ?? "?")' has no working internet"
            return .join(ssid: hs, reason: reason, penalizeLeftNet: !homeSignalWeak && currentInternetBad)
        }
        return .none("on home '\(cur ?? "?")' (\(rssi)dBm) — fine")
    }

    // On the hotspot or disconnected: prefer a strong home that isn't in backoff.
    let bestHome = uniqueNetworks(state)
        .filter { config.homeSSIDs.contains($0.ssid) && !blocked($0.ssid) }
        .sorted { $0.rssi > $1.rssi }.first
    if let best = bestHome, best.rssi >= config.rssiPrefer {
        if cur == best.ssid { return .none("already on '\(best.ssid)'") }
        // The user manually chose the current network → don't yank them back to home.
        // (Exception: if the pinned network has no working internet, fall through and rescue them.)
        if let pin = last.pinnedSSID, cur == pin, !currentInternetBad {
            return .none("'\(best.ssid)' in range, but staying on manually-chosen '\(pin)' — auto-switch paused")
        }
        if coolingDown { return .none("would join '\(best.ssid)' but cooling down") }
        // Leaving the hotspot because IT has no internet? penalize the hotspot.
        return .join(ssid: best.ssid, reason: "home '\(best.ssid)' in range (\(best.rssi)dBm ≥ \(config.rssiPrefer))", penalizeLeftNet: onHotspot && currentInternetBad)
    }

    // No usable home in range. If we're disconnected, get onto 5G (ignore backoff as a last resort).
    if disconnected {
        guard let hs = config.hotspotSSID, !hs.isEmpty else { return .none("disconnected, no home in range, no hotspot set") }
        if coolingDown { return .none("disconnected but cooling down") }
        return .join(ssid: hs, reason: "disconnected and no home in range — joining hotspot", penalizeLeftNet: false)
    }
    if onHotspot && currentInternetBad { return .none("on hotspot, no internet and no home in range — staying") }
    if let bh = uniqueNetworks(state).first(where: { config.homeSSIDs.contains($0.ssid) && blocked($0.ssid) && $0.rssi >= config.rssiPrefer }) {
        return .none("home '\(bh.ssid)' in range but in backoff — staying on hotspot")
    }
    if let best = bestHome { return .none("on hotspot; home '\(best.ssid)' too weak (\(best.rssi)dBm < \(config.rssiPrefer))") }
    return .none("on hotspot, no home in range — staying")
}

// MARK: - Connectivity probe (captive portal / dead internet detection)

/// Returns true iff the internet is genuinely reachable. Uses Apple's captive
/// portal endpoint: a captive portal or dead link returns something other than
/// the expected "Success" body, which is exactly the "full bars, no internet" case.
func internetWorks(timeout: TimeInterval = 2.0) -> Bool {
    guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else { return true }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
    req.setValue("CaptiveNetworkSupport-wifi", forHTTPHeaderField: "User-Agent")
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeout
    cfg.waitsForConnectivity = false
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    let task = URLSession(configuration: cfg).dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let d = data, let body = String(data: d, encoding: .utf8), body.contains("Success") { ok = true }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + timeout + 0.5)
    return ok
}

// MARK: - Instant Hotspot wake via Control Center (Accessibility)

// An idle iPhone Personal Hotspot isn't broadcasting a normal Wi-Fi beacon — it's
// advertised over Bluetooth/Continuity and is invisible to a Wi-Fi scan, so
// `networksetup` can't see it ("Could not find network"). The CoreWLAN private API
// the system menu uses (CWWiFiClient.startBrowsingForTetherDevices / CWInterface.
// connectToTetherDevice) is gated behind AMFI-restricted entitlements
// (com.apple.wifi.tether.browse/connect) that a self-signed app can't carry without
// disabling SIP. The remaining un-privileged route is to drive the system's own
// Control Center Wi-Fi popover via the Accessibility API — i.e. press the same row
// the user would click. That wakes the phone and joins it.

enum AX {
    static func attr(_ el: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v : nil
    }
    static func str(_ el: AXUIElement, _ a: String) -> String { (attr(el, a) as? String) ?? "" }
    static func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, "AXChildren") as? [AXUIElement]) ?? [] }
    @discardableResult static func press(_ el: AXUIElement) -> Bool { AXUIElementPerformAction(el, "AXPress" as CFString) == .success }
    /// Dismiss an open Control Center popover by synthesizing an Escape keypress.
    /// AXPress on a row joins the network but, unlike a real mouse click, leaves the
    /// popover on screen; Escape closes it (and is a harmless no-op if already closed).
    static func sendEscape() {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)   // 53 = Escape
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }
    static func find(_ root: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        if depth > 12 { return nil }
        if str(root, "AXIdentifier") == identifier { return root }
        for c in children(root) { if let f = find(c, identifier: identifier, depth: depth + 1) { return f } }
        return nil
    }
}

/// Press the hotspot's row in the Control Center Wi-Fi popover (wakes + joins an idle
/// Personal Hotspot). Returns true if the row was found and pressed. MUST run on the
/// main thread (it drives UI). The row is identified by AXIdentifier "wifi-network-<SSID>".
func pressHotspotRowInControlCenter(_ ssid: String) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    guard let cc = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.controlcenter" }) else { return false }
    let app = AXUIElementCreateApplication(cc.processIdentifier)
    guard let embAny = AX.attr(app, "AXExtrasMenuBar") else { return false }
    let emb = embAny as! AXUIElement
    guard let wifi = AX.children(emb).first(where: { AX.str($0, "AXIdentifier") == "com.apple.menuextra.wifi" }) else { return false }
    AX.press(wifi)   // open the Wi-Fi popover
    let wantID = "wifi-network-\(ssid)"
    var row: AXUIElement?
    for _ in 0..<33 {   // poll up to ~5s for the popover + the (Continuity-advertised) row
        for w in (AX.attr(app, "AXWindows") as? [AXUIElement]) ?? [] {
            if let f = AX.find(w, identifier: wantID) { row = f; break }
        }
        if row != nil { break }
        Thread.sleep(forTimeInterval: 0.15)
    }
    guard let target = row else { AX.press(wifi); return false }   // not advertising → close the popover and bail
    AX.press(target)   // join the network
    Thread.sleep(forTimeInterval: 0.2)   // let the press register before dismissing the UI
    AX.sendEscape()   // AXPress leaves the popover open — close it so it doesn't linger
    return true
}

// MARK: - Switching

@discardableResult
func joinNetwork(_ ssid: String, interface: String, wakeViaUI: Bool = false, hotspotInScan: Bool = true) -> (ok: Bool, output: String) {
    let client = CWWiFiClient.shared()
    func associated() -> Bool { client.interface(withName: interface)?.ssid() == ssid }

    // When we already know the hotspot is idle (not broadcasting / absent from the latest
    // scan) and we're allowed to wake it, skip networksetup entirely — it would just spend
    // 3–6s failing with "Could not find network" before we fall back to the menu anyway.
    let goStraightToUI = wakeViaUI && !hotspotInScan
    var trimmed = ""
    if !goStraightToUI {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-setairportnetwork", interface, ssid]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do {
            try p.run(); p.waitUntilExit()
            trimmed = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return (false, error.localizedDescription) }
        // networksetup misreports success (e.g. "-3900 tmpErr") — trust the observed
        // association instead. An idle hotspot fails fast with "Could not find network";
        // don't burn the poll window on it, fall through to the UI wake below.
        if !trimmed.localizedCaseInsensitiveContains("could not find network") {
            for _ in 0..<16 {   // ~12s — covers an *awake* network whose join takes a moment
                if associated() { return (true, "joined") }
                Thread.sleep(forTimeInterval: 0.75)
            }
        }
    }

    // Idle Instant Hotspot: wake + join it through the Control Center Wi-Fi menu.
    if wakeViaUI {
        guard AXIsProcessTrusted() else { return (false, "needs Accessibility permission to wake the hotspot") }
        var pressed = false
        if Thread.isMainThread { pressed = pressHotspotRowInControlCenter(ssid) }
        else { DispatchQueue.main.sync { pressed = pressHotspotRowInControlCenter(ssid) } }
        if !pressed { return (false, "hotspot not shown in Wi-Fi menu (phone asleep, out of range, or Bluetooth off?)") }
        for _ in 0..<27 {   // ~20s — Bluetooth wake + association can be slow
            if associated() { return (true, "joined via Control Center") }
            Thread.sleep(forTimeInterval: 0.75)
        }
        return (false, "pressed hotspot in Wi-Fi menu but it didn't associate")
    }

    return (false, trimmed.isEmpty ? "did not associate to \(ssid)" : trimmed)
}

func logLine(_ msg: String) {
    let url = Config.dir().appendingPathComponent("switch.log")
    let line = ISO8601DateFormatter().string(from: Date()) + " " + msg + "\n"
    try? FileManager.default.createDirectory(at: Config.dir(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, CWEventDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let loc = LocationGate()
    var config = Config.load()
    var state = PersistedState.load()
    var lastWifi: WifiState?
    var lastInternetOK: Bool?
    var consecutiveNetFails = 0
    var consecutiveWeakReads = 0      // debounce the weak-signal bail
    var lastSeenSSID: String?         // SSID observed last cycle (to spot a change)
    var lastCommandedSSID: String?    // last SSID *we* joined (so a self-initiated change isn't read as manual)
    var sawFirstCycle = false         // first read just sets the baseline; never treated as a manual switch
    var timer: Timer?
    let work = DispatchQueue(label: "wifiautoswitch.cycle")
    var sliderLabel: NSTextField?
    var activity: NSObjectProtocol?  // App Nap suppressor
    var scores = NetworkScores.load()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Keep this background app from being App-Napped, or the poll timer and
        // Wi-Fi event callbacks get throttled when the lid is closed / screen off.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Wi-Fi auto-switch monitoring")
        loc.start()
        // React instantly when the link drops or the SSID changes (the real trigger),
        // instead of waiting up to one poll interval.
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        // Wake from sleep (lid lift): run a cycle promptly so we reconnect to home or
        // fall back to the hotspot, rather than waiting for the next poll tick.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        updateButton()
        // First cycle shortly after launch (give location a moment to settle), then on interval.
        scheduleTimer()
        work.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runCycle() }
    }

    // CWEventDelegate — refresh the icon instantly, then run a full cycle.
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { refreshIconNow(); work.async { [weak self] in self?.runCycle() } }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { refreshIconNow(); work.async { [weak self] in self?.runCycle() } }

    /// Update just the menu-bar icon from the *current* network, skipping the blocking
    /// multi-second `scanForNetworks` that `readWifi` runs. Wi-Fi events fire the moment a
    /// connection changes, but the full cycle's scan (or an in-progress join) would otherwise
    /// hold the icon stale for a few seconds — the current SSID/RSSI read here is instant.
    func refreshIconNow() {
        let status = loc.status
        let client = CWWiFiClient.shared()
        let iface = client.interface(withName: config.interface) ?? client.interface()
        var cur: NetInfo? = nil
        if let i = iface {
            let s = i.ssid(); let r = i.rssiValue()
            if s != nil || r != 0 { cur = NetInfo(ssid: s, bssid: i.bssid(), rssi: r, channel: nil, band: nil) }
        }
        let authorized = isAuthorized(status)
        DispatchQueue.main.async {
            if var w = self.lastWifi {
                w.current = cur; w.authorized = authorized
                if authorized { w.redacted = false } else if cur?.ssid == nil { w.redacted = true }
                self.lastWifi = w
            } else {
                self.lastWifi = WifiState(interface: iface?.interfaceName, authStatus: authString(status),
                                          authorized: authorized, redacted: !authorized && cur?.ssid == nil,
                                          current: cur, scan: [], scanError: nil)
            }
            self.updateButton()
        }
    }

    @objc func systemDidWake() {
        loc.start()  // re-arm the location session after sleep
        // Give Wi-Fi a few seconds to power up and finish its own join attempt first.
        work.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runCycle() }
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.pollSeconds, repeats: true) { [weak self] _ in
            self?.work.async { self?.runCycle() }
        }
    }

    // One read → decide → (maybe) switch. Runs on the background queue.
    func runCycle() {
        let wifi = readWifi(config: config, status: loc.status)
        DispatchQueue.main.async { self.lastWifi = wifi; self.updateButton() }

        guard wifi.authorized, !wifi.redacted else {
            logLine("ABORT: \(wifi.redacted ? "redacted scan" : "not authorized (\(wifi.authStatus))") — doing nothing")
            return
        }
        // Tally networks we see for menu sorting (even when auto-switch is off).
        // Confine score mutation/IO to the main thread, where the menu reads it.
        let now = Date().timeIntervalSince1970
        let seen = uniqueNetworks(wifi).map { $0.ssid }
        if !seen.isEmpty { DispatchQueue.main.async { self.scores.bump(seen, now: now); self.scores.save() } }

        guard config.enabled else { return }

        let cur = wifi.current?.ssid
        let onHome = cur.map { config.homeSSIDs.contains($0) } ?? false

        // Detect a switch we didn't initiate (e.g. the system Wi-Fi menu) and honour it:
        // landing on a non-home network we didn't command pins it (auto-switch paused), while
        // moving to home or disconnecting resumes normal auto-switching. The first read after
        // launch only seeds the baseline, so being already on the hotspot at startup isn't
        // mistaken for a manual choice (a *persisted* pin from a real manual switch survives).
        if !sawFirstCycle {
            sawFirstCycle = true
            lastSeenSSID = cur
            lastCommandedSSID = cur
        } else if cur != lastSeenSSID {
            if let c = cur, c != lastCommandedSSID, !config.homeSSIDs.contains(c) {
                if state.pinnedSSID != c { state.pinnedSSID = c; state.save(); logLine("manual switch to '\(c)' detected → auto-switch paused") }
            } else if cur == nil || (cur.map { config.homeSSIDs.contains($0) } ?? false) {
                if state.pinnedSSID != nil { state.pinnedSSID = nil; state.save(); logLine("on '\(cur ?? "disconnected")' → auto-switch resumed") }
            }
            lastSeenSSID = cur
        }

        // Verify the internet only on home Wi-Fi (unmetered) — every cycle. The hotspot is
        // cellular, so we never probe it (assume it works once joined; spare the data).
        var currentInternetBad = false
        if onHome, let cur = cur {
            let ok = internetWorks()
            consecutiveNetFails = ok ? 0 : consecutiveNetFails + 1
            lastInternetOK = ok
            if ok, state.backoff[cur] != nil { state.backoff[cur] = nil; state.save() }  // recovered → clear backoff
            currentInternetBad = consecutiveNetFails >= config.netFailThreshold
        } else {
            lastInternetOK = nil
            consecutiveNetFails = 0
        }

        // Debounce the weak-signal trigger: only treat home as "weak" after several
        // consecutive low reads, so a momentary dip doesn't bounce us off home.
        var homeSignalWeak = false
        if onHome {
            consecutiveWeakReads = (wifi.current?.rssi ?? 0) < config.rssiDrop ? consecutiveWeakReads + 1 : 0
            homeSignalWeak = consecutiveWeakReads >= config.weakThreshold
        } else {
            consecutiveWeakReads = 0
        }

        let action = decide(config: config, state: wifi, last: state, now: now,
                            currentInternetBad: currentInternetBad, homeSignalWeak: homeSignalWeak)
        switch action {
        case .none(let reason):
            logLine("noop: \(reason)")
        case .join(let ssid, let reason, let penalizeLeftNet):
            let leftNet = wifi.current?.ssid
            let r = joinNetwork(ssid, interface: config.interface,
                                wakeViaUI: ssid == config.hotspotSSID && config.hotspotWakeViaUI,
                                hotspotInScan: uniqueNetworks(wifi).contains { $0.ssid == ssid })
            if r.ok {
                state.lastSwitchEpoch = now
                state.lastTarget = ssid
                state.backoff[ssid] = nil            // joined fine → clear any backoff on the target
                state.pinnedSSID = nil               // an automatic switch supersedes any manual pin
                lastCommandedSSID = ssid             // mark as self-initiated so it isn't read as a manual switch
                lastSeenSSID = ssid
                if penalizeLeftNet, let ln = leftNet {
                    var b = state.backoff[ln] ?? Backoff(fails: 0, until: 0)
                    b.fails += 1
                    let wait = backoffWait(fails: b.fails, base: config.backoffBaseSeconds, cap: config.backoffMaxSeconds)
                    b.until = now + wait
                    state.backoff[ln] = b
                    logLine("backoff '\(ln)' ×\(b.fails) → retry in ~\(Int(wait / 60))min")
                }
                state.save()
                consecutiveNetFails = 0; consecutiveWeakReads = 0
                logLine("SWITCHED → '\(ssid)' :: \(reason)")
            } else {
                // Couldn't join (e.g. an idle hotspot that can't be woken) → back off this
                // target so we don't retry it on every cycle.
                var b = state.backoff[ssid] ?? Backoff(fails: 0, until: 0)
                b.fails += 1
                let wait = backoffWait(fails: b.fails, base: config.backoffBaseSeconds, cap: config.backoffMaxSeconds)
                b.until = now + wait
                state.backoff[ssid] = b
                state.save()
                logLine("FAILED → '\(ssid)' :: \(reason) :: \(r.output) (backoff ~\(Int(wait / 60))min)")
            }
            DispatchQueue.main.async { self.updateButton() }
        }
    }

    // MARK: status button

    enum StatusIcon {
        case symbol(String, NSColor?)
    }

    func statusIcon() -> StatusIcon {
        guard let w = lastWifi else { return .symbol("antenna.radiowaves.left.and.right", nil) }
        if !w.authorized || w.redacted { return .symbol("exclamationmark.triangle", nil) }
        if !config.enabled { return .symbol("pause.circle", nil) }
        if let s = w.current?.ssid, s == config.hotspotSSID {
            return .symbol(
                "antenna.radiowaves.left.and.right",
                NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)  // #0A84FF — system blue
            )
        }
        return .symbol("antenna.radiowaves.left.and.right", nil)
    }

    func updateButton() {
        guard let button = statusItem.button else { return }
        switch statusIcon() {
        case .symbol(let name, let tint):
            var img = NSImage(systemSymbolName: name, accessibilityDescription: "WifiAutoswitch")
            if let tint = tint {
                // Bake the colour into a NON-template image. contentTintColor on a status
                // item is unreliable, and a template image is forced monochrome (→ black/white).
                img = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
                img?.isTemplate = false
            } else {
                img?.isTemplate = true   // adaptive monochrome, matches the menu bar
            }
            button.contentTintColor = nil
            button.image = img
        }
        button.toolTip = statusText()
    }

    func statusText() -> String {
        guard let w = lastWifi else { return "Reading Wi-Fi…" }
        if !w.authorized || w.redacted { return "⚠︎ Location permission needed to read Wi-Fi names" }
        guard let ssid = w.current?.ssid else { return "Not connected" }
        let rssi = w.current?.rssi ?? 0
        let paused = (state.pinnedSSID == ssid) ? " · manual (paused)" : ""
        if ssid == config.hotspotSSID { return "On hotspot · \(ssid) · \(rssi) dBm\(paused)" }
        var s = "On \(ssid) · \(rssi) dBm"
        if config.homeSSIDs.contains(ssid), let net = lastInternetOK { s += net ? " · internet ✓" : " · internet ✗" }
        return s + paused
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) { work.async { [weak self] in self?.refreshRead() } }

    func refreshRead() {
        let wifi = readWifi(config: config, status: loc.status)
        DispatchQueue.main.async { self.lastWifi = wifi; self.updateButton() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addCheck(menu, "Wake idle hotspot", config.hotspotWakeViaUI, #selector(toggleHotspotWake))
        menu.addItem(.separator())

        // Signal slider
        let hdr = NSMenuItem(title: "Minimum home signal", action: nil, keyEquivalent: ""); hdr.isEnabled = false
        menu.addItem(hdr)
        menu.addItem(sliderItem())
        menu.addItem(.separator())

        menu.addItem(submenuItem("Home networks", build: homeSubmenu()))
        menu.addItem(submenuItem("Hotspot network", build: hotspotSubmenu()))
        menu.addItem(.separator())

        // Only offer the switch you're not already in.
        let curSSID = lastWifi?.current?.ssid
        let onHome = curSSID.map { config.homeSSIDs.contains($0) } ?? false
        let onHotspot = curSSID != nil && curSSID == config.hotspotSSID
        if !onHome {
            let homeNow = NSMenuItem(title: "Switch to home now", action: #selector(switchHomeNow), keyEquivalent: "")
            homeNow.target = self
            homeNow.isEnabled = bestVisibleHome() != nil
            menu.addItem(homeNow)
        }
        if !onHotspot, !(config.hotspotSSID ?? "").isEmpty {
            let hsNow = NSMenuItem(title: "Switch to hotspot now", action: #selector(switchHotspotNow), keyEquivalent: "")
            hsNow.target = self
            menu.addItem(hsNow)
        }
        if let pin = state.pinnedSSID {
            let resume = NSMenuItem(title: "Resume auto-switch (paused on “\(pin)”)", action: #selector(resumeAuto), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        }
        let log = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: ""); log.target = self
        menu.addItem(log)
        menu.addItem(.separator())

        addCheck(menu, "Launch at login", loginEnabled(), #selector(toggleLogin))
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        menu.addItem(quit)
    }

    func addCheck(_ menu: NSMenu, _ title: String, _ on: Bool, _ sel: Selector) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self; it.state = on ? .on : .off
        menu.addItem(it)
    }

    func submenuItem(_ title: String, build: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.submenu = build; return it
    }

    func label(forSignal v: Int) -> String {
        if v >= -55 { return "Strict" }; if v >= -72 { return "Balanced" }; return "Lenient"
    }

    func sliderItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
        let lbl = NSTextField(labelWithString: "\(config.minSignal) dBm · \(label(forSignal: config.minSignal))")
        lbl.frame = NSRect(x: 20, y: 28, width: 200, height: 18)
        lbl.font = .menuFont(ofSize: 12); lbl.textColor = .secondaryLabelColor
        let slider = NSSlider(value: Double(config.minSignal), minValue: -85, maxValue: -45,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 20, y: 6, width: 200, height: 20)
        slider.isContinuous = true
        container.addSubview(lbl); container.addSubview(slider)
        sliderLabel = lbl
        let it = NSMenuItem(); it.view = container; return it
    }

    /// Visible networks tagged hotspot-like by name, sorted by decayed score (signal breaks ties).
    func classified() -> [(ssid: String, rssi: Int, hotspotLike: Bool)] {
        let now = Date().timeIntervalSince1970
        return uniqueNetworks(lastWifi)
            .map { ($0.ssid, $0.rssi, nameLooksLikePhone($0.ssid)) }
            .sorted { a, b in
                let sa = scores.score(a.0, now: now), sb = scores.score(b.0, now: now)
                return sa != sb ? sa > sb : a.1 > b.1
            }
    }

    func homeItem(_ ssid: String) -> NSMenuItem {
        let it = NSMenuItem(title: ssid, action: #selector(toggleHome(_:)), keyEquivalent: "")
        it.target = self; it.representedObject = ssid; it.state = config.homeSSIDs.contains(ssid) ? .on : .off
        return it
    }
    func hotspotItem(_ ssid: String) -> NSMenuItem {
        let it = NSMenuItem(title: ssid, action: #selector(chooseHotspot(_:)), keyEquivalent: "")
        it.target = self; it.representedObject = ssid; it.state = (config.hotspotSSID == ssid) ? .on : .off
        return it
    }

    func homeSubmenu() -> NSMenu {
        let m = NSMenu()
        let hint = NSMenuItem(title: "Check all that count as “home”:", action: nil, keyEquivalent: ""); hint.isEnabled = false
        m.addItem(hint)
        let nets = classified().filter { $0.ssid != config.hotspotSSID }
        var listed = Set<String>()
        for n in nets where !n.hotspotLike { m.addItem(homeItem(n.ssid)); listed.insert(n.ssid) }
        // Configured homes that aren't currently in range still show (checked), so you can manage them anywhere.
        for h in config.homeSSIDs where !listed.contains(h) && h != config.hotspotSSID { m.addItem(homeItem(h)); listed.insert(h) }
        if listed.isEmpty { let e = NSMenuItem(title: "(no networks seen yet)", action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e) }
        let other = nets.filter { $0.hotspotLike && !listed.contains($0.ssid) }
        if !other.isEmpty {
            m.addItem(.separator())
            let sub = NSMenu(); for n in other { sub.addItem(homeItem(n.ssid)) }
            m.addItem(submenuItem("Other networks", build: sub))
        }
        m.addItem(.separator())
        let add = NSMenuItem(title: "Add network by name…", action: #selector(addHomeByName), keyEquivalent: "")
        add.target = self; m.addItem(add)
        return m
    }

    func hotspotSubmenu() -> NSMenu {
        let m = NSMenu()
        let none = NSMenuItem(title: "None", action: #selector(chooseHotspot(_:)), keyEquivalent: "")
        none.target = self; none.representedObject = ""; none.state = (config.hotspotSSID ?? "").isEmpty ? .on : .off
        m.addItem(none); m.addItem(.separator())
        let nets = classified()
        var listed = Set<String>()
        if let h = config.hotspotSSID, !h.isEmpty { m.addItem(hotspotItem(h)); listed.insert(h) }   // pin current choice
        for n in nets where n.hotspotLike && !listed.contains(n.ssid) { m.addItem(hotspotItem(n.ssid)); listed.insert(n.ssid) }
        let other = nets.filter { !$0.hotspotLike && !listed.contains($0.ssid) }
        if !other.isEmpty {
            m.addItem(.separator())
            let sub = NSMenu(); for n in other { sub.addItem(hotspotItem(n.ssid)) }
            m.addItem(submenuItem("Other networks", build: sub))
        }
        return m
    }

    func bestVisibleHome() -> String? {
        uniqueNetworks(lastWifi).first { config.homeSSIDs.contains($0.ssid) }?.ssid
    }

    // MARK: actions

    @objc func toggleHotspotWake() {
        config.hotspotWakeViaUI.toggle(); config.save()
        guard config.hotspotWakeViaUI, !AXIsProcessTrusted() else { return }
        // Trigger the system prompt that adds the app to the Accessibility list, and guide the user.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Allow Accessibility to wake the hotspot"
        a.informativeText = "To wake and join an idle iPhone hotspot, WifiAutoswitch clicks it in the Wi‑Fi menu for you — which needs Accessibility access.\n\nEnable WifiAutoswitch under System Settings → Privacy & Security → Accessibility, then it works automatically (no notarization or SIP changes)."
        a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func sliderChanged(_ sender: NSSlider) {
        config.minSignal = Int(sender.doubleValue.rounded())
        sliderLabel?.stringValue = "\(config.minSignal) dBm · \(label(forSignal: config.minSignal))"
        config.save()
    }
    @objc func toggleHome(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        if let i = config.homeSSIDs.firstIndex(of: s) { config.homeSSIDs.remove(at: i) } else { config.homeSSIDs.append(s) }
        config.save(); work.async { self.runCycle() }
    }
    @objc func addHomeByName() {
        let alert = NSAlert()
        alert.messageText = "Add a home network"
        alert.informativeText = "Enter the exact Wi-Fi name (SSID). You can add networks you're not currently near, e.g. your office."
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Network name"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !config.homeSSIDs.contains(name) {
                config.homeSSIDs.append(name); config.save(); work.async { self.runCycle() }
            }
        }
    }
    @objc func chooseHotspot(_ sender: NSMenuItem) {
        let s = sender.representedObject as? String ?? ""
        config.hotspotSSID = s.isEmpty ? nil : s; config.save()
    }
    @objc func switchHomeNow() {
        guard let s = bestVisibleHome() else { return }
        work.async {
            // Manual intervention resets backoff and resumes normal auto-switching (home is the preferred state).
            self.state.backoff.removeAll(); self.consecutiveNetFails = 0; self.state.pinnedSSID = nil; self.state.save()
            let r = joinNetwork(s, interface: self.config.interface)
            if r.ok { self.lastCommandedSSID = s }
            logLine("MANUAL → '\(s)' (auto-switch resumed) :: \(r.ok ? "joined" : r.output)")
            if !r.ok { self.notifyManualFailure(s, r.output) }
            self.runCycle()
        }
    }
    @objc func switchHotspotNow() {
        guard let s = config.hotspotSSID, !s.isEmpty else { return }
        work.async {
            self.state.backoff.removeAll(); self.consecutiveNetFails = 0
            let inScan = uniqueNetworks(self.lastWifi).contains { $0.ssid == s }
            let r = joinNetwork(s, interface: self.config.interface, wakeViaUI: self.config.hotspotWakeViaUI, hotspotInScan: inScan)
            if r.ok {
                self.lastCommandedSSID = s
                self.state.pinnedSSID = s   // pin: honour this manual choice — don't auto-return to home
                logLine("MANUAL → '\(s)' (pinned; auto-switch paused) :: joined")
            } else {
                logLine("MANUAL → '\(s)' :: FAILED :: \(r.output)")
            }
            self.state.save()
            if !r.ok { self.notifyManualFailure(s, r.output) }
            self.runCycle()
        }
    }
    @objc func resumeAuto() {
        work.async {
            if self.state.pinnedSSID != nil { self.state.pinnedSSID = nil; self.state.save(); logLine("auto-switch resumed (manual)") }
            self.runCycle()
        }
    }
    /// A user-initiated switch failed (most often: an idle iPhone hotspot that can't be woken
    /// over Bluetooth via networksetup). Surface it instead of failing silently.
    func notifyManualFailure(_ ssid: String, _ detail: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Couldn't switch to “\(ssid)”"
            a.informativeText = "macOS couldn't join “\(ssid)”. If that's your iPhone hotspot it may be asleep — open Personal Hotspot on the phone (or toggle it off/on) so it's awake, then try again.\n\n\(detail)"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }
    @objc func openLog() { NSWorkspace.shared.open(Config.dir().appendingPathComponent("switch.log")) }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: login item
    func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
            catch { logLine("login toggle failed: \(error.localizedDescription)") }
        }
    }
}

// MARK: - CLI modes (development/debugging)

func cmdRead() {
    let gate = LocationGate(); gate.start()
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline { if isAuthorized(gate.status) { break }; RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2)) }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2)) // let a fix arrive
    let wifi = readWifi(config: .load(), status: gate.status)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = Config.dir().appendingPathComponent("last-read.json")
    try? FileManager.default.createDirectory(at: Config.dir(), withIntermediateDirectories: true)
    if let d = try? enc.encode(wifi) { try? d.write(to: url); FileHandle.standardOutput.write(d); print("") }
}

func cmdSelftest() {
    var fail = 0
    func check(_ n: String, _ got: Action, _ want: Action) {
        if got == want { print("ok   \(n)") } else { print("FAIL \(n)\n  got:  \(got)\n  want: \(want)"); fail += 1 }
    }
    var c = Config(); c.homeSSIDs = ["HomeWiFi"]; c.hotspotSSID = "MyPhone"; c.minSignal = -68; c.hysteresisGap = 6; c.cooldownSeconds = 45
    let fresh = PersistedState()
    let cooling = PersistedState(lastSwitchEpoch: 1000)
    var blockedState = PersistedState(); blockedState.backoff["HomeWiFi"] = Backoff(fails: 1, until: 9999)
    var hotspotBlocked = PersistedState(); hotspotBlocked.backoff["MyPhone"] = Backoff(fails: 1, until: 9999)
    var pinnedHotspot = PersistedState(); pinnedHotspot.pinnedSSID = "MyPhone"
    func S(_ cur: NetInfo?, _ scan: [NetInfo]) -> WifiState {
        WifiState(interface: "en0", authStatus: "authorizedAlways", authorized: true, redacted: false, current: cur, scan: scan, scanError: nil)
    }
    let orimarStrong = NetInfo(ssid: "HomeWiFi", bssid: nil, rssi: -45, channel: 149, band: "5GHz")
    let orimarWeak = NetInfo(ssid: "HomeWiFi", bssid: nil, rssi: -80, channel: 149, band: "5GHz")
    let hotspot = NetInfo(ssid: "MyPhone", bssid: nil, rssi: -60, channel: 11, band: "2GHz")
    let homeWeakCur = NetInfo(ssid: "HomeWiFi", bssid: nil, rssi: -82, channel: 149, band: "5GHz")
    let homeOkCur = NetInfo(ssid: "HomeWiFi", bssid: nil, rssi: -55, channel: 149, band: "5GHz")
    let otherCur = NetInfo(ssid: "CoffeeShop", bssid: nil, rssi: -50, channel: 6, band: "2GHz")

    check("join home from hotspot", decide(config: c, state: S(hotspot, [orimarStrong]), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .join(ssid: "HomeWiFi", reason: "home 'HomeWiFi' in range (-45dBm ≥ -68)", penalizeLeftNet: false))
    check("on hotspot, weak home → stay", decide(config: c, state: S(hotspot, [orimarWeak]), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .none("on hotspot; home 'HomeWiFi' too weak (-80dBm < -68)"))
    check("on hotspot, no home → stay", decide(config: c, state: S(hotspot, []), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .none("on hotspot, no home in range — staying"))
    check("on good home → noop", decide(config: c, state: S(homeOkCur, []), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .none("on home 'HomeWiFi' (-55dBm) — fine"))
    check("home weak but NOT debounced → stay", decide(config: c, state: S(homeWeakCur, []), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .none("on home 'HomeWiFi' (-82dBm) — fine"))
    check("home weak (debounced) → hotspot", decide(config: c, state: S(homeWeakCur, []), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: true),
          .join(ssid: "MyPhone", reason: "home 'HomeWiFi' weak (-82dBm < -74)", penalizeLeftNet: false))
    check("home weak but hotspot in backoff → stay", decide(config: c, state: S(homeWeakCur, []), last: hotspotBlocked, now: 5000, currentInternetBad: false, homeSignalWeak: true),
          .none("home 'HomeWiFi' weak, but hotspot in backoff — staying"))
    check("good home, dead internet → hotspot+backoff", decide(config: c, state: S(homeOkCur, []), last: fresh, now: 5000, currentInternetBad: true, homeSignalWeak: false),
          .join(ssid: "MyPhone", reason: "home 'HomeWiFi' has no working internet", penalizeLeftNet: true))
    check("LOST HOME (disconnected) → hotspot", decide(config: c, state: S(nil, []), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .join(ssid: "MyPhone", reason: "disconnected and no home in range — joining hotspot", penalizeLeftNet: false))
    check("disconnected but home in range → home", decide(config: c, state: S(nil, [orimarStrong]), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .join(ssid: "HomeWiFi", reason: "home 'HomeWiFi' in range (-45dBm ≥ -68)", penalizeLeftNet: false))
    check("on OTHER wifi → leave alone", decide(config: c, state: S(otherCur, [orimarStrong]), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .none("on other network 'CoffeeShop' — leaving it alone"))
    check("cooldown blocks join", decide(config: c, state: S(hotspot, [orimarStrong]), last: cooling, now: 1030, currentInternetBad: false, homeSignalWeak: false),
          .none("would join 'HomeWiFi' but cooling down"))
    check("backed-off home not rejoined", decide(config: c, state: S(hotspot, [orimarStrong]), last: blockedState, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .none("home 'HomeWiFi' in range but in backoff — staying on hotspot"))
    check("manual pin on hotspot → don't rejoin home", decide(config: c, state: S(hotspot, [orimarStrong]), last: pinnedHotspot, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .none("'HomeWiFi' in range, but staying on manually-chosen 'MyPhone' — auto-switch paused"))
    check("manual pin but hotspot dead → rescue to home", decide(config: c, state: S(hotspot, [orimarStrong]), last: pinnedHotspot, now: 5000, currentInternetBad: true, homeSignalWeak: false),
          .join(ssid: "HomeWiFi", reason: "home 'HomeWiFi' in range (-45dBm ≥ -68)", penalizeLeftNet: true))
    var multi = c; multi.homeSSIDs = ["HomeWiFi", "Office"]
    let office = NetInfo(ssid: "Office", bssid: nil, rssi: -50, channel: 36, band: "5GHz")
    check("multiple homes: joins whichever is in range", decide(config: multi, state: S(hotspot, [office]), last: fresh, now: 5000, currentInternetBad: false, homeSignalWeak: false),
          .join(ssid: "Office", reason: "home 'Office' in range (-50dBm ≥ -68)", penalizeLeftNet: false))

    var sc = NetworkScores()
    sc.bump(["A"], now: 0); sc.bump(["A"], now: 0)
    let s0 = sc.score("A", now: 0), sHalf = sc.score("A", now: NetworkScores.halfLife)
    if s0 > 1.9 && abs(sHalf - s0 / 2) < 0.05 { print("ok   score decays by half-life") }
    else { print("FAIL score decay: s0=\(s0) sHalf=\(sHalf)"); fail += 1 }

    let w = (1...4).map { backoffWait(fails: $0, base: 600, cap: 21600) }
    if w == [600, 1200, 2400, 4800] && backoffWait(fails: 99, base: 600, cap: 21600) == 21600 { print("ok   backoff doubles then caps") }
    else { print("FAIL backoff: \(w)"); fail += 1 }

    let partial = #"{"homeSSIDs":["X"],"minSignal":-55}"#.data(using: .utf8)!
    let lc = (try? JSONDecoder().decode(Config.self, from: partial)) ?? Config()
    if lc.homeSSIDs == ["X"] && lc.minSignal == -55 && lc.weakThreshold == 3 && lc.netFailThreshold == 2 { print("ok   config decodes leniently (missing keys default)") }
    else { print("FAIL lenient config: home=\(lc.homeSSIDs) min=\(lc.minSignal) weak=\(lc.weakThreshold)"); fail += 1 }

    print(fail == 0 ? "\nALL PASS" : "\n\(fail) FAILED")
    exit(fail == 0 ? 0 : 1)
}

// MARK: - Entry

var appDelegate: AppDelegate?  // strong ref; NSApplication.delegate is unowned
switch CommandLine.arguments.dropFirst().first {
case "read": cmdRead()
case "selftest": cmdSelftest()
default:
    let app = NSApplication.shared
    appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
