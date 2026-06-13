# YeelightSyncColorScreenCore

`YeelightSyncColorScreenCore` contains the testable pieces used by the
`YeelightSyncColorScreen` executable: CLI parsing, device selection, and color
conversion between screen capture and Yeelight Wi-Fi types.

## CLI Options

`CLIParser.parse(_:)` converts command-line arguments into `CLIOptions`.

```swift
let options = try CLIParser.parse([
    "--display", "0",
    "--id", "0x00000000189921cf",
    "--fps", "10"
])
```

Defaults:

- `fps`: `10`
- `sampleStride`: `8`
- `discoveryTimeout`: `5`

Sync mode requires:

- `--display <id>`
- at least one `--id <device-id>`

## Actions

`CLIAction` has three modes:

- `.listDisplays`
- `.listDevices`
- `.sync`

`--list-displays` and `--list-devices` do not require sync arguments.

## Device Selection

`DeviceSelector.select(from:ids:)` filters discovered `YeelightDevice` values by
the requested IDs.

Selection rules:

- Every requested ID must be discovered.
- Known white-only bulbs are rejected.
- Unknown devices are allowed only if their support list is empty or includes
  `set_rgb`.
- Color devices must support RGB where support is known.

## Color Conversion

`yeelightRGB(from:)` maps `ScreenCapture.ScreenRGB` to `YeelightWiFi.RGB`.

```swift
let bulbColor = yeelightRGB(from: screenColor)
```

No brightness curve, minimum brightness clamp, or power behavior is applied here.
The executable sends the resulting RGB value directly.

## Errors

`CLIParseError` covers invalid or missing CLI arguments.

`DeviceSelectionError` covers missing device IDs and non-RGB-capable devices.
