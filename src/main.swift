import Foundation
import CoreWLAN
import CoreLocation
import AppKit
import ServiceManagement

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
    var connectivityCheck = true
    var netFailThreshold = 2    // consecutive failed internet probes before bailing
    var weakThreshold = 3       // consecutive weak-signal reads before leaving home (anti-flap)
    var backoffBaseSeconds: Double = 600      // first retry wait after a dead-internet switch (10 min)
    var backoffMaxSeconds: Double = 6 * 3600  // cap on the exponential backoff (6 h)
    var hotspotProbeSeconds: Double = 600     // how often to re-verify the cellular hotspot (keep sparse)

    var rssiPrefer: Int { minSignal }
    var rssiDrop: Int { minSignal - hysteresisGap }

    enum CodingKeys: String, CodingKey {
        case interface, homeSSIDs, hotspotSSID, minSignal, hysteresisGap, cooldownSeconds, pollSeconds,
             enabled, connectivityCheck, netFailThreshold, weakThreshold,
             backoffBaseSeconds, backoffMaxSeconds, hotspotProbeSeconds
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
        connectivityCheck = (try? c.decode(Bool.self, forKey: .connectivityCheck)) ?? connectivityCheck
        netFailThreshold = (try? c.decode(Int.self, forKey: .netFailThreshold)) ?? netFailThreshold
        weakThreshold = (try? c.decode(Int.self, forKey: .weakThreshold)) ?? weakThreshold
        backoffBaseSeconds = (try? c.decode(Double.self, forKey: .backoffBaseSeconds)) ?? backoffBaseSeconds
        backoffMaxSeconds = (try? c.decode(Double.self, forKey: .backoffMaxSeconds)) ?? backoffMaxSeconds
        hotspotProbeSeconds = (try? c.decode(Double.self, forKey: .hotspotProbeSeconds)) ?? hotspotProbeSeconds
    }
}

// MARK: - Persisted state (anti-flap)

struct Backoff: Codable { var fails: Int; var until: Double }

struct PersistedState: Codable {
    var lastSwitchEpoch: Double = 0
    var lastTarget = ""
    var backoff: [String: Backoff] = [:]   // SSID → exponential backoff after a dead-internet switch

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

// MARK: - Switching

@discardableResult
func joinNetwork(_ ssid: String, interface: String) -> (ok: Bool, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    p.arguments = ["-setairportnetwork", interface, ssid]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    var out = ""
    do {
        try p.run(); p.waitUntilExit()
        out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } catch { return (false, error.localizedDescription) }
    // networksetup is unreliable about reporting success — it frequently prints
    // "Error: -3900 ... tmpErr" even when the join actually worked. Trust the
    // observed association instead: re-read the SSID for a few seconds.
    // Joining an idle iPhone hotspot goes through Instant Hotspot (Bluetooth wake),
    // which can take ~10s — so poll a generous window before declaring failure.
    let client = CWWiFiClient.shared()
    for _ in 0..<16 {
        if client.interface(withName: interface)?.ssid() == ssid { return (true, "joined") }
        Thread.sleep(forTimeInterval: 0.75)
    }
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var lastHotspotProbe: Double = 0  // throttle cellular internet probes
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

    // CWEventDelegate — fire a cycle immediately on Wi-Fi changes.
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { work.async { [weak self] in self?.runCycle() } }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { work.async { [weak self] in self?.runCycle() } }

    @objc func systemDidWake() {
        loc.start()  // re-arm the location session after sleep
        // Give Wi-Fi a few seconds to power up and finish its own join attempt first.
        work.asyncAfter(deadline: .now() + 3) { [weak self] in self?.lastHotspotProbe = 0; self?.runCycle() }
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

        // Verify internet on the network we're sitting on. Home is unmetered → probe
        // every cycle. The hotspot is cellular → probe sparingly (every hotspotProbeSeconds).
        let cur = wifi.current?.ssid
        let onHome = cur.map { config.homeSSIDs.contains($0) } ?? false
        let onHotspot = cur != nil && cur == config.hotspotSSID
        var currentInternetBad = false
        if config.connectivityCheck, let cur = cur, onHome || onHotspot {
            let shouldProbe = onHome || (now - lastHotspotProbe >= config.hotspotProbeSeconds)
            if shouldProbe {
                if onHotspot { lastHotspotProbe = now }
                let ok = internetWorks()
                consecutiveNetFails = ok ? 0 : consecutiveNetFails + 1
                lastInternetOK = ok
                if ok, state.backoff[cur] != nil { state.backoff[cur] = nil; state.save() } // recovered → clear backoff
                currentInternetBad = consecutiveNetFails >= config.netFailThreshold
            }
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
            let r = joinNetwork(ssid, interface: config.interface)
            if r.ok {
                state.lastSwitchEpoch = now
                state.lastTarget = ssid
                state.backoff[ssid] = nil            // joined fine → clear any backoff on the target
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
                if ssid == config.hotspotSSID { lastHotspotProbe = 0 } // force a fresh verify of the new hotspot session
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
                NSColor(calibratedRed: 27 / 255, green: 112 / 255, blue: 212 / 255, alpha: 1)
            )
        }
        return .symbol("antenna.radiowaves.left.and.right", nil)
    }

    func updateButton() {
        guard let button = statusItem.button else { return }
        switch statusIcon() {
        case .symbol(let name, let tint):
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "WifiAutoswitch")
            img?.isTemplate = true
            button.contentTintColor = tint
            button.image = img
        }
        button.toolTip = statusText()
    }

