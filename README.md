# ChargeWatts

A tiny macOS menu bar app that shows the wattage your MacBook is charging at. It also says when the charger is not keeping up, and it disappears when the Mac is not charging.

![ChargeWatts in the menu bar](docs/screenshot.png)

No settings window, no Dock icon, no network access, no dependencies. One Swift file, about 250 lines.

## Features

- Live charging wattage in the menu bar, refreshed every 2 seconds
- Hidden when you are on battery, fully charged, or held at a charge limit. It stays up when the Mac draws more than the charger supplies, which makes battery current go negative
- Click it to see whether the battery is charging, losing, or holding, and how that splits between the Mac, the charger, and the battery
- The menu also shows power into the battery, power from the charger, the charger's rated wattage, and battery percentage
- Choose which number the menu bar shows: power into the battery (default) or power from the charger
- Launch at Login toggle in the menu (macOS 13 or later)

## Install

### Download

1. Grab `ChargeWatts.zip` from the [latest release](https://github.com/AndreCamm/ChargeWatts/releases/latest) and unzip it.
2. Move `ChargeWatts.app` to your Applications folder.
3. Open it. The app isn't notarised by Apple, so the first time macOS will block it. Go to **System Settings, Privacy & Security**, scroll down and click **Open Anyway**. Alternatively, run:

   ```
   xattr -dr com.apple.quarantine /Applications/ChargeWatts.app
   ```

### Build from source

You need Xcode or the Command Line Tools (`xcode-select --install`).

```
git clone https://github.com/AndreCamm/ChargeWatts.git
cd ChargeWatts
./build.sh
cp -r build/ChargeWatts.app /Applications/
open /Applications/ChargeWatts.app
```

Apps you build yourself aren't quarantined, so there's no Gatekeeper prompt.

## Using it

**Nothing appears when I open it.** That's expected unless the Mac is actively charging. Plug in a charger with the battery below full and the bolt will show up within a couple of seconds. On MacBooks with a notch, a crowded menu bar can also push items behind the notch.

**The menu says "Losing battery".** The charger is connected, and macOS still reports charging, but the Mac is using more than the adapter supplies. The battery covers the difference, so the percentage can fall while the bolt is showing. The second menu line is the split: what the Mac is using, what the charger is delivering, and what the battery is covering. Within 1W of zero the menu says **Holding** instead.

**Start at login.** Click the item and tick **Launch at Login** (macOS 13 or later). On macOS 12, add ChargeWatts under System Settings, General, Login Items instead.

**Quit.** Click the item and choose Quit. If it's hidden because you're not charging, run `killall ChargeWatts` in Terminal.

## Why doesn't it match my wall meter?

There are three different numbers, measured at different points:

| Where | Example | What it is |
|---|---|---|
| Wall socket | 103W | What the power brick draws from the mains |
| From charger | 96W | What reaches the Mac. The difference is lost as heat in the brick |
| Into battery | 35W | What's left after the Mac takes what it needs to run |

So with those numbers the Mac itself is using about 61W, and the rest goes into the battery. The menu's second line is that split. If you want the figure closest to your wall meter, click the item and choose **Show power from charger**.

If the Mac uses more than the charger delivers, "into battery" goes negative and the menu says **Losing battery**. The menu bar can still show a positive "from charger" number. That is the charger doing its job while the battery makes up the rest.

Charging also slows down on its own as the battery passes roughly 80%, because macOS tapers charging to protect the battery.

## How it works

macOS publishes live battery data in the IORegistry under `AppleSmartBattery`. ChargeWatts reads it every 2 seconds:

- **Into battery** is `Voltage` multiplied by `Amperage`. Above 1W the menu says charging, below -1W it says the battery is covering the difference, and in between it says holding
- **From charger** is `PowerTelemetryData.SystemPowerIn` (Apple Silicon only)
- **Mac load** is `PowerTelemetryData.SystemLoad` (Apple Silicon only)
- **Charger rating** is `AdapterDetails.Watts`, the wattage the charger and Mac negotiated
- **Charging** means the adapter is connected and macOS reports `IsCharging`. That flag stays true even when battery current goes negative because the Mac is drawing more than the charger supplies. The item hides a few seconds after charging stops

You can see the same raw data yourself with:

```
ioreg -rn AppleSmartBattery
```

## Requirements

- macOS 12 Monterey or later. Launch at Login needs macOS 13
- A Mac with a battery. The "from charger" and Mac load figures need Apple Silicon

## Contributing

Issues and pull requests are welcome. The whole app lives in [`Sources/ChargeWatts.swift`](Sources/ChargeWatts.swift), and the aim is to keep it small and single purpose.

## License

[MIT](LICENSE)
