import Foundation
import YeelightWiFi

// Test: off() actually removes a registered handler
// We use EventHandler directly and trigger via updatePower (which emits stateUpdate).

print("=== Test 1: off() removes a registered handler ===")

let device = YeelightWiFi.Yeelight()

var callCount = 0
let handler: EventHandler = { payload in
    if let _ = payload as? YeelightDevice { callCount += 1 }
}

let token1 = device.on(YeelightEvent.stateUpdate.rawValue, handler: handler)
device.updatePower("on")
// Give async emit a moment to fire
Thread.sleep(forTimeInterval: 0.1)
print("After on + 1 updatePower: callCount = \(callCount)")  // Expected: 1

device.off(YeelightEvent.stateUpdate.rawValue, id: token1)
device.updatePower("off")
Thread.sleep(forTimeInterval: 0.1)
print("After off + 1 updatePower: callCount = \(callCount)")  // Expected: 1 (not 2)

if callCount == 1 {
    print("✅ PASS: off() correctly removed the handler")
} else {
    print("❌ FAIL: off() did not remove the handler (callCount = \(callCount))")
}

// Test: off() only removes the specific handler, not all handlers
print("\n=== Test 2: off() removes only the specific handler ===")

let device2 = YeelightWiFi.Yeelight()
var countA = 0
var countB = 0

let handlerA: EventHandler = { payload in
    if let _ = payload as? YeelightDevice { countA += 1 }
}
let handlerB: EventHandler = { payload in
    if let _ = payload as? YeelightDevice { countB += 1 }
}

let tokenA = device2.on(YeelightEvent.stateUpdate.rawValue, handler: handlerA)
let tokenB = device2.on(YeelightEvent.stateUpdate.rawValue, handler: handlerB)
device2.updatePower("on")
Thread.sleep(forTimeInterval: 0.1)
print("After both handlers registered: countA = \(countA), countB = \(countB)")  // Expected: 1, 1

device2.off(YeelightEvent.stateUpdate.rawValue, id: tokenA)
device2.updatePower("off")
Thread.sleep(forTimeInterval: 0.1)
print("After removing A: countA = \(countA), countB = \(countB)")  // Expected: 1, 2

if countA == 1 && countB == 2 {
    print("✅ PASS: off() removed only the specific handler")
} else {
    print("❌ FAIL: off() removed wrong handler(s) (countA = \(countA), countB = \(countB))")
}

// Test: off() on non-existent event does nothing
print("\n=== Test 3: off() on non-existent event ===")
device2.off("nonexistent", id: UUID())
print("✅ PASS: off() on non-existent event did not crash")

// Test: off() with unregistered token does nothing
print("\n=== Test 4: off() with unregistered token ===")
device2.off(YeelightEvent.stateUpdate.rawValue, id: UUID())
device2.updatePower("on")
Thread.sleep(forTimeInterval: 0.1)
print("After removing unregistered token: countB = \(countB)")  // Expected: 3
if countB == 3 {
    print("✅ PASS: off() with unregistered token did not affect registered handlers")
} else {
    print("❌ FAIL: off() with unregistered token removed a registered handler (countB = \(countB))")
}

print("\n=== All tests complete ===")