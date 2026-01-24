// ContentView.swift wires the SwiftUI interface, hosting the toolbar and MetalView canvas binding.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

	struct ContentView: View {
	    // Reference to MetalView's coordinator for adding cards
	    @State private var metalViewCoordinator: MetalView.Coordinator?
	    @State private var editingCard: Card? // The card being edited
	    @State private var showSettingsSheet = false
	    @State private var showingImportPicker = false
	    @State private var isExporting = false
	    @State private var exportDocument = CanvasDocument()
	    @State private var exportFilename = "canvas"
	    @State private var isBrushMenuExpanded = false
	    @State private var isMenuExpanded = false
	    @State private var showClearConfirmation = false
	    @State private var isHandwritingRefinementMenuExpanded = false

	    @State private var handwritingRefinementEnabled: Bool = false
	    @State private var handwritingRefinementBias: Double = 2.0
	    @State private var handwritingRefinementInputScale: Double = 2.0
	    @State private var handwritingRefinementStrength: Double = 0.7
	    @State private var handwritingRefinementDebounceSeconds: Double = 0.5

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MetalView(coordinator: $metalViewCoordinator)
            .edgesIgnoringSafeArea(.all)
            .onChange(of: metalViewCoordinator) { _, newCoord in
                // Bind the callback when coordinator is set
                newCoord?.onEditCard = { card in
                    self.editingCard = card
                    self.showSettingsSheet = true
                }
                newCoord?.onPencilSqueeze = {
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if !isMenuExpanded {
                                isMenuExpanded = true
                                isBrushMenuExpanded = false
                            } else if !isBrushMenuExpanded {
                                isBrushMenuExpanded = true
                            } else {
                                isBrushMenuExpanded = false
                                isMenuExpanded = false
                            }
                        }
                    }
                }

                if let newCoord {
                    // Keep UI state in sync with coordinator defaults (and vice versa).
                    handwritingRefinementEnabled = newCoord.handwritingRefinementEnabled
                    handwritingRefinementBias = Double(newCoord.handwritingRefinementBias)
                    handwritingRefinementInputScale = Double(newCoord.handwritingRefinementInputScale)
                    handwritingRefinementStrength = Double(newCoord.handwritingRefinementStrength)
                    handwritingRefinementDebounceSeconds = newCoord.handwritingRefinementDebounceSeconds
                }
            }

            VStack(alignment: .trailing, spacing: 12) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isMenuExpanded.toggle()
                        if !isMenuExpanded {
                            isBrushMenuExpanded = false
                        }
                    }
                }) {
                    VStack(spacing: 2) {
                        Image(systemName: isMenuExpanded ? "xmark" : "line.3.horizontal")
                            .font(.system(size: 20))
                        Text("Menu")
                            .font(.caption)
                    }
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }

                if isMenuExpanded, let coordinator = metalViewCoordinator {
                    VStack(alignment: .trailing, spacing: 12) {
                        HStack(spacing: 12) {
                            Button(action: { coordinator.addCard() }) {
                                VStack(spacing: 2) {
                                    Image(systemName: "plus.rectangle.fill")
                                        .font(.system(size: 20))
                                    Text("Card")
                                        .font(.caption)
                                }
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                            }

                            Button(action: { coordinator.undo() }) {
                                VStack(spacing: 2) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 20))
                                    Text("Undo")
                                        .font(.caption)
                                }
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                            }

                            Button(action: { coordinator.redo() }) {
                                VStack(spacing: 2) {
                                    Image(systemName: "arrow.uturn.forward")
                                        .font(.system(size: 20))
                                    Text("Redo")
                                        .font(.caption)
                                }
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                            }
                        }

	                        HStack(spacing: 12) {
	                            Button(action: {
	                                if let data = PersistenceManager.shared.exportCanvas(rootFrame: coordinator.rootFrame,
	                                                                                    fractalFrameExtent: coordinator.fractalFrameExtent,
	                                                                                    layers: coordinator.layers,
	                                                                                    zOrder: coordinator.zOrder,
	                                                                                    selectedLayerID: coordinator.selectedLayerID) {
	                                    exportDocument = CanvasDocument(data: data)
	                                    exportFilename = "canvas"
	                                    isExporting = true
	                                }
	                            }) {
	                                VStack(spacing: 2) {
	                                    Image(systemName: "square.and.arrow.up")
	                                        .font(.system(size: 20))
	                                    Text("Export")
	                                        .font(.caption)
	                                }
	                                .foregroundColor(.white)
	                                .padding(8)
	                                .background(.ultraThinMaterial)
	                                .cornerRadius(12)
	                            }

	                            Button(action: {
	                                if let data = PersistenceManager.shared.exportRNNStrokeSequence(rootFrame: coordinator.rootFrame,
	                                                                                             fractalFrameExtent: coordinator.fractalFrameExtent) {
	                                    exportDocument = CanvasDocument(data: data)
	                                    exportFilename = "rnn_strokes"
	                                    isExporting = true
	                                }
	                            }) {
	                                VStack(spacing: 2) {
	                                    Image(systemName: "waveform.path")
	                                        .font(.system(size: 20))
	                                    Text("RNN")
	                                        .font(.caption)
	                                }
	                                .foregroundColor(.white)
	                                .padding(8)
	                                .background(.ultraThinMaterial)
	                                .cornerRadius(12)
	                            }

	                            Button(action: { showingImportPicker = true }) {
	                                VStack(spacing: 2) {
	                                    Image(systemName: "square.and.arrow.down")
	                                        .font(.system(size: 20))
	                                    Text("Import")
                                        .font(.caption)
                                }
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                            }
                        }

		                        HStack(spacing: 12) {
		                            Button(action: { coordinator.debugPopulateFrames() }) {
		                                VStack(spacing: 2) {
		                                    Image(systemName: "bolt.fill")
		                                        .font(.system(size: 20))
	                                    Text("Fill")
	                                        .font(.caption)
	                                }
	                                .foregroundColor(.yellow)
	                                .padding(8)
	                                .background(.ultraThinMaterial)
	                                .cornerRadius(12)
	                            }

	                            Button(action: { showClearConfirmation = true }) {
                                VStack(spacing: 2) {
                                    Image(systemName: "trash.slash")
                                        .font(.system(size: 20))
                                    Text("Clear")
                                        .font(.caption)
                                }
                                .foregroundColor(.red)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                            }
                            .confirmationDialog("Clear all strokes?",
                                                isPresented: $showClearConfirmation,
                                                titleVisibility: .visible) {
                                Button("Clear", role: .destructive) {
                                    coordinator.clearAllStrokes()
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
	                                Text("Clears canvas strokes and card drawings across all frames. This cannot be undone.")
	                            }
	                        }

	                        Button(action: {
	                            coordinator.presentLayersMenu()
	                        }) {
	                            HStack(spacing: 8) {
	                                Image(systemName: "square.3.layers.3d")
	                                    .font(.system(size: 16))
	                                Text("Layers")
	                                    .font(.system(size: 14, weight: .medium))
	                            }
	                            .foregroundColor(.white)
	                            .padding(.horizontal, 12)
	                            .padding(.vertical, 10)
	                            .background(.ultraThinMaterial)
	                            .cornerRadius(16)
	                        }

	                        Button(action: {
	                            withAnimation(.easeInOut(duration: 0.2)) {
	                                isHandwritingRefinementMenuExpanded.toggle()
	                            }
	                        }) {
	                            HStack(spacing: 8) {
	                                Image(systemName: isHandwritingRefinementMenuExpanded ? "wand.and.stars.inverse" : "wand.and.stars")
	                                    .font(.system(size: 16))
	                                Text("Refinement")
	                                    .font(.system(size: 14, weight: .medium))
	                            }
	                            .foregroundColor(.white)
	                            .padding(.horizontal, 12)
	                            .padding(.vertical, 10)
	                            .background(.ultraThinMaterial)
	                            .cornerRadius(16)
	                        }

	                        if isHandwritingRefinementMenuExpanded {
	                            VStack(alignment: .trailing, spacing: 10) {
	                                Toggle(isOn: $handwritingRefinementEnabled) {
	                                    HStack(spacing: 8) {
	                                        Image(systemName: handwritingRefinementEnabled ? "pencil.and.outline" : "pencil")
	                                            .font(.system(size: 14))
	                                            .foregroundColor(.white)
	                                        Text(handwritingRefinementEnabled ? "Refinement On" : "Refinement Off")
	                                            .font(.system(size: 14, weight: .medium))
	                                            .foregroundColor(.white)
	                                    }
	                                }
	                                .toggleStyle(SwitchToggleStyle(tint: .blue))

	                                VStack(alignment: .trailing, spacing: 6) {
	                                    HStack(spacing: 8) {
	                                        Image(systemName: "wand.and.stars")
	                                            .font(.system(size: 14))
	                                            .foregroundColor(.white)
	                                        Text("Bias: \(String(format: "%.2f", handwritingRefinementBias))")
	                                            .font(.system(size: 14, weight: .medium))
	                                            .foregroundColor(.white)
	                                    }
	                                    Slider(value: $handwritingRefinementBias, in: 0.5...6.0, step: 0.05)
	                                        .tint(.white)
	                                }

	                                VStack(alignment: .trailing, spacing: 6) {
	                                    HStack(spacing: 8) {
	                                        Image(systemName: "slider.horizontal.3")
	                                            .font(.system(size: 14))
	                                            .foregroundColor(.white)
	                                        Text("Strength: \(String(format: "%.2f", handwritingRefinementStrength))")
	                                            .font(.system(size: 14, weight: .medium))
	                                            .foregroundColor(.white)
	                                    }
	                                    Slider(value: $handwritingRefinementStrength, in: 0.0...1.0, step: 0.05)
	                                        .tint(.white)
	                                }

	                                VStack(alignment: .trailing, spacing: 6) {
	                                    HStack(spacing: 8) {
	                                        Image(systemName: "arrow.left.and.right")
	                                            .font(.system(size: 14))
	                                            .foregroundColor(.white)
	                                        Text("Scale: \(String(format: "%.1f", handwritingRefinementInputScale))")
	                                            .font(.system(size: 14, weight: .medium))
	                                            .foregroundColor(.white)
	                                    }
	                                    Slider(value: $handwritingRefinementInputScale, in: 0.5...10.0, step: 0.1)
	                                        .tint(.white)
	                                }

	                                VStack(alignment: .trailing, spacing: 6) {
	                                    HStack(spacing: 8) {
	                                        Image(systemName: "timer")
	                                            .font(.system(size: 14))
	                                            .foregroundColor(.white)
	                                        Text("Debounce: \(Int(handwritingRefinementDebounceSeconds * 1000))ms")
	                                            .font(.system(size: 14, weight: .medium))
	                                            .foregroundColor(.white)
	                                    }
	                                    Slider(value: $handwritingRefinementDebounceSeconds, in: 0.1...1.5, step: 0.05)
	                                        .tint(.white)
	                                }
	                            }
	                            .padding(.horizontal, 16)
	                            .padding(.vertical, 12)
	                            .background(.ultraThinMaterial)
	                            .cornerRadius(20)
	                            .onChange(of: handwritingRefinementEnabled) { _, newValue in
	                                coordinator.handwritingRefinementEnabled = newValue
	                            }
	                            .onChange(of: handwritingRefinementBias) { _, newValue in
	                                coordinator.handwritingRefinementBias = Float(newValue)
	                            }
	                            .onChange(of: handwritingRefinementStrength) { _, newValue in
	                                coordinator.handwritingRefinementStrength = Float(newValue)
	                            }
	                            .onChange(of: handwritingRefinementInputScale) { _, newValue in
	                                coordinator.handwritingRefinementInputScale = Float(newValue)
	                            }
	                            .onChange(of: handwritingRefinementDebounceSeconds) { _, newValue in
	                                coordinator.handwritingRefinementDebounceSeconds = newValue
	                            }
	                        }

	                        Button(action: {
	                            withAnimation(.easeInOut(duration: 0.2)) {
	                                isBrushMenuExpanded.toggle()
	                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: isBrushMenuExpanded ? "paintbrush.fill" : "paintbrush")
                                    .font(.system(size: 16))
                                Text("Brush Settings")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .cornerRadius(16)
                        }

                        if isBrushMenuExpanded {
                            VStack(alignment: .trailing, spacing: 12) {
                                VStack(alignment: .trailing, spacing: 12) {
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            coordinator.brushSettings.toolMode = coordinator.brushSettings.isMaskEraser ? .paint : .maskEraser
                                        }) {
                                            VStack(spacing: 2) {
                                                Image(systemName: coordinator.brushSettings.isMaskEraser ? "eraser.fill" : "eraser")
                                                    .font(.system(size: 20))
                                                Text("Erase")
                                                    .font(.caption)
                                            }
                                            .foregroundColor(coordinator.brushSettings.isMaskEraser ? .pink : .white)
                                            .padding(8)
                                            .background(.ultraThinMaterial)
                                            .cornerRadius(12)
                                        }

                                        Button(action: {
                                            coordinator.brushSettings.toolMode = coordinator.brushSettings.isStrokeEraser ? .paint : .strokeEraser
                                        }) {
                                            VStack(spacing: 2) {
                                                Image(systemName: coordinator.brushSettings.isStrokeEraser ? "trash.fill" : "trash")
                                                    .font(.system(size: 20))
                                                Text("Stroke")
                                                    .font(.caption)
                                            }
                                            .foregroundColor(coordinator.brushSettings.isStrokeEraser ? .orange : .white)
                                            .padding(8)
                                            .background(.ultraThinMaterial)
                                            .cornerRadius(12)
                                        }
                                    }

                                    HStack(spacing: 12) {
                                        Button(action: {
                                            coordinator.brushSettings.toolMode = coordinator.brushSettings.isFreehandLasso ? .paint : .lasso
                                        }) {
                                            VStack(spacing: 2) {
                                                Image(systemName: "lasso")
                                                    .font(.system(size: 20))
                                                Text("Lasso")
                                                    .font(.caption)
                                            }
                                            .foregroundColor(coordinator.brushSettings.isFreehandLasso ? .cyan : .white)
                                            .padding(8)
                                            .background(.ultraThinMaterial)
                                            .cornerRadius(12)
                                        }

                                        Button(action: {
                                            coordinator.brushSettings.toolMode = coordinator.brushSettings.isBoxLasso ? .paint : .boxLasso
                                        }) {
                                            VStack(spacing: 2) {
                                                Image(systemName: "rectangle.dashed")
                                                    .font(.system(size: 20))
                                                Text("Box")
                                                    .font(.caption)
                                            }
                                            .foregroundColor(coordinator.brushSettings.isBoxLasso ? .cyan : .white)
                                            .padding(8)
                                            .background(.ultraThinMaterial)
                                            .cornerRadius(12)
                                        }
                                    }
                                }

                                StrokeSizeSlider(brushSettings: coordinator.brushSettings)
                                    .frame(width: 240)
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showSettingsSheet) {
            if let card = editingCard {
                CardSettingsView(card: card, onDelete: {
                    metalViewCoordinator?.deleteCard(card)
                    editingCard = nil
                    showSettingsSheet = false
                })
                    .presentationDetents([.medium])
            }
        }
	        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
	                guard let coordinator = metalViewCoordinator else { return }
	                guard let data = try? Data(contentsOf: url) else { return }
	                let viewSize = coordinator.metalView?.bounds.size ?? .zero
	                let extent = SIMD2<Double>(Double(viewSize.width), Double(viewSize.height))
	                if let imported = PersistenceManager.shared.importCanvas(data: data, device: coordinator.device, fractalFrameExtent: extent) {
	                    coordinator.replaceCanvas(with: imported.rootFrame,
	                                              fractalExtent: imported.fractalFrameExtent,
	                                              layers: imported.layers,
	                                              zOrder: imported.zOrder,
	                                              selectedLayerID: imported.selectedLayerID)
	                }
	            case .failure(let error):
	                print("Import error: \(error)")
	            }
		        }
	        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: exportFilename) { result in
	            if case .failure(let error) = result {
	                print("Export error: \(error)")
	            }
	        }
	    }
	}

