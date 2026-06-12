# swift-yeelight-wifi

A Swift port of the [`node-yeelight-wifi`](https://github.com/Bastl34/node-yeelight-wifi)
library for controlling Yeelight smart bulbs over your local network.

The original Node.js implementation exposes two classes:

- `Lookup` — discovers bulbs on the LAN via SSDP (with a port-scan
  fallback).
- `Yeelight` — opens a persistent JSON-RPC-over-TCP connection to a
  single bulb and lets you set power, color, brightness, color
  temperature, and HSV.

This package reproduces both with the same public surface, so a Node.js
caller translates to Swift with minimal changes.

## Requirements

- macOS 12+ (Apple's `Network.framework` is the only system dependency)
- Swift 5.9+

## Installation

Add `swift-yeelight-wifi` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourname/swift-yeelight-wifi.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["YeelightWiFi"])
]
```

## Usage

```swift
import YeelightWiFi

let look = YeelightWiFi.Lookup()

look.on(YeelightEvent.detected) { light in
    print("new yeelight detected: id=\(light.id) name=\(light.name)")

    light.on(YeelightEvent.connected) { _ in print("connected") }
    light.on(YeelightEvent.disconnected) { _ in print("disconnected") }
    light.on(YeelightEvent.stateUpdate) { l in print(l.rgb) }
    light.on(YeelightEvent.failed) { failure in
        if let f = failure as? FailedEvent { print(f) }
    }

    Task {
        try? await light.setPower(true)
        try? await light.setRGB(RGB(r: 255, g: 255, b: 0))
        try? await light.setBright(80)
        try? await light.updateState()
    }
}

// Keep the process alive.
RunLoop.main.run()
```

### Methods on `Yeelight`

| Method | Description |
|--------|-------------|
| `setPower(_ on: Bool, duration: Int = 0)` | Turn the bulb on or off. |
| `setRGB(_ rgb: RGB, duration: Int = 0)` | Set the RGB color (0–255 per channel). |
| `setHSV(_ hsv: HSV, duration: Int = 0)` | Set the HSV color. |
| `setCT(_ ct: Int, duration: Int = 0)` | Set the color temperature (1700–6500 K). |
| `setBright(_ value: Int, duration: Int = 0)` | Set brightness (0–100). |
| `updateState()` | Refresh the cached state via `get_prop`. |

`duration` is the transition time in milliseconds. Anything `> 0`
selects `"smooth"` mode; otherwise the change is `"sudden"`.

### Cached state (read-only on `Yeelight`)

| Property | Type | Notes |
|----------|------|-------|
| `power` | `Bool` | |
| `type` | `YeelightType` | `.unknown`, `.white`, `.color` |
| `bright` | `Int` | 0–100 |
| `rgb` | `RGB` | |
| `hsb` | `HSV` | |
| `colorMode` | `Int` | 1 = RGB, 2 = CT, 3 = HSV |
| `id`, `name`, `host`, `port`, `mac`, `model`, `firmware`, `support` | `String` / `Int` | MAC is always empty in the Swift port (see *Limitations*). |

### Events

`Yeelight` and `Lookup` both emit events through `on(_:handler:)`.
Use the `YeelightEvent` enum to make event names refactor-safe:

- `connected` / `disconnected`
- `stateUpdate` (caller receives the `Yeelight` instance)
- `update`, `success`, `timeout`, `failed`
- `detected` (emitted by `Lookup`)

### Port-scan fallback

If SSDP is blocked on your network you can drive a slow scan instead:

```swift
let look = YeelightWiFi.Lookup()
await look.findByPortscanning()
```

The fallback walks every `/24` prefix of every non-internal IPv4
interface and probes TCP 55443. Detected lights are added to
`look.lights` and emit the `detected` event.

## Limitations vs. the Node.js version

- The `mac` field is always empty. The original library obtains it
  through `node-arp`, which has no portable Foundation equivalent; the
  upstream README already notes MAC is "not guaranteed".
- The SSDP implementation supports the `wifi_bulb` search target only,
  matching what the original library uses.
- The Swift port is currently macOS-only. The implementation uses
  `Network.framework` (`NWConnection`, `NWConnectionGroup`) and the
  `getifaddrs` POSIX API. Linux support is feasible with `Network`
  + `Glibc` but is out of scope for this port.

## License

MIT — see [`LICENSE`](LICENSE). Copyright (c) 2017 Bastian Karge,
preserved from the original `node-yeelight-wifi` project.
