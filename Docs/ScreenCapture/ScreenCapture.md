# ScreenCapture

`ScreenCapture` lists macOS displays, checks Screen Recording permission,
captures display frames, and computes dominant sampled screen colors from
captured frame bytes.

## Public API

Main type:

```swift
public enum ScreenCapture
```

Display and capture methods:

```swift
ScreenCapture.listDisplays() async throws -> [ScreenDisplay]
ScreenCapture.capture(screen: Int = 0) async throws -> CapturedFrame
ScreenCapture.captureAll() async throws -> [CapturedFrame]
ScreenCapture.preflightPermission() -> Bool
ScreenCapture.requestPermission() -> Bool
```

Useful value types:

```swift
public struct ScreenDisplay
public struct CapturedFrame
public struct ScreenRGB
```

`ScreenDisplay.id` is the user-facing display index used by the CLI. Display
`0` is the main display.

## Average Color

`CapturedFrame.averageColor(sampleStride:)` returns `ScreenRGB`. The method name
is kept for API compatibility, but internally it samples BGRA pixels, clusters
them in HSV hue/saturation space, and returns the dominant cluster color.

```swift
let frame = try await ScreenCapture.capture(screen: 0)
let color = frame.averageColor(sampleStride: 8)
print(color.array)
```

`sampleStride` controls how many pixels are sampled before HSV clustering:

- Lower values sample more pixels and cost more CPU.
- Higher values sample fewer pixels and are faster but less precise.
- Values below `1` are clamped to `1`.

For live syncing, `ScreenCaptureSession.averageColor(sampleStride:)` draws the
captured display into a small color-only buffer sized from `sampleStride` before
clustering. This avoids a full-resolution BGRA redraw for each color update.

## Permission Flow

macOS requires Screen Recording permission before display capture works.

```swift
if !ScreenCapture.preflightPermission() {
    ScreenCapture.requestPermission()
}
```

If permission is denied, capture methods throw `ScreenCaptureError.permissionDenied`.

## Errors

`ScreenCaptureError` can report:

- `noDisplays`: No active displays were found.
- `invalidDisplay`: The requested display ID is not available.
- `permissionDenied`: Screen Recording permission is missing.
- `captureFailed`: CoreGraphics failed to capture the display.
- `unsupportedPixelFormat`: The captured image could not be converted to BGRA8.

## Notes

- Captured frame bytes use BGRA8 premultiplied-first format.
- The live capture tests are skipped unless `ALLOW_SCREEN_CAPTURE_TESTS=1`.
