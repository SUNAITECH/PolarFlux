import Foundation
import Darwin
import QuartzCore

class SerialPort {
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.sunaish.polarflux.serial", qos: .userInteractive)
    
    // Ring Buffer Strategy
    private var pendingData: [UInt8]?
    private var pendingCompletion: (() -> Void)?
    private var isSending: Bool = false
    private let lock = NSLock()

    // fd lifecycle mutex: makes {snapshot fd → syscall(fd)} atomic against
    // close(). Without it, closeInternal() could Darwin.close(fd) between a
    // writer's snapshot and its write(), and a concurrent open() could recycle
    // the descriptor number — misdirecting writes to an unrelated file.
    // Lock order: ioLock → lock (never the reverse; closeInternal releases
    // `lock` before acquiring ioLock).
    private let ioLock = NSLock()
    
    // Connection State
    private var isConnectedInternal: Bool = false
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isConnectedInternal && fileDescriptor >= 0
    }

    var onDisconnect: (() -> Void)?

    // Performance Tracking
    // Counters are written on the serial queue and read from the main thread,
    // so all access is serialised through `statsLock` to avoid data races
    // (TSan-visible torn reads / lost increments).
    private let statsLock = NSLock()
    private var _totalBytesSent: UInt64 = 0
    private var _totalPacketsSent: UInt64 = 0
    private var _lastWriteLatency: Double = 0
    private var _writeErrorCount: Int = 0
    private var _reconnectCount: Int = 0

    var totalBytesSent: UInt64 {
        statsLock.lock(); defer { statsLock.unlock() }
        return _totalBytesSent
    }
    var totalPacketsSent: UInt64 {
        statsLock.lock(); defer { statsLock.unlock() }
        return _totalPacketsSent
    }
    var lastWriteLatency: Double {
        statsLock.lock(); defer { statsLock.unlock() }
        return _lastWriteLatency
    }
    var writeErrorCount: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return _writeErrorCount
    }
    var reconnectCount: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return _reconnectCount
    }

    func resetCounters() {
        statsLock.lock(); defer { statsLock.unlock() }
        _totalBytesSent = 0
        _totalPacketsSent = 0
        _writeErrorCount = 0
        _reconnectCount = 0
        _lastWriteLatency = 0
    }

    /// Safely snapshots the current fd under the connection lock.
    private func currentFileDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fileDescriptor
    }

    // Buffer Telemetry
    var outputQueueSize: Int {
        let fd = currentFileDescriptor()
        guard fd >= 0 else { return 0 }
        var bytes: Int32 = 0
        // TIOCOUTQ returns the number of bytes in the output queue
        if ioctl(fd, TIOCOUTQ, &bytes) != -1 {
            return Int(bytes)
        }
        return 0
    }
    
    func listPorts() -> [String] {
        // Only `cu.*` (callout) devices are used; `tty.*` is avoided to prevent
        // conflicts with incoming-call semantics on classic serial lines.
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: "/dev")
            return files
                .filter { entry in
                    // Match common USB-serial chip families, but never expose the
                    // Bluetooth modem or other virtual ports.
                    guard entry.hasPrefix("cu.") else { return false }
                    if entry.contains("Bluetooth") { return false }
                    return entry.hasPrefix("cu.usbserial") ||
                           entry.hasPrefix("cu.usbmodem") ||
                           entry.hasPrefix("cu.SLAB_USBtoUART") ||
                           entry.hasPrefix("cu.wch")
                }
                .sorted()
                .map { "/dev/\($0)" }
        } catch {
            return []
        }
    }
    
    func connect(path: String, baudRate: Int) -> Bool {
        // Close any existing connection first
        self.closeInternal()
        
        statsLock.lock()
        self._reconnectCount += 1
        statsLock.unlock()
        
        // Open the serial port
        // O_RDWR - Read and write
        // O_NOCTTY - No controlling terminal
        let fd = open(path, O_RDWR | O_NOCTTY)
        if fd == -1 {
            Logger.shared.log("Error opening port \(path): \(errno)")
            return false
        }
        
        // Configure the serial port
        var options = termios()
        if tcgetattr(fd, &options) == -1 {
            Logger.shared.log("Error getting attributes: \(errno)")
            Darwin.close(fd)
            return false
        }
        
        // Set baud rate
        let speed: speed_t
        switch baudRate {
        case 9600: speed = speed_t(B9600)
        case 19200: speed = speed_t(B19200)
        case 38400: speed = speed_t(B38400)
        case 57600: speed = speed_t(B57600)
        case 115200: speed = speed_t(B115200)
        case 230400: speed = speed_t(230400)
        case 460800: speed = speed_t(460800)
        case 500000: speed = speed_t(500000)
        case 921600: speed = speed_t(921600)
        default: speed = speed_t(B115200)
        }
        
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)
        
        // On macOS, setting custom baud rate might require IOSSIOSPEED if standard calls fail,
        // but often passing the integer to cfsetospeed works for standard non-POSIX rates supported by the driver.
        // If the driver supports it, it should work.
        
        // Configure 8N1 (8 bits, No parity, 1 stop bit)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        
        // No flow control
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        
        // Local mode and enable receiver
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        
        // Raw input
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        
        // Disable software flow control and other input processing
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_iflag &= ~tcflag_t(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL)
        
        // Raw output
        options.c_oflag &= ~tcflag_t(OPOST | ONLCR)
        
        // VMIN=0, VTIME=5: reads return after at most 0.5s even if no data
        // arrives. This bounds handshake/device-info reads so a silent device
        // can never block the connection path forever. (On Darwin, VMIN==16
        // and VTIME==17; Swift tuples only allow literal positional member
        // access, so we use those directly.)
        options.c_cc.16 = 0 // VMIN
        options.c_cc.17 = 5 // VTIME (x0.1s)
        
        if tcsetattr(fd, TCSANOW, &options) == -1 {
            Logger.shared.log("Error setting attributes: \(errno)")
            Darwin.close(fd)
            return false
        }
        
        // Update state in a thread-safe way
        lock.lock()
        self.fileDescriptor = fd
        self.isConnectedInternal = true
        lock.unlock()
        
        Logger.shared.log("Connected to \(path) with baud rate \(baudRate)")
        return true
    }
    
    func disconnect() {
        self.closeInternal()
    }
    
    // Must be called on queue or protected by lock
    private func closeInternal() {
        lock.lock()
        let fd = fileDescriptor
        var savedCompletion: (() -> Void)?
        if fd >= 0 {
            fileDescriptor = -1
            isConnectedInternal = false
            pendingData = nil
            savedCompletion = pendingCompletion
            pendingCompletion = nil
        }
        lock.unlock()

        if fd >= 0 {
            // Close under ioLock so no in-flight write()/ioctl() can touch a
            // descriptor that is being (or has just been) closed and recycled.
            ioLock.lock()
            Darwin.close(fd)
            ioLock.unlock()
            Logger.shared.log("Closing serial port")
            // Invoke outside any lock: the completion may acquire other locks
            // (AppState.sendLock) and must never stall the connection lock.
            savedCompletion?()
        }
    }
    
    func send(data: [UInt8], completion: (() -> Void)? = nil) {
        // Non-blocking Send Queue with "Swap" strategy
        // This ensures the serial loop never blocks the main thread or capture/processing loop.

        // Completion for the frame being superseded (if any). User callbacks are
        // NEVER invoked while holding `lock` — they may acquire their own locks
        // (e.g. AppState.sendLock), and calling them under ours can stall the
        // serial queue or, worse, create a lock-order inversion.
        var droppedCompletion: (() -> Void)?

        lock.lock()
        if !isConnectedInternal {
            lock.unlock()
            completion?()
            return
        }

        // 1. Overwrite the pending frame.
        // If there was ALREADY a pending frame that hasn't started transmitting yet, we drop it.
        // This effectively implements "Latest Data Wins" (Head Dropping) behavior.
        if pendingData != nil {
            droppedCompletion = pendingCompletion
        }

        pendingData = data
        pendingCompletion = completion

        // 2. Drive the loop
        if !isSending {
            isSending = true
            lock.unlock()

            queue.async { [weak self] in
                self?.transmitLoop()
            }
        } else {
            // Already sending, the loop will pick up 'pendingData' when it finishes current write
            lock.unlock()
        }

        droppedCompletion?()
    }
    
    private func transmitLoop() {
        // We use a loop that can yield to allow other tasks (like close) to run
        lock.lock()
        guard isConnectedInternal, let data = pendingData else {
            isSending = false
            lock.unlock()
            return // Stop loop
        }

        // Backpressure Check: Check OS buffer size before commiting to write
        // If buffer is too full, dropping this frame is better than adding to latency.
        // NOTE: we already hold `lock` here, so `fileDescriptor` is read directly —
        // calling currentFileDescriptor() would re-acquire the non-recursive NSLock
        // and self-deadlock the serial queue (which then wedges every sender).
        var outBytes: Int32 = 0
        if fileDescriptor >= 0, ioctl(fileDescriptor, TIOCOUTQ, &outBytes) != -1 {
            // Threshold: 2048 bytes (approx 0.17s latency at 115200 baud). 
            // Ideally we want < 30ms latency. At 115200, 30ms is ~345 bytes.
            // But we must allow at least one full packet (e.g. 500 bytes for 150 LEDs).
            // Let's set a conservative "Emergency Brake" at 1024 bytes to prevent massive lag.
            if outBytes > 1024 {
                // Buffer Bloat Detected. Drop this frame to allow buffer to drain.
                // We leave isSending = true and re-queue to retry/check later or pick up next frame.
                // Actually, if we drop this one, we should check if there is a NEWER one logic?
                // But pendingData is the newest.
                // If we don't write it, we should maybe sleep a tiny bit?
                // Better strategy: Drop it, but keep loop alive to check next time.
                // Or better: Process the drop, wait 10ms, then loop.
                
                // For now, simple drop behavior:
                // Treat as "Sent" (consumed) but didn't write.
                pendingData = nil
                let cb = pendingCompletion
                pendingCompletion = nil
                lock.unlock()
                
                // Log warning occasionally?
                // Just fire callback as if sent (to unlock Pipeline)
                cb?()
                
                // Pace the retry slightly to let buffer drain
                queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.transmitLoop()
                }
                return
            }
        }

        // Consume the data
        pendingData = nil
        let cb = pendingCompletion
        pendingCompletion = nil
        lock.unlock()
        
        performWrite(data: data)
        cb?()
        
        // Yield and re-queue
        queue.async { [weak self] in
            self?.transmitLoop()
        }
    }
    
    private func performWrite(data: [UInt8]) {
        let startTime = CACurrentMediaTime()

        // fd snapshot → write() must be atomic against close()/recycle.
        ioLock.lock()
        lock.lock()
        let fd = self.fileDescriptor
        let isConnected = self.isConnectedInternal
        lock.unlock()

        guard isConnected && fd >= 0 else {
            ioLock.unlock()
            return
        }

        data.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            // Blocking write
            let bytesWritten = write(fd, baseAddress, buffer.count)

            if bytesWritten < 0 {
                let err = errno
                Logger.shared.log("Write error: \(err)")
                statsLock.lock()
                self._writeErrorCount += 1
                statsLock.unlock()
                if err == 6 || err == 9 || err == 5 {
                    ioLock.unlock()
                    self.handleError()
                    statsLock.lock()
                    self._lastWriteLatency = CACurrentMediaTime() - startTime
                    statsLock.unlock()
                    return
                }
            } else {
                statsLock.lock()
                self._totalBytesSent += UInt64(bytesWritten)
                self._totalPacketsSent += 1
                statsLock.unlock()
            }

            // Removed tcdrain and manual pacing to allow true asynchronous hardware transmission.
            // Theoretical transfer happens in background via Kernel/UART driver.
            // This relies on the kernel buffer to handle backpressure (write will block if buffer full).
        }

        ioLock.unlock()

        statsLock.lock()
        self._lastWriteLatency = CACurrentMediaTime() - startTime
        statsLock.unlock()
    }
    
    private func handleError() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.closeInternal()
            DispatchQueue.main.async {
                self.onDisconnect?()
            }
        }
    }
    
    func sendSkydimo(rgbData: [UInt8], completion: (() -> Void)? = nil) {
        // Skydimo protocol: Ada + 0x00 + Count Hi + Count Lo + Data
        // Note: Count is the actual number of LEDs
        let count = rgbData.count / 3
        guard count > 0 else {
            completion?()
            return
        }
        
        let hi = UInt8((count >> 8) & 0xFF)
        let lo = UInt8(count & 0xFF)
        
        var packet: [UInt8] = [0x41, 0x64, 0x61, 0x00, hi, lo]
        packet.append(contentsOf: rgbData)
        
        send(data: packet, completion: completion)
    }
    
    // Robustness: Add an explicit check method to verify connectivity
    // This is useful for periodic health checks or post-wake validation.
    //
    // The tcgetattr() probe runs while holding `lock`: it is a fast, non-blocking
    // ioctl, and doing it under the lock makes the whole check atomic against
    // closeInternal()/connect() (no window where a recycled fd could produce a
    // false positive). It deliberately does NOT dispatch through the serial
    // queue: if the queue were ever blocked in a slow write, queue.sync here
    // would freeze the calling thread (notably main, on the wake path).
    func checkConnection() -> Bool {
        lock.lock()
        let fd = fileDescriptor
        var healthy = false
        if fd >= 0 {
            var options = termios()
            healthy = (tcgetattr(fd, &options) == 0)
        }
        lock.unlock()

        if !healthy && fd >= 0 {
            let err = errno
            Logger.shared.log("Connection check failed (errno: \(err)). Assuming disconnected.")
            closeInternal() // closeInternal takes the lock itself, so we must be unlocked here
            DispatchQueue.main.async {
                self.onDisconnect?()
            }
        }
        return healthy
    }
    
    func getDeviceInfo() -> String? {
        // Snapshot fd → syscalls must be atomic against close()/recycle.
        ioLock.lock()
        defer { ioLock.unlock() }

        lock.lock()
        let fd = fileDescriptor
        lock.unlock()

        guard fd >= 0 else { return nil }

        // Flush input buffer
        tcflush(fd, TCIFLUSH)

        // Send "Moni-A" — use a scoped buffer pointer so the address is valid for the syscall.
        let cmd = [UInt8]("Moni-A".utf8)
        let written = cmd.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return write(fd, base, buf.count)
        }
        if written < 0 {
            Logger.shared.log("Error writing command: \(errno)")
            return nil
        }

        // Wait for response (100ms)
        usleep(100000)

        // Read response
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return read(fd, base, buf.count)
        }

        if n > 0 {
            let response = String(bytes: buffer.prefix(n), encoding: .utf8)
            return response?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    /// Safely probes a baud rate without affecting current application state beyond the serial link.
    /// This is intended for background testing of baud rates.
    func probeBaudRate(path: String, baudRate: Int) -> Bool {
        // We use a temporary local file descriptor to avoid interfering with the main one
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd == -1 { return false }
        defer { Darwin.close(fd) }

        var options = termios()
        if tcgetattr(fd, &options) == -1 { return false }

        let speed: speed_t
        switch baudRate {
        case 9600: speed = speed_t(B9600)
        case 19200: speed = speed_t(B19200)
        case 38400: speed = speed_t(B38400)
        case 57600: speed = speed_t(B57600)
        case 115200: speed = speed_t(B115200)
        case 230400: speed = speed_t(230400)
        case 460800: speed = speed_t(460800)
        case 500000: speed = speed_t(500000)
        case 921600: speed = speed_t(921600)
        default: return false
        }

        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)
        
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL)
        options.c_oflag &= ~tcflag_t(OPOST | ONLCR)
        options.c_cc.16 = 0 // VMIN=0 with O_NONBLOCK for immediate read
        options.c_cc.17 = 5 // VTIME (500ms)

        if tcsetattr(fd, TCSANOW, &options) == -1 { return false }

        // Probe with Handshake
        tcflush(fd, TCIFLUSH)
        let cmd = [UInt8]("Moni-A".utf8)
        cmd.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(fd, base, buf.count)
        }

        // Wait up to 200ms for response
        usleep(200000)

        var buffer = [UInt8](repeating: 0, count: 32)
        let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return read(fd, base, buf.count)
        }

        guard n > 0,
              let response = String(bytes: buffer.prefix(n), encoding: .utf8)
        else { return false }

        // Only accept a genuine device handshake. Previously this returned true for *any*
        // bytes received (due to operator precedence), which produced false positives and
        // locked onto the wrong baud rate / arbitrary data.
        return response.contains("PolarFlux") || response.contains("SK0") || response.contains("SKA")
    }
}
