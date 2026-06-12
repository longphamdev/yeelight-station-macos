# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: swift-yeelight-wifi

A Swift port of [`node-yeelight-wifi`](https://github.com/Bastl34/node-yeelight-wifi) for controlling Yeelight smart bulbs over the local network. Public API mirrors the JS library 1:1 (see `YeelightWiFi` typealiases in `Sources/YeelightWiFi/YeelightWiFi.swift`).

**Platforms:** macOS 12+, Swift 5.9+. macOS-only — uses `Network.framework` (`NWConnection`, `NWConnectionGroup`) and the POSIX `getifaddrs` API. Linux is intentionally out of scope.

## Build, Run, Test

```bash
swift build                              # build library + executables
swift run Example                        # run the SSDP discovery + control sample (port of examples/example.js)
swift run TestOff                        # run the in-source test program (off() handler removal)
swift test                               # run any XCTest targets (none today — TestOff/ is an executable, not a test target)
```

This is a SwiftPM-only project (see `Package.swift`). Three products: library `YeelightWiFi`, executable `Example`, executable `TestOff`. No external dependencies, no CocoaPods, no Xcode project file is required — open `Package.swift` in Xcode if preferred.

There is no linter or formatter configured; match the surrounding Swift style (4-space indent, `MARK:` headers, doc comments on every public symbol).

## Codebase Architecture

All library code lives in `Sources/YeelightWiFi/`. Six files, each with a focused responsibility:

| File | Responsibility |
|------|----------------|
| `YeelightWiFi.swift` | Public façade: `YeelightWiFi` enum exposing `Yeelight` and `Lookup` typealiases. **No types are defined here.** |
| `YeelightEvents.swift` | `YeelightEvent` enum (string rawValues matching JS event names), event handler typealiases, `FailedEvent` / `TimeoutEvent` / `SuccessEvent` payloads, `YeelightError`. |
| `Yeelight.swift` | `YeelightDevice` — persistent JSON-RPC-over-TCP connection to one bulb, typed setters (`setPower`, `setRGB`, `setHSV`, `setCT`, `setBright`, `updateState`), event emitter, pending-message map keyed by JSON-RPC `id`. |
| `SSDPClient.swift` | `SSDPClient` + `SSDPMessage`. Multicast `M-SEARCH` for `wifi_bulb` on `239.255.255.250:1982` via `NWConnectionGroup`. Uses a private `SSDPActor` to serialize receive state and avoid Swift 6 concurrency warnings. |
| `Lookup.swift` | `YeelightLookup` — periodic SSDP discovery (60s interval, matches upstream) + opt-in `findByPortscanning()` fallback that walks every `/24` of every non-internal IPv4 interface and probes TCP 55443. Uses `LocalNetwork.ipv4Addresses()` (`getifaddrs`). |
| `ColorMath.swift` | `RGB` / `HSV` value types, wire-format conversions (`rgbToInt` / `intToRGB`), RGB↔HSV, `ColorTemp.toRGB(kelvin:)` (Tanner Helland approximation, replaces the `color-temp` npm package). |

**Two executables** demonstrate the library:
- `Examples/main.swift` — direct port of `examples/example.js`. Discovers bulbs, toggles brightness every second, refreshes state every 10s.
- `TestOff/main.swift` — manual integration test for the `off(_:id:)` event-listener removal path. Not wired into `swift test`.

### Key invariants

- **Frame splitting** (`Yeelight.swift:drainFrames`) splits incoming bytes on `\r\n`, matching the JS upstream's behavior. Don't change to `NWConnection.receiveMessage` without re-validating against a real bulb.
- **JSON-RPC pending messages** (`Yeelight.swift:sendCommand`) — every command gets a `DispatchWorkItem` timer (`requestTimeout: 5s`); on expiry the pending entry is removed, a `timeout` event fires, and the `CheckedContinuation` rejects with `YeelightError.timeout(id:)`. Cancellation must be paired carefully with the timer.
- **SetHSV concurrency** (`Yeelight.swift:setHSV`) — the upstream library fires `set_hsv` and `set_bright` in parallel; the Swift port awaits them sequentially. Preserve the dual-command shape even though it's serialized.
- **`mac` field is always empty** (`Yeelight.swift:mac`) — `node-arp` has no portable Foundation equivalent. Don't add a `getifaddrs`-based MAC scraper; the upstream README already notes MAC is "not guaranteed".
- **Event emitter thread-safety** — both `YeelightDevice` and `YeelightLookup` guard the listener map with an `NSLock` and dispatch handlers on `DispatchQueue.global(qos: .userInitiated)`. Don't replace the lock with `@MainActor` isolation; it changes the contract documented in the README.
- **`off(_:id:)` uses UUIDs**, `off(_:handler:)` uses `ObjectIdentifier`. The latter only works for handlers registered through the `EventHandler` overload — the `YeelightEvent`-typed `on` wraps the handler in a new closure and breaks identity comparison.
- **Discovery cadence** — `YeelightLookup` kicks off a SSDP search on `init` and again every 60s in a long-running `Task`. Constructing a `Lookup` from a test or script will start the network loop immediately; cancel the task by dropping the reference or calling `deinit`.
- **Port-scan timeout** (`Lookup.swift:portScanTimeout = 10s`) is per-IP. A scan of a `/24` is 254 × 10s worst case; the work is fan-outed via a `TaskGroup`, not serialized.

## GitNexus

The repo is indexed by GitNexus (36 symbols, 29 relationships). Always check before editing:

- **MUST run `gitnexus_impact`** on any symbol before modifying it; report the blast radius (direct callers, affected processes, risk level) to the user. HIGH/CRITICAL → warn before proceeding.
- **MUST run `gitnexus_detect_changes()`** before committing.
- Use `gitnexus_query` and `gitnexus_context` for navigation instead of grepping.
- Use `gitnexus_rename` for any symbol rename; never find-and-replace.
- If the index is stale, run `npx gitnexus analyze` first.

CLI/skill references: `.claude/skills/gitnexus/`. Resource list: `gitnexus://repo/yeelight-station-macos/...`.
