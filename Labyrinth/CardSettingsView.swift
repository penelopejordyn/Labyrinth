// CardSettingsView.swift provides the UI for editing card properties (type, background, etc.)
import SwiftUI
import MetalKit
import UIKit

struct CardSettingsView: View {
    let card: Card // Reference class, so modifying it updates Metal immediately
    let onDelete: (() -> Void)?

    @State private var selectedTab = 0
    @State private var spacing: Float = 25.0
    @State private var lineWidth: Float = 1.0
    @State private var backgroundColor: Color = .white
    @State private var lineColor: Color = Color(.sRGB, red: 0.7, green: 0.8, blue: 1.0, opacity: 0.5)
    @State private var cardOpacity: Float = 1.0
    @State private var isLocked: Bool = false
    @State private var showImagePicker = false
    @State private var uiImage: UIImage?
    @State private var youtubeURL: String = ""
    @State private var pluginTypeID: String = ""
    @Environment(\.dismiss) var dismiss

    init(card: Card, onDelete: (() -> Void)? = nil) {
        self.card = card
        self.onDelete = onDelete
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { backgroundColor },
            set: { newColor in
                backgroundColor = newColor
                applyBackgroundColor(newColor)
            }
        )
    }

    private var lineColorBinding: Binding<Color> {
        Binding(
            get: { lineColor },
            set: { newColor in
                lineColor = newColor
                updateCardType(for: selectedTab)
            }
        )
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Type Picker
                    let tabs: [(title: String, tag: Int)] = [
                        ("Solid", 0),
                        ("Lined", 1),
                        ("Grid", 2),
                        ("Image", 3),
                        ("YouTube", 4),
                        ("Plugin", 5),
                    ]
                    let columns = [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ]
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(tabs, id: \.tag) { tab in
                            Button {
                                selectedTab = tab.tag
                                updateCardType(for: tab.tag)
                            } label: {
                                Text(tab.title)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(selectedTab == tab.tag ? Color.accentColor.opacity(0.25) : Color(.systemGray6))
                                    )
                                    .foregroundColor(selectedTab == tab.tag ? .primary : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Background Color")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        ColorPicker("Background Color", selection: backgroundBinding, supportsOpacity: false)
                            .font(.subheadline)
                    }
                    .padding(.horizontal)

                    // Opacity Slider (appears on all tabs)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Opacity: \(Int(cardOpacity * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Slider(value: $cardOpacity, in: 0.0...1.0, step: 0.05)
                            .onChange(of: cardOpacity) { _, newValue in
                                card.opacity = newValue
                            }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { isLocked },
                            set: { newValue in
                                isLocked = newValue
                                card.isLocked = newValue
                                if newValue {
                                    card.isEditing = false
                                }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                                Text("Lock Card")
                            }
                            .font(.subheadline)
                        }

                        Button(role: .destructive) {
                            onDelete?()
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                Text("Delete Card")
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.horizontal)

                    // Settings for selected type
                    if selectedTab == 1 || selectedTab == 2 {
                        // Lined or Grid settings
                        VStack(alignment: .leading, spacing: 16) {
                            // Line Spacing Slider
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Line Spacing: \(Int(spacing)) pt")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Slider(value: $spacing, in: 10...100, step: 5)
                                    .onChange(of: spacing) {
                                        updateCardType(for: selectedTab)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Line Color")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                ColorPicker("Line Color", selection: lineColorBinding, supportsOpacity: true)
                                    .font(.subheadline)
                            }

                            // Line Width Slider
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Line Width: \(String(format: "%.1f", lineWidth)) pt")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Slider(value: $lineWidth, in: 0.5...5.0, step: 0.5)
                                    .onChange(of: lineWidth) {
                                        updateCardType(for: selectedTab)
                                    }
                            }
                        }
                        .padding(.horizontal)

                    } else if selectedTab == 0 {
                        // Solid color settings
                        Text("Solid color background")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()

                    } else if selectedTab == 3 {
                        // Image settings
                        VStack(spacing: 16) {
                            Button(action: {
                                showImagePicker = true
                            }) {
                                HStack {
                                    Image(systemName: "photo.on.rectangle")
                                    Text("Select Image")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.blue)
                                .cornerRadius(12)
                            }

                            if case .image = card.type {
                                Text("Image loaded")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal)
                    } else if selectedTab == 4 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("YouTube Link")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            TextField("Paste a YouTube URL", text: $youtubeURL)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)

                            Button("Set YouTube Video") {
                                applyYouTubeLink(youtubeURL)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal)
                    } else if selectedTab == 5 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Plugin Card")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            let defs = CardPluginRegistry.shared.allDefinitions
                            if defs.isEmpty {
                                Text("No card plugins installed.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            } else {
                                Picker("Plugin", selection: $pluginTypeID) {
                                    ForEach(defs, id: \.typeID) { def in
                                        Text(def.name).tag(def.typeID)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: pluginTypeID) { _, newValue in
                                    applyPluginType(newValue, resetPayload: true)
                                }

                                if !pluginTypeID.isEmpty {
                                    Text(pluginTypeID)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }

                                Button("Reset Plugin State") {
                                    applyPluginType(pluginTypeID, resetPayload: true)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Card Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $uiImage)
        }
        .onChange(of: uiImage) { _, newImage in
            guard let img = newImage else { return }

            // Load Texture
            let device = MTLCreateSystemDefaultDevice()!
            let loader = MTKTextureLoader(device: device)

            if let cgImg = img.cgImage,
               let texture = try? loader.newTexture(
                cgImage: cgImg,
                options: [
                    .origin: MTKTextureLoader.Origin.bottomLeft,
                    // The renderer targets `.bgra8Unorm` (non-sRGB). If we load card images as sRGB textures,
                    // Metal will convert them to linear on sample, making them appear too dark when written
                    // into a non-sRGB render target.
                    .SRGB: false,
                ]
               ) {

                card.type = .image(texture)

                // Optional: Resize card to match image aspect ratio
                let aspect = Double(img.size.width / img.size.height)
                let newHeight = card.size.x / aspect
                card.size.y = newHeight
                card.rebuildGeometry() // Important! Rebuild quad vertices
            }
        }
        .onAppear {
            // Initialize state from current card
            backgroundColor = colorFromSIMD(card.backgroundColor)
            cardOpacity = card.opacity
            isLocked = card.isLocked
            switch card.type {
            case .solidColor:
                selectedTab = 0
            case .lined(let config):
                selectedTab = 1
                spacing = config.spacing
                lineWidth = config.lineWidth
                lineColor = colorFromSIMD(config.color)
            case .grid(let config):
                selectedTab = 2
                spacing = config.spacing
                lineWidth = config.lineWidth
                lineColor = colorFromSIMD(config.color)
            case .image:
                selectedTab = 3
            case .youtube(let videoID, _):
                selectedTab = 4
                youtubeURL = videoID
            case .drawing:
                selectedTab = 0 // Default to solid for now
            case .plugin(let typeID, _):
                selectedTab = 5
                pluginTypeID = typeID
            }

            if pluginTypeID.isEmpty, let first = CardPluginRegistry.shared.allDefinitions.first {
                pluginTypeID = first.typeID
            }
        }
    }

    /// Update the card type based on selected tab and current settings
    private func updateCardType(for tab: Int) {
        let background = simdFromColor(backgroundColor)
        card.backgroundColor = background

        switch tab {
        case 0: // Solid
            card.type = .solidColor(background)
        case 1: // Lined
            card.type = .lined(LinedBackgroundConfig(
                spacing: spacing,
                lineWidth: lineWidth,
                color: simdFromColor(lineColor)
            ))
        case 2: // Grid
            card.type = .grid(LinedBackgroundConfig(
                spacing: spacing,
                lineWidth: lineWidth,
                color: simdFromColor(lineColor)
            ))
        case 3: // Image
            // Will be handled in Phase 4
            break
        case 4: // YouTube
            card.type = .youtube(videoID: "", aspectRatio: 16.0 / 9.0)
        case 5: // Plugin
            if pluginTypeID.isEmpty, let first = CardPluginRegistry.shared.allDefinitions.first {
                pluginTypeID = first.typeID
            }
            applyPluginType(pluginTypeID, resetPayload: false)
        default:
            break
        }
    }

    private func applyBackgroundColor(_ color: Color) {
        let background = simdFromColor(color)
        card.backgroundColor = background
        if case .solidColor = card.type {
            card.type = .solidColor(background)
        }
    }

    private func simdFromColor(_ color: Color) -> SIMD4<Float> {
        let uiColor = UIColor(color)
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
        }
        return SIMD4<Float>(1, 1, 1, 1)
    }

    private func colorFromSIMD(_ color: SIMD4<Float>) -> Color {
        Color(.sRGB,
              red: Double(color.x),
              green: Double(color.y),
              blue: Double(color.z),
              opacity: Double(color.w))
    }

    private func applyYouTubeLink(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = parseYouTubeVideoInfo(from: trimmed) else { return }

        card.type = .youtube(videoID: info.videoID, aspectRatio: info.aspectRatio)

        if info.aspectRatio.isFinite, info.aspectRatio > 0 {
            let newHeight = card.size.x / info.aspectRatio
            if newHeight.isFinite, newHeight > 0 {
                card.size.y = newHeight
            }
        }
        card.rebuildGeometry()
    }

    private func applyPluginType(_ typeID: String, resetPayload: Bool) {
        let trimmed = typeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            card.pluginSnapshotTexture = nil
            card.type = .plugin(typeID: "", payload: Data())
            return
        }

        if case .plugin(let currentTypeID, let currentPayload) = card.type,
           currentTypeID == trimmed,
           resetPayload == false {
            return
        }

        let payload: Data = {
            if resetPayload {
                return CardPluginRegistry.shared.definition(for: trimmed)?.defaultPayload ?? Data()
            }
            if case .plugin(let currentTypeID, let currentPayload) = card.type,
               currentTypeID == trimmed {
                return currentPayload
            }
            return CardPluginRegistry.shared.definition(for: trimmed)?.defaultPayload ?? Data()
        }()

        card.pluginSnapshotTexture = nil
        card.type = .plugin(typeID: trimmed, payload: payload)
    }

    private func parseYouTubeVideoInfo(from input: String) -> (videoID: String, aspectRatio: Double)? {
        guard !input.isEmpty else { return nil }

        if !input.contains("://"),
           input.range(of: #"^[A-Za-z0-9_-]{6,}$"#, options: .regularExpression) != nil {
            return (videoID: input, aspectRatio: 16.0 / 9.0)
        }

        guard let url = URL(string: input),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let host = (components.host ?? "").lowercased()
        let path = components.path

        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
               !v.isEmpty {
                return (videoID: v, aspectRatio: 16.0 / 9.0)
            }
        }

        if host.contains("youtu.be") {
            let parts = path.split(separator: "/")
            if let first = parts.first, !first.isEmpty {
                return (videoID: String(first), aspectRatio: 16.0 / 9.0)
            }
        }

        if let range = path.range(of: "/embed/") {
            let rest = path[range.upperBound...]
            if let first = rest.split(separator: "/").first, !first.isEmpty {
                return (videoID: String(first), aspectRatio: 16.0 / 9.0)
            }
        }

        if let range = path.range(of: "/shorts/") {
            let rest = path[range.upperBound...]
            if let first = rest.split(separator: "/").first, !first.isEmpty {
                return (videoID: String(first), aspectRatio: 9.0 / 16.0)
            }
        }

        return nil
    }
}