// MARK: - Stroke Size Slider Component

struct StrokeSizeSlider: View {
    @ObservedObject var brushSettings: BrushSettings

    // Convert SIMD4<Float> to SwiftUI Color
    private var strokeColor: Binding<Color> {
        Binding(
            get: {
                Color(.sRGB,
                    red: Double(brushSettings.color.x),
                    green: Double(brushSettings.color.y),
                    blue: Double(brushSettings.color.z),
                    opacity: Double(brushSettings.color.w)
                )
            },
            set: { newColor in
                // Convert SwiftUI Color back to SIMD4<Float>
                if let rgba = sRGBComponents(from: newColor) {
                    brushSettings.color = rgba
                }
            }
        )
    }

    private func sRGBComponents(from color: Color) -> SIMD4<Float>? {
        let uiColor = UIColor(color)
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                Text("\(Int(brushSettings.size))pt")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 50, alignment: .leading)
            }

            Slider(
                value: $brushSettings.size,
                in: BrushSettings.minSize...BrushSettings.maxSize,
                step: 1.0
            )
            .tint(.white)

            // Color Picker
            ColorPicker("Stroke Color", selection: strokeColor, supportsOpacity: false)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            // Culling Box Size Slider (Test)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                    Text("Culling: \(String(format: "%.2fx", brushSettings.cullingMultiplier))")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
                Slider(
                    value: Binding(
                        get: { brushSettings.cullingMultiplier },
                        set: { newValue in
                            // Snap to 1.0, 0.5, or 0.25
                            if newValue >= 0.75 {
                                brushSettings.cullingMultiplier = 1.0
                            } else if newValue >= 0.375 {
                                brushSettings.cullingMultiplier = 0.5
                            } else {
                                brushSettings.cullingMultiplier = 0.25
                            }
                        }
                    ),
                    in: 0.25...1.0
                )
                .tint(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Constant Screen Size Toggle
            Toggle(isOn: $brushSettings.constantScreenSize) {
                HStack(spacing: 8) {
                    Image(systemName: brushSettings.constantScreenSize ? "pencil.tip" : "pencil.tip.crop.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                    Text(brushSettings.constantScreenSize ? "Fixed Screen Size" : "Scales with Zoom")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }
}

struct CanvasDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#if !CODEX
#Preview {
    ContentView()
}
#endif
