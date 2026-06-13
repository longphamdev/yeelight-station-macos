import Foundation
import Network

public enum YeelightMusicModeError: Error, LocalizedError, Sendable {
    case missingLocalAddress
    case listenerPortUnavailable
    case callbackTimedOut
    case listenerFailed(String)
    case connectionFailed(String)
    case notStarted

    public var errorDescription: String? {
        switch self {
        case .missingLocalAddress:
            return "Could not find a local IPv4 address for Yeelight music mode."
        case .listenerPortUnavailable:
            return "Music mode listener did not expose a local port."
        case .callbackTimedOut:
            return "Timed out waiting for the Yeelight music mode callback connection."
        case let .listenerFailed(message):
            return "Music mode listener failed: \(message)"
        case let .connectionFailed(message):
            return "Music mode connection failed: \(message)"
        case .notStarted:
            return "Music mode has not been started."
        }
    }
}

public enum YeelightCommandEncoder {
    public static func commandLine(id: Int, method: String, params: [Any]) throws -> Data {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [])
        var line = String(data: json, encoding: .utf8) ?? ""
        line += "\r\n"
        guard let bytes = line.data(using: .utf8) else {
            throw YeelightError.socketError("failed to encode request")
        }
        return bytes
    }

    public static func setRGBLine(id: Int, color: RGB, duration: Int = 0) throws -> Data {
        try commandLine(
            id: id,
            method: "set_rgb",
            params: [
                rgbToInt(color),
                duration > 0 ? "smooth" : "sudden",
                duration > 0 ? duration : 0
            ]
        )
    }
}

private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var completed = false

    func wait(timeout: TimeInterval, timeoutError: Error) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
                return
            }
            self.continuation = continuation
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                self.finish(.failure(timeoutError))
            }
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

public final class YeelightMusicModeSession: @unchecked Sendable {
    private let device: YeelightDevice
    private let listener: NWListener
    private let callback = OneShotSignal()
    private let queue = DispatchQueue(label: "yeelight.music-mode")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var messageId = 1
    private var stopped = false

    private init(device: YeelightDevice, listener: NWListener) {
        self.device = device
        self.listener = listener
    }

    deinit {
        closeSockets()
    }

    public static func start(
        device: YeelightDevice,
        localHost: String? = nil,
        preferredPort: UInt16 = 0,
        callbackTimeout: TimeInterval = 5
    ) async throws -> YeelightMusicModeSession {
        let listener: NWListener
        if preferredPort == 0 {
            listener = try NWListener(using: .tcp)
        } else if let port = NWEndpoint.Port(rawValue: preferredPort) {
            listener = try NWListener(using: .tcp, on: port)
        } else {
            throw YeelightMusicModeError.listenerPortUnavailable
        }

        let session = YeelightMusicModeSession(device: device, listener: listener)
        let callbackAddress = localHost ?? LocalNetwork.ipv4Addresses().sorted().first
        guard let callbackAddress, !callbackAddress.isEmpty else {
            throw YeelightMusicModeError.missingLocalAddress
        }

        try await session.startListener(callbackTimeout: callbackTimeout)
        guard let port = listener.port else {
            throw YeelightMusicModeError.listenerPortUnavailable
        }

        try await device.setMusic(enabled: true, host: callbackAddress, port: Int(port.rawValue))
        try await session.waitForCallback(timeout: callbackTimeout)
        return session
    }

    public func sendRGB(_ color: RGB, duration: Int = 0) async throws {
        let id = nextMessageId()
        let bytes = try YeelightCommandEncoder.setRGBLine(id: id, color: color, duration: duration)
        let conn = currentConnection()
        guard let conn else {
            throw YeelightMusicModeError.notStarted
        }

        device.updateByRGB("\(rgbToInt(color))")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: YeelightMusicModeError.connectionFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func stop() async {
        closeSockets()
        try? await device.setMusic(enabled: false)
    }

    private func startListener(callbackTimeout: TimeInterval) async throws {
        let ready = OneShotSignal()

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.finish(.success(()))
            case let .failed(error):
                ready.finish(.failure(YeelightMusicModeError.listenerFailed("\(error)")))
                self?.callback.finish(.failure(YeelightMusicModeError.listenerFailed("\(error)")))
            case .cancelled:
                self?.callback.finish(.failure(YeelightMusicModeError.callbackTimedOut))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.setConnection(connection)
            connection.start(queue: self.queue)
            self.callback.finish(.success(()))
        }

        listener.start(queue: queue)
        try await ready.wait(
            timeout: callbackTimeout,
            timeoutError: YeelightMusicModeError.listenerFailed("listener did not become ready")
        )
    }

    private func waitForCallback(timeout: TimeInterval) async throws {
        let existing = currentConnection()
        if existing != nil { return }

        try await callback.wait(timeout: timeout, timeoutError: YeelightMusicModeError.callbackTimedOut)
    }

    private func setConnection(_ connection: NWConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    private func currentConnection() -> NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    private func nextMessageId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = messageId
        messageId += 1
        return id
    }

    private func closeSockets() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let conn = connection
        connection = nil
        lock.unlock()

        conn?.cancel()
        listener.cancel()
    }
}

extension YeelightDevice {
    public func setMusic(enabled: Bool, host: String? = nil, port: Int? = nil) async throws {
        let params: [Any]
        if enabled {
            guard let host, let port else {
                throw YeelightError.emptyParams
            }
            params = [1, host, port]
        } else {
            params = [0]
        }
        try await sendCommand(method: "set_music", params: params)
    }
}
