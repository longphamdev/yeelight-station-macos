# AverageColor

`AverageColor` is a small image utility module. It decodes an image, converts it
to an 8-bit RGBA bitmap, and returns the average color.

## Public API

Main type:

```swift
public enum AverageColor
```

Entry points:

```swift
AverageColor.averageColor(of data: Data) throws -> RGBAColor
AverageColor.averageColor(contentsOf url: URL) throws -> RGBAColor
AverageColor.averageColor(of image: CGImage) throws -> RGBAColor
```

Return type:

```swift
public struct RGBAColor: Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8
    public var array: [Int]
}
```

## Example

```swift
import AverageColor
import Foundation

let url = URL(fileURLWithPath: "/path/to/image.png")
let color = try AverageColor.averageColor(contentsOf: url)

print(color.array)
```

## Errors

`AverageColorError` can report:

- `invalidImageData`: The input is not decodable image data.
- `missingFirstFrame`: The image source has no readable first frame.
- `unsupportedBitmapConversion`: The image could not be converted to the needed
  8-bit RGBA bitmap.
- `zeroSizedImage`: The image width or height is zero.

## Notes

- Alpha is included in the average.
- Premultiplied color channels are unpremultiplied before averaging.
- This module is independent from live screen capture. Use `ScreenCapture` for
  display frames.