    func statusText() -> String {
        guard let w = lastWifi else { return "Reading Wi-Fi…" }
        if !w.authorized || w.redacted { return "⚠︎ Location permission needed to read Wi-Fi names" }
        guard let ssid = w.current?.ssid else { return "Not connected" }
        let rssi = w.current?.rssi ?? 0
        if ssid == config.hotspotSSID { return "On hotspot · \(ssid) · \(rssi) dBm" }
        var s = "On \(ssid) · \(rssi) dBm"
        if config.homeSSIDs.contains(ssid), let net = lastInternetOK { s += net ? " · internet ✓" : " · internet ✗" }
        return s
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

        addCheck(menu, "Auto-switch", config.enabled, #selector(toggleEnabled))
        addCheck(menu, "Verify internet works", config.connectivityCheck, #selector(toggleConnectivity))
        menu.addItem(.separator())

        // Signal slider
        let hdr = NSMenuItem(title: "Minimum home signal", action: nil, keyEquivalent: ""); hdr.isEnabled = false
        menu.addItem(hdr)
        menu.addItem(sliderItem())
        menu.addItem(.separator())

        menu.addItem(submenuItem("Home networks", build: homeSubmenu()))
        menu.addItem(submenuItem("Hotspot network", build: hotspotSubmenu()))
        menu.addItem(.separator())

        let homeNow = NSMenuItem(title: "Switch to home now", action: #selector(switchHomeNow), keyEquivalent: "")
        homeNow.target = self
        homeNow.isEnabled = bestVisibleHome() != nil
        menu.addItem(homeNow)
        let hsNow = NSMenuItem(title: "Switch to hotspot now", action: #selector(switchHotspotNow), keyEquivalent: "")
        hsNow.target = self
        hsNow.isEnabled = !(config.hotspotSSID ?? "").isEmpty
        menu.addItem(hsNow)
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

    @objc func toggleEnabled() { config.enabled.toggle(); config.save(); updateButton(); work.async { self.runCycle() } }
    @objc func toggleConnectivity() { config.connectivityCheck.toggle(); config.save() }
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
            self.state.backoff.removeAll(); self.consecutiveNetFails = 0; self.state.save()  // manual intervention resets backoff
            let r = joinNetwork(s, interface: self.config.interface)
            logLine("MANUAL → '\(s)' (backoff reset) :: \(r.ok ? "joined" : r.output)")
            self.runCycle()
        }
    }
    @objc func switchHotspotNow() {
        guard let s = config.hotspotSSID, !s.isEmpty else { return }
        work.async {
            self.state.backoff.removeAll(); self.consecutiveNetFails = 0; self.lastHotspotProbe = 0; self.state.save()
            let r = joinNetwork(s, interface: self.config.interface)
            logLine("MANUAL → '\(s)' (backoff reset) :: \(r.ok ? "joined" : r.output)")
            self.runCycle()
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
    if lc.homeSSIDs == ["X"] && lc.minSignal == -55 && lc.weakThreshold == 3 && lc.hotspotProbeSeconds == 600 { print("ok   config decodes leniently (missing keys default)") }
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
