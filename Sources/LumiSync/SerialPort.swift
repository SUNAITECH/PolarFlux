import Foundation
import Darwin

class SerialPort {
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.lumisync.serial")
    
    var onDisconnect: (() -> Void)?
    
    var isConnected: Bool {
        return fileDescriptor >= 0
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
        close()
        
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
        
        self.fileDescriptor = fd
        Logger.shared.log("Connected to \(path) with baud rate \(baudRate)")
        return true
    }
    
    func disconnect() {
        close()
    }
    
    private func close() {
        if fileDescriptor >= 0 {
            Logger.shared.log("Closing serial port")
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
    
    func send(data: [UInt8], completion: (() -> Void)? = nil) {
        guard fileDescriptor >= 0 else {
            completion?()
            return
        }
        
        queue.async {
            data.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                
                // Blocking write
                let bytesWritten = write(self.fileDescriptor, baseAddress, buffer.count)
                
                if bytesWritten < 0 {
                    let err = errno
                    Logger.shared.log("Write error: \(err)")
                    // Handle disconnection (ENXIO=6, EBADF=9, EIO=5)
                    if err == 6 || err == 9 || err == 5 {
                        self.close()
                        DispatchQueue.main.async {
                            self.onDisconnect?()
                        }
                    }
                } else if bytesWritten < buffer.count {
                    Logger.shared.log("Partial write: \(bytesWritten)/\(buffer.count)")
                }
                
                // Wait for data to be transmitted (matches C++ tcdrain)
                if self.fileDescriptor >= 0 {
                    let result = tcdrain(self.fileDescriptor)
                    if result == -1 {
                        let err = errno
                        Logger.shared.log("tcdrain error: \(err)")
                        if err == 6 || err == 9 || err == 5 {
                            self.close()
                            DispatchQueue.main.async {
                                self.onDisconnect?()
                            }
                            completion?()
                            return
                        }
                    }
                    // Add a delay to prevent overwhelming the device/driver
                    usleep(4000) 
                }
            }
            completion?()
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
