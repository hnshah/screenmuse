import SwiftUI
import ScreenCaptureKit

struct RecordView: View {
    @StateObject private var viewModel = RecordViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Screen Recording")
                .font(.title2)
                .fontWeight(.semibold)

            if viewModel.isRecording {
                Text(viewModel.formattedDuration)
                    .font(.system(.largeTitle, design: .monospaced))
                    .foregroundColor(.red)
            }

            HStack(spacing: 16) {
                if viewModel.isRecording {
                    Button {
                        Task { await viewModel.stopRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .foregroundColor(.red)
                    }
                } else {
                    Button {
                        Task { await viewModel.startRecording() }
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
                            .foregroundColor(.red)
                    }
                }
            }

            GroupBox("Source") {
                Picker("Capture Source", selection: $viewModel.selectedSourceIndex) {
                    Text("Full Screen").tag(0)
                    ForEach(Array(viewModel.availableWindows.enumerated()), id: \.offset) { index, window in
                        Text(window.title ?? "Untitled Window").tag(index + 1)
                    }
                }
                .labelsHidden()
            }

            GroupBox("Audio") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("System Audio", isOn: $viewModel.includeSystemAudio)
                    Toggle("Microphone", isOn: $viewModel.includeMicrophone)
                }
            }
        }
        .padding()
        .task {
            await viewModel.refreshWindows()
        }
    }
}
