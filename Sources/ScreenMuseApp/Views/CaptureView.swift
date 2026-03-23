import SwiftUI

struct CaptureView: View {
    @StateObject private var viewModel = CaptureViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Screenshot")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                Button {
                    Task { await viewModel.captureFullScreen() }
                } label: {
                    Label("Full Screen", systemImage: "desktopcomputer")
                }
                .disabled(viewModel.isCapturing)

                Button {
                    Task { await viewModel.captureWindow() }
                } label: {
                    Label("Window", systemImage: "macwindow")
                }
                .disabled(viewModel.isCapturing)

                Button {
                    Task { await viewModel.captureRegion() }
                } label: {
                    Label("Region", systemImage: "crop")
                }
                .disabled(viewModel.isCapturing)
            }

            if viewModel.isCapturing {
                ProgressView("Capturing...")
            }

            if let image = viewModel.lastCapture {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 250)
                    .cornerRadius(8)
                    .shadow(radius: 4)

                HStack(spacing: 12) {
                    Button {
                        viewModel.copyToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        viewModel.saveToDesktop()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.15))
                    .frame(maxHeight: 250)
                    .overlay(
                        Text("No capture yet")
                            .foregroundColor(.secondary)
                    )
            }
        }
        .padding()
    }
}
