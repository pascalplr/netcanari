// NetCanari: a yellow-and-black hazard frame around every screen when the Mac is on an
// untrusted network AND detectable. A banner at the top names what is wrong:
//   - OUTSIDE VPN TUNNEL: default traffic does not leave through the accepted VPN
//   - VISIBLE TO PING: the firewall's stealth mode is off
// A menu bar icon shows the state and the options.
// Install: ./install.sh
import AppKit
import CoreLocation
import CoreWLAN
import Network
import SystemConfiguration

// --- Settings -------------------------------------------------------------
let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
let borderWidth: CGFloat = 10
let stripeWidth: CGFloat = 14
let issueNoTunnel = "OUTSIDE VPN TUNNEL"
let issuePingable = "VISIBLE TO PING"
let hazardYellow = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
/// The canary's head, and the same with crossed-out eyes for "something is wrong".
/// `iconSVG` and `iconAlertSVG` are generated from the .svg files by install.sh.
let canaryIcon: NSImage? = NSImage(data: Data(iconSVG.utf8))
let canaryAlertIcon: NSImage? = NSImage(data: Data(iconAlertSVG.utf8)) ?? canaryIcon

let configDir = NSHomeDirectory() + "/.config/canari"
let trustedPath = configDir + "/trusted"
let tunnelPath = configDir + "/tunnel"
let agentLabel = "local.canari"
let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let stealthScript = NSHomeDirectory() + "/.local/bin/stealth-auto.sh"
// --------------------------------------------------------------------------

func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Optional settings: ~/.config/canari/config (KEY="value" lines), read at launch.
func loadConfig() -> [String: String] {
    guard let text = try? String(contentsOfFile: configDir + "/config", encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        out[key] = value
    }
    return out
}
let wifiInterface = loadConfig()["WIFI_INTERFACE"] ?? "en0"

// --- Trusted networks -------------------------------------------------------
// A network is recognised by its gateway AND its router's MAC address: macOS hides
// the Wi-Fi name from programs without location access, and a name is easier to
// imitate.

func parseMAC(_ s: String) -> [UInt8]? {
    let parts = s.split(separator: ":")
    guard parts.count == 6 else { return nil }
    var out: [UInt8] = []
    for p in parts {
        guard let v = UInt8(p, radix: 16) else { return nil }
        out.append(v)
    }
    return out
}

func formatMAC(_ mac: [UInt8]) -> String {
    mac.map { String(format: "%02x", $0) }.joined(separator: ":")
}

struct TrustedNetwork: Equatable {
    var gateway: String
    var mac: [UInt8]
    var label: String
}

/// File shared with stealth-auto.sh: one "gateway mac name" line per network.
func loadTrusted() -> [TrustedNetwork] {
    guard let text = try? String(contentsOfFile: trustedPath, encoding: .utf8) else { return [] }
    var out: [TrustedNetwork] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let mac = parseMAC(String(parts[1])) else { continue }
        let gw = String(parts[0])
        out.append(TrustedNetwork(gateway: gw, mac: mac, label: parts.count > 2 ? String(parts[2]) : gw))
    }
    return out
}

func saveTrusted(_ list: [TrustedNetwork]) {
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    var text = "# Trusted networks: gateway, router MAC, name. Managed by canari.\n"
    for n in list { text += "\(n.gateway) \(formatMAC(n.mac)) \(n.label)\n" }
    try? text.write(toFile: trustedPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trustedPath)
}

let configStore = SCDynamicStoreCreate(nil, "canari.read" as CFString, nil, nil)

/// Gateway and router MAC of the current Wi-Fi, read from the macOS configuration
/// store. `arp` is no use here: launched by a program not signed by Apple, it
/// returns no entries (local network privacy).
/// nil = no network on the interface; nil mac = router not resolved yet.
func currentNetwork() -> (gateway: String, mac: [UInt8]?)? {
    guard let store = configStore,
          let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString)
            as? [String] else { return nil }
    for key in keys {
        guard let d = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
              d["InterfaceName"] as? String == wifiInterface,
              let router = d["Router"] as? String else { continue }
        return (router, (d["ARPResolvedHardwareAddress"] as? String).flatMap(parseMAC))
    }
    return nil
}

