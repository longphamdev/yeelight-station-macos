import Foundation
import Network

// MARK: - YeelightType

/// Reported bulb capability tier.
public enum YeelightType: String, Sendable {
    case unknown = "unknown"
    case white   = "white"
    case color   = "color"
}

// MARK: - YeelightState

/// Snapshot of the cached state, returned by `getState()`.
public struct YeelightState: Sendable {
    public let type: YeelightType
    public let power: Bool
    public let bright: Int
    public let rgb: RGB
    public let hsb: HSV
}

// MARK: - Pending message

/// Tracks a single in-flight JSON-RPC command. Mirrors the
/// `this.messages[id]` object in the JavaScript implementation.
private struct PendingMessage {
    let id: Int
    let method: String
    let params: [Any]
    let timeout: DispatchWorkItem
    let resolve: (YeelightDevice) -> Void
    let reject: (Error) -> Void
}

// MARK: - YeelightDevice

/// A single Yeelight bulb. This is the Swift counterpart of the
/// `Yeelight` class in `node-yeelight-wifi`. It owns a persistent TCP
/// connection to the bulb and exposes typed Swift setters that map
/// to the JSON-RPC commands the bulb understands.
public final class YeelightDevice: @unchecked Sendable {

    // MARK: Constants

    private static let socketTimeout: TimeInterval = 5
    private static let requestTimeout: TimeInterval = 5

    // MARK: Socket

    private var connection: NWConnection?
    private(set) public var isConnected: Bool = false
    /// Receive buffer that we accumulate between frame boundaries.
    private var receiveBuffer = Data()

    // MARK: JSON-RPC

    private var messageId: Int = 1
    private var messages: [Int: PendingMessage] = [:]

    // MARK: Cached state

    public var id: String = ""
    public var name: String = ""
    public var host: String = ""
    public var port: Int = 0
    /// MAC address. The upstream library notes this is "not guaranteed"
    /// because the lookup goes through `arp.getMAC`, which is a
    /// platform-specific best-effort call. Foundation has no equivalent
    /// portable API, so this is always empty in the Swift port.
    public var mac: String = ""
    public var model: String = ""
    public var firmware: String = ""
    public var support: String = ""
    public var type: YeelightType = .unknown
    public var colorMode: Int = 0

    public var power: Bool = false
    public var bright: Int = 0
    public var rgb: RGB = RGB(r: 0, g: 0, b: 0)
    public var hsb: HSV = HSV(h: 0, s: 0, b: 0)

    // MARK: Event emitter

    /// A registered listener, identified by a stable UUID so that
    /// `off()` can remove the exact handler that was registered.
    private struct Listener {
        let id: UUID
        let handler: EventHandler
    }

    private var listeners: [String: [Listener]] = [:]
    private let listenersLock = NSLock()

    // MARK: Lifecycle

    public init(ssdpMessage: SSDPMessage? = nil) {
        if let message = ssdpMessage {
            updateBySSDPMessage(message)
            connect()
        }
    }

    /// Constructor used when the bulb is discovered by host+port (e.g.
    /// the port-scan fallback). Equivalent to `init(host, port, mac)`
    /// in the JavaScript source.
    public func initialize(host: String, port: Int, mac: String = "") {
        self.mac = mac
        self.host = host
        self.port = port
        connect()
        Task { [weak self] in
            do { try await self?.updateState() }
            catch { NSLog("Yeelight.updateState failed: \(error)") }
        }
    }

    deinit {
        disconnect()
    }

    // MARK: Public state

    public func getState() -> YeelightState {
        YeelightState(type: type, power: power, bright: bright, rgb: rgb, hsb: hsb)
    }

    // MARK: SSDP-driven update

    public func updateBySSDPMessage(_ message: SSDPMessage) {
        id = message.id
        name = message.name
        model = message.model
        firmware = message.firmware
        support = message.support

        // Extract host and port from `LOCATION: //host:port/...`
        if let parsed = Self.parseLocation(message.location) {
            host = parsed.host
            port = parsed.port
        } else {
            NSLog("Yeelight location parse failed for \(message.location)")
        }

        // Type detection.
        if !support.isEmpty {
            let supported = support.split(separator: " ").map(String.init)
            if supported.contains("set_ct_abx") {
                type = .white
            }
            if supported.contains("set_rgb") || supported.contains("set_hsv") {
                type = .color
            }
        }

        updatePower(message.power)
        updateColor(bySSDPMessage: message)
    }

    private func updateColor(bySSDPMessage message: SSDPMessage) {
        // 1 = color mode, 2 = color temperature mode, 3 = HSV mode.
        let mode = Int(message.colorMode) ?? 0
        switch mode {
        case 1:
            updateByRGB(message.rgb, bright: message.bright)
        case 2:
            updateCT(message.ct, bright: message.bright)
        case 3:
            updateHSV(message.hue, sat: message.sat, val: message.bright)
        default:
            break
        }
    }

