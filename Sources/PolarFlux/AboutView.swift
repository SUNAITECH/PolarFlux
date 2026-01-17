import SwiftUI

struct AboutView: View {
    let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2025.12.28"
    }()
    
    @StateObject private var updateChecker = UpdateChecker()

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(radius: 10)
            
            VStack(spacing: 8) {
                Text("PolarFlux")
                    .font(.system(size: 32, weight: .bold))
                
                Text(String(format: String(localized: "VERSION"), version))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Link("GitHub: SUNAITECH/PolarFlux", destination: URL(string: "https://github.com/SUNAITECH/PolarFlux")!)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                
                Button(action: {
                    updateChecker.checkForUpdates(userInitiated: true)
                }) {
                    HStack(spacing: 4) {
                        if updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                        }
                        Text(updateChecker.isChecking ? String(localized: "CHECKING_UPDATES") : String(localized: "CHECK_FOR_UPDATES"))
                    }
                }
                .disabled(updateChecker.isChecking)
                .padding(.top, 4)
            }
            
            VStack(spacing: 12) {
                Text(String(localized: "COPYRIGHT"))
                    .font(.caption)
                
                Text(String(localized: "LICENSE_INFO"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 10)
            
            GroupBox(String(localized: "LICENSE_AGREEMENT")) {
                ScrollView {
                    Text("""
                    MIT License

                    Copyright (c) 2025 Shanghai Sunai Technology Co., Ltd.

                    Permission is hereby granted, free of charge, to any person obtaining a copy
                    of this software and associated documentation files (the "Software"), to deal
                    in the Software without restriction, including without limitation the rights
                    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
                    copies of the Software, and to permit persons to whom the Software is
                    furnished to do so, subject to the following conditions:

                    The above copyright notice and this permission notice shall be included in all
                    copies or substantial portions of the Software.

                    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
                    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
                    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
                    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
                    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
                    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
                    SOFTWARE.
                    """)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(5)
                }
                .frame(height: 120)
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(String(localized: "UP_TO_DATE"), isPresented: $updateChecker.showUpToDateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(String(format: String(localized: "UP_TO_DATE_MSG"), version))
        }
        .alert(String(localized: "UPDATE_ERROR"), isPresented: Binding<Bool>(
            get: { updateChecker.error != nil },
            set: { if !$0 { updateChecker.error = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            if let error = updateChecker.error {
                Text(error)
            }
        }
        .sheet(item: $updateChecker.updateAvailable) { release in
            UpdateAvailableView(release: release)
        }
    }
}

struct UpdateAvailableView: View {
    let release: GitHubRelease
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .resizable()
                .frame(width: 48, height: 48)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.accentColor)
            
            VStack(spacing: 8) {
                Text(String(localized: "UPDATE_AVAILABLE"))
                    .font(.title2)
                    .bold()
                
                Text(String(format: String(localized: "UPDATE_AVAILABLE_MSG"), release.tagName))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            GroupBox(label: Text(String(localized: "VIEW_RELEASE_NOTES"))) {
                ScrollView {
                    Text(release.body)
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 200)
            
            HStack(spacing: 20) {
                Button(String(localized: "LATER")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Link(destination: URL(string: release.htmlUrl)!) {
                    Text(String(localized: "DOWNLOAD"))
                        .frame(minWidth: 100)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(width: 450)
    }
}
