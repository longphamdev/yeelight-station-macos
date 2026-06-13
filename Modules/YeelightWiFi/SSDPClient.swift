import Foundation
import Network

// MARK: - SSDPMessage

/// Parsed headers from a single SSDP response. The fields correspond
/// 1:1 with the `ID`, `NAME`, `MODEL`, `FW_VER`, `SUPPORT`,
/// `LOCATION`, `POWER`, `BRIGHT`, `COLOR_MODE`, `RGB`, `CT`, `HUE`
/// and `SAT` headers used by the upstream JavaScript source.
public struct SSDPMessage: Sendable {
    public var id: String = ""
    public var name: String = ""
    public var model: String = ""
    public var firmware: String = ""
    public var support: String = ""
    public var location: String = ""
    public var power: String = ""
    public var bright: String = ""
    public var colorMode: String = ""
    public var rgb: String = ""
    public var ct: String = ""
    public var hue: String = ""
    public var sat: String = ""

    public init() {}

    public init(rawText: String) {
        // Lower-cased per-header scan: the bulb sends `id`, `model`,
        // `fw_ver`, `support`, `location` (etc.) in mixed case, so a
        // case-insensitive split is required. We tokenize on `\r\n`
        // and on each line split on the first `:` to preserve
        // values that themselves contain colons.
        var text = rawText
        // Tolerate both `\r\n` and bare `\n` line endings.
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "id":          id = value
            case "name":        name = value
            case "model":       model = value
            case "fw_ver":      firmware = value
            case "support":     support = value
            case "location":    location = value
            case "power":       power = value
            case "bright":      bright = value
            case "color_mode":  colorMode = value
            case "rgb":         rgb = value
            case "ct":          ct = value
            case "hue":         hue = value
            case "sat":         sat = value
            default:            break
            }
        }
    }
}

// MARK: - SSDPClient

/// Minimal SSDP client that performs an M-SEARCH for `wifi_bulb` on the
/// Yeelight multicast group and returns the parsed responses.
///
/// This is a focused re-implementation of the parts of `node-ssdp`
/// the original library actually uses. It only handles the
/// `wifi_bulb` search target.
///
/// On macOS the multicast group is reached with a regular UDP
/// `NWConnection` pointed at `239.255.255.250:1982`. We send a single
/// M-SEARCH and accumulate responses until the configured timeout
/// elapses.
public final class SSDPClient: @unchecked Sendable {

    public struct Options: Sendable {
        public var host: String = "239.255.255.250"
        public var port: UInt16 = 1982
        /// Time the bulb is allowed to wait before responding (`MX`).
        public var mx: Int = 2
        /// Maximum total time the client waits for responses.
        public var timeout: TimeInterval = 3
        /// Search target (ST header). `wifi_bulb` is the value used
        /// by the original library.
        public var searchTarget: String = "wifi_bulb"

        public init() {}
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Perform an M-SEARCH and return all responses received before
    /// the timeout fires. The list is de-duplicated by `id` since
    /// bulbs can answer more than once.
    public func search() async -> [SSDPMessage] {
        let host = NWEndpoint.Host(options.host)
        guard let port = NWEndpoint.Port(rawValue: options.port) else {
            return []
        }
        NSLog("SSDP search: starting for \(options.host):\(port)")

        // Multicast UDP socket. NWConnectionGroup is the API that
        // actually joins the 239.255.255.250 group on macOS; a
        // plain NWConnection sends unicast and the SSDP M-SEARCH
        // never reaches the bulb.
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let endpoints = [NWEndpoint.hostPort(host: host, port: port)]
        let descriptor: NWMulticastGroup
        do {
            descriptor = try NWMulticastGroup(for: endpoints)
        } catch {
            NSLog("SSDP failed to create multicast group: \(error)")
            return []
        }
        let group = NWConnectionGroup(
            with: descriptor,
            using: params
        )

        let actor = SSDPActor()
        var didReceive = false

        group.stateUpdateHandler = { (state: NWConnectionGroup.State) in
            switch state {
            case .ready:
                NSLog("SSDP group ready")
                Task { await actor.markReady() }
            case .failed(let error):
                NSLog("SSDP group failed: \(error)")
                Task { await actor.fail() }
            default:
                break
            }
        }

        group.setReceiveHandler(maximumMessageSize: 65_536, rejectOversizedMessages: false) { (message: NWConnectionGroup.Message, content: Data?, isComplete: Bool) in
            if let data = content, !data.isEmpty {
                didReceive = true
                if let text = String(data: data, encoding: .utf8) {
                    Task { await actor.ingest(text: text) }
                }
            }
        }

        group.start(queue: DispatchQueue.global(qos: .userInitiated))

        // Fire the M-SEARCH once the socket is ready.
        await actor.waitForReady()
        let payload = Self.msearchPayload(mx: options.mx, st: options.searchTarget)
        if let data = payload.data(using: .utf8) {
            group.send(content: data) { error in
                if let error = error {
                    NSLog("SSDP send error: \(error)")
                }
            }
        }

        // Read responses until the timeout fires. We poll for
        // completion because NWConnectionGroup uses a single
        // receive handler instead of per-message callbacks.
        let deadline = Date().addingTimeInterval(options.timeout)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        let messages = await actor.snapshot()
        NSLog("SSDP search finished: \(messages.count) unique responses, didReceive=\(didReceive)")
        for m in messages {
            NSLog("  msg id=\(m.id) loc=\(m.location) support=\(m.support.prefix(30))")
        }
        NSLog("SSDP search returning to caller")
        group.cancel()
        return messages
    }

    // MARK: Private

    private static func msearchPayload(mx: Int, st: String) -> String {
        """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1982\r
        MAN: "ssdp:discover"\r
        MX: \(mx)\r
        ST: \(st)\r
        \r

        """
    }
}

// MARK: - SSDPActor

/// Small actor that owns the receive state for an SSDP search. It
/// serializes the result set and the lifetime flag, which avoids the
/// "concurrent access to captured `var`" Swift 6 warnings we'd
/// otherwise hit when using `NSLock` from `stateUpdateHandler` or
/// `receive` callbacks.
private actor SSDPActor {
    private var messages: [SSDPMessage] = []
    private var seenIds: Set<String> = []
    private var ready: Bool = false
    private var finished: Bool = false

    func waitForReady() async {
        while !ready {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
    }

    func markReady() {
        ready = true
    }

    func fail() {
        finished = true
    }

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        return finished
    }

    func ingest(text: String) {
        let message = SSDPMessage(rawText: text)
        NSLog("SSDP ingest: id=\(message.id) loc=\(message.location) support=\(message.support.prefix(40)) raw=\(text.prefix(200).replacingOccurrences(of: "\r\n", with: "\\r\\n").replacingOccurrences(of: "\n", with: "\\n"))")
        guard !message.id.isEmpty, !seenIds.contains(message.id) else { return }
        seenIds.insert(message.id)
        messages.append(message)
    }

    func snapshot() -> [SSDPMessage] {
        return messages
    }
}
