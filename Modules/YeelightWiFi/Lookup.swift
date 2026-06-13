import Foundation
import Network

// MARK: - Local IP address discovery

/// Tiny helper that guards a one-shot continuation so the timeout
/// race in `NWConnection.stateUpdateHandler` can be resolved without
/// touching shared mutable state from multiple queues.
private final class PortProbe: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var resumed = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(result: Bool) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: result)
    }
}

/// Lightweight equivalent of `os.networkInterfaces()` in Node.js.
/// Returns the IPv4 addresses of every non-internal interface.
public enum LocalNetwork {
    public static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let p = pointer {
            defer { pointer = p.pointee.ifa_next }
            let interface = p.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)
            // Skip loopback and interfaces that are down.
            if (flags & IFF_LOOPBACK) != 0 || (flags & IFF_UP) == 0 { continue }
            _ = name

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            if result == 0 {
                let address = String(cString: host)
                if !address.isEmpty, address != "127.0.0.1" {
                    addresses.append(address)
                }
            }
        }
        return Array(Set(addresses))
    }
}

// MARK: - YeelightLookup

/// Periodically searches the LAN for Yeelight bulbs using SSDP, with
/// an opt-in port-scanning fallback. This is the Swift counterpart
/// of the `Lookup` class in `node-yeelight-wifi`.
public final class YeelightLookup: @unchecked Sendable {

    // MARK: Constants

    /// How often the periodic SSDP search runs. Matches the
    /// upstream library.
    public static let lookupInterval: TimeInterval = 60

    /// Per-IP timeout for the port-scan fallback. Matches the
    /// upstream library.
    public static let portScanTimeout: TimeInterval = 10

    public static let yeelightPort: UInt16 = 55443

    private let ssdp: SSDPClient
    private let interval: TimeInterval

    // MARK: State

    public private(set) var lights: [YeelightDevice] = []
    private var intervalTask: Task<Void, Never>?

    // MARK: Event emitter

    private var listeners: [String: [EventHandler]] = [:]
    private let listenersLock = NSLock()

    public init(
        ssdp: SSDPClient = SSDPClient(),
        interval: TimeInterval = YeelightLookup.lookupInterval
    ) {
        self.ssdp = ssdp
        self.interval = interval
        NSLog("Lookup: init entered, scheduling task")
        intervalTask = Task { [weak self] in
            NSLog("Lookup: task started")
            await self?.lookup()
            NSLog("Lookup: init sequence finished, lights=\(self?.lights.count ?? -1)")
            while !Task.isCancelled {
                let delay = UInt64((self?.interval ?? 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                await self?.lookup()
            }
        }
        NSLog("Lookup: init returned, task scheduled")
    }

    deinit {
        intervalTask?.cancel()
    }

    // MARK: Public API

    /// Perform a single SSDP search and update `lights` with anything
    /// new that comes back.
    public func lookup() async {
        NSLog("Lookup: lookup() called, lights=\(lights.count)")
        let messages = await ssdp.search()
        NSLog("Lookup: search returned \(messages.count) messages, current lights=\(lights.count)")
        for message in messages {
            NSLog("  msg: id=\(message.id) loc=\(message.location) support=\(message.support.prefix(30))")
        }
        NSLog("Lookup: starting merge, messages=\(messages.count)")
        for message in messages {
            guard !message.id.isEmpty else { continue }
            if let existing = lights.first(where: { $0.id == message.id }) {
                existing.updateBySSDPMessage(message)
            } else {
                NSLog("  creating YeelightDevice from message id=\(message.id) loc=\(message.location)")
                let light = YeelightDevice(ssdpMessage: message)
                NSLog("  after init: id=\(light.id) host=\(light.host) port=\(light.port) type=\(light.type.rawValue)")
                lights.append(light)
                NSLog("Lookup: detected new light id=\(light.id) host=\(light.host) port=\(light.port) lights=\(lights.count)")
                emit(YeelightEvent.detected.rawValue, payload: light)
                NSLog("Lookup: emit done, lights=\(lights.count)")
            }
        }
        NSLog("Lookup: lookup() returning, lights=\(lights.count)")
    }

    /// Scan the local `/24` subnets of every non-internal interface
    /// for TCP 55443. Mirrors `Lookup.findByPortscanning()` in the
    /// JavaScript source. The returned promise resolves when every IP
    /// has been probed.
    public func findByPortscanning() async {
        let rawAddresses = LocalNetwork.ipv4Addresses()
        // Reduce every address to its `/24` prefix.
        var prefixes = Set<String>()
        for address in rawAddresses {
            if let dotIndex = address.lastIndex(of: ".") {
                prefixes.insert(String(address[address.startIndex...dotIndex]))
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for prefix in prefixes {
                for t in 1..<255 {
                    let host = "\(prefix)\(t)"
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        if await Self.isPortOpen(host: host, port: YeelightLookup.yeelightPort) {
                            await MainActor.run {
                                if !self.lights.contains(where: { $0.host == host }) {
                                    let light = YeelightDevice()
                                    light.initialize(host: host, port: Int(YeelightLookup.yeelightPort))
                                    self.lights.append(light)
                                    self.emit(YeelightEvent.detected.rawValue, payload: light)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    public func getLights() -> [YeelightDevice] {
        lights
    }

    // MARK: Port probe

    private static func isPortOpen(host: String, port: UInt16) async -> Bool {
        let queue = DispatchQueue(label: "yeelight.portscan.\(host)")
        return await withCheckedContinuation { continuation in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 55443,
                using: .tcp
            )
            let probe = PortProbe(continuation: continuation)
            let timeout = DispatchWorkItem {
                probe.finish(result: false)
                conn.cancel()
            }
            queue.asyncAfter(deadline: .now() + portScanTimeout, execute: timeout)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeout.cancel()
                    probe.finish(result: true)
                    conn.cancel()
                case .failed, .cancelled:
                    timeout.cancel()
                    probe.finish(result: false)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    // MARK: Event emitter

    public func on(_ event: String, handler: @escaping EventHandler) {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        var handlers = listeners[event] ?? []
        handlers.append(handler)
        listeners[event] = handlers
    }

    public func on(_ event: YeelightEvent, handler: @escaping DetectedHandler) {
        on(event.rawValue) { payload in
            if let light = payload as? YeelightDevice { handler(light) }
        }
    }

    private func emit(_ event: String, payload: Any) {
        listenersLock.lock()
        let handlers = listeners[event] ?? []
        listenersLock.unlock()
        for handler in handlers {
            DispatchQueue.global(qos: .userInitiated).async {
                handler(payload)
            }
        }
    }
}
