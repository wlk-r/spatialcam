import SwiftUI
import ARKit
import RealityKit

struct ContentView: View {
    @StateObject private var manager = CaptureSessionManager()
    @State private var pendingStorageWarning: String?
    @State private var shareItem: ShareItem?
    @State private var shareErrorMessage: String?

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
        .alert("Can't Create Zip", isPresented: shareErrorBinding) {
            Button("Open Files") {
                shareErrorMessage = nil
                manager.resumeAfterShare()
                if let url = CaptureSessionManager.capturesFolderFilesURL() {
                    UIApplication.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {
                shareErrorMessage = nil
                manager.resumeAfterShare()
            }
        } message: {
            Text(shareErrorMessage ?? "")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url]) {
                try? FileManager.default.removeItem(at: item.url)
                shareItem = nil
                manager.resumeAfterShare()
            }
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

                if manager.hasCompletedSession, manager.completedSessionURL != nil {
                    Button {
                        shareCompletedSessionAsZip()
                    } label: {
                        Group {
                            if manager.isPreparingShare {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.headline)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(manager.isPreparingShare)
                }

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
                .disabled(manager.isFinalizing || manager.isPreparingShare)
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
        if manager.isRecording {
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
        if manager.isRecording {
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

    private var shareErrorBinding: Binding<Bool> {
        Binding(
            get: { shareErrorMessage != nil },
            set: { if !$0 { shareErrorMessage = nil } }
        )
    }

    private func shareCompletedSessionAsZip() {
        manager.prepareShareArchive { result in
            switch result {
            case .success(let url):
                shareItem = ShareItem(url: url)
            case .failure(let error):
                shareErrorMessage = error.localizedDescription
            }
        }
    }

    private var buttonColor: Color {
        if manager.isRecording {
            return .red
        }
        if manager.isFinalizing || manager.isPreparingShare {
            return .gray
        }
        return .accentColor
    }

    private var sessionStatusText: String {
        if manager.isRecording {
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
        case "interrupted", "paused":
            return "Camera paused"
        case "failed":
            return "Camera failed"
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

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
