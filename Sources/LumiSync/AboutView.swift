import SwiftUI

struct AboutView: View {
    let version: String = {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: date)
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(radius: 10)
            
            VStack(spacing: 8) {
                Text("LumiSync")
                    .font(.system(size: 32, weight: .bold))
                
                Text(String(format: String(localized: "VERSION"), version))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
    }
}
