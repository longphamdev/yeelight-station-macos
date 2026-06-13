import Darwin
import Foundation
import ScreenCapture
import YeelightSyncColorScreenCore
import YeelightWiFi

@main
struct YeelightSyncColorScreenCLI {
    static func main() async {
        do {
            let options = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options: options)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            if error is CLIParseError {
                fputs(Self.usage, stderr)
            }
            exit(1)
        }
    }

    private static func run(options: CLIOptions) async throws {
        switch options.action {
        case .listDisplays:
            try await listDisplays()
        case .listDevices:
            try await listDevices(timeout: options.discoveryTimeout)
        case .sync:
            let runtime = SyncRuntime()
            let signalTask = Task {
                for await _ in makeSignalStream() {
                    await runtime.stop()
                    print("\nStopped Yeelight screen sync.")
                    break
                }
            }
            defer { signalTask.cancel() }
            try await runtime.run(options: options)
        }
    }

    private static func listDisplays() async throws {
        let displays = try await ScreenCapture.listDisplays()
        guard !displays.isEmpty else {
            print("No active displays found.")
            return
        }

        for display in displays {
            let marker = display.isMain ? " main" : ""
            print("\(display.id)\(marker): \(display.name) \(display.pixelWidth)x\(display.pixelHeight)")
        }
    }

    private static func listDevices(timeout: TimeInterval) async throws {
        let devices = try await discoverDevices(timeout: timeout)
        guard !devices.isEmpty else {
            print("No Yeelight devices discovered.")
            return
        }

        for device in devices {
            let support = device.support.isEmpty ? "unknown support" : device.support
            let name = device.name.isEmpty ? "-" : device.name
            print("\(device.id) name=\(name) host=\(device.host):\(device.port) type=\(device.type.rawValue) support=\(support)")
        }
    }

    private static var usage: String {
        """

        Usage:
          YeelightSyncColorScreen --list-displays
          YeelightSyncColorScreen --list-devices [--discovery-timeout seconds]
          YeelightSyncColorScreen --display <id> --id <device-id> [--id <device-id>] [--fps 10] [--sample-stride 8] [--discovery-timeout 5]

        """
    }
}

private actor SyncRuntime {
    private var sessions: [YeelightMusicModeSession] = []
    private var stopped = false

    func run(options: CLIOptions) async throws {
        do {
            try await runLoop(options: options)
            await stop()
        } catch {
            if stopped {
                return
            }
            await stop()
            throw error
        }
    }

    func stop() async {
        if stopped {
            return
        }
        stopped = true
        let activeSessions = sessions
        sessions = []

        for session in activeSessions {
            await session.stop()
        }
    }

    private func runLoop(options: CLIOptions) async throws {
        guard let displayID = options.displayID else {
            throw CLIParseError.missingDisplay
        }

        try await requestScreenCapturePermissionIfNeeded()

        let devices = try await discoverDevices(timeout: options.discoveryTimeout)
        let selectedDevices = try DeviceSelector.select(from: devices, ids: options.deviceIDs)

        print("Starting music mode for \(selectedDevices.count) Yeelight device(s).")
        let activeSessions = try await startMusicSessions(for: selectedDevices)
        setSessions(activeSessions)

        print("Syncing display \(displayID) at \(options.fps) FPS. Press Ctrl-C to stop.")
        let frameDelay = UInt64((1_000_000_000 / options.fps).rounded())
        var lastColor: RGB?

        while !Task.isCancelled, !stopped {
            let frame = try await ScreenCapture.capture(screen: displayID)
            let color = yeelightRGB(from: frame.averageColor(sampleStride: options.sampleStride))

            if color != lastColor {
                try await broadcast(color, to: activeSessions)
                lastColor = color
            }

            try await Task.sleep(nanoseconds: frameDelay)
        }
    }

    private func startMusicSessions(for devices: [YeelightDevice]) async throws -> [YeelightMusicModeSession] {
        var activeSessions: [YeelightMusicModeSession] = []
        do {
            for device in devices {
                let session = try await YeelightMusicModeSession.start(device: device)
                activeSessions.append(session)
            }
            return activeSessions
        } catch {
            for session in activeSessions {
                await session.stop()
            }
            throw error
        }
    }

    private func broadcast(_ color: RGB, to sessions: [YeelightMusicModeSession]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask {
                    try await session.sendRGB(color)
                }
            }
            try await group.waitForAll()
        }
    }

    private func setSessions(_ sessions: [YeelightMusicModeSession]) {
        self.sessions = sessions
    }
}

private enum RuntimeError: Error, LocalizedError {
    case screenCapturePermissionDenied

    var errorDescription: String? {
        switch self {
        case .screenCapturePermissionDenied:
            return """
            Screen capture permission was not granted. If macOS did not show a prompt, enable Screen & System Audio Recording / Screen Recording for your terminal app in System Settings > Privacy & Security, then quit and reopen the terminal.
            """
        }
    }
}

private func requestScreenCapturePermissionIfNeeded() async throws {
    let granted = await MainActor.run {
        if ScreenCapture.preflightPermission() {
            return true
        }

        fputs("Requesting macOS screen capture permission...\n", stderr)
        if ScreenCapture.requestPermission() {
            return true
        }

        return ScreenCapture.preflightPermission()
    }

    guard granted else {
        throw RuntimeError.screenCapturePermissionDenied
    }
}

private func discoverDevices(timeout: TimeInterval) async throws -> [YeelightDevice] {
    var options = SSDPClient.Options()
    options.timeout = timeout
    options.mx = max(1, Int(ceil(timeout)))

    let lookup = YeelightLookup(
        ssdp: SSDPClient(options: options),
        interval: 3_600,
        autoStart: false
    )
    await lookup.lookup()
    return lookup.getLights()
}

private func makeSignalStream() -> AsyncStream<Int32> {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    return AsyncStream { continuation in
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

        intSource.setEventHandler {
            continuation.yield(SIGINT)
            continuation.finish()
        }
        termSource.setEventHandler {
            continuation.yield(SIGTERM)
            continuation.finish()
        }

        continuation.onTermination = { _ in
            intSource.cancel()
            termSource.cancel()
        }

        intSource.resume()
        termSource.resume()
    }
}
