import SwiftUI

struct HistoryItem: Identifiable {
    let id = UUID()
    let name: String
    let date: Date
    let type: ItemType

    enum ItemType {
        case screenshot
        case recording
    }
}

struct HistoryView: View {
    @State private var items: [HistoryItem] = [
        HistoryItem(name: "Screenshot 1", date: .now, type: .screenshot),
        HistoryItem(name: "Recording 1", date: .now.addingTimeInterval(-3600), type: .recording),
        HistoryItem(name: "Screenshot 2", date: .now.addingTimeInterval(-7200), type: .screenshot),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Recent Captures")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()

            if items.isEmpty {
                Spacer()
                Text("No captures yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(items) { item in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 60, height: 40)
                            .overlay(
                                Image(systemName: item.type == .screenshot ? "camera" : "video")
                                    .foregroundColor(.secondary)
                            )

                        VStack(alignment: .leading) {
                            Text(item.name)
                                .fontWeight(.medium)
                            Text(item.date, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: item.type == .screenshot ? "photo" : "film")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
