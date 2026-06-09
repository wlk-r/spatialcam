import SwiftUI
import ARKit
import RealityKit

struct ContentView: View {
    @StateObject private var manager = CaptureSessionManager()
    @State private var pendingStorageWarning: String?

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding()
        }
        .alert("Low Storage", isPresented: storageWarningBinding) {
            Button("Cancel", role: .cancel) {
                pendingStorageWarning = nil
            }
            Button("Start Anyway") {
                pendingStorageWarning = nil
                manager.start()
            }
        } message: {
            Text(pendingStorageWarning ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.tier.label)
                    .font(.subheadline.monospaced().weight(.semibold))
                Text(sessionStatusText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(trackingStatusText)
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(manager.trackingStatus == "normal" ? .green : .orange)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(manager.captureCount) shots")
                        .font(.title3.monospaced().bold())
                    Text("\(manager.seedPointCount) seed points")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    handleCaptureButton()
                } label: {
                    Text(captureButtonTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: 116, height: 44)
                        .background(buttonColor, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .disabled(manager.isFinalizing)
            }

            writeStatus
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var writeStatus: some View {
        let total = max(1, manager.captureCount + manager.pendingWriteCount)
        let progress = Double(manager.captureCount) / Double(total)

        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(manager.pendingWriteCount == 0 && !manager.isFinalizing ? .green : .accentColor)

            Text(writeStatusText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var captureButtonTitle: String {
        if manager.isRunning {
            return "Stop"
        }
        if manager.isFinalizing {
            return "Saving"
        }
        if manager.hasCompletedSession {
            return "New Capture"
        }
        return "Start"
    }

    private func handleCaptureButton() {
        if manager.isRunning {
            manager.stop()
        } else if manager.hasCompletedSession {
            manager.newCapture()
        } else {
            startWithStorageCheck()
        }
    }

    private func startWithStorageCheck() {
        if let warning = manager.storageWarningMessage() {
            pendingStorageWarning = warning
        } else {
            manager.start()
        }
    }

    private var storageWarningBinding: Binding<Bool> {
        Binding(
            get: { pendingStorageWarning != nil },
            set: { if !$0 { pendingStorageWarning = nil } }
        )
    }

    private var buttonColor: Color {
        if manager.isRunning {
            return .red
        }
        if manager.isFinalizing {
            return .gray
        }
        return .accentColor
    }

    private var sessionStatusText: String {
        if manager.isRunning {
            return "Recording \(manager.sessionFolderName)"
        }
        if manager.isFinalizing {
            return "Saving capture"
        }
        if manager.hasCompletedSession {
            return "Capture saved"
        }
        return "Ready to capture"
    }

    private var trackingStatusText: String {
        switch manager.trackingStatus {
        case "normal":
            return "Tracking ready"
        case "not_started":
            return "Ready"
        case "not_available":
            return "Tracking unavailable"
        case "limited:initializing":
            return "Initializing"
        case "limited:excessive_motion":
            return "Move slower"
        case "limited:insufficient_features":
            return "Need texture"
        case "limited:relocalizing":
            return "Relocalizing"
        default:
            return "Tracking limited"
        }
    }

    private var writeStatusText: String {
        if manager.isFinalizing {
            return "Finalizing session"
        }
        if manager.pendingWriteCount > 0 {
            return "\(manager.captureCount) written, \(manager.pendingWriteCount) pending"
        }
        if manager.captureCount > 0 {
            return "All files written"
        }
        return "Ready"
    }
}

struct ARViewContainer: UIViewRepresentable {
    let manager: CaptureSessionManager

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        manager.bind(session: view.session)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