/// Name of the current Wi-Fi. macOS only gives it to an app allowed to read the
/// location; otherwise nil. A label only: the router's MAC is what identifies a network.
func currentSSID() -> String? {
    CWWiFiClient.shared().interface(withName: wifiInterface)?.ssid()
}

func trustedMatch() -> TrustedNetwork? {
    guard let net = currentNetwork(), let mac = net.mac else { return nil }
    return loadTrusted().first { $0.gateway == net.gateway && $0.mac == mac }
}

// --- Accepted tunnel ----------------------------------------------------------
// By default any VPN carrying the default traffic counts as protection. A specific
// VPN can be required instead, picked from those configured on the Mac.

struct VPNService: Equatable {
    var id: String
    var name: String
}

/// Required VPN (file "id<TAB>name"), or nil to accept any.
func requiredTunnel() -> VPNService? {
    guard let text = try? String(contentsOfFile: tunnelPath, encoding: .utf8) else { return nil }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty else { return nil }
    return VPNService(id: parts[0], name: parts[1])
}

func setRequiredTunnel(_ service: VPNService?) {
    guard let service = service else {
        try? FileManager.default.removeItem(atPath: tunnelPath)
        return
    }
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    try? "\(service.id)\t\(service.name)\n".write(toFile: tunnelPath, atomically: true, encoding: .utf8)
}

/// VPNs configured on the Mac, as listed by `scutil --nc list`.
func configuredVPNs() -> [VPNService] {
    var out: [VPNService] = []
    for line in run("/usr/sbin/scutil", ["--nc", "list"]).split(separator: "\n") {
        guard let id = line.range(of: "[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
                                  options: .regularExpression),
              let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""),
              open < close else { continue }
        out.append(VPNService(id: String(line[id]), name: String(line[line.index(after: open)..<close])))
    }
    return out
}

/// Service and interface carrying the default traffic; nil = offline.
func primaryRoute() -> (service: String, interface: String)? {
    guard let store = configStore,
          let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
          let service = g["PrimaryService"] as? String,
          let interface = g["PrimaryInterface"] as? String else { return nil }
    return (service, interface)
}

func stealthModeOn() -> Bool {
    run(firewallTool, ["--getstealthmode"]).contains(" on")
}

/// place: offline (no network), trusted (trusted network) or away (anywhere else).
/// issues: unmet criteria; always empty outside "away".
struct Assessment: Equatable {
    var place: String
    var match: TrustedNetwork?
    var issues: [String]
}

func assess() -> Assessment {
    guard let route = primaryRoute() else { return Assessment(place: "offline", match: nil, issues: []) }
    if let hit = trustedMatch() {
        return Assessment(place: "trusted", match: hit, issues: [])
    }
    var issues: [String] = []
    if let wanted = requiredTunnel() {
        if route.service != wanted.id { issues.append("OUTSIDE \(wanted.name.uppercased()) TUNNEL") }
    } else if !["utun", "ipsec", "ppp"].contains(where: route.interface.hasPrefix) {
        issues.append(issueNoTunnel)
    }
    if !stealthModeOn() { issues.append(issuePingable) }
    return Assessment(place: "away", match: nil, issues: issues)
}

func describe(_ a: Assessment) -> String {
    switch a.place {
    case "offline": return "Offline"
    case "trusted": return "Trusted network: \(a.match?.label ?? "?")"
    default:
        return a.issues.isEmpty
            ? "Protected: \(requiredTunnel()?.name ?? "VPN") tunnel and stealth mode"
            : "Exposed: " + a.issues.joined(separator: ", ")
    }
}

// --- Launch at login ----------------------------------------------------------
// Enabled = the LaunchAgent exists. Removing it does not stop the running program.

func loginEnabled() -> Bool { FileManager.default.fileExists(atPath: agentPath) }

