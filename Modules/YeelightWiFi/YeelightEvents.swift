import Foundation

// MARK: - Event names

/// String constants for the events emitted by `Yeelight` and
/// `YeelightLookup`. They mirror the JavaScript event names so existing
/// callers can translate 1:1.
public enum YeelightEvent: String, Sendable {
    /// Connection to the bulb has been opened.
    case connected
    /// Connection has been closed cleanly.
    case disconnected
    /// `stateUpdate` fires whenever a cached state field changes
    /// (power, RGB, HSV, brightness, color temperature).
    case stateUpdate
    /// Emitted when a `props` notification arrives from the bulb.
    case update
    /// Emitted when a command finishes successfully.
    case success
    /// Emitted when a command times out.
    case timeout
    /// Emitted on any failure (socket error, unparsable response,
    /// get_prop length mismatch, unsupported method).
    case failed
    /// Emitted by `Lookup` when a previously-unknown bulb is seen.
    case detected
}

// MARK: - Handler types

/// A handler invoked when a bulb event fires. It receives the bulb
/// that the event refers to.
public typealias LightHandler = (YeelightDevice) -> Void

/// A handler invoked when a `Lookup` detects a new bulb.
public typealias DetectedHandler = (YeelightDevice) -> Void

/// A handler invoked for generic bulb events. The associated payload is
/// defined per event (see the `FailedEvent` / `TimeoutEvent` / etc.
/// enums below).
public typealias EventHandler = (Any) -> Void

// MARK: - Event payloads

/// Payload for the `failed` event.
public struct FailedEvent: Sendable {
    public let reason: String
    public let response: String?

    public init(reason: String, response: String? = nil) {
        self.reason = reason
        self.response = response
    }
}

/// Payload for the `timeout` event. The `params` array is kept
/// type-erased (`Any`) on purpose: the upstream library stores the
/// exact JSON value the caller passed, which can be a string, an
/// integer, or a dictionary depending on the command.
public struct TimeoutEvent {
    public let id: Int
    public let method: String
    public let params: [Any]

    public init(id: Int, method: String, params: [Any]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Payload for the `success` event. Same type-erasure rationale as
/// `TimeoutEvent`.
public struct SuccessEvent {
    public let id: Int
    public let method: String
    public let params: [Any]
    public let response: [String: Any]

    public init(id: Int, method: String, params: [Any], response: [String: Any]) {
        self.id = id
        self.method = method
        self.params = params
        self.response = response
    }
}

// MARK: - Errors

/// Errors thrown by `Yeelight` operations.
public enum YeelightError: Error, LocalizedError, Sendable {
    case notConnected
    case methodNotSupported(method: String)
    case emptyParams
    case timeout(id: Int)
    case socketError(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Yeelight is not connected"
        case .methodNotSupported(let method):
            return "method is not supported: \(method)"
        case .emptyParams:
            return "empty params are not allowed"
        case .timeout(let id):
            return "request timed out (id: \(id))"
        case .socketError(let message):
            return "socket error: \(message)"
        case .parseError(let response):
            return "response is not parsable: \(response)"
        }
    }
}
