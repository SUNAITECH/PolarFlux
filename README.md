# PolarFlux Documentation

PolarFlux is a macOS-native ambient lighting synchronization system. It leverages `ScreenCaptureKit` for low-latency frame acquisition, `AVFoundation` for real-time audio analysis, and the `Accelerate` framework for hardware-accelerated digital signal processing. The system integrates a second-order fluid physics engine for temporal smoothing and a saliency-based sampling algorithm for color extraction.

## Table of Contents
1. [Introduction](#introduction)
2. [System Architecture](#system-architecture)
    - [State Orchestration (`AppState`)](#1-central-state-management-appstateswift)
    - [Vision Engine (`ScreenCapture`)](#2-vision-engine-screencaptureswift)
    - [Audio Processing (`AudioProcessor`)](#3-audio-processing-audioprocessorswift)
    - [Effect Generation (`EffectEngine`)](#4-effect-engine-effectengineswift)
3. [Vision Pipeline](#vision-pipeline)
    - [Perceptual Color Science](#1-unified-computational-color-science-engine)
    - [Metal GPU Acceleration](#2-metal-gpu-acceleration)
    - [Performance Telemetry](#3-advanced-performance-telemetry)
4. [Dynamics & Smoothing](#dynamics--smoothing)
    - [Fluid Physics Engine](#1-fluid-physics-engine)
    - [Adaptive Kalman Filtering](#2-adaptive-kalman-filtering)
    - [Temporal Adaptation](#3-temporal-adaptation-exponential-smoothing)
5. [Algorithm Specifications](#algorithm-specifications)
    - [Perceptual Saliency Engine](#1-perceptual-saliency-engine)
    - [Intensity-Aware Sensitivity](#2-intensity-aware-sensitivity)
6. [Hardware & Connectivity](#hardware--connectivity)
    - [Transmission Pipeline](#1-robust-transmission-pipeline)
    - [Power Management (ABL)](#3-power-management-logic)
7. [Developer Tools](#developer-tools)
    - [Debug Mode](#2-developer-debug-mode)
    - [Diagnostic Dashboard](#diagnostic-dashboard)
8. [Build & Configuration](#build--configuration)
9. [Detailed Module Breakdown](#detailed-module-breakdown)
10. [Q&A](#qa-frequently-asked-questions)
11. [License](#license)

---

## Introduction
PolarFlux is a high-performance, macOS-native ambient lighting system designed for professional-grade display synchronization. Unlike traditional software that relies on simple pixel averages, PolarFlux implements a sophisticated computational color science pipeline that accounts for human visual perception, spatial importance, and fluid temporal dynamics.

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
- **SCStream Integration**: Implements `SCStreamOutput` to receive display frames directly from the window server with near-zero latency.
- **Concurrency**: Frame processing is offloaded to a dedicated `DispatchQueue` with `.userInteractive` Quality of Service (QoS) to minimize input lag.
- **Coordinate Transformation**: Automatically handles screen orientation changes (0°, 90°, 180°, 270°) and aspect ratio scaling.

### 3. Audio Processing (`AudioProcessor.swift`)
Real-time frequency analysis for music-reactive lighting.
- **Low-Latency Capture**: Uses `AVAudioEngine` for high-performance audio routing.
- **Spectral Decomposition**: Leverages Apple's `Accelerate` framework to perform Radix-2 FFTs on system output.
- **Energy Mapping**: Maps frequency energy (Bass, Mid, Treble) to lighting intensity and color shifts.

### 4. Effect Engine (`EffectEngine.swift`)
A procedural animation system for ambient lighting effects.
- **Dynamic Generation**: Includes 20+ built-in effects (Rainbow, Plasma, Waves, etc.) calculated in real-time.
- **Physics Integration**: Effects can be piped through the physics engine for organic motion.

---

## Dynamics & Smoothing

### 1. Fluid Physics Engine
Applies temporal smoothing to raw color data to eliminate flicker and provide organic transitions.
- **Stateful Simulation**: Maintains independent `SpringState` (position, velocity) for each LED channel.
- **Fluid Neighbors (Circular Coupling)**: Implements spatial advection and drag forces between neighboring LEDs to simulate fluid-like color flow.
- **Edge-Aware Flow Field**: Coupling force is reduced when high color gradients are detected between zones, preserving sharp visual boundaries while smoothing gradients.

### 2. Adaptive Kalman Filtering
To stabilize colors in static scenes while maintaining responsiveness during motion, a 1D Kalman filter is applied per zone:

- **State Vector**: $\hat{x}_k = [R, G, B]^T$
- **Process Noise ($Q$):** Dynamically adjusted between $0.1$ and $0.4$ based on frame-to-frame color residuals.
- **Measurement Noise ($R$):** Inversely proportional to scene transition magnitude to prioritize new information during rapid changes.
- **Temporal Hysteresis**: Prevents micro-flicker in dark zones without introducing perceptible lag.

### 3. Temporal Adaptation (Exponential Smoothing)
PolarFlux uses unified exponential decay for consistent perceptual adaptation:
- **White Point Adaptation**: $\tau \approx 1.5s$ for smooth, natural color temperature shifts.
- **Luminance Adaptation**: $\tau \approx 0.5s$ for responsive brightness tracking.

---

## Vision Pipeline

### 1. Unified Computational Color Science Engine
PolarFlux features a state-of-the-art vision pipeline inspired by the **CIECAM02** color appearance model. This ensures that the light colors match human visual perception rather than just raw sensor data.

- **Von Kries Chromatic Adaptation**: Dynamically adjusts the scene's white point to maintain color constancy as the screen content changes.
- **Hunt Effect**: Sophisticated luminance-induced saturation modelling—ensuring colors remain vibrant even as brightness fluctuates.
- **Helmholtz-Kohlrausch (H-K) Effect**: Compensates for the perceived brightness of highly saturated colors.
- **Sigmoid S-Curve Adaptation**: A multi-stage non-linear response curve that simulates human contrast sensitivity, expanding dynamic range without clipping.

### 2. Metal GPU Acceleration
PolarFlux incorporates a high-performance compute pipeline using Apple's Metal framework.
- **Compute Shaders**: Custom `.metal` shaders analyze display buffers on the GPU, executing the entire perceptual pipeline in parallel.
- **Zero-Copy Architecture**: Uses `CoreVideo` texture caches (`CVMetalTextureCache`) to allow the GPU to read `CVPixelBuffer` data directly from `ScreenCaptureKit` without memory copying.
- **1:1 Logic Parity**: Strictly aligned constants (Sigmoid center $0.45$, slope $15.0$) between GPU and CPU paths.

---

## Algorithm Specifications

### 1. Perceptual Saliency Engine
The system utilizes a multi-factor weighting algorithm to extract the most "meaningful" colors from a scene:

$$Saliency = Sigmoid(Purity) \times e^{(Vividness \times 2.8)} \times HueWeight \times BrightnessWeight$$

- **Hue Weighting**: Dynamically prioritizes certain wavelengths (e.g., Red/Blue) that are more impactful in ambient lighting environments.
- **Purity Sigmoid**: Centered at $0.45$ with a slope of $15.0$ to aggressively filter out neutral/gray pixels.
- **Expansion/Compression**: Uses an exponential vividness boost to make primary colors "punchier" against desaturated backgrounds.

### 2. Intensity-Aware Sensitivity
PolarFlux calculates **Local Intensity** ($I_{local}$) for each zone to modulate responsiveness:
- **Responsive Tracking**: In high-intensity zones, the physics engine stiffness $k$ increases ($k_{high}$) to prioritize speed.
- **Stable Filtering**: In low-intensity scenes, damping increases and stiffness decreases ($k_{low}$) to prevent "dancing" or jitter in dark content.

$$Mix = \text{smoothstep}(0.1, 0.7, I_{local})$$
$$k_{dynamic} = k_{low} + (k_{high} - k_{low}) \times Mix$$

---

## Hardware & Connectivity

### 1. Robust Transmission Pipeline
- **Thread-Safe Serial Interface**: Employs mandatory `NSLock` synchronization to prevent race conditions between frame processing and keep-alive timers.
- **Keep-Alive System**: High-frequency ($4Hz$) heartbeat ensures the hardware remains active even during static content (e.g., pauses or desktop usage).
- **Busy-Protection**: Prevents command flooding by tracking `isSending` state across all concurrent callback sources.

### 2. Developer Debug Mode
- **Volatile Configuration**: Debug settings (Force CPU, Manual Overrides) are design-to-be-volatile and reset on every launch to ensure application stability.
- **Parity Analysis**: The "Force CPU Acceleration" toggle allows developers to verify algorithmic consistency between Metal and CPU paths in real-time.
- **Diagnostic Dashboard**: Real-time view of serial buffer occupancy and Metal support status.

### 3. Internationalization (i18n)
Full UI and telemetry support for 9 languages: English, Simplified Chinese, Traditional Chinese, German, French, Spanish, Russian, Japanese, and Korean.

---

## Implementation Details

### 1. Zone State Management (`ZoneState`)
Each LED zone maintains a persistent state to handle temporal accumulation and peak detection:
- **Temporal Accumulation**: Stores weighted statistical moments of pixels within the zone, allowing for $O(1)$ storage regardless of zone size.
- **Hybrid Mixing**: Blends average zone color with the "Peak Saliency" color (boosted by 25% saturation) based on a dynamic coefficient derived from the color coefficient of variation (CV).
- **Kalman State Persistence**: Maintains the error covariance matrix $P$ across frames to estimate measurement certainty.

### 2. Serial Communication Protocol
PolarFlux utilizes a non-blocking POSIX serial implementation:
- **Termios Configuration**: Configured for Raw 8N1 communication with no software flow control (`~IXON & ~IXOFF`).
- **Packet Atomicity**: Frames are written as a single contiguous buffer (Adalight protocol compatible) to minimize jitter.
- **Auto-Handshake**: Scans `/dev/cu.*` ports and probes for a successful handshake at various baud rates (115200 to 921600).

### 3. Power Management Logic
- **ABL (Auto Brightness Limiter)**: Calculates estimated current draw ($A_{total}$) and scales global brightness to keep it within the defined power budget.
- **Smart Fallback**: If connection stability drops, the system reduces internal processing frequency and attempts automatic reconnection with reduced brightness.

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

---

## Detailed Module Breakdown

### 1. Core State & Utility
- **`Sources/PolarFlux/AppState.swift`**: Primary coordinator and state machine.
- **`Sources/PolarFlux/Logger.swift`**: Thread-safe persistent logging.
- **`Sources/PolarFlux/LaunchAtLogin.swift`**: Helper for login item management.

### 2. Visual Engines
- **`Sources/PolarFlux/Metal/Shaders.metal`**: GPU-side perceptual compute kernel.
- **`Sources/PolarFlux/Metal/MetalProcessor.swift`**: Swift wrapper for Metal resource management.
- **`Sources/PolarFlux/ScreenCapture.swift`**: Vision orchestration, zone mapping, and Kalman stabilization.

### 3. Dynamic Subsystems
- **`Sources/PolarFlux/FluidPhysicsEngine.swift`**: Multi-order spring-damping system with neighbor coupling.
- **`Sources/PolarFlux/AudioProcessor.swift`**: FFT-based spectral analysis and audio capture.
- **`Sources/PolarFlux/EffectEngine.swift`**: Procedural pattern generation.

### 4. Telemetry & Hardware
- **`Sources/PolarFlux/PerformanceMonitor.swift`**: High-precision execution tracking.
- **`Sources/PolarFlux/SerialPort.swift`**: POSIX serial implementation for device communication.

### 5. Specialized Settings & Views
- **`Sources/PolarFlux/PerspectiveOriginSettings.swift`**: Logic for "Perspective Origin" calculations (Golden Ratio vs Manual).
- **`Sources/PolarFlux/PerformanceSettingsView.swift`**: Dedicated UI for tuning compute-intensive parameters.
- **`Sources/PolarFlux/SettingsView.swift`**: Main configuration interface.
- **`Sources/PolarFlux/AboutView.swift`**: Application version and license information.

---

## Q&A (Frequently Asked Questions)

### 1. Permissions & Security
**Q: Why does PolarFlux need Screen Recording permission?**  
**A:** It uses `ScreenCaptureKit` to capture display frames. Without this, the app cannot access the display buffer. Enable in `System Settings > Privacy & Security > Screen Recording`.

**Q: Why is Microphone access required?**  
**A:** Necessary for Music mode to perform FFT analysis on system audio output. Enable in `System Settings > Privacy & Security > Microphone`.

### 2. Hardware & Connectivity
**Q: My device is not appearing in the port list.**  
**A:** Ensure your USB cable is data-capable. For CH340 or CP210x chips, ensure appropriate drivers are installed. PolarFlux scans for `/dev/cu.usbserial*`, `/dev/cu.usbmodem*`, and `/dev/cu.wch*`.

**Q: What baud rate should I use?**  
**A:** Most Adalight devices use `115200` or `921600`. Use the "Auto-Detect" feature for best results.

### 3. Performance
**Q: Will PolarFlux slow down my Mac?**  
**A:** On Apple Silicon, CPU usage is typically <2% due to `ScreenCaptureKit` zero-copy and `Accelerate` hardware acceleration.

---

## License
PolarFlux is released under the **MIT License**.
Copyright © 2025 Shanghai Sunai Technology Co., Ltd.
Full license text in the [LICENSE](LICENSE) file.