func setLogin(_ on: Bool) {
    guard on else {
        try? FileManager.default.removeItem(atPath: agentPath)
        return
    }
    let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath().path
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [exe],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],   // restart after a crash, not after Quit
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "AssociatedBundleIdentifiers": [agentLabel],
    ]
    guard let data = try? PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0) else { return }
    try? FileManager.default.createDirectory(
        atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: agentPath))
}

// --- Display ------------------------------------------------------------------

final class HazardView: NSView {
    var issues: [String] = []
    var topInset: CGFloat = 0   // notch height, so the banner sits below it

    override func draw(_ dirtyRect: NSRect) {
        // Frame ring: yellow background, black diagonal stripes.
        NSGraphicsContext.saveGraphicsState()
        let ring = NSBezierPath(rect: bounds)
        ring.append(NSBezierPath(rect: bounds.insetBy(dx: borderWidth, dy: borderWidth)))
        ring.windingRule = .evenOdd
        ring.addClip()
        hazardYellow.setFill()
        bounds.fill()
        NSColor.black.setFill()
        let h = bounds.height
        var x = -h
        while x < bounds.width {
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: x, y: 0))
            stripe.line(to: NSPoint(x: x + stripeWidth, y: 0))
            stripe.line(to: NSPoint(x: x + stripeWidth + h, y: h))
            stripe.line(to: NSPoint(x: x + h, y: h))
            stripe.close()
            stripe.fill()
            x += stripeWidth * 2
        }
        NSGraphicsContext.restoreGraphicsState()

        // Banner: canary + unmet criteria, centred under the top edge (or the notch).
        guard !issues.isEmpty else { return }
        let icon = canaryAlertIcon
        let text = NSAttributedString(
            string: (icon == nil ? "⚠  " : "") + issues.joined(separator: "   ·   "),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .heavy),
                .foregroundColor: hazardYellow,
                .kern: 0.6,
            ])
        let size = text.size()
        let iconSize: CGFloat = icon == nil ? 0 : 28
        let gap: CGFloat = icon == nil ? 0 : 8
        let padLeft: CGFloat = icon == nil ? 16 : 6, padRight: CGFloat = 16, padY: CGFloat = 4
        let w = padLeft + iconSize + gap + size.width + padRight
        let hgt = max(size.height, iconSize) + padY * 2
        let top = bounds.maxY - max(borderWidth, topInset)
        let box = NSRect(x: bounds.midX - w / 2, y: top - hgt, width: w, height: hgt)
        let pill = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
        NSColor(srgbRed: 0.078, green: 0.078, blue: 0.078, alpha: 1).setFill()   // icon background
        pill.fill()
        hazardYellow.setStroke()
        pill.lineWidth = 2
        pill.stroke()
        icon?.draw(in: NSRect(x: box.minX + padLeft, y: box.midY - iconSize / 2,
                              width: iconSize, height: iconSize))
        text.draw(at: NSPoint(x: box.minX + padLeft + iconSize + gap, y: box.midY - size.height / 2))
    }
}

/// Window that refuses any automatic repositioning by macOS.
final class FrameWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, CLLocationManagerDelegate {
    var demo = false
    private var windows: [NSWindow] = []
    private var issues: [String] = []
    private var last = Assessment(place: "offline", match: nil, issues: [])
    private let monitor = NWPathMonitor()
    private let work = DispatchQueue(label: "canari.eval")
    private let scriptQueue = DispatchQueue(label: "canari.script")
    private var pending: DispatchWorkItem?
    private var store: SCDynamicStore?
    private var usr1: DispatchSourceSignal?
    private var usr2: DispatchSourceSignal?
    private var demoActive = false
    private var statusItem: NSStatusItem?
    private let stateLine = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    private let location = CLLocationManager()

    func applicationDidFinishLaunching(_ note: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.render() }

