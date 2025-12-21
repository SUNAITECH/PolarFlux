import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var isCalibrationLocked: Bool = true
    
    var body: some View {
        TabView {
            connectionSettings
                .tabItem {
                    Label("Connection", systemImage: "cable.connector")
                }
            
            ledSettings
                .tabItem {
                    Label("LED Layout", systemImage: "lightbulb.led")
                }
            
            calibrationSettings
                .tabItem {
                    Label("Calibration", systemImage: "slider.horizontal.3")
                }
            
            powerSettings
                .tabItem {
                    Label("Power", systemImage: "bolt.shield")
                }
            
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 480)
        .padding()
    }
    
    var connectionSettings: some View {
        Form {
            Section {
                Picker("Serial Port:", selection: $appState.selectedPort) {
                    if appState.availablePorts.isEmpty {
                        Text("No ports found").tag("")
                    } else {
                        ForEach(appState.availablePorts, id: \.self) { port in
                            Text(port).tag(port)
                        }
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                Picker("Baud Rate:", selection: $appState.baudRate) {
                    ForEach(appState.availableBaudRates, id: \.self) { rate in
                        Text(rate).tag(rate)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                Button("Refresh Ports") {
                    appState.refreshPorts()
                }
                .padding(.top, 10)
            }
        }
        .padding()
    }
    
    var ledSettings: some View {
        Form {
            Section(header: Text("Zone Configuration").font(.headline)) {
                VStack(spacing: 12) {
                    HStack {
                        settingsRow(label: "Total LEDs:", text: $appState.ledCount)
                        Button("Auto Detect") {
                            appState.autoDetectDevice()
                        }
                    }
                    Divider()
                    settingsRow(label: "Top Zone:", text: $appState.topZone)
                    settingsRow(label: "Bottom Zone:", text: $appState.bottomZone)
                    settingsRow(label: "Left Zone:", text: $appState.leftZone)
                    settingsRow(label: "Right Zone:", text: $appState.rightZone)
                }
            }
            
            Section(header: Text("Screen Sync Orientation").font(.headline)) {
                Picker("Direction:", selection: $appState.screenOrientation) {
                    Text("Standard (CW)").tag(ScreenOrientation.standard)
                    Text("Reverse (CCW)").tag(ScreenOrientation.reverse)
                }
                .pickerStyle(MenuPickerStyle())
                
                Text("Standard: Bottom-Left -> Top -> Right -> Bottom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Reverse: Bottom-Right -> Top -> Left -> Bottom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button(action: {
                    appState.startOrientationTest()
                }) {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Run Orientation Test (Snake)")
                    }
                }
                
                if appState.isRunning && appState.statusMessage.contains("Testing") {
                    Text("A white light should move in the direction of your setup.")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            Section(header: Text("Capture Settings").font(.headline)) {
                settingsRow(label: "Capture Depth:", text: $appState.depth)
            }
        }
        .padding()
    }
    
    var powerSettings: some View {
        Form {
            Section(header: Text("Power Safety").font(.headline)) {
                Text("Prevents the lights from turning off unexpectedly when displaying bright colors.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)
                
                Picker("Safety Mode:", selection: $appState.powerMode) {
                    Text("Smart Protection (Recommended)").tag(PowerMode.abl)
                    Text("Safe Mode (Always Limit)").tag(PowerMode.globalCap)
                    Text("Auto-Recovery").tag(PowerMode.smartFallback)
                }
                .pickerStyle(RadioGroupPickerStyle())
                
                Divider()
                
                if appState.powerMode == .abl {
                    VStack(alignment: .leading) {
                        Text("Protection Level: \(Int(appState.powerLimit * 100))%")
                        Slider(value: $appState.powerLimit, in: 0.5...1.0, step: 0.05)
                        Text("Automatically dims the lights ONLY when they are too bright for your power supply. Most colors will remain at full brightness.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if appState.powerMode == .globalCap {
                    VStack(alignment: .leading) {
                        Text("Max Brightness Limit: \(Int(appState.powerLimit * 100))%")
                        Slider(value: $appState.powerLimit, in: 0.1...1.0, step: 0.05)
                        Text("Permanently limits the maximum brightness to this level.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if appState.powerMode == .smartFallback {
                    Text("If the lights turn off, the app will automatically restart them at a lower brightness.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
    
    var calibrationSettings: some View {
        Form {
            Section(header: HStack {
                Text("White Balance Calibration").font(.headline)
                Spacer()
                Button(action: {
                    isCalibrationLocked.toggle()
                }) {
                    Image(systemName: isCalibrationLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundColor(isCalibrationLocked ? .secondary : .blue)
                }
                .buttonStyle(PlainButtonStyle())
                .help(isCalibrationLocked ? "Unlock to edit" : "Lock to prevent changes")
            }) {
                Text("Adjust these sliders if your white looks blue or red.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading) {
                    HStack {
                        Text("Red Gain")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationR, in: 0.0...1.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationR))
                            .frame(width: 40)
                    }
                    
                    HStack {
                        Text("Green Gain")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationG, in: 0.0...1.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationG))
                            .frame(width: 40)
                    }
                    
                    HStack {
                        Text("Blue Gain")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationB, in: 0.0...1.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationB))
                            .frame(width: 40)
                    }
                    
                    Button("Reset Calibration") {
                        appState.calibrationR = 1.0
                        appState.calibrationG = 1.0
                        appState.calibrationB = 1.0
                    }
                    .padding(.top)
                    .disabled(isCalibrationLocked)
                }
            }
        }
        .padding()
    }
    
    var generalSettings: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                    .toggleStyle(CheckboxToggleStyle())
            }
        }
        .padding()
    }
    
    func settingsRow(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
        }
    }
}
