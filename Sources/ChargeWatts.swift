// ChargeWatts: shows live charging wattage in the macOS menu bar.
// The item hides a few seconds after charging stops. Battery current is not
// part of that decision: under load it goes negative while macOS still
// reports that the battery is charging.

import AppKit
import IOKit
import ServiceManagement

enum Mode: String {
    case battery   // power flowing into the battery (Voltage x Amperage)
    case input     // power coming in from the charger (Apple Silicon only)
}

struct Reading {
    let charging: Bool
    let batteryWatts: Double
    let inputWatts: Double?
    let systemLoad: Double?
    let adapterRating: Int?
    let percent: Int?
}

func num(_ dict: [String: Any], _ key: String) -> Int64? {
    (dict[key] as? NSNumber)?.int64Value
}

func readBattery() -> Reading? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

    let external = (props["ExternalConnected"] as? Bool) ?? false
    let isCharging = (props["IsCharging"] as? Bool) ?? false
    let millivolts = num(props, "Voltage") ?? 0
    let milliamps = num(props, "Amperage") ?? 0          // positive into the battery
    let batteryWatts = Double(millivolts) * Double(milliamps) / 1_000_000

    var inputWatts: Double? = nil
    var systemLoad: Double? = nil
    if let telemetry = props["PowerTelemetryData"] as? [String: Any] {
        if let mw = num(telemetry, "SystemPowerIn"), mw > 0 {
            inputWatts = Double(mw) / 1000
        }
        if let mw = num(telemetry, "SystemLoad"), mw > 0 {
            systemLoad = Double(mw) / 1000
        }
    }

    var rating: Int? = nil
    if let adapter = props["AdapterDetails"] as? [String: Any], let w = num(adapter, "Watts"), w > 0 {
        rating = Int(w)
    }

    var percent: Int? = nil
    if let cur = num(props, "CurrentCapacity"), let max = num(props, "MaxCapacity"), max > 0 {
        percent = Int(cur * 100 / max)
    }

    // IsCharging stays true when the Mac draws more than the adapter supplies.
    // Positive battery watts are only a fallback for a lagging IsCharging flag.
    let charging = external && (isCharging || batteryWatts >= 0.3)
    return Reading(charging: charging, batteryWatts: batteryWatts,
                   inputWatts: inputWatts, systemLoad: systemLoad,
                   adapterRating: rating, percent: percent)
}

// Within 1W of zero the battery is not really charging or discharging.
let paceBand = 1.0

enum Pace {
    case charging, losing, holding
}

func pace(of batteryWatts: Double) -> Pace {
    if batteryWatts >= paceBand { return .charging }
    if batteryWatts <= -paceBand { return .losing }
    return .holding
}

func paceTitle(_ pace: Pace) -> String {
    switch pace {
    case .charging: return "Charging"
    case .losing: return "Losing battery"
    case .holding: return "Holding"
    }
}

func headroomTitle(batteryWatts: Double, input: Double?, load: Double?) -> String? {
    var parts: [String] = []
    if let load, load > 0 { parts.append("Mac " + format(load)) }
    if let input, input > 0 { parts.append("charger " + format(input)) }
    switch pace(of: batteryWatts) {
    case .charging:
        parts.append(format(batteryWatts) + " into the battery")
    case .losing:
        parts.append("battery covering " + format(abs(batteryWatts)))
    case .holding:
        break
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

func format(_ watts: Double) -> String {
    abs(watts) < 10 ? String(format: "%.1fW", watts) : String(format: "%.0fW", watts)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var idleSince: Date?
    private let hideDelay: TimeInterval = 6

    private let paceLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let headroomLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let intoBatteryLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fromChargerLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ratingLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let percentLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let batteryChoice = NSMenuItem(title: "Show power into battery", action: #selector(pickBattery), keyEquivalent: "")
    private let inputChoice = NSMenuItem(title: "Show power from charger", action: #selector(pickInput), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .battery }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mode"); refresh() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = false
        configureButton()

        let menu = NSMenu()
        for line in [paceLine, headroomLine, intoBatteryLine, fromChargerLine, ratingLine, percentLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.insertItem(.separator(), at: 2)
        menu.addItem(.separator())
        batteryChoice.target = self
        inputChoice.target = self
        menu.addItem(batteryChoice)
        menu.addItem(inputChoice)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit ChargeWatts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        updateLoginItem()
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(refresh),
                                     userInfo: nil, repeats: true)
    }

    @objc func pickBattery() { mode = .battery }
    @objc func pickInput() { mode = .input }

    private func configureButton() {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Charging")
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    // Launch at Login uses SMAppService, available from macOS 13.
    // On macOS 12 the menu item is hidden; add the app under Login Items instead.
    @objc func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add ChargeWatts manually in System Settings, General, Login Items."
            alert.runModal()
        }
        updateLoginItem()
    }

    func updateLoginItem() {
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
    }

    @objc func refresh() {
        guard let r = readBattery() else { return }

        if r.charging {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = Date()
        }

        // Keep the last reading through a short gap so one sample cannot
        // remove the item and leave it stuck behind the menu bar.
        let grace = item.isVisible
            && (idleSince.map { Date().timeIntervalSince($0) < hideDelay } ?? false)
        guard r.charging || grace else {
            item.isVisible = false
            return
        }

        if !item.isVisible || item.button?.image == nil {
            configureButton()
        }

        let shown = (mode == .input ? r.inputWatts : nil) ?? r.batteryWatts
        item.button?.title = " " + format(shown)
        item.length = NSStatusItem.variableLength
        item.isVisible = true

        paceLine.title = paceTitle(pace(of: r.batteryWatts))
        if let headroom = headroomTitle(batteryWatts: r.batteryWatts, input: r.inputWatts, load: r.systemLoad) {
            headroomLine.title = headroom
            headroomLine.isHidden = false
        } else {
            headroomLine.isHidden = true
        }

        intoBatteryLine.title = "Into battery: " + format(r.batteryWatts)
        fromChargerLine.title = "From charger: " + (r.inputWatts.map(format) ?? "n/a")
        fromChargerLine.isHidden = r.inputWatts == nil
        ratingLine.title = "Charger rating: " + (r.adapterRating.map { "\($0)W" } ?? "n/a")
        ratingLine.isHidden = r.adapterRating == nil
        percentLine.title = "Battery: " + (r.percent.map { "\($0)%" } ?? "n/a")
        percentLine.isHidden = r.percent == nil

        batteryChoice.state = mode == .battery ? .on : .off
        inputChoice.state = mode == .input ? .on : .off
        inputChoice.isEnabled = r.inputWatts != nil
        updateLoginItem()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
