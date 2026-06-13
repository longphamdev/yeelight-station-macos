# YeelightWiFi

`YeelightWiFi` discovers Yeelight bulbs on the local network and sends Yeelight
JSON-RPC commands over TCP. It also provides color conversion helpers and music
mode streaming for high-frequency RGB updates.

## Public Facade

```swift
import YeelightWiFi

let lookup = YeelightWiFi.Lookup()
```

The facade exposes:

```swift
YeelightWiFi.Lookup   // YeelightLookup
YeelightWiFi.Yeelight // YeelightDevice
```

## Discovery

`YeelightLookup` uses SSDP with Yeelight's `wifi_bulb` search target.

```swift
let lookup = YeelightLookup(autoStart: false)
await lookup.lookup()
let lights = lookup.getLights()
```

Discovered devices are represented by `YeelightDevice`. Important fields:

- `id`: Yeelight device ID.
- `name`: Device name from SSDP, if present.
- `host` and `port`: TCP endpoint for commands.
- `support`: Space-separated supported Yeelight methods.
- `type`: `.color`, `.white`, or `.unknown`.

## Normal Commands

`YeelightDevice` owns a TCP connection to the bulb and sends CRLF-terminated
JSON-RPC commands.

Common setters:

```swift
try await light.setPower(true)
try await light.setRGB(RGB(r: 255, g: 120, b: 40))
try await light.setBright(80)
try await light.setHSV(HSV(h: 30, s: 100, b: 80))
try await light.setCT(3000)
```

`sendCommand(method:params:)` is public for commands that do not have a typed
wrapper.

## Color Helpers

Yeelight RGB uses a 24-bit integer wire format:

```swift
let rgb = RGB(r: 255, g: 120, b: 40)
let value = rgbToInt(rgb)
let roundTrip = intToRGB(value)
```

The module also includes HSV conversion and color-temperature helpers.

## Music Mode

Music mode lets the bulb connect back to a local TCP listener. Once connected,
the app can stream `set_rgb` lines over that callback socket.

```swift
let session = try await YeelightMusicModeSession.start(device: light)
try await session.sendRGB(RGB(r: 10, g: 20, b: 30))
await session.stop()
```

`setMusic(enabled:host:port:)` wraps Yeelight's `set_music` command:

```swift
try await light.setMusic(enabled: true, host: "192.168.2.10", port: 50000)
try await light.setMusic(enabled: false)
```

## Errors and Failures

Common failures:

- `request timed out`: The bulb did not answer a JSON-RPC command.
- `method is not supported`: The bulb support list does not include the method.
- `missingLocalAddress`: No local IPv4 address was found for music mode.
- `callbackTimedOut`: The bulb did not connect back to the local listener.

Check LAN control, local firewall rules, Wi-Fi reachability, and the fresh device
ID from discovery when these occur.