    private static func parseLocation(_ location: String) -> (host: String, port: Int)? {
        // Bulbs reply with `Location: yeelight://192.168.2.33:55443`
        // (no `//` and `yeelight://` scheme). Tolerate both forms.
        let schemeStripped: Substring
        if let schemeRange = location.range(of: "://") {
            schemeStripped = location[schemeRange.upperBound...]
        } else if location.hasPrefix("//") {
            schemeStripped = location.dropFirst(2)
        } else {
            schemeStripped = Substring(location)
        }

        let pattern = #"^([^:/]+):(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(schemeStripped.startIndex..., in: schemeStripped)
        guard let match = regex.firstMatch(in: String(schemeStripped), range: range),
              match.numberOfRanges >= 3,
              let hostRange = Range(match.range(at: 1), in: schemeStripped),
              let portRange = Range(match.range(at: 2), in: schemeStripped)
        else { return nil }
        let host = String(schemeStripped[hostRange])
        let port = Int(schemeStripped[portRange]) ?? 55443
        return (host, port)
    }

    // MARK: State mutators (preserve upstream event semantics)

    public func updateByRGB(_ rgbString: String, bright: String? = nil) {
        guard let intValue = Int(rgbString) else { return }
        let color = intToRGB(intValue)
        let hsv = rgbToHSV(color)

        rgb = color
        if let b = bright, !b.isEmpty, let v = Int(b) { self.bright = v }
        hsb = HSV(h: hsv.h, s: hsv.s, b: Double(self.bright))
        emit(YeelightEvent.stateUpdate.rawValue, payload: self)
    }

    public func updateCT(_ ct: String, bright: String? = nil) {
        guard let kelvin = Int(ct) else { return }
        let color = ColorTemp.toRGB(kelvin: kelvin)
        let hsv = rgbToHSV(color)
        rgb = color
        if let b = bright, !b.isEmpty, let v = Int(b) { self.bright = v }
        hsb = HSV(h: hsv.h, s: hsv.s, b: Double(self.bright))
        emit(YeelightEvent.stateUpdate.rawValue, payload: self)
    }

    public func updateHSV(_ hue: String, sat: String, val: String? = nil) {
        if let v = val, !v.isEmpty, let n = Int(v) { bright = n }
        let h = Double(Int(hue) ?? 0)
        let s = Double(Int(sat) ?? 0)
        hsb = HSV(h: h, s: s, b: Double(bright))

        let color = hsvToRGB(hsb)
        rgb = color
        emit(YeelightEvent.stateUpdate.rawValue, payload: self)
    }

    public func updateBright(_ value: String) {
        if let n = Int(value) { bright = n }
        hsb = HSV(h: hsb.h, s: hsb.s, b: Double(bright))
        emit(YeelightEvent.stateUpdate.rawValue, payload: self)
    }

    public func updatePower(_ value: String) {
        let lower = value.lowercased()
        power = !(lower == "off" || lower == "false" || value == "0") && !value.isEmpty
        emit(YeelightEvent.stateUpdate.rawValue, payload: self)
    }

    public func updatePower(_ value: Bool) {
        power = value
        emit(YeelightEvent.stateUpdate.rawValue, payload: self)
    }

    // MARK: Connection

    public func connect() {
        if connection != nil { disconnect() }
        emit(YeelightEvent.connected.rawValue, payload: self)
        // Provide a no-op "connect" event alongside the underlying
        // connection establishment, matching the JS implementation.
        emit("connect", payload: self)

        let host = NWEndpoint.Host(self.host)
        let port = NWEndpoint.Port(rawValue: UInt16(self.port)) ?? 55443
        let conn = NWConnection(host: host, port: port, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.emit(YeelightEvent.connected.rawValue, payload: self)
            case .failed(let error):
                self.emit(YeelightEvent.failed.rawValue,
                          payload: FailedEvent(reason: "socket error", response: "\(error)"))
                self.disconnect()
            case .cancelled:
                self.emit(YeelightEvent.disconnected.rawValue, payload: self)
                self.disconnect()
            default:
                break
            }
        }

