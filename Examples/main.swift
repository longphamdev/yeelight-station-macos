import Foundation
import YeelightWiFi

// Port of node-yeelight-wifi/examples/example.js
// https://github.com/Bastl34/node-yeelight-wifi

let look = YeelightWiFi.Lookup()

look.on(YeelightEvent.detected) { light in
    print("new yeelight detected: host=\(light.host) type=\(light.type.rawValue)")
}

Task {
    // Wait 6 s for SSDP to return any answers (matches the JS sample
    // and gives the multicast group enough time to receive replies
    // from the bulb).
    try? await Task.sleep(nanoseconds: 6_000_000_000)

    let lights = look.getLights()
    print("lights after 5s: \(lights.count)")
    for l in lights {
        print("  id=\(l.id) host=\(l.host) port=\(l.port) type=\(l.type.rawValue)")
    }
    guard !lights.isEmpty else {
        print("no yeelight found")
        exit(0)
    }
    let light = lights[0]

    light.on(YeelightEvent.connected)     { _ in print("connected") }
    light.on(YeelightEvent.disconnected)  { _ in print("disconnected") }
    light.on(YeelightEvent.stateUpdate)   { l in print(l.rgb) }
    // `on(_:handler:)` for `YeelightEvent.failed` takes the typed
    // `EventHandler`, so the payload here is `Any`. Successful casts
    // are `FailedEvent` / `SuccessEvent` / `TimeoutEvent`.
    light.on(YeelightEvent.failed.rawValue) { payload in
        if let f = payload as? FailedEvent { print("failed: \(f)") }
    }

    if light.type == .color {
        do {
            try await light.setRGB(RGB(r: 255, g: 255, b: 0))
            print("setRGB promise resolved")
        } catch {
            print("promise rejected: \(error)")
        }
    }

    do {
        try await light.updateState()
        print("updateState promise resolved")
    } catch {
        print("promise rejected: \(error)")
    }

    // Toggle brightness every second, like the JS sample.
    Task.detached {
        while !Task.isCancelled {
            do {
                if light.bright < 100 {
                    try await light.setBright(100)
                } else {
                    try await light.setBright(10)
                }
            } catch {
                print("setBright failed: \(error)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // Refresh state every 10 seconds.
    Task.detached {
        while !Task.isCancelled {
            do {
                try await light.updateState()
                print("updateState promise resolved")
            } catch {
                print("updateState failed: \(error)")
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
}

RunLoop.main.run()
