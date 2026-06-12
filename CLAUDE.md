# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **yeelight-station-macos** (13 symbols, 9 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/yeelight-station-macos/context` | Codebase overview, check index freshness |
| `gitnexus://repo/yeelight-station-macos/clusters` | All functional areas |
| `gitnexus://repo/yeelight-station-macos/processes` | All execution flows |
| `gitnexus://repo/yeelight-station-macos/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->

---

# Project: swift-yeelight-wifi

A Swift port of the Node.js [`node-yeelight-wifi`](https://github.com/Bastl34/node-yeelight-wifi) library for controlling Yeelight smart bulbs over the local network. Swift package name on disk is `swift-yeelight-wifi`; the product consumers import is `YeelightWiFi`. macOS 12+ only — uses `Network.framework` and `getifaddrs`.

## Build, Run, Test

Swift Package Manager, no Xcode project. All commands run from repo root.

```bash
swift build                           # Debug build of all targets
swift build -c release                # Release build
swift run Example                     # Run the Example executable (Examples/main.swift) — requires a bulb on the LAN
swift run TestOff                     # Run the in-process test executable (TestOff/main.swift) — offline, no bulb needed
```

The `TestOff` target is a self-contained `main.swift` that exercises `YeelightDevice.on/off` lifecycle (4 cases) using `Thread.sleep` to wait for async emit. There is no XCTest target — keep the `TestOff` pattern when adding new offline tests, and add a separate executable target that depends on `YeelightWiFi` if it needs new paths under `TestOff/`.

To add a third-party dependency, edit `Package.swift` directly (no `Package.resolved` is checked in; this repo currently has no external dependencies).

## Architecture

The library reproduces the upstream Node.js public surface as closely as possible: same two classes, same event names, same JSON-RPC command wire format. The public façade is `YeelightWiFi` (an empty `enum` namespace) which exposes two typealiases so call sites can use the original names: `YeelightWiFi.Yeelight == YeelightDevice` and `YeelightWiFi.Lookup == YeelightLookup`. Internal types use the descriptive names.

### Source files (under `Sources/YeelightWiFi/`)

- **`YeelightWiFi.swift`** — Public façade. Only file a downstream consumer is *required* to look at to know the typealiases.
- **`Yeelight.swift`** — `YeelightDevice`. Owns a single `NWConnection` to one bulb, maintains the JSON-RPC request/response state machine, the cached `power`/`rgb`/`hsb`/`bright` state, and the listener registry. The state mutators (`updateByRGB`, `updateCT`, `updateHSV`, `updateBright`, `updatePower`) are the **single emit point for `stateUpdate`** — both the public setters and the `parseResponse` path flow through them, which is how cached state stays consistent with the bulb.
- **`Lookup.swift`** — `YeelightLookup`. Owns one `SSDPClient` and a periodic `Task` that calls `lookup()` every `YeelightLookup.lookupInterval` (60 s). `findByPortscanning()` is the slow `/24` walk fallback when SSDP is blocked. Uses `LocalNetwork.ipv4Addresses()` (raw `getifaddrs`) to enumerate interfaces.
- **`SSDPClient.swift`** — `SSDPClient` + private `SSDPActor`. M-SEARCHes `wifi_bulb` on `239.255.255.250:1982` via `NWConnectionGroup` (a plain `NWConnection` would send unicast and never reach the bulb). The `SSDPActor` actor serializes the response list and the `ready`/`finished` lifetime flags — it exists specifically to avoid Swift 6 "concurrent access to captured `var`" warnings that `NSLock` from `NWConnectionGroup` callbacks would otherwise hit.
- **`ColorMath.swift`** — `RGB`, `HSV`, `rgbToInt`/`intToRGB`, `rgbToHSV`/`hsvToRGB`, and `ColorTemp.toRGB(kelvin:)` (Tanner Helland approximation). The CT input is clamped to 1700–6500 K to match the bulb's accepted range and the upstream behavior.
- **`YeelightEvents.swift`** — `YeelightEvent` enum (string-backed), the three handler typealiases (`LightHandler`, `DetectedHandler`, `EventHandler`), the three event-payload structs (`FailedEvent`, `TimeoutEvent`, `SuccessEvent`), and `YeelightError`. `TimeoutEvent`/`SuccessEvent` use `[Any]` for `params` on purpose — the upstream library preserves the exact JSON value passed in (string/int/dict depending on command).

### Wire protocol

Bulb control is JSON-RPC over TCP port **55443**, one request per line, `\r\n`-terminated. Responses are also `\r\n`-terminated frames. The set of allowed methods is gated by the bulb's `support` header (parsed in `updateBySSDPMessage`); `sendCommand` rejects with `.methodNotSupported` if the method isn't in `support`. Requests that don't get a response within `YeelightDevice.requestTimeout` (5 s) reject with `.timeout(id:)`.

There are two response shapes:
- **Notifications** (`method == "props"`) — bulb-initiated state push, handled in `parseResponse` and converted to state updates.
- **Command responses** — resolved by the in-flight `PendingMessage` keyed on `id`; the continuation is resumed in `parseResponse`, or rejected by the timeout `DispatchWorkItem`.

### Concurrency model

- `YeelightDevice` and `YeelightLookup` are `@unchecked Sendable` with internal `NSLock` for the listener registry.
- `NWConnection` callbacks land on a `userInitiated` global queue. The receive loop accumulates bytes in `receiveBuffer` and `drainFrames()` splits on `\r\n`.
- Outbound `sendCommand` wraps a `withCheckedThrowingContinuation` around a `DispatchWorkItem` timeout — there is no per-request `Task`; the continuation is held by the `PendingMessage` until the matching response arrives.
- `SSDPClient` uses a private actor (`SSDPActor`) instead of `NSLock` because `NWConnectionGroup` callbacks are easier to bridge through actor `Task`s.
- `Lookup.findByPortscanning` uses a `withTaskGroup` fan-out (one task per `/24` host) and touches `lights` from `MainActor.run` to keep mutation serialized.

## Things to know that aren't obvious

- The Node.js library uses `node-arp` to fill in MAC addresses; there is no portable Foundation equivalent, so `YeelightDevice.mac` is **always `""`** in this port. Don't try to fix that — the upstream README already notes MAC is "not guaranteed."
- The `YeelightDevice` init has two paths: `init(ssdpMessage:)` (the SSDP-discovered path, which immediately calls `connect()`) and `initialize(host:port:mac:)` (the port-scan path, which spawns a `Task` to call `updateState()` after connecting). Mirror this asymmetry when adding new construction sites.
- `setHSV` sends `set_hsv` and `set_bright` as **two sequential** commands — the comment in `Yeelight.swift` notes the JS implementation fires them concurrently, but the Swift port awaits them in sequence. Don't parallelize this without testing — the bulb's `props` notification race against the second `set_bright` response can otherwise leave cached `bright` stale.
- The `on(_ event: YeelightEvent, handler: LightHandler)` overload wraps the typed handler in a fresh closure, so the `off(_:handler:)` path (which uses `ObjectIdentifier` on the closure) **cannot** remove handlers registered through the typed overload. Direct users of the string-typed `on(_:handler:)` (returning a `UUID` token) and call `off(_:id:)` to remove them — this asymmetry is exercised by `TestOff/main.swift`.
- Many call sites log to `NSLog` at high frequency (every SSDP response, every `lookup()` tick). This is intentional in this codebase to aid LAN debugging; don't strip it without asking.
- `Package.swift` lists the library path as `Sources/YeelightWiFi` and the executables as `Examples` and `TestOff`. When adding files, follow the existing per-class layout — don't group all types into one file.
