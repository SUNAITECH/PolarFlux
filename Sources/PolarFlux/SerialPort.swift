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
    
    // Connection State
    private var isConnectedInternal: Bool = false
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isConnectedInternal && fileDescriptor >= 0
    }
    
    private let targetDevicePacing: Double = 0.004 // DEPRECATED: 4ms assumed device processing capability
    
    var onDisconnect: (() -> Void)?
    
    // Performance Tracking
    private(set) var totalBytesSent: UInt64 = 0
    private(set) var totalPacketsSent: UInt64 = 0
    private(set) var lastWriteLatency: Double = 0
    private(set) var writeErrorCount: Int = 0
    private(set) var reconnectCount: Int = 0
    
    func resetCounters() {
        totalBytesSent = 0
        totalPacketsSent = 0
        writeErrorCount = 0
        reconnectCount = 0
        lastWriteLatency = 0
    }
    
    // Buffer Telemetry
    var outputQueueSize: Int {
        guard fileDescriptor >= 0 else { return 0 }
        var bytes: Int32 = 0
        // TIOCOUTQ returns the number of bytes in the output queue
        if ioctl(fileDescriptor, TIOCOUTQ, &bytes) != -1 {
            return Int(bytes)
        }
        return 0
    }
    
    func listPorts() -> [String] {
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: "/dev")
            return files.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.wch") }.map { "/dev/\($0)" }
        } catch {
            return []
        }
    }
    
    func connect(path: String, baudRate: Int) -> Bool {
        // Close any existing connection first
        self.closeInternal()
        
        self.reconnectCount += 1
        
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
        
        // VMIN=1, VTIME=0: Block until at least 1 byte is received (for reading)
        options.c_cc.16 = 1 // VMIN
        options.c_cc.17 = 0 // VTIME
        
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
        if fileDescriptor >= 0 {
            Logger.shared.log("Closing serial port")
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
            isConnectedInternal = false
            pendingData = nil
            pendingCompletion?()
            pendingCompletion = nil
        }
        lock.unlock()
    }
    
    func send(data: [UInt8], completion: (() -> Void)? = nil) {
        // Non-blocking Send Queue with "Swap" strategy
        // This ensures the serial loop never blocks the main thread or capture/processing loop.
        
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
            // Drop previous pending completion
            pendingCompletion?() 
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
        var outBytes: Int32 = 0
        if ioctl(fileDescriptor, TIOCOUTQ, &outBytes) != -1 {
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
        
        lock.lock()
        let fd = self.fileDescriptor
        let isConnected = self.isConnectedInternal
        lock.unlock()
        
        guard isConnected && fd >= 0 else { return }
        
        data.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            // Blocking write
            let bytesWritten = write(fd, baseAddress, buffer.count)
            
            if bytesWritten < 0 {
                let err = errno
                Logger.shared.log("Write error: \(err)")
                self.writeErrorCount += 1
                if err == 6 || err == 9 || err == 5 {
                    self.handleError()
                }
            } else {
                self.totalBytesSent += UInt64(bytesWritten)
                self.totalPacketsSent += 1
            }
            
            // Removed tcdrain and manual pacing to allow true asynchronous hardware transmission.
            // Theoretical transfer happens in background via Kernel/UART driver.
            // This relies on the kernel buffer to handle backpressure (write will block if buffer full).
        }
        
        self.lastWriteLatency = CACurrentMediaTime() - startTime
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
    // This is useful for periodic health checks or post-wake validation
    func checkConnection() -> Bool {
        return queue.sync {
            lock.lock()
            let fd = fileDescriptor
            lock.unlock()
            
            guard fd >= 0 else { return false }
            
            // Try to get terminal attributes - this is a lightweight check if the FD is still valid
            var options = termios()
            if tcgetattr(fd, &options) == -1 {
                let err = errno
                Logger.shared.log("Connection check failed (errno: \(err)). Assuming disconnected.")
                closeInternal() // closeInternal takes the lock itself, so we must be unlocked here
                DispatchQueue.main.async {
                    self.onDisconnect?()
                }
                return false
            }
            return true
        }
    }
    
    func getDeviceInfo() -> String? {
        lock.lock()
        let fd = fileDescriptor
        lock.unlock()
        
        guard fd >= 0 else { return nil }
        
        // Flush input buffer
        tcflush(fd, TCIFLUSH)
        
        // Send "Moni-A"
        let cmd = "Moni-A"
        var data = [UInt8](cmd.utf8)
        let written = write(fd, &data, data.count)
        if written < 0 {
            Logger.shared.log("Error writing command: \(errno)")
            return nil
        }
        
        // Wait for response (100ms)
        usleep(100000)
        
        // Read response
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buffer, buffer.count)
        
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
        options.c_cc.17 = 5 // 500ms VTIME

        if tcsetattr(fd, TCSANOW, &options) == -1 { return false }

        // Probe with Handshake
        tcflush(fd, TCIFLUSH)
        var cmd = [UInt8]("Moni-A".utf8)
        write(fd, &cmd, cmd.count)
        
        // Wait up to 200ms for response
        usleep(200000)
        
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buffer, buffer.count)
        
        return n > 0 && String(bytes: buffer.prefix(n), encoding: .utf8)?.contains("PolarFlux") == true || n > 0
    }
}
