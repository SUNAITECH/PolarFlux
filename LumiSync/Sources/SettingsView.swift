import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    
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
            
            Section(header: Text("Capture Settings").font(.headline)) {
                settingsRow(label: "Capture Depth:", text: $appState.depth)
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
