import SwiftUI
import ARKit
import RealityKit

@main
struct SplatCaptureApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var manager = CaptureSessionManager()

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .edgesIgnoringSafeArea(.all)

            VStack {
                HStack {
                    Text("Tier \(manager.tier.label)")
                        .font(.subheadline.monospaced())
                    Spacer()
                    Text(manager.trackingStatus)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(manager.trackingStatus == "normal" ? .green : .orange)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                HStack {
                    Text("\(manager.captureCount) shots")
                        .font(.title3.monospaced().bold())
                    Spacer()
                    Button {
                        manager.isRunning ? manager.stop() : manager.start()
                    } label: {
                        Text(manager.isRunning ? "Stop" : "Start")
                            .font(.headline)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(manager.isRunning ? Color.red : Color.accentColor,
                                        in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
    }
}

/// Hosts the ARView and hands its session to the manager. We disable ARView's
/// automatic session configuration so our gravity-aligned config wins.
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
