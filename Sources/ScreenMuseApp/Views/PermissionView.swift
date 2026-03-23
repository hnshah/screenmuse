import SwiftUI

struct PermissionView: View {
    @ObservedObject var permissions: PermissionManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.red)
                Text("ScreenMuse")
                    .font(.system(size: 28, weight: .bold))
                Text("Grant permissions to start recording")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 32)

            // Permission rows
            VStack(spacing: 12) {
                PermissionRow(
                    icon: "display",
                    title: "Screen Recording",
                    description: "Required to capture your screen",
                    isGranted: permissions.hasScreenRecording,
                    isRequired: true,
                    onRequest: { permissions.requestScreenRecording() },
                    onOpenSettings: { permissions.openScreenRecordingSettings() }
                )

                PermissionRow(
                    icon: "keyboard",
                    title: "Accessibility",
                    description: "Enables keystroke overlays and click effects",
                    isGranted: permissions.hasAccessibility,
                    isRequired: false,
                    onRequest: { permissions.requestAccessibility() },
                    onOpenSettings: { permissions.openAccessibilitySettings() }
                )
            }
            .padding(.horizontal, 32)

            Spacer()

            // Bottom actions
            VStack(spacing: 10) {
                if permissions.hasRequiredPermissions {
                    Button(action: { /* dismiss — handled by parent */ }) {
                        Label("Continue to ScreenMuse", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(action: { permissions.checkAll() }) {
                        Label("Check Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Text("Screen Recording is required. Accessibility is optional.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 500)
        .onAppear { permissions.checkAll() }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let isRequired: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Icon + status dot
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(isGranted ? .green : .secondary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isGranted ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
                Circle()
                    .fill(isGranted ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                    .offset(x: 3, y: 3)
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if isRequired {
                        Text("Required")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                            .foregroundColor(.red)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action button
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Menu {
                    Button("Request Permission", action: onRequest)
                    Button("Open System Settings", action: onOpenSettings)
                } label: {
                    Text("Grant")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundColor(.accentColor)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
    }
}
