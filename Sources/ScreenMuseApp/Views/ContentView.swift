import SwiftUI

struct ContentView: View {
    @StateObject private var permissions = PermissionManager()

    var body: some View {
        Group {
            if permissions.hasRequiredPermissions {
                MainTabView()
            } else {
                PermissionView(permissions: permissions)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check permissions every time the app comes to foreground
            permissions.checkAll()
        }
    }
}

private struct MainTabView: View {
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