        if demo {   // show the frame for 8 s with both criteria, then quit
            issues = [issueNoTunnel, issuePingable]
            render()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
            return
        }
        setupStatusItem()
        // Ask for location access on first launch, to read the Wi-Fi name.
        location.delegate = self
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        monitor.pathUpdateHandler = { [weak self] _ in self?.schedule() }
        monitor.start(queue: work)
        watchDynamicStore()
        // `pkill -USR1 -x canari` forces a re-evaluation (sent by stealth-auto.sh).
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: work)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.resume()
        usr1 = src
        // `canari --demo` sends SIGUSR2: show the alert state for 8 s, then go back to reality.
        signal(SIGUSR2, SIG_IGN)
        let demoSrc = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        demoSrc.setEventHandler { [weak self] in self?.runDemo() }
        demoSrc.resume()
        usr2 = demoSrc
        // Safety net: a stealth mode change emits no network event.
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.schedule()
        }
        timer.tolerance = 20
        schedule()
    }

    /// Frame, banner and menu bar icon in their alert state for 8 s.
    private func runDemo() {
        guard !demoActive else { return }
        demoActive = true
        issues = [issueNoTunnel, issuePingable]
        render()
        setStatusIcon(alert: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            self.demoActive = false
            self.issues = []
            self.render()
            self.schedule(after: 0)
        }
    }

    /// Re-evaluates the state after the last event (debounced).
    func schedule(after delay: TimeInterval = 1) {
        work.async {
            self.pending?.cancel()
            let item = DispatchWorkItem {
                var a = assess()
                // A trusted network's stored name follows the real Wi-Fi name.
                if let m = a.match, let ssid = currentSSID(), !ssid.isEmpty, ssid != m.label {
                    var list = loadTrusted()
                    if let i = list.firstIndex(of: m) {
                        list[i].label = ssid.replacingOccurrences(of: "\n", with: " ")
                        saveTrusted(list)
                        a.match = list[i]
                    }
                }
                let unconfigured = loadTrusted().isEmpty
                DispatchQueue.main.async {
                    guard !self.demoActive else { return }
                    self.setStatusIcon(alert: !a.issues.isEmpty || (unconfigured && a.place != "offline"))
                    // Moving between offline, a trusted network and anywhere else re-runs
                    // stealth-auto.sh. NetCanari does this itself: the Shortcuts Wi-Fi trigger
                    // is debounced and drops joins that follow each other closely.
                    if a.place != self.last.place || a.match != self.last.match, a.place != "offline" {
                        self.runStealthScript()
                    }
                    self.last = a
                    self.stateLine.title = describe(a)
                    self.statusItem?.button?.toolTip = "NetCanari · " + describe(a)
                        + (unconfigured ? " · no trusted network yet" : "")
                    guard a.issues != self.issues else { return }
                    self.issues = a.issues
                    self.render()
                }
            }
            self.pending = item
            self.work.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // --- Menu bar ---

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "canari"   // macOS remembers where Cmd-drag put it
        statusItem = item
        setStatusIcon(alert: false)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        stateLine.isEnabled = false
        item.menu = menu
        statusItem = item
    }

    /// Crossed-out eyes when a criterion is unmet or no trusted network is set up yet.
    private func setStatusIcon(alert: Bool) {
        guard let button = statusItem?.button else { return }
        if let icon = (alert ? canaryAlertIcon : canaryIcon)?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
        } else {
            button.title = alert ? "✕" : "●"
        }
    }

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.isEnabled = action != nil
        return i
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { schedule(after: 0) }

    private var ssidReadable: Bool {
        let s = location.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    @objc private func askWiFiName() {
        if location.authorizationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            location.requestWhenInUseAuthorization()
        } else {
            inform("Wi-Fi name hidden",
                   "To show it, allow NetCanari in System Settings → Privacy & Security → "
                   + "Location Services.")
        }
    }

    /// The menu is rebuilt each time it opens, from the networks file.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(stateLine)
        if last.place != "offline" {
            if let ssid = currentSSID() {
                menu.addItem(item("Wi-Fi: \(ssid)", nil))
            } else if !ssidReadable {
                menu.addItem(item("Show Wi-Fi Name…", #selector(askWiFiName)))
            }
        }
        menu.addItem(.separator())

        if last.place == "trusted" {
            menu.addItem(item("Stop Trusting This Network", #selector(untrustCurrent)))
        } else if last.place == "away" {
            menu.addItem(item("Trust This Network…", #selector(trustCurrent)))
        }
        let sub = NSMenu()
        sub.autoenablesItems = false
        let list = loadTrusted()
        if list.isEmpty {
            sub.addItem(item("No networks", nil))
        } else {
            sub.addItem(item("Click a network to remove it", nil))
            sub.addItem(.separator())
            for (index, n) in list.enumerated() {
                let entry = item("\(n.label)  —  \(n.gateway)  ·  router \(formatMAC(n.mac))",
                                 #selector(removeTrusted(_:)))
                entry.tag = index
                entry.state = (n == last.match) ? .on : .off
                sub.addItem(entry)
            }
        }
        let parent = item("Trusted Networks", nil)
        parent.isEnabled = true
        parent.submenu = sub
        menu.addItem(parent)

        let tunnels = NSMenu()
        tunnels.autoenablesItems = false
        let wanted = requiredTunnel()
        let anyVPN = item("Any VPN", #selector(selectTunnel(_:)))
        anyVPN.state = wanted == nil ? .on : .off
        tunnels.addItem(anyVPN)
        tunnels.addItem(.separator())
        var services = configuredVPNs()
        if let wanted = wanted, !services.contains(where: { $0.id == wanted.id }) {
            services.append(VPNService(id: wanted.id, name: wanted.name + " (not found)"))
        }
        if services.isEmpty { tunnels.addItem(item("No VPN configured on this Mac", nil)) }
        for service in services {
            let entry = item(service.name, #selector(selectTunnel(_:)))
            entry.representedObject = [service.id, service.name]
            entry.state = service.id == wanted?.id ? .on : .off
            tunnels.addItem(entry)
        }
        let tunnelParent = item("Accepted Tunnel", nil)
        tunnelParent.isEnabled = true
        tunnelParent.submenu = tunnels
        menu.addItem(tunnelParent)
        menu.addItem(.separator())

        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit NetCanari",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleLogin() { setLogin(!loginEnabled()) }

    @objc private func selectTunnel(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [String], pair.count == 2 {
            setRequiredTunnel(VPNService(id: pair[0], name: pair[1]))
        } else {
            setRequiredTunnel(nil)
        }
        schedule(after: 0)
    }

    @objc private func trustCurrent() {
        work.async {
            let net = currentNetwork()
            DispatchQueue.main.async {
                guard let gw = net?.gateway, let mac = net?.mac else {
                    self.inform("Network not identifiable",
                                "Could not read the gateway or the router address on \(wifiInterface).")
                    return
                }
                // The name is the Wi-Fi's; only asked for when macOS hides it.
                let ssid = currentSSID()
                let alert = NSAlert()
                alert.messageText = ssid.map { "Trust “\($0)”?" } ?? "Trust this network?"
                alert.informativeText = "Gateway \(gw), router \(formatMAC(mac)).\n\n"
                    + "On a trusted network the frame no longer appears and the firewall's "
                    + "stealth mode is turned off. Only trust networks you control."
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                if ssid == nil {
                    field.stringValue = "Network \(gw)"
                    field.placeholderString = "Network name"
                    alert.accessoryView = field
                    alert.window.initialFirstResponder = field
                }
                alert.addButton(withTitle: "Trust")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                var label = (ssid ?? field.stringValue)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if label.isEmpty { label = "Network \(gw)" }
                var list = loadTrusted().filter { !($0.gateway == gw && $0.mac == mac) }
                list.append(TrustedNetwork(gateway: gw, mac: mac, label: label))
                saveTrusted(list)
                self.trustedDidChange()
            }
        }
    }

    @objc private func untrustCurrent() {
        guard let match = last.match else { return }
        saveTrusted(loadTrusted().filter { $0 != match })
        trustedDidChange()
    }

    @objc private func removeTrusted(_ sender: NSMenuItem) {
        var list = loadTrusted()
        guard list.indices.contains(sender.tag) else { return }
        let n = list[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Remove “\(n.label)” from trusted networks?"
        alert.informativeText = "Gateway \(n.gateway), router \(formatMAC(n.mac))."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        list.remove(at: sender.tag)
        saveTrusted(list)
        trustedDidChange()
    }

    /// After the list changes, re-evaluate; a change of place then re-runs the script.
    private func trustedDidChange() { schedule(after: 0) }

    /// Runs stealth-auto.sh off the evaluation queue (it can wait ~10 s for the network).
    private func runStealthScript() {
        guard FileManager.default.isExecutableFile(atPath: stealthScript) else { return }
        scriptQueue.async { _ = run(stealthScript, []) }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // --- Network events and windows ---

    private func watchDynamicStore() {
        var ctx = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        guard let s = SCDynamicStoreCreate(nil, "canari" as CFString, { _, _, info in
            guard let info = info else { return }
            Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().schedule()
        }, &ctx) else { return }
        SCDynamicStoreSetNotificationKeys(
            s, ["State:/Network/Global/IPv4"] as CFArray,
            ["State:/Network/Service/.*/IPv4"] as CFArray)
        SCDynamicStoreSetDispatchQueue(s, work)
        store = s
    }

    private func render() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guard !issues.isEmpty else { return }
        for screen in NSScreen.screens {
            let w = FrameWindow(contentRect: screen.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            if !demo { w.sharingType = .none }   // hidden from screen sharing
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = HazardView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.issues = issues
            view.topInset = screen.safeAreaInsets.top
            w.contentView = view
            w.orderFrontRegardless()
            w.setFrame(screen.frame, display: true)
            windows.append(w)
        }
    }
}

// --- Command line -------------------------------------------------------------

let args = CommandLine.arguments
if args.contains("--status") {
    let a = assess()
    print("\(describe(a)) (place=\(a.place), launch at login=\(loginEnabled() ? "yes" : "no"), "
          + "Wi-Fi=\(currentSSID() ?? "name hidden"))")
    exit(0)
}
if args.contains("--trusted") {
    // For stealth-auto.sh: 0 = trusted network, 1 = not trusted, 2 = network not ready yet.
    guard let net = currentNetwork(), net.mac != nil else { exit(2) }
    exit(trustedMatch() == nil ? 1 : 0)
}
if args.contains("--tunnels") {
    let wanted = requiredTunnel()
    print("\(wanted == nil ? "*" : " ") Any VPN")
    for v in configuredVPNs() { print("\(v.id == wanted?.id ? "*" : " ") \(v.name)") }
    exit(0)
}
if args.contains("--list") {
    let list = loadTrusted()
    if list.isEmpty { print("No trusted networks.") }
    for n in list { print("\(n.label)\t\(n.gateway)\t\(formatMAC(n.mac))") }
    exit(0)
}
if let i = args.firstIndex(of: "--login"), i + 1 < args.count {
    setLogin(args[i + 1] == "on")
    exit(0)
}
let app = NSApplication.shared
if let i = args.firstIndex(of: "--icon-png"), i + 2 < args.count, let px = Int(args[i + 1]) {
    // Renders the embedded icon to a transparent PNG (install.sh builds the app icon from it).
    guard let icon = canaryIcon,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.current = nil
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: args[i + 2])) } catch { exit(1) }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    // Renders the frame to a PNG without showing anything (off-screen visual check).
    let view = HazardView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
    view.issues = [issueNoTunnel, issuePingable]
    view.topInset = 38
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: args[i + 1])) } catch { exit(1) }
    exit(0)
}
if args.contains("--demo") {
    // If NetCanari is already running, ask it to play the demo itself, so the menu bar
    // icon changes too. Otherwise fall through and show the frame from this process.
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: agentLabel)
        .filter { $0.processIdentifier != me }
    if let running = others.first {
        kill(running.processIdentifier, SIGUSR2)
        exit(0)
    }
}
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
delegate.demo = args.contains("--demo")
app.delegate = delegate
app.run()
