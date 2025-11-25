// MetalView.swift hosts the SwiftUI UIViewRepresentable wrapper that creates and updates
// the underlying MTKView while binding it to the coordinator.
import SwiftUI
import MetalKit

// MARK: - MetalView

struct MetalView: UIViewRepresentable {
    @Binding var coordinator: Coordinator?

    func makeUIView(context: Context) -> MTKView {
        print("makeUIView called")
        let mtkView = TouchableMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 1.0, blue: 1.0, alpha: 1.0)

        // Enable Stencil Buffer for card clipping
        mtkView.depthStencilPixelFormat = .stencil8

        mtkView.delegate = context.coordinator
        mtkView.isUserInteractionEnabled = true

        mtkView.coordinator = context.coordinator
        context.coordinator.metalView = mtkView

        // Assign coordinator back to parent view via Binding
        print("Setting coordinator via Binding")
        DispatchQueue.main.async {
            coordinator = context.coordinator
            print("Coordinator set via Binding")
        }

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Update coordinator binding if it hasn't been set yet
        if coordinator == nil {
            print("updateUIView: Setting coordinator")
            DispatchQueue.main.async {
                coordinator = context.coordinator
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        print("makeCoordinator called")
        return Coordinator()
    }
}
