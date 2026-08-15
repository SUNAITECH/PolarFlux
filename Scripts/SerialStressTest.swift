// SerialStressTest.swift
// Concurrency regression test for PolarFlux's serial pipeline.
//
// Reproduces the class of deadlocks that shipped in the failed build:
//   1. transmitLoop() re-acquiring the non-recursive connection lock,
//      which wedges the serial queue AND every subsequent sender
//      (including main-thread heartbeat timers -> beachball).
//   2. User completions invoked while the connection lock is held
//      (lock-order inversion with the caller's own locks).
//   3. checkConnection() dispatching queue.sync behind a busy serial queue.
//
// A pseudo-terminal (openpty) stands in for the USB-serial device. Three
// worker threads hammer send / health-check / connect-disconnect churn for
// a few seconds; a watchdog process-exits non-zero if anything stops making
// progress. Pass criteria are printed at the end.
//
// Run via: ./Scripts/run.sh test

import Foundation
import Darwin

// --- Watchdog: any deadlock anywhere must fail the test, not hang CI ---
DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
    FileHandle.standardError.write("FAIL: watchdog fired — deadlock detected\n".data(using: .utf8)!)
    exit(42)
}

final class Atomic {
    private let l = NSLock()
    private var v = 0
    func add() { l.lock(); v += 1; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return v }
}

let port = SerialPort()

var master: Int32 = 0
var slave: Int32 = 0
var nameBuf = [CChar](repeating: 0, count: 256)
guard openpty(&master, &slave, &nameBuf, nil, nil) == 0 else {
    print("FAIL: openpty unavailable")
    exit(1)
}
let slavePath = String(cString: nameBuf)
defer { close(master); close(slave) }

// Drain the master side continuously so slave writes never stall on a full pty.
// The read handler uses a local buffer: dispatch may run coalesced handler
// invocations on different worker threads, and sharing one global array would
// itself be a (harmless but noisy) data race under ThreadSanitizer.
let drainSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue.global())
drainSource.setEventHandler {
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
    defer { buf.deallocate() }
    _ = read(master, buf, 65536)
}
drainSource.resume()

guard port.connect(path: slavePath, baudRate: 115200) else {
    print("FAIL: initial connect failed")
    exit(1)
}

// Mimic AppState.sendData's lock ordering: completions acquire the app-level
// sendLock. If the serial layer ever invokes a completion while holding its
// connection lock, this creates the inversion and the watchdog fires.
let appSendLock = NSLock()
let sent = Atomic()
let completed = Atomic()
let checks = Atomic()
let reconnects = Atomic()

let group = DispatchGroup()
let runDuration: TimeInterval = 3.0

// T1: high-rate frame sender (the ScreenCapture / Effect / Music producers).
// Paced to ~10k sends/s — far beyond real usage (producers top out at 30–120
// fps) but WITHOUT the pacing this thread starves the health-check and
// reconnect workers on small CI VMs (3 cores), failing their progress
// thresholds spuriously. The deadlock we guard against is caught by the
// watchdog; lost completions by sent == completed.
group.enter()
DispatchQueue.global(qos: .userInitiated).async {
    let payload = [UInt8](repeating: 0xA5, count: 306) // 102 LEDs, Skydimo frame
    let deadline = Date().addingTimeInterval(runDuration)
    while Date() < deadline {
        port.sendSkydimo(rgbData: payload) {
            appSendLock.lock()
            completed.add()
            appSendLock.unlock()
        }
        sent.add()
        usleep(100)
    }
    group.leave()
}

// T2: periodic health checks + telemetry reads (the 2 Hz monitor & wake path).
group.enter()
DispatchQueue.global(qos: .userInitiated).async {
    let deadline = Date().addingTimeInterval(runDuration)
    while Date() < deadline {
        _ = port.checkConnection()
        _ = port.outputQueueSize
        _ = port.totalPacketsSent
        checks.add()
        usleep(2000)
    }
    group.leave()
}

// T3: connect/disconnect churn (unplug simulation) racing the senders.
group.enter()
DispatchQueue.global(qos: .userInitiated).async {
    let deadline = Date().addingTimeInterval(runDuration)
    while Date() < deadline {
        port.disconnect()
        reconnects.add()
        usleep(3000)
        _ = port.connect(path: slavePath, baudRate: 115200)
        usleep(3000)
    }
    group.leave()
}

// Block until all workers finish. The watchdog above guarantees termination
// if anything deadlocks. (Note: no DispatchQueue.main usage here — a CLI
// never pumps the main queue.)
group.wait()

// Deterministic drain: the final send may still be in flight on the serial
// queue when the workers exit. Give completions a bounded window to land
// before the equality check (a hang here is still caught by the watchdog).
var drainWaits = 0
while completed.value < sent.value && drainWaits < 100 {
    usleep(10_000)
    drainWaits += 1
}

print("progress: sent=\(sent.value) completed=\(completed.value) checks=\(checks.value) reconnects=\(reconnects.value)")
// Thresholds are deliberately conservative: their only job is proving the
// workers were scheduled at all. Deadlocks trip the watchdog; lost
// completions break sent == completed; post-churn liveness is verified
// separately below. Absolute counts vary with machine speed — do NOT
// tighten these to local-machine numbers (a 10-core dev box gets ~1000
// checks where a 3-core CI VM may only reach ~200).
guard sent.value > 1000, completed.value == sent.value,
      checks.value > 50, reconnects.value > 20 else {
    print("FAIL: insufficient progress — pipeline stalled or lost completions")
    exit(44)
}

// --- Disconnected synchronous completion must be delivered immediately ---
port.disconnect()
let delivered = Atomic()
port.sendSkydimo(rgbData: [UInt8](repeating: 1, count: 90)) { delivered.add() }
guard delivered.value == 1 else {
    print("FAIL: disconnected completion not delivered synchronously")
    exit(45)
}

// --- Post-churn liveness: reconnect and verify real writes flow ---
guard port.connect(path: slavePath, baudRate: 115200) else {
    print("FAIL: reconnect after churn failed")
    exit(46)
}
let wrote = Atomic()
port.sendSkydimo(rgbData: [UInt8](repeating: 2, count: 90)) { wrote.add() }
let wrote2 = Atomic()
port.sendSkydimo(rgbData: [UInt8](repeating: 3, count: 90)) { wrote2.add() }
Thread.sleep(forTimeInterval: 0.3)
guard wrote.value == 1, wrote2.value == 1, port.totalPacketsSent > 0 else {
    print("FAIL: post-churn sends did not complete (packets=\(port.totalPacketsSent))")
    exit(47)
}

print("PASS: serial stress test (packets=\(port.totalPacketsSent), reconnects=\(reconnects.value))")
exit(0)
