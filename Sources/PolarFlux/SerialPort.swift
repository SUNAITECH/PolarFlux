import Foundation
import Darwin
import QuartzCore

class SerialPort {
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.sunaish.polarflux.serial", qos: .userInteractive)
    
    // Ring Buffer Strategy
    private var pendingData: [UInt8]?
    private var isSending: Bool = false
    private let lock = NSLock()
    
    // Adaptive Timing
    private let targetDevicePacing: Double = 0.004 // 4ms assumed device processing capability
    
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
        // Ensure any previous connection is closed properly on the queue
        queue.sync {
            self.closeInternal()
        }
        
        self.reconnectCount += 1
        
        // Open the serial port
        // O_RDWR - Read and write
        // O_NOCTTY - No controlling terminal
        // Removed O_NONBLOCK to use blocking mode (handled by background queue)
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
        queue.sync {
            self.fileDescriptor = fd
            self.isConnectedState = true
        }
        Logger.shared.log("Connected to \(path) with baud rate \(baudRate)")
        return true
    }
    
    func disconnect() {
        queue.sync {
            self.closeInternal()
        }
    }
    
    // Must be called on queue
    private func closeInternal() {
        if fileDescriptor >= 0 {
            Logger.shared.log("Closing serial port")
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
            isConnectedState = false
        }
    }
    
    // Thread-safe check for connection status
    private var isConnectedState: Bool = false
    var isConnected: Bool {
        return queue.sync { isConnectedState }
    }
    
    func send(data: [UInt8], completion: (() -> Void)? = nil) {
        // Non-blocking Send Queue with "Overwrite Oldest" strategy
        lock.lock()
        if !isConnectedState {
            lock.unlock()
            completion?()
            return
        }
        
        // Overwrite the pending frame with the newest one (Depth 2: Current + Pending)
        pendingData = data
        
        // If we are not currently sending, start the transmission loop
        if !isSending {
            isSending = true
            lock.unlock()
            
            queue.async { [weak self] in
                self?.transmitLoop()
            }
        } else {
            lock.unlock()
        }
        
        // Immediate completion because we've queued it (non-blocking)
        completion?()
    }
    
    private func transmitLoop() {
        while true {
            lock.lock()
            guard let data = pendingData else {
                isSending = false
                lock.unlock()
                return // Queue empty, stop loop
            }
            // Consume the data, clear pending
            pendingData = nil
            lock.unlock()
            
            performWrite(data: data)
        }
    }
    
    private func performWrite(data: [UInt8]) {
        let startTime = CACurrentMediaTime()
        
        data.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            // Blocking write
            let bytesWritten = write(self.fileDescriptor, baseAddress, buffer.count)
            
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
            
            // Wait for drainage
            if self.fileDescriptor >= 0 {
                let drainResult = tcdrain(self.fileDescriptor)
                if drainResult == -1 {
                    self.handleError()
                }
                
                // Adaptive Waiting
                // Calculate how long actual transmission + drain took
                let elapsed = CACurrentMediaTime() - startTime
                
                // If the operation was faster than our target pacing, wait the difference
                // This ensures we don't flood the device, but we don't wait unnecessarily if transmission was slow
                if elapsed < targetDevicePacing {
                    let sleepTime = targetDevicePacing - elapsed
                    usleep(useconds_t(sleepTime * 1_000_000))
                }
            }
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
            guard fileDescriptor >= 0 else { return false }
            
            // Try to get terminal attributes - this is a lightweight check if the FD is still valid
            var options = termios()
            if tcgetattr(fileDescriptor, &options) == -1 {
                let err = errno
                Logger.shared.log("Connection check failed (errno: \(err)). Assuming disconnected.")
                closeInternal()
                DispatchQueue.main.async {
                    self.onDisconnect?()
                }
                return false
            }
            return true
        }
    }
    
    func getDeviceInfo() -> String? {
        guard fileDescriptor >= 0 else { return nil }
        
        // Flush input buffer
        tcflush(fileDescriptor, TCIFLUSH)
        
        // Send "Moni-A"
        let cmd = "Moni-A"
        var data = [UInt8](cmd.utf8)
        let written = write(fileDescriptor, &data, data.count)
        if written < 0 {
            Logger.shared.log("Error writing command: \(errno)")
            return nil
        }
        
        // Wait for response (100ms)
        usleep(100000)
        
        // Read response
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(fileDescriptor, &buffer, buffer.count)
        
        if n > 0 {
            let response = String(bytes: buffer.prefix(n), encoding: .utf8)
            return response?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
}
