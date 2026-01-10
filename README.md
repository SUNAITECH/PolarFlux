# PolarFlux Documentation

PolarFlux is a macOS-native ambient lighting synchronization system. It leverages `ScreenCaptureKit` for low-latency frame acquisition, `AVFoundation` for real-time audio analysis, and the `Accelerate` framework for hardware-accelerated digital signal processing. The system integrates a second-order fluid physics engine for temporal smoothing and a saliency-based sampling algorithm for color extraction.

## Table of Contents
1. [System Architecture](#system-architecture)
2. [Vision Pipeline](#vision-pipeline)
3. [Fluid Physics Engine](#fluid-physics-engine)
4. [Audio Processing (DSP)](#audio-processing-dsp)
5. [Hardware Communication](#hardware-communication)
6. [Algorithm Specifications](#algorithm-specifications)
7. [Implementation Details](#implementation-details)
8. [Build & Configuration](#build--configuration)
9. [Q&A (Frequently Asked Questions)](#qa-frequently-asked-questions)
10. [Detailed Module Breakdown](#detailed-module-breakdown)
11. [License](#license)

---

## System Architecture

PolarFlux is built on a reactive, state-driven architecture using `SwiftUI` and `Combine`.

### 1. Central State Management (`AppState.swift`)
The `AppState` class serves as the primary coordinator for all subsystems.
- **Lifecycle Management**: Utilizes `NSWorkspace` notifications to handle system sleep, wake, and session lock events, ensuring hardware state consistency.
- **Persistence**: State serialization is handled via `UserDefaults` for persistent user configurations.
- **Mode Orchestration**: Manages transitions between `Sync`, `Music`, `Effect`, and `Manual` modes, ensuring resource deallocation of inactive modules.
- **First-Run Logic**: Implements automated hardware discovery on initial launch to streamline user onboarding.
- **Reactive Updates**: Uses `@Published` properties to drive the UI and `Combine` pipelines for internal state propagation.

### 2. Vision Engine (`ScreenCapture.swift`)
The vision engine transforms raw display buffers into LED-mapped color data.
- **SCStream Integration**: Implements `SCStreamOutput` to receive display frames directly from the window server.
- **Concurrency**: Frame processing is offloaded to a dedicated `DispatchQueue` with `.userInteractive` Quality of Service (QoS) to minimize input lag.

### 3. Physics Engine (`FluidPhysicsEngine.swift`)
Applies temporal smoothing to raw color data to eliminate flicker and provide organic transitions.
- **Stateful Simulation**: Maintains independent `SpringState` (position, velocity) for each LED channel.
- **Fluid Coupling**: Implements spatial advection and drag forces between neighboring LEDs to simulate fluid-like color flow.

---

## Vision Pipeline

### 1. Metal GPU Acceleration
PolarFlux incorporates a high-performance compute pipeline using Apple's Metal framework.
- **Compute Shaders**: Custom `.metal` shaders analyze display buffers on the GPU, calculating perceptual saliency and dominant colors in parallel.
- **Low CPU Overhead**: By offloading pixel analysis to the GPU, CPU usage for screen synchronization is reduced by up to 70-80%.
- **Zero-Copy Architecture**: Uses `CoreVideo` texture caches (`CVMetalTextureCache`) to allow the GPU to read `CVPixelBuffer` data directly from `ScreenCaptureKit` without memory copying.

### 2. Polar Binning Algorithm
Pixel-to-LED mapping is performed in polar coordinates relative to a configurable perspective origin.
- **Coordinate Mapping**: Pixels are mapped to LED indices based on their angular position relative to the origin.
- **Search Efficiency**: Uses binary search for $O(\log N)$ LED index resolution during the mapping phase.
- **Perspective Origin**: Supports automatic calculation based on the "Golden Ratio" or manual override for ultra-wide or multi-monitor setups.

### 3. Perceptual Saliency Sampling
A weighted sampling method that prioritizes high-chroma and high-luminance pixels.
- **Saliency Weighting**: Uses a sigmoid-mapped saturation weight to favor vibrant colors over neutral tones.
- **Hybrid Mixing**: Employs the Coefficient of Variation (CV) of saliency within a zone to dynamically switch between mean color and peak saliency color.
- **Zone State Management**: Each LED zone maintains a `ZoneState` that accumulates statistical moments (accR, accG, accB, accWeight) for $O(1)$ storage complexity.

---

## Fluid Physics Engine

The physics engine implements a second-order spring-damping system to govern color transitions.

### 1. Integration Logic
The engine uses Euler integration for state updates:

```math
v_{t+1} = v_t + (F_{attraction} + F_{advection} + F_{drag}) \times \Delta t
```
```math
x_{t+1} = x_t + v_{t+1} \times \Delta t
```

### 2. Adaptive Dynamics
- **Stiffness ($k$)**: Dynamically adjusted between $0.02$ and $0.2$ based on scene intensity.
- **Damping ($\zeta$)**: Calculated to maintain a near-critical damping state, preventing excessive oscillation.
- **Snapping Logic**: For color distances $> 120$ (8-bit RGB), the engine bypasses smoothing to prevent ghosting during scene cuts.
- **Flow Field**: A dynamic flow phase ($\phi$) generates a time-varying advection vector, creating organic movement even in static scenes.

---

## Audio Processing (DSP)

### 1. Signal Acquisition
- **CoreAudio Integration**: Scans for available input devices using `AudioHardwarePropertyDevices`.
- **AVAudioEngine**: Uses bus taps on the `AVAudioInputNode` for non-blocking PCM buffer acquisition.
- **Buffer Window**: Processing is performed in 1024-sample windows.

### 2. Frequency Analysis
- **vDSP FFT**: Utilizes the `Accelerate` framework for 1024-point Fast Fourier Transforms (`vDSP_DFT_Execute`).
- **Energy Tracking**: Implements RMS (Root Mean Square) calculation for temporal energy estimation and dynamic intensity scaling.
- **Logarithmic Binning**: Maps linear frequency bins to a logarithmic scale for more musical visualization.

---

## Hardware Communication

### 1. Serial Implementation (`SerialPort.swift`)
- **Telemetry System**: Provides industry-leading real-time diagnostics:
    - **Data Rate (KB/s)**: Real-time throughput calculation for USB/Serial bandwidth.
    - **PPS (Packets/Sec)**: Command frequency tracking for temporal resolution monitoring.
    - **Write Latency (ms)**: Microsecond-precision timing of POSIX write operations to detect hardware-level bottlenecks.
- **POSIX Interface**: Uses low-level `termios` for direct serial communication.
- **Configuration**: 8N1 (8 data bits, no parity, 1 stop bit) raw mode.
- **Baud Rates**: Supports standard and non-standard rates up to 3,000,000 bps.
- **Raw Mode Flags**:
    - `c_lflag`: `~ICANON & ~ECHO & ~ISIG` (Raw input).
    - `c_iflag`: `~IXON & ~IXOFF` (No software flow control).
    - `c_oflag`: `~OPOST` (Raw output).

### 2. Adalight Protocol
PolarFlux implements the Skydimo-variant of the Adalight protocol:
`[0x41, 0x64, 0x61, 0x01, CountHi, CountLo, R1, G1, B1, ...]`
- **Timing**: Uses `tcdrain` to ensure hardware buffer clearance and precise latency measurement using `CACurrentMediaTime`.
- **Packet Atomicity**: Frames are written as a single contiguous buffer to minimize jitter.
- **Header Structure**: `[0x41, 0x64, 0x61]` identifies the protocol, followed by a command byte and a 16-bit LED count.

---

## Algorithm Specifications

### 1. Perceptual Saliency Formula
The system avoids simple averaging to prevent color "muddiness." Instead, it calculates a saliency score for each pixel:

```math
Saliency = \frac{1}{1 + e^{-15(S - 0.4)}} \times \text{LuminanceWeight}
```

Where:
- **$S$ (Saturation)**: Calculated as the variance between RGB channels relative to the mean.
- **Sigmoid Mapping**: The saturation is passed through a sigmoid function centered at 0.4 with a steepness of 15 to aggressively prioritize vibrant colors.
- **Luminance Weight**: $Y = 0.299R^2 + 0.587G^2 + 0.114B^2$.

### 2. Adaptive Kalman Filter
To stabilize colors in static scenes while maintaining responsiveness during motion, a 1D Kalman filter is applied per channel:

- **State Vector**:
```math
\hat{x}_k = [R, G, B]^T
```
- **Process Noise ($Q$):** Dynamically adjusted based on the frame-to-frame color residual.
- **Measurement Noise ($R$):** Inversely proportional to the scene intensity $I_t$.
- **Update Equation**:
```math
\hat{x}_{k|k} = \hat{x}_{k|k-1} + K_k(z_k - \hat{x}_{k|k-1})
```

### 3. Scene Intensity Detection
Median Euclidean distance between frames is smoothed using a first-order IIR filter:

```math
I_{t} = 0.85 I_{t-1} + 0.15 D_{median}
```

This intensity value $I_t$ modulates the stiffness $k$ of the physics engine via a `smoothstep` interpolation.

---

## Implementation Details

### 1. Zone State Management (`ZoneState`)
Each LED zone maintains a persistent state to handle temporal accumulation and peak detection:
- **Temporal Accumulation**: Stores weighted statistical moments of pixels within the zone, allowing for $O(1)$ storage regardless of zone size.
- **Peak Memory**: Tracks the highest saliency pixel encountered in the current frame for hybrid mixing.
- **Error Covariance**: Maintains the $P$ matrix for the Kalman filter to estimate measurement certainty.

### 2. Serial Communication Protocol
PolarFlux utilizes a non-blocking POSIX serial implementation:
- **File Descriptor**: Opened with `O_RDWR | O_NOCTTY`.
- **Termios Configuration**:
    - `c_cflag`: `CS8 | CLOCAL | CREAD` (8-bit, local, enable receiver).
    - `c_lflag`: `~ICANON & ~ECHO & ~ISIG` (Raw mode).
    - `c_iflag`: `~IXON & ~IXOFF` (No software flow control).
- **Packet Atomicity**: Frames are written as a single contiguous buffer to minimize jitter.

### 3. Power Management Logic
- **ABL (Auto Brightness Limiter)**:
    - Calculates estimated current: $A_{total} = \sum (R_i + G_i + B_i) \times \text{Constant}$.
    - If $A_{total} > \text{Limit}$, scales all channels by $Scale = \frac{\text{Limit}}{A_{total}}$.
- **Smart Fallback**: If the serial connection is interrupted, the system gracefully reduces internal processing frequency to conserve CPU resources and attempts automatic reconnection.

---

## Build & Configuration

PolarFlux uses a unified build script to handle cross-compilation and packaging.

### Prerequisites
- macOS 14.0 or later.
- Xcode 15.0+ with Command Line Tools.
- Swift 5.9+.

### Compilation
To generate a Universal Binary (arm64 + x86_64):
```bash
./Scripts/run.sh build
```

### Packaging
To generate a styled DMG distribution:
```bash
./Scripts/run.sh dmg
```

### Release
To trigger an automated release to GitHub (CI/CD):
```bash
./Scripts/release.sh
```
This script will guide you through versioning, tag creation, and push. GitHub Actions will then automatically build and publish the DMG.

---

## Q&A (Frequently Asked Questions)

### 1. Permissions & Security
**Q: Why does PolarFlux need Screen Recording permission?**  
**A:** PolarFlux uses `ScreenCaptureKit` to capture display frames for real-time color analysis. Without this permission, the app cannot access the display buffer, resulting in a black screen in Sync mode. You can enable this in `System Settings > Privacy & Security > Screen Recording`.

**Q: Why is Microphone access required?**  
**A:** Microphone access is necessary for Music mode. PolarFlux captures system audio (or your selected input device) to perform FFT analysis and synchronize lighting with sound. Enable this in `System Settings > Privacy & Security > Microphone`.

### 2. Hardware & Connectivity
**Q: My device is not appearing in the port list. What should I do?**  
**A:** Ensure your USB cable is data-capable and securely connected. If you are using a device with a CH340 or CP210x serial chip, you may need to install the appropriate macOS drivers. PolarFlux scans for `/dev/cu.usbserial*`, `/dev/cu.usbmodem*`, and `/dev/cu.wch*` devices.

**Q: What baud rate should I use?**  
**A:** Most Adalight-compatible devices (like Skydimo) use `115200` or `921600`. Check your hardware documentation. If the baud rate is incorrect, the LEDs may flicker or show random colors.

**Q: How do I configure the LED count?**  
**A:** In the Settings panel, enter the total number of LEDs on your strip. You must also specify the distribution (Left, Top, Right, Bottom) to ensure the spatial mapping algorithm correctly aligns with your monitor's edges.

### 3. Performance & Optimization
**Q: Will PolarFlux slow down my Mac?**  
**A:** PolarFlux is highly optimized. It uses `ScreenCaptureKit` for zero-copy frame acquisition and the `Accelerate` framework for hardware-accelerated DSP. On Apple Silicon, CPU usage is typically negligible (<2%).

**Q: How can I reduce latency?**  
**A:** Ensure your "Target Frame Rate" is set to match your monitor's refresh rate (e.g., 60Hz or 120Hz). Additionally, using a higher baud rate (e.g., 921600) reduces the time required to transmit data to the hardware.

### 4. Features & Algorithms
**Q: What is the "Fluid Physics Engine"?**  
**A:** It is a second-order spring-damping system that smooths color transitions. Unlike simple linear fading, it simulates physical momentum and advection, making the lighting feel more organic and "liquid."

**Q: What does the "Auto Brightness Limiter (ABL)" do?**  
**A:** ABL estimates the total current draw of your LED strip based on the color data. If the estimated power exceeds your defined limit, PolarFlux automatically scales down the brightness to prevent overloading your USB port or power supply.

**Q: How does "Auto-Detection" work?**  
**A:** On the first run, PolarFlux attempts to identify Skydimo-compatible hardware by scanning available serial ports and checking for a successful handshake. Once found, it saves the configuration for future use.

---

## Detailed Module Breakdown

### 1. `Sources/PolarFlux/ScreenCapture.swift`
The core vision processing unit.
- **`SCStreamOutput` Implementation**: Handles the asynchronous delivery of `CMSampleBuffer` objects.
- **`processFrame(_:)`**: 
    - Extracts the `CVPixelBuffer`.
    - Performs linear-to-SRGB conversion (approximation).
    - Executes the polar binning and saliency sampling loop.
- **`calculatePerceptualSaliency`**: A private helper that implements the sigmoid-weighted chroma extraction.

### 2. `Sources/PolarFlux/FluidPhysicsEngine.swift`
The temporal smoothing engine.
- **`SpringState`**: A struct encapsulating the physical properties of a single color channel.
- **`update(target:dt:)`**: 
    - Calculates the attraction force: $F_{att} = k \times (target - current)$.
    - Calculates the damping force: $F_{damp} = velocity \times 2\zeta\sqrt{k}$.
    - Updates velocity and position using Euler integration.

### 3. `Sources/PolarFlux/AudioProcessor.swift`
The frequency-domain analysis unit.
- **`AVAudioEngine` Setup**: Configures the audio graph for real-time capture.
- **`vDSP_fft_zrip`**: Performs the in-place real-to-complex FFT.
- **`vDSP_zvmags`**: Calculates the squared magnitudes of the frequency bins.

### 4. `Sources/PolarFlux/SerialPort.swift`
The hardware abstraction layer.
- **`listPorts()`**: Scans `/dev/cu.*` using `FileManager`.
- **`connect(path:baudRate:)`**: Configures the `termios` structure for raw 8N1 communication.
- **`write(_:)`**: A thread-safe method that pushes data to the serial buffer.

### 5. `Sources/PolarFlux/AppState.swift`
The central state machine.
- **`@Published` Properties**: Drives the SwiftUI views via the `ObservableObject` protocol.
- **`LightingMode`**: An enum defining the operational states (`sync`, `music`, `effect`, `manual`).
- **`PowerMode`**: Manages the ABL and global brightness capping logic.

---

## License
PolarFlux is released under the **MIT License**.

Copyright © 2025 Shanghai Sunai Technology Co., Ltd.

The full license text is available in the [LICENSE](LICENSE) file and within the application's **About** page.

