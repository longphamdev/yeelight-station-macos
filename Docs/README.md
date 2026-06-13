# Module Documentation

This folder documents the Swift modules and executable in Yeelight Station
macOS. Module docs use the module name as the filename.

Start with the root [`Readme.md`](../Readme.md) if you only want to use the
screen-sync CLI.

## Modules

- [`AverageColor`](AverageColor/AverageColor.md): Average RGBA color from image data,
  image files, or `CGImage` values.
- [`ScreenCapture`](ScreenCapture/ScreenCapture.md): macOS display listing, screen
  capture permission checks, frame capture, and average screen color.
- [`YeelightWiFi`](YeelightWiFi/YeelightWiFi.md): Yeelight discovery, TCP control,
  color conversion, and music-mode streaming.
- [`YeelightSyncColorScreenCore`](YeelightSyncColorScreenCore/YeelightSyncColorScreenCore.md): CLI
  argument parsing, device selection, and screen RGB conversion.
- [`YeelightSyncColorScreen`](YeelightSyncColorScreen/YeelightSyncColorScreen.md): The executable
  that wires screen capture to selected Yeelight bulbs.

## Build and Test

Build the package:

```bash
swift build
```

Run tests:

```bash
swift test
```

Live screen-capture tests are skipped unless this environment variable is set:

```bash
ALLOW_SCREEN_CAPTURE_TESTS=1 swift test
```
