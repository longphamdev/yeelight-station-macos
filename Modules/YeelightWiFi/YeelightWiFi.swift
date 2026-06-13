import Foundation

/// Public façade of the `YeelightWiFi` library. The actual class
/// names are `YeelightDevice` and `YeelightLookup`; the typealiases
/// below expose them under the same names the original Node.js
/// library uses (`Yeelight` and `Lookup`) so porting a call site is
/// a 1:1 rename.
public enum YeelightWiFi {
    public typealias Yeelight = YeelightDevice
    public typealias Lookup   = YeelightLookup
}
