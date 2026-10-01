// ChargeWatts: shows live charging wattage in the macOS menu bar.
// The menu bar item is hidden whenever the Mac is not actively charging.

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
    let milliamps = num(props, "Amperage") ?? 0          // positive while charging
    let batteryWatts = Double(millivolts) * Double(milliamps) / 1_000_000

    var inputWatts: Double? = nil
    if let telemetry = props["PowerTelemetryData"] as? [String: Any],
       let mw = num(telemetry, "SystemPowerIn"), mw > 0 {
        inputWatts = Double(mw) / 1000
    }

    var rating: Int? = nil
    if let adapter = props["AdapterDetails"] as? [String: Any], let w = num(adapter, "Watts"), w > 0 {
        rating = Int(w)
    }

    var percent: Int? = nil
    if let cur = num(props, "CurrentCapacity"), let max = num(props, "MaxCapacity"), max > 0 {
        percent = Int(cur * 100 / max)
    }

    let charging = external && isCharging && batteryWatts >= 0.3
    return Reading(charging: charging, batteryWatts: batteryWatts,
                   inputWatts: inputWatts, adapterRating: rating, percent: percent)
}

func format(_ watts: Double) -> String {
    watts < 10 ? String(format: "%.1fW", watts) : String(format: "%.0fW", watts)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?

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
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Charging")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        let menu = NSMenu()
        for line in [intoBatteryLine, fromChargerLine, ratingLine, percentLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
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
        guard let r = readBattery(), r.charging else {
            item.isVisible = false
            return
        }

        let shown = (mode == .input ? r.inputWatts : nil) ?? r.batteryWatts
        item.button?.title = " " + format(shown)
        item.isVisible = true

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