        conn.start(queue: .global(qos: .userInitiated))
        receiveNext()
    }

    public func disconnect() {
        if let conn = connection {
            conn.cancel()
        }
        connection = nil
        isConnected = false
        emit(YeelightEvent.disconnected.rawValue, payload: self)
        emit("disconnect", payload: self)
    }

    private func receiveNext() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainFrames()
            }
            if let error = error {
                self.emit(YeelightEvent.failed.rawValue,
                          payload: FailedEvent(reason: "socket error", response: "\(error)"))
                self.disconnect()
                return
            }
            if isComplete {
                self.disconnect()
                return
            }
            self.receiveNext()
        }
    }

    private func drainFrames() {
        // The upstream library splits incoming bytes on `\r\n`. We do
        // the same so the behaviour matches 1:1.
        let crlf: UInt8 = 0x0D
        let lf:   UInt8 = 0x0A
        while let lfIndex = receiveBuffer.firstIndex(of: lf) {
            let frame: Data
            if lfIndex > 0, receiveBuffer[lfIndex - 1] == crlf {
                frame = receiveBuffer.subdata(in: 0..<(lfIndex - 1))
            } else {
                frame = receiveBuffer.subdata(in: 0..<lfIndex)
            }
            receiveBuffer.removeSubrange(0...lfIndex)
            if !frame.isEmpty, let text = String(data: frame, encoding: .utf8) {
                parseResponse(text)
            }
        }
    }

    // MARK: Response parsing

    private func parseResponse(_ text: String) {
        // Try to parse the response as JSON.
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            emit(YeelightEvent.failed.rawValue,
                 payload: FailedEvent(reason: "response is not parsable", response: text))
            return
        }

        let id = (json["id"] as? Int) ?? -1
        let method = json["method"] as? String
        let params = json["params"] as? [String: Any]
        let result = json["result"] as? [Any]

        // ******************** notification message ********************
        if method == "props", let params = params {
            if let p = params["power"] as? String   { updatePower(p) }
            if let r = params["rgb"] as? String     { updateByRGB(r) }
            if let b = params["bright"] as? String  { updateBright(b) }
            if let c = params["ct"] as? String      { updateCT(c) }
            if let h = params["hue"] as? String,
               let s = params["sat"] as? String     { updateHSV(h, sat: s) }
            if let n = params["name"] as? String     { name = n }

            emit(YeelightEvent.update.rawValue, payload: ["response": json])
            return
        }

        // ******************** get_prop result ********************
        if let result = result, id >= 0, let message = messages[id], message.method == "get_prop" {
            let requestedParams = message.params.compactMap { $0 as? String }
            guard requestedParams.count == result.count else {
                emit(YeelightEvent.failed.rawValue,
                     payload: FailedEvent(
                        reason: "error on parsing get_prop result --> params length != values length",
                        response: text))
                return
            }

            var obj: [String: Any] = [:]
            for (key, value) in zip(requestedParams, result) {
                obj[key] = value
            }

            // Type detection: empty rgb means the bulb doesn't support
            // RGB. Otherwise, default to .color.
            if let r = obj["rgb"] as? String {
                type = (r.isEmpty) ? .white : .color
            }

            if let p = obj["power"] as? String    { updatePower(p) }
            if let cm = obj["color_mode"] as? Int {
                colorMode = cm
                switch cm {
                case 1:
                    if let r = obj["rgb"] as? String, let b = obj["bright"] as? String {
                        updateByRGB(r, bright: "\(b)")
                    }
                case 2:
                    if let c = obj["ct"] as? String, let b = obj["bright"] as? String {
                        updateCT(c, bright: "\(b)")
                    }
                case 3:
                    if let h = obj["hue"] as? String,
                       let s = obj["sat"] as? String,
                       let b = obj["bright"] as? String {
                        updateHSV(h, sat: s, val: "\(b)")
                    }
                default:
                    break
                }
            } else if let b = obj["bright"] as? String {
                updateBright(b)
            }
        }

        // ******************** command response ********************
        if id >= 0, let message = messages[id] {
            message.timeout.cancel()
            emit(YeelightEvent.success.rawValue,
                 payload: SuccessEvent(
                    id: message.id,
                    method: message.method,
                    params: message.params,
                    response: json))
            messages.removeValue(forKey: id)
            message.resolve(self)
        }
    }

    // MARK: Setters

    public func updateState() async throws {
        try await sendCommand(method: "get_prop", params: [
            "power", "color_mode", "ct", "rgb", "hue", "sat", "bright"
        ])
    }

    public func setPower(_ on: Bool, duration: Int = 0) async throws {
        power = on
        let params: [Any] = [
            on ? "on" : "off",
            duration > 0 ? "smooth" : "sudden",
            duration > 0 ? duration : 0
        ]
        try await sendCommand(method: "set_power", params: params)
    }

    public func setRGB(_ color: RGB, duration: Int = 0) async throws {
        let number = rgbToInt(color)
        updateByRGB("\(number)")
        let params: [Any] = [
            number,
            duration > 0 ? "smooth" : "sudden",
            duration > 0 ? duration : 0
        ]
        try await sendCommand(method: "set_rgb", params: params)
    }

    public func setBright(_ value: Int, duration: Int = 0) async throws {
        updateBright("\(value)")
        let params: [Any] = [
            value,
            duration > 0 ? "smooth" : "sudden",
            duration > 0 ? duration : 0
        ]
        try await sendCommand(method: "set_bright", params: params)
    }

    public func setHSV(_ value: HSV, duration: Int = 0) async throws {
        let h = Int(value.h)
        let s = Int(value.s)
        let v = Int(value.b)

        updateHSV("\(h)", sat: "\(s)", val: "\(v)")

        let hsvParams: [Any] = [
            h, s,
            duration > 0 ? "smooth" : "sudden",
            duration > 0 ? duration : 0
        ]
        let brightParams: [Any] = [
            v,
            duration > 0 ? "smooth" : "sudden",
            duration > 0 ? duration : 0
        ]

        // Mirror the JS implementation, which fires `set_hsv` and
        // `set_bright` concurrently and waits for both. We do the
        // same by awaiting them sequentially in a `Task` group.
        try await sendCommand(method: "set_hsv", params: hsvParams)
        try await sendCommand(method: "set_bright", params: brightParams)
    }

    public func setCT(_ ct: Int, duration: Int = 0) async throws {
        updateCT("\(ct)")
        let params: [Any] = [
            ct,
            duration > 0 ? "smooth" : "sudden",
            duration > 0 ? duration : 0
        ]
        try await sendCommand(method: "set_ct_abx", params: params)
    }

    // MARK: sendCommand

    @discardableResult
    public func sendCommand(method: String, params: [Any]) async throws -> YeelightDevice {
        if connection == nil {
            connect()
        }
        try await waitUntilConnected()

        var supportedMethods: [String] = []
        if !support.isEmpty {
            supportedMethods = support.split(separator: " ").map(String.init)
        }
        let allowed = support.isEmpty || supportedMethods.contains(method)
        guard allowed, !params.isEmpty else {
            throw YeelightError.methodNotSupported(method: method)
        }

        let id = messageId
        messageId += 1

        let bytes = try YeelightCommandEncoder.commandLine(id: id, method: method, params: params)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<YeelightDevice, Error>) in
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard let pending = self.messages.removeValue(forKey: id) else { return }
                self.emit(YeelightEvent.timeout.rawValue,
                          payload: TimeoutEvent(id: pending.id, method: pending.method, params: pending.params))
                pending.reject(YeelightError.timeout(id: id))
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Self.requestTimeout,
                execute: workItem
            )
            messages[id] = PendingMessage(
                id: id, method: method, params: params,
                timeout: workItem,
                resolve: { light in continuation.resume(returning: light) },
                reject:  { error in continuation.resume(throwing: error) }
            )
            connection?.send(content: bytes, completion: .contentProcessed { error in
                if let error = error {
                    NSLog("Yeelight send error: \(error)")
                }
            })
        }
    }

    private func waitUntilConnected() async throws {
        if isConnected { return }

        let deadline = Date().addingTimeInterval(Self.socketTimeout)
        while !isConnected, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        guard isConnected else {
            throw YeelightError.socketError("connection timed out")
        }
    }

    // MARK: Event emitter

    @discardableResult
    public func on(_ event: String, handler: @escaping EventHandler) -> UUID {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        let id = UUID()
        var handlers = listeners[event] ?? []
        handlers.append(Listener(id: id, handler: handler))
        listeners[event] = handlers
        return id
    }

    /// Remove a listener by the UUID token returned from `on()`.
    public func off(_ event: String, id: UUID) {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        guard var handlers = listeners[event] else { return }
        handlers.removeAll { $0.id == id }
        listeners[event] = handlers
    }

    /// Remove a listener by handler reference. Uses `ObjectIdentifier`
    /// to compare closure identity. Note: this only works when the
    /// closure was registered via the `EventHandler`-typed overload
    /// (not the `YeelightEvent`-typed overload, which wraps the
    /// handler in a new closure).
    public func off(_ event: String, handler: EventHandler) {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        guard var handlers = listeners[event] else { return }
        let key = ObjectIdentifier(handler as AnyObject)
        handlers.removeAll { ObjectIdentifier($0.handler as AnyObject) == key }
        listeners[event] = handlers
    }

    public func on(_ event: YeelightEvent, handler: @escaping LightHandler) {
        on(event.rawValue) { payload in
            if let light = payload as? YeelightDevice { handler(light) }
        }
    }

    private func emit(_ event: String, payload: Any) {
        listenersLock.lock()
        let handlers = listeners[event] ?? []
        listenersLock.unlock()
        for listener in handlers {
            DispatchQueue.global(qos: .userInitiated).async {
                listener.handler(payload)
            }
        }
    }
}
