import Foundation
import ScreenCapture
import YeelightWiFi

public enum CLIAction: Equatable, Sendable {
    case listDisplays
    case listDevices
    case sync
}

public struct CLIOptions: Equatable, Sendable {
    public var action: CLIAction = .sync
    public var displayID: Int?
    public var deviceIDs: [String] = []
    public var fps: Double = 10
    public var sampleStride: Int = 8
    public var discoveryTimeout: TimeInterval = 5

    public init() {}
}

public enum CLIParseError: Error, Equatable, LocalizedError, Sendable {
    case missingValue(String)
    case invalidNumber(option: String, value: String)
    case invalidPositiveNumber(option: String, value: String)
    case unknownOption(String)
    case missingDisplay
    case missingDeviceID

    public var errorDescription: String? {
        switch self {
        case let .missingValue(option):
            return "Missing value for \(option)."
        case let .invalidNumber(option, value):
            return "Invalid number for \(option): \(value)."
        case let .invalidPositiveNumber(option, value):
            return "\(option) must be greater than zero; got \(value)."
        case let .unknownOption(option):
            return "Unknown option: \(option)."
        case .missingDisplay:
            return "Sync mode requires --display <id>. Run --list-displays to choose one."
        case .missingDeviceID:
            return "Sync mode requires at least one --id <device-id>. Run --list-devices to choose devices."
        }
    }
}

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--list-displays":
                options.action = .listDisplays
                index += 1
            case "--list-devices":
                options.action = .listDevices
                index += 1
            case "--display":
                let value = try value(after: argument, at: index, in: arguments)
                guard let id = Int(value) else {
                    throw CLIParseError.invalidNumber(option: argument, value: value)
                }
                options.displayID = id
                index += 2
            case "--id":
                let value = try value(after: argument, at: index, in: arguments)
                options.deviceIDs.append(value)
                index += 2
            case "--fps":
                let value = try value(after: argument, at: index, in: arguments)
                guard let fps = Double(value) else {
                    throw CLIParseError.invalidNumber(option: argument, value: value)
                }
                guard fps > 0 else {
                    throw CLIParseError.invalidPositiveNumber(option: argument, value: value)
                }
                options.fps = fps
                index += 2
            case "--sample-stride":
                let value = try value(after: argument, at: index, in: arguments)
                guard let stride = Int(value) else {
                    throw CLIParseError.invalidNumber(option: argument, value: value)
                }
                guard stride > 0 else {
                    throw CLIParseError.invalidPositiveNumber(option: argument, value: value)
                }
                options.sampleStride = stride
                index += 2
            case "--discovery-timeout":
                let value = try value(after: argument, at: index, in: arguments)
                guard let timeout = Double(value) else {
                    throw CLIParseError.invalidNumber(option: argument, value: value)
                }
                guard timeout > 0 else {
                    throw CLIParseError.invalidPositiveNumber(option: argument, value: value)
                }
                options.discoveryTimeout = timeout
                index += 2
            default:
                throw CLIParseError.unknownOption(argument)
            }
        }

        if options.action == .sync {
            guard options.displayID != nil else {
                throw CLIParseError.missingDisplay
            }
            guard !options.deviceIDs.isEmpty else {
                throw CLIParseError.missingDeviceID
            }
        }

        return options
    }

    private static func value(after option: String, at index: Int, in arguments: [String]) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CLIParseError.missingValue(option)
        }
        let value = arguments[valueIndex]
        guard !value.hasPrefix("--") else {
            throw CLIParseError.missingValue(option)
        }
        return value
    }
}

public enum DeviceSelectionError: Error, Equatable, LocalizedError, Sendable {
    case missingDeviceIDs([String])
    case nonColorDevice(id: String, name: String)

    public var errorDescription: String? {
        switch self {
        case let .missingDeviceIDs(ids):
            return "No discovered Yeelight device matched id(s): \(ids.joined(separator: ", "))."
        case let .nonColorDevice(id, name):
            let label = name.isEmpty ? id : "\(name) (\(id))"
            return "Selected Yeelight device is not RGB-capable: \(label)."
        }
    }
}

public enum DeviceSelector {
    public static func select(from devices: [YeelightDevice], ids: [String]) throws -> [YeelightDevice] {
        let requested = Set(ids)
        let selected = devices.filter { requested.contains($0.id) }
        let found = Set(selected.map(\.id))
        let missing = ids.filter { !found.contains($0) }
        guard missing.isEmpty else {
            throw DeviceSelectionError.missingDeviceIDs(missing)
        }

        for device in selected where !isRGBCapable(device) {
            throw DeviceSelectionError.nonColorDevice(id: device.id, name: device.name)
        }
        return selected
    }

    public static func isRGBCapable(_ device: YeelightDevice) -> Bool {
        let supported = Set(device.support.split(separator: " ").map(String.init))
        switch device.type {
        case .white:
            return false
        case .color, .unknown:
            return device.support.isEmpty || supported.contains("set_rgb")
        }
    }
}

public enum FramePacer {
    public static func frameDelayNanoseconds(fps: Double) -> UInt64 {
        let nanoseconds = (1_000_000_000 / fps).rounded()
        guard nanoseconds.isFinite, nanoseconds > 0 else {
            return 1
        }
        return max(1, UInt64(nanoseconds))
    }

    public static func elapsedNanoseconds(since start: UInt64, now: UInt64) -> UInt64 {
        guard now >= start else {
            return 0
        }
        return now - start
    }

    public static func remainingDelayNanoseconds(frameDelay: UInt64, elapsed: UInt64) -> UInt64 {
        guard elapsed < frameDelay else {
            return 0
        }
        return frameDelay - elapsed
    }
}

public func yeelightRGB(from color: ScreenRGB) -> RGB {
    RGB(r: color.r, g: color.g, b: color.b)
}
