import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem {
                    Label("Capture", systemImage: "camera")
                }

            RecordView()
                .tabItem {
                    Label("Record", systemImage: "record.circle")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
        }
        .frame(minWidth: 600, minHeight: 450)
    }
}
