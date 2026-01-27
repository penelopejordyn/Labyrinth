// FloatingMenuViewController.swift
// Custom floating menus (sections + cards) presented near the touch point.

import UIKit
import MetalKit
import PhotosUI

// MARK: - Simple Floating Menu (Sections)

final class FloatingMenuViewController: UIViewController {

    struct ColorOption {
        let color: UIColor
        let simdColor: SIMD4<Float>
    }

    struct MenuItem {
        let title: String
        let icon: String?
        let isDestructive: Bool
        let action: () -> Void

        init(title: String, icon: String? = nil, isDestructive: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.isDestructive = isDestructive
            self.action = action
        }
    }

    private let colors: [ColorOption]
    private let menuItems: [MenuItem]
    private let onColorSelected: ((Int, SIMD4<Float>) -> Void)?
    private let initialPickerColor: UIColor?
    private let onDismiss: (() -> Void)?
    private let sourceRect: CGRect
    private let sourceView: UIView

    private let containerView = UIView()
    private let popoverScaleHidden: CGFloat = 0.96
    private var didNotifyDismiss = false

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let tintOverlayView = UIView()
    private let glossOverlayView = UIView()
    private let glossLayer = CAGradientLayer()

    init(
        colors: [ColorOption] = [],
        menuItems: [MenuItem] = [],
        onColorSelected: ((Int, SIMD4<Float>) -> Void)? = nil,
        initialPickerColor: UIColor? = nil,
        onDismiss: (() -> Void)? = nil,
        sourceRect: CGRect,
        sourceView: UIView
    ) {
        self.colors = colors
        self.menuItems = menuItems
        self.onColorSelected = onColorSelected
        self.initialPickerColor = initialPickerColor
        self.onDismiss = onDismiss
        self.sourceRect = sourceRect
        self.sourceView = sourceView
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissMenu))
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)

        setupContainer()
        setupContent()
        positionContainer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateInIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glossLayer.frame = glossOverlayView.bounds
    }

    private func setupContainer() {
        containerView.backgroundColor = .clear
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 12
        containerView.layer.shadowOpacity = 0.25
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.alpha = 0.0
        containerView.transform = CGAffineTransform(scaleX: popoverScaleHidden, y: popoverScaleHidden)
        view.addSubview(containerView)

        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = 16
        blurView.clipsToBounds = true
        blurView.layer.borderWidth = 1.0
        blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        containerView.addSubview(blurView)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: containerView.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        tintOverlayView.backgroundColor = UIColor(white: 0.0, alpha: 0.18)
        tintOverlayView.isUserInteractionEnabled = false
        tintOverlayView.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(tintOverlayView)

        glossOverlayView.backgroundColor = .clear
        glossOverlayView.isUserInteractionEnabled = false
        glossOverlayView.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(glossOverlayView)

        NSLayoutConstraint.activate([
            tintOverlayView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
            tintOverlayView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
            tintOverlayView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
            tintOverlayView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),

            glossOverlayView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
            glossOverlayView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
            glossOverlayView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
            glossOverlayView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
        ])

        glossLayer.colors = [
            UIColor.white.withAlphaComponent(0.24).cgColor,
            UIColor.white.withAlphaComponent(0.10).cgColor,
            UIColor.white.withAlphaComponent(0.00).cgColor
        ]
        glossLayer.locations = [0.0, 0.18, 0.55]
        glossLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        glossLayer.endPoint = CGPoint(x: 0.0, y: 1.0)
        glossOverlayView.layer.addSublayer(glossLayer)
    }

    private func animateInIfNeeded() {
        guard containerView.alpha == 0 else { return }
        UIView.animate(withDuration: 0.18,
                       delay: 0,
                       usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0.6,
                       options: [.curveEaseOut, .allowUserInteraction],
                       animations: { [weak self] in
                           guard let self else { return }
                           self.containerView.alpha = 1.0
                           self.containerView.transform = .identity
                       },
                       completion: nil)
    }

    private func dismissPopover(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.12,
                       delay: 0,
                       options: [.curveEaseIn, .beginFromCurrentState],
                       animations: { [weak self] in
                           guard let self else { return }
                           self.containerView.alpha = 0.0
                           self.containerView.transform = CGAffineTransform(scaleX: self.popoverScaleHidden,
                                                                            y: self.popoverScaleHidden)
                       },
                       completion: { [weak self] _ in
                           guard let self else { return }
                           self.notifyDismissIfNeeded()
                           self.dismiss(animated: false, completion: completion)
                       })
    }

    private func notifyDismissIfNeeded() {
        guard !didNotifyDismiss else { return }
        didNotifyDismiss = true
        onDismiss?()
    }

    private func setupContent() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 14),
            stackView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 14),
            stackView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -14),
            stackView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -14)
        ])

        if !colors.isEmpty {
            let buttonsPerRow = 3
            let grid = UIStackView()
            grid.axis = .vertical
            grid.spacing = 8
            grid.alignment = .center

            let totalButtons = colors.count + 1
            for rowStart in stride(from: 0, to: totalButtons, by: buttonsPerRow) {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 8
                row.alignment = .center

                let rowEnd = min(rowStart + buttonsPerRow, totalButtons)
                for index in rowStart..<rowEnd {
                    if index < colors.count {
                        let colorOption = colors[index]
                        let button = UIButton(type: .custom)
                        button.backgroundColor = colorOption.color
                        button.layer.cornerRadius = 15
                        button.layer.borderWidth = 1
                        button.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
                        button.tag = index
                        button.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
                        button.translatesAutoresizingMaskIntoConstraints = false
                        button.layer.shadowColor = colorOption.color.cgColor
                        button.layer.shadowOffset = CGSize(width: 0, height: 2)
                        button.layer.shadowRadius = 3
                        button.layer.shadowOpacity = 0.22

                        NSLayoutConstraint.activate([
                            button.widthAnchor.constraint(equalToConstant: 30),
                            button.heightAnchor.constraint(equalToConstant: 30)
                        ])
                        row.addArrangedSubview(button)
                    } else {
                        if #available(iOS 14.0, *) {
                            let wellContainer = UIView()
                            wellContainer.translatesAutoresizingMaskIntoConstraints = false
                            wellContainer.layer.cornerRadius = 15
                            wellContainer.clipsToBounds = true
                            wellContainer.layer.borderWidth = 1
                            wellContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
                            NSLayoutConstraint.activate([
                                wellContainer.widthAnchor.constraint(equalToConstant: 30),
                                wellContainer.heightAnchor.constraint(equalToConstant: 30)
                            ])

                            let well = UIColorWell()
                            well.supportsAlpha = false
                            well.selectedColor = initialPickerColor ?? colors.first?.color ?? .white
                            well.addTarget(self, action: #selector(colorWellChanged(_:)), for: .valueChanged)
                            well.translatesAutoresizingMaskIntoConstraints = false
                            wellContainer.addSubview(well)
                            NSLayoutConstraint.activate([
                                well.leadingAnchor.constraint(equalTo: wellContainer.leadingAnchor),
                                well.trailingAnchor.constraint(equalTo: wellContainer.trailingAnchor),
                                well.topAnchor.constraint(equalTo: wellContainer.topAnchor),
                                well.bottomAnchor.constraint(equalTo: wellContainer.bottomAnchor)
                            ])
                            row.addArrangedSubview(wellContainer)
                        } else {
                            let pickerButton = UIButton(type: .custom)
                            pickerButton.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
                            pickerButton.layer.cornerRadius = 15
                            pickerButton.layer.borderWidth = 1
                            pickerButton.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
                            pickerButton.setImage(UIImage(systemName: "paintpalette.fill"), for: .normal)
                            pickerButton.tintColor = .white
                            pickerButton.addTarget(self, action: #selector(dismissMenu), for: .touchUpInside)
                            pickerButton.translatesAutoresizingMaskIntoConstraints = false

                            NSLayoutConstraint.activate([
                                pickerButton.widthAnchor.constraint(equalToConstant: 30),
                                pickerButton.heightAnchor.constraint(equalToConstant: 30)
                            ])
                            row.addArrangedSubview(pickerButton)
                        }
                    }
                }

                grid.addArrangedSubview(row)
            }

            stackView.addArrangedSubview(grid)
        }

        if !colors.isEmpty && !menuItems.isEmpty {
            let divider = UIView()
            divider.backgroundColor = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(divider)
            NSLayoutConstraint.activate([
                divider.heightAnchor.constraint(equalToConstant: 1),
                divider.widthAnchor.constraint(equalTo: stackView.widthAnchor)
            ])
        }

        for item in menuItems {
            let button = createMenuButton(item: item)
            stackView.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalTo: stackView.widthAnchor)
            ])
        }
    }

    private func createMenuButton(item: MenuItem) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = item.title
        config.baseForegroundColor = item.isDestructive ? .systemRed : .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        if let iconName = item.icon {
            config.image = UIImage(systemName: iconName)
            config.imagePadding = 8
        }

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak self] _ in
            self?.dismissPopover { item.action() }
        }, for: .touchUpInside)
        return button
    }

    private func positionContainer() {
        let windowRect = sourceView.convert(sourceRect, to: nil)
        let anchorRect = view.convert(windowRect, from: nil)

        containerView.layoutIfNeeded()
        let containerSize = containerView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)

        let padding: CGFloat = 16
        let gap: CGFloat = 14

        let bounds = view.bounds
        let minX = bounds.minX + padding
        let maxX = bounds.maxX - padding - containerSize.width

        // Prefer the menu to the RIGHT of the finger; if it doesn't fit, fall back to the left.
        let desiredRightX = anchorRect.midX + gap
        let desiredLeftX = anchorRect.midX - gap - containerSize.width

        let fitsRight = desiredRightX <= maxX
        let fitsLeft = desiredLeftX >= minX

        let targetX: CGFloat
        if fitsRight {
            targetX = max(minX, desiredRightX)
        } else if fitsLeft {
            targetX = min(maxX, desiredLeftX)
        } else {
            // Clamp to screen if neither side fully fits.
            targetX = max(minX, min(desiredRightX, maxX))
        }

        var targetY = anchorRect.midY - containerSize.height * 0.5
        let minY = bounds.minY + padding + 44
        let maxY = bounds.maxY - padding - containerSize.height
        targetY = max(minY, min(targetY, maxY))

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: targetX),
            containerView.topAnchor.constraint(equalTo: view.topAnchor, constant: targetY),
        ])
    }

    private func simdColor(from color: UIColor) -> SIMD4<Float> {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let resolved = color.resolvedColor(with: traitCollection)
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    @objc private func colorTapped(_ sender: UIButton) {
        let index = sender.tag
        dismissPopover { [weak self] in
            guard let self, index < self.colors.count else { return }
            self.onColorSelected?(index, self.colors[index].simdColor)
        }
    }

    @available(iOS 14.0, *)
    @objc private func colorWellChanged(_ sender: UIColorWell) {
        guard let selected = sender.selectedColor else { return }
        onColorSelected?(colors.count, simdColor(from: selected))
    }

    @objc private func dismissMenu() {
        dismissPopover()
    }
}

extension FloatingMenuViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: containerView)
        return !containerView.bounds.contains(location)
    }
}

// MARK: - Card Settings Floating Menu

final class CardSettingsFloatingMenu: UIViewController {

    private let card: Card
    private var shadowsEnabled: Bool
    private let onToggleShadows: (Bool) -> Void
    private var cardNamesVisible: Bool
    private let onToggleCardNames: (Bool) -> Void
    private let onDelete: () -> Void
    private let onActivatePlugin: (() -> Void)?
    private let sourceRect: CGRect
    private let sourceView: UIView

    private let containerView = UIView()
    private let popoverScaleHidden: CGFloat = 0.96

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let tintOverlayView = UIView()
    private let glossOverlayView = UIView()
    private let glossLayer = CAGradientLayer()

    private var selectedTab = 0
    private var spacing: Float = 25.0
    private var lineWidth: Float = 1.0
    private var cardOpacity: Float = 1.0

    private var typeSegment: UISegmentedControl!
    private var spacingSlider: UISlider!
    private var spacingLabel: UILabel!
    private var lineWidthSlider: UISlider!
    private var lineWidthLabel: UILabel!
    private var opacitySlider: UISlider!
    private var opacityLabel: UILabel!
    private var shadowsSwitch: UISwitch?
    private var cardNamesSwitch: UISwitch?
    private var lineSettingsStack: UIStackView!
    private var backgroundColorWell: UIColorWell?
    private var lineColorWell: UIColorWell?
    private var imageSettingsStack: UIStackView!
    private var youtubeSettingsStack: UIStackView!
    private var youtubeURLField: UITextField!
    private var youtubeErrorLabel: UILabel!
    private var youtubeInputText: String = ""
    private var pluginSettingsStack: UIStackView!
    private var pluginTypeButton: UIButton!
    private var pluginTypeID: String = ""

    private var lineColor: SIMD4<Float> = SIMD4<Float>(0.7, 0.8, 1.0, 0.5)

    private static let backgroundColors: [SIMD4<Float>] = [
        SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
        SIMD4<Float>(0.95, 0.95, 0.90, 1.0),
        SIMD4<Float>(1.0, 0.95, 0.85, 1.0),
        SIMD4<Float>(0.85, 0.95, 1.0, 1.0),
        SIMD4<Float>(0.9, 0.9, 0.9, 1.0),
        SIMD4<Float>(0.2, 0.2, 0.2, 1.0)
    ]

    init(card: Card,
         shadowsEnabled: Bool,
         onToggleShadows: @escaping (Bool) -> Void,
         cardNamesVisible: Bool,
         onToggleCardNames: @escaping (Bool) -> Void,
         onDelete: @escaping () -> Void,
         onActivatePlugin: (() -> Void)? = nil,
         sourceRect: CGRect,
         sourceView: UIView) {
        self.card = card
        self.shadowsEnabled = shadowsEnabled
        self.onToggleShadows = onToggleShadows
        self.cardNamesVisible = cardNamesVisible
        self.onToggleCardNames = onToggleCardNames
        self.onDelete = onDelete
        self.onActivatePlugin = onActivatePlugin
        self.sourceRect = sourceRect
        self.sourceView = sourceView
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissMenu))
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)

        loadCardState()
        setupContainer()
        setupContent()
        positionContainer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateInIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glossLayer.frame = glossOverlayView.bounds
    }

    private func loadCardState() {
        cardOpacity = card.opacity
	        switch card.type {
	        case .solidColor:
	            selectedTab = 0
	        case .lined(let config):
	            selectedTab = 1
            spacing = config.spacing
            lineWidth = config.lineWidth
            lineColor = config.color
        case .grid(let config):
            selectedTab = 2
            spacing = config.spacing
            lineWidth = config.lineWidth
            lineColor = config.color
        case .image:
            selectedTab = 3
	        case .youtube(let videoID, _):
	            selectedTab = 4
	            youtubeInputText = videoID
        case .drawing:
            selectedTab = 0
        case .plugin(let typeID, _):
            selectedTab = 5
            pluginTypeID = typeID
        }
    }

    private func setupContainer() {
        containerView.backgroundColor = .clear
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 12
        containerView.layer.shadowOpacity = 0.25
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.alpha = 0.0
        containerView.transform = CGAffineTransform(scaleX: popoverScaleHidden, y: popoverScaleHidden)
        view.addSubview(containerView)

        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = 16
        blurView.clipsToBounds = true
        blurView.layer.borderWidth = 1.0
        blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        containerView.addSubview(blurView)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: containerView.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        tintOverlayView.backgroundColor = UIColor(white: 0.0, alpha: 0.18)
        tintOverlayView.isUserInteractionEnabled = false
        tintOverlayView.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(tintOverlayView)

        glossOverlayView.backgroundColor = .clear
        glossOverlayView.isUserInteractionEnabled = false
        glossOverlayView.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(glossOverlayView)

        NSLayoutConstraint.activate([
            tintOverlayView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
            tintOverlayView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
            tintOverlayView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
            tintOverlayView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),

            glossOverlayView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
            glossOverlayView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
            glossOverlayView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
            glossOverlayView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
        ])

        glossLayer.colors = [
            UIColor.white.withAlphaComponent(0.24).cgColor,
            UIColor.white.withAlphaComponent(0.10).cgColor,
            UIColor.white.withAlphaComponent(0.00).cgColor
        ]
        glossLayer.locations = [0.0, 0.18, 0.55]
        glossLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        glossLayer.endPoint = CGPoint(x: 0.0, y: 1.0)
        glossOverlayView.layer.addSublayer(glossLayer)
    }

    private func animateInIfNeeded() {
        guard containerView.alpha == 0 else { return }
        UIView.animate(withDuration: 0.18,
                       delay: 0,
                       usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0.6,
                       options: [.curveEaseOut, .allowUserInteraction],
                       animations: { [weak self] in
                           guard let self else { return }
                           self.containerView.alpha = 1.0
                           self.containerView.transform = .identity
                       },
                       completion: nil)
    }

    private func dismissPopover(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.12,
                       delay: 0,
                       options: [.curveEaseIn, .beginFromCurrentState],
                       animations: { [weak self] in
                           guard let self else { return }
                           self.containerView.alpha = 0.0
                           self.containerView.transform = CGAffineTransform(scaleX: self.popoverScaleHidden,
                                                                            y: self.popoverScaleHidden)
                       },
                       completion: { [weak self] _ in
                           self?.dismiss(animated: false, completion: completion)
                       })
    }

    private func setupContent() {
        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.spacing = 12
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -14),
            mainStack.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -14),
            mainStack.widthAnchor.constraint(equalToConstant: 220)
        ])

        // Background colors (+ system picker)
        let buttonsPerRow = 3
        let colorGrid = UIStackView()
        colorGrid.axis = .vertical
        colorGrid.spacing = 8
        colorGrid.alignment = .center

        let totalButtons = Self.backgroundColors.count + 1
        for rowStart in stride(from: 0, to: totalButtons, by: buttonsPerRow) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center

            let rowEnd = min(rowStart + buttonsPerRow, totalButtons)
            for index in rowStart..<rowEnd {
                if index < Self.backgroundColors.count {
                    let color = Self.backgroundColors[index]
                    let button = UIButton(type: .custom)
                    button.backgroundColor = UIColor(red: CGFloat(color.x),
                                                     green: CGFloat(color.y),
                                                     blue: CGFloat(color.z),
                                                     alpha: 1.0)
                    button.layer.cornerRadius = 14
                    button.layer.borderWidth = 1
                    button.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
                    button.tag = index
                    button.addTarget(self, action: #selector(backgroundColorTapped(_:)), for: .touchUpInside)
                    button.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        button.widthAnchor.constraint(equalToConstant: 28),
                        button.heightAnchor.constraint(equalToConstant: 28)
                    ])
                    row.addArrangedSubview(button)
                } else {
                    if #available(iOS 14.0, *) {
                        let wellContainer = UIView()
                        wellContainer.translatesAutoresizingMaskIntoConstraints = false
                        wellContainer.layer.cornerRadius = 14
                        wellContainer.clipsToBounds = true
                        wellContainer.layer.borderWidth = 1
                        wellContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
                        NSLayoutConstraint.activate([
                            wellContainer.widthAnchor.constraint(equalToConstant: 28),
                            wellContainer.heightAnchor.constraint(equalToConstant: 28)
                        ])

                        let well = UIColorWell()
                        well.supportsAlpha = false
                        well.selectedColor = UIColor(red: CGFloat(card.backgroundColor.x),
                                                     green: CGFloat(card.backgroundColor.y),
                                                     blue: CGFloat(card.backgroundColor.z),
                                                     alpha: 1.0)
                        well.addTarget(self, action: #selector(backgroundColorWellChanged(_:)), for: .valueChanged)
                        well.translatesAutoresizingMaskIntoConstraints = false
                        wellContainer.addSubview(well)
                        NSLayoutConstraint.activate([
                            well.leadingAnchor.constraint(equalTo: wellContainer.leadingAnchor),
                            well.trailingAnchor.constraint(equalTo: wellContainer.trailingAnchor),
                            well.topAnchor.constraint(equalTo: wellContainer.topAnchor),
                            well.bottomAnchor.constraint(equalTo: wellContainer.bottomAnchor)
                        ])

                        backgroundColorWell = well
                        row.addArrangedSubview(wellContainer)
                    }
                }
            }

            colorGrid.addArrangedSubview(row)
        }

        mainStack.addArrangedSubview(colorGrid)

        // Type segment
        typeSegment = UISegmentedControl(items: ["Solid", "Lined", "Grid", "Image", "YouTube", "Plugin"])
        typeSegment.selectedSegmentIndex = min(selectedTab, 5)
        typeSegment.addTarget(self, action: #selector(typeChanged(_:)), for: .valueChanged)
        mainStack.addArrangedSubview(typeSegment)

        // Line settings (hidden for solid + image)
        lineSettingsStack = UIStackView()
        lineSettingsStack.axis = .vertical
        lineSettingsStack.spacing = 12
        lineSettingsStack.isHidden = !(selectedTab == 1 || selectedTab == 2)

        // Spacing
        let spacingStack = UIStackView()
        spacingStack.axis = .vertical
        spacingStack.spacing = 4
        spacingLabel = UILabel()
        spacingLabel.text = "Spacing: \(Int(spacing)) pt"
        spacingLabel.font = .systemFont(ofSize: 13)
        spacingLabel.textColor = .secondaryLabel
        spacingSlider = UISlider()
        spacingSlider.minimumValue = 1
        spacingSlider.maximumValue = 100
        spacingSlider.value = spacing
        spacingSlider.addTarget(self, action: #selector(spacingChanged(_:)), for: .valueChanged)
        spacingStack.addArrangedSubview(spacingLabel)
        spacingStack.addArrangedSubview(spacingSlider)
        lineSettingsStack.addArrangedSubview(spacingStack)

        // Line width
        let widthStack = UIStackView()
        widthStack.axis = .vertical
        widthStack.spacing = 4
        lineWidthLabel = UILabel()
        lineWidthLabel.text = "Line Width: \(String(format: "%.1f", lineWidth)) pt"
        lineWidthLabel.font = .systemFont(ofSize: 13)
        lineWidthLabel.textColor = .secondaryLabel
        lineWidthSlider = UISlider()
        lineWidthSlider.minimumValue = 0.5
        lineWidthSlider.maximumValue = 5.0
        lineWidthSlider.value = lineWidth
        lineWidthSlider.addTarget(self, action: #selector(lineWidthChanged(_:)), for: .valueChanged)
        widthStack.addArrangedSubview(lineWidthLabel)
        widthStack.addArrangedSubview(lineWidthSlider)
        lineSettingsStack.addArrangedSubview(widthStack)

        // Line color (used for Lined + Grid)
        let lineColorStack = UIStackView()
        lineColorStack.axis = .horizontal
        lineColorStack.spacing = 8
        let lineColorLabel = UILabel()
        lineColorLabel.text = "Line Color"
        lineColorLabel.font = .systemFont(ofSize: 13)
        lineColorLabel.textColor = .secondaryLabel
        lineColorStack.addArrangedSubview(lineColorLabel)
        lineColorStack.addArrangedSubview(UIView())
        if #available(iOS 14.0, *) {
            let wellContainer = UIView()
            wellContainer.translatesAutoresizingMaskIntoConstraints = false
            wellContainer.layer.cornerRadius = 14
            wellContainer.clipsToBounds = true
            wellContainer.layer.borderWidth = 1
            wellContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
            NSLayoutConstraint.activate([
                wellContainer.widthAnchor.constraint(equalToConstant: 28),
                wellContainer.heightAnchor.constraint(equalToConstant: 28)
            ])

            let well = UIColorWell()
            well.supportsAlpha = true
            well.selectedColor = UIColor(red: CGFloat(lineColor.x),
                                         green: CGFloat(lineColor.y),
                                         blue: CGFloat(lineColor.z),
                                         alpha: CGFloat(lineColor.w))
            well.addTarget(self, action: #selector(lineColorWellChanged(_:)), for: .valueChanged)
            well.translatesAutoresizingMaskIntoConstraints = false
            wellContainer.addSubview(well)
            NSLayoutConstraint.activate([
                well.leadingAnchor.constraint(equalTo: wellContainer.leadingAnchor),
                well.trailingAnchor.constraint(equalTo: wellContainer.trailingAnchor),
                well.topAnchor.constraint(equalTo: wellContainer.topAnchor),
                well.bottomAnchor.constraint(equalTo: wellContainer.bottomAnchor)
            ])

            lineColorWell = well
            lineColorStack.addArrangedSubview(wellContainer)
        }
        lineSettingsStack.addArrangedSubview(lineColorStack)

        mainStack.addArrangedSubview(lineSettingsStack)

        // Image settings (only shown for image)
        imageSettingsStack = UIStackView()
        imageSettingsStack.axis = .vertical
        imageSettingsStack.spacing = 8
        imageSettingsStack.isHidden = selectedTab != 3
        let pickImageButton = createActionButton(title: "Select Image", icon: "photo.on.rectangle", isDestructive: false) { [weak self] in
            self?.presentImagePicker()
        }
        imageSettingsStack.addArrangedSubview(pickImageButton)
        mainStack.addArrangedSubview(imageSettingsStack)

        // YouTube settings (only shown for YouTube)
        youtubeSettingsStack = UIStackView()
        youtubeSettingsStack.axis = .vertical
        youtubeSettingsStack.spacing = 8
        youtubeSettingsStack.isHidden = selectedTab != 4

        let youtubeLabel = UILabel()
        youtubeLabel.text = "YouTube Link"
        youtubeLabel.font = .systemFont(ofSize: 13)
        youtubeLabel.textColor = .secondaryLabel
        youtubeSettingsStack.addArrangedSubview(youtubeLabel)

        youtubeURLField = UITextField()
        youtubeURLField.placeholder = "Paste a YouTube URL"
        youtubeURLField.text = youtubeInputText.isEmpty ? nil : youtubeInputText
        youtubeURLField.font = .systemFont(ofSize: 13)
        youtubeURLField.textColor = .white
        youtubeURLField.tintColor = .white
        youtubeURLField.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        youtubeURLField.layer.cornerRadius = 10
        youtubeURLField.layer.masksToBounds = true
        youtubeURLField.layer.borderWidth = 1
        youtubeURLField.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        youtubeURLField.autocapitalizationType = .none
        youtubeURLField.autocorrectionType = .no
        youtubeURLField.keyboardType = .URL
        youtubeURLField.returnKeyType = .done
        youtubeURLField.clearButtonMode = .whileEditing
        youtubeURLField.delegate = self

        let padX: CGFloat = 10.0
        youtubeURLField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        youtubeURLField.leftViewMode = .always
        youtubeURLField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        youtubeURLField.rightViewMode = .always

        youtubeSettingsStack.addArrangedSubview(youtubeURLField)

        let youtubeButtons = UIStackView()
        youtubeButtons.axis = .horizontal
        youtubeButtons.spacing = 8
        youtubeButtons.distribution = .fillEqually

        let pasteButton = makeCompactButton(title: "Paste", systemImage: "doc.on.clipboard") { [weak self] in
            guard let self else { return }
            self.youtubeErrorLabel.isHidden = true
            if let text = UIPasteboard.general.string, !text.isEmpty {
                self.youtubeURLField.text = text
            }
        }

        let setButton = makeCompactButton(title: "Set", systemImage: "checkmark") { [weak self] in
            self?.applyYouTubeFromField()
        }

        youtubeButtons.addArrangedSubview(pasteButton)
        youtubeButtons.addArrangedSubview(setButton)
        youtubeSettingsStack.addArrangedSubview(youtubeButtons)

        youtubeErrorLabel = UILabel()
        youtubeErrorLabel.text = "Invalid YouTube link"
        youtubeErrorLabel.font = .systemFont(ofSize: 12)
        youtubeErrorLabel.textColor = .systemRed
        youtubeErrorLabel.numberOfLines = 0
        youtubeErrorLabel.isHidden = true
        youtubeSettingsStack.addArrangedSubview(youtubeErrorLabel)

        mainStack.addArrangedSubview(youtubeSettingsStack)

        // Plugin settings (only shown for Plugin)
        pluginSettingsStack = UIStackView()
        pluginSettingsStack.axis = .vertical
        pluginSettingsStack.spacing = 8
        pluginSettingsStack.isHidden = selectedTab != 5

        let pluginLabel = UILabel()
        pluginLabel.text = "Plugin Card"
        pluginLabel.font = .systemFont(ofSize: 13)
        pluginLabel.textColor = .secondaryLabel
        pluginSettingsStack.addArrangedSubview(pluginLabel)

        let chooseButton = makeCompactButton(title: "Choose Plugin", systemImage: "puzzlepiece") { [weak self] in
            self?.presentPluginPicker()
        }
        pluginTypeButton = chooseButton
        pluginSettingsStack.addArrangedSubview(chooseButton)

        let resetPluginStateButton = makeCompactButton(title: "Reset State", systemImage: "arrow.counterclockwise") { [weak self] in
            self?.applyPluginType(resetPayload: true)
        }
        pluginSettingsStack.addArrangedSubview(resetPluginStateButton)

        mainStack.addArrangedSubview(pluginSettingsStack)

        // Prime the plugin title from current selection.
        if let def = CardPluginRegistry.shared.definition(for: pluginTypeID) {
            pluginTypeButton.setTitle(def.name, for: .normal)
        } else if pluginTypeID.isEmpty, let first = CardPluginRegistry.shared.allDefinitions.first {
            pluginTypeID = first.typeID
            pluginTypeButton.setTitle(first.name, for: .normal)
        }

        // Opacity
        let opacityStack = UIStackView()
        opacityStack.axis = .vertical
        opacityStack.spacing = 4
        opacityLabel = UILabel()
        opacityLabel.text = "Opacity: \(Int(cardOpacity * 100))%"
        opacityLabel.font = .systemFont(ofSize: 13)
        opacityLabel.textColor = .secondaryLabel
        opacitySlider = UISlider()
        opacitySlider.minimumValue = 0
        opacitySlider.maximumValue = 1
        opacitySlider.value = cardOpacity
        opacitySlider.addTarget(self, action: #selector(opacityChanged(_:)), for: .valueChanged)
        opacityStack.addArrangedSubview(opacityLabel)
        opacityStack.addArrangedSubview(opacitySlider)
        mainStack.addArrangedSubview(opacityStack)

        // Card Names toggle (global)
        let cardNamesRow = UIStackView()
        cardNamesRow.axis = .horizontal
        cardNamesRow.alignment = .center
        cardNamesRow.distribution = .equalSpacing

        let cardNamesLabel = UILabel()
        cardNamesLabel.text = "Show Card Names"
        cardNamesLabel.font = .systemFont(ofSize: 13)
        cardNamesLabel.textColor = .secondaryLabel

        let namesSwitch = UISwitch()
        namesSwitch.isOn = cardNamesVisible
        namesSwitch.addTarget(self, action: #selector(cardNamesToggled(_:)), for: .valueChanged)
        cardNamesSwitch = namesSwitch

        cardNamesRow.addArrangedSubview(cardNamesLabel)
        cardNamesRow.addArrangedSubview(namesSwitch)
        mainStack.addArrangedSubview(cardNamesRow)

        // Shadows toggle (global)
        let shadowsRow = UIStackView()
        shadowsRow.axis = .horizontal
        shadowsRow.alignment = .center
        shadowsRow.distribution = .equalSpacing

        let shadowsLabel = UILabel()
        shadowsLabel.text = "Shadows"
        shadowsLabel.font = .systemFont(ofSize: 13)
        shadowsLabel.textColor = .secondaryLabel

        let shadowSwitch = UISwitch()
        shadowSwitch.isOn = shadowsEnabled
        shadowSwitch.addTarget(self, action: #selector(shadowsToggled(_:)), for: .valueChanged)
        shadowsSwitch = shadowSwitch

        shadowsRow.addArrangedSubview(shadowsLabel)
        shadowsRow.addArrangedSubview(shadowSwitch)
        mainStack.addArrangedSubview(shadowsRow)

        // Divider
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(divider)
        NSLayoutConstraint.activate([divider.heightAnchor.constraint(equalToConstant: 1)])

        // Lock button
        let lockButton = createActionButton(
            title: card.isLocked ? "Unlock" : "Lock",
            icon: card.isLocked ? "lock.open" : "lock",
            isDestructive: false
        ) { [weak self] in
            guard let self else { return }
            self.card.isLocked.toggle()
            if self.card.isLocked { self.card.isEditing = false }
            self.dismissPopover()
        }
        mainStack.addArrangedSubview(lockButton)

        // Delete button
        let deleteButton = createActionButton(title: "Delete", icon: "trash", isDestructive: true) { [weak self] in
            self?.dismissPopover { self?.onDelete() }
        }
        mainStack.addArrangedSubview(deleteButton)
    }

    private func createActionButton(title: String, icon: String, isDestructive: Bool, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: icon)
        config.imagePadding = 8
        config.baseForegroundColor = isDestructive ? .systemRed : .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func positionContainer() {
        let windowRect = sourceView.convert(sourceRect, to: nil)
        let anchorRect = view.convert(windowRect, from: nil)

        containerView.layoutIfNeeded()
        let containerSize = containerView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)

        let padding: CGFloat = 16
        let gap: CGFloat = 14

        let bounds = view.bounds
        let minX = bounds.minX + padding
        let maxX = bounds.maxX - padding - containerSize.width

        // Prefer the menu to the RIGHT of the finger; if it doesn't fit, fall back to the left.
        let desiredRightX = anchorRect.midX + gap
        let desiredLeftX = anchorRect.midX - gap - containerSize.width

        let fitsRight = desiredRightX <= maxX
        let fitsLeft = desiredLeftX >= minX

        let targetX: CGFloat
        if fitsRight {
            targetX = max(minX, desiredRightX)
        } else if fitsLeft {
            targetX = min(maxX, desiredLeftX)
        } else {
            targetX = max(minX, min(desiredRightX, maxX))
        }

        var targetY = anchorRect.midY - containerSize.height * 0.5
        let minY = bounds.minY + padding + 50
        let maxY = bounds.maxY - padding - containerSize.height
        targetY = max(minY, min(targetY, maxY))

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: targetX),
            containerView.topAnchor.constraint(equalTo: view.topAnchor, constant: targetY)
        ])
    }

    private func updateCardType() {
        switch selectedTab {
        case 0:
            card.type = .solidColor(card.backgroundColor)
        case 1:
            card.type = .lined(LinedBackgroundConfig(spacing: spacing, lineWidth: lineWidth, color: lineColor))
        case 2:
            card.type = .grid(LinedBackgroundConfig(spacing: spacing, lineWidth: lineWidth, color: lineColor))
        case 3:
            break
        case 4:
            break
        case 5:
            applyPluginType(resetPayload: false)
        default:
            break
        }
    }

    private func makeCompactButton(title: String, systemImage: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = UIImage(systemName: systemImage)
        config.imagePadding = 6
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.12)
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func applyYouTubeFromField() {
        youtubeURLField.resignFirstResponder()
        youtubeErrorLabel.isHidden = true

        let text = youtubeURLField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let info = parseYouTubeVideoInfo(from: text) else {
            youtubeErrorLabel.isHidden = false
            return
        }

        let videoID = info.videoID
        let aspect = info.aspectRatio

        var shouldClearThumbnail = true
        if case .youtube(let existingID, _) = card.type, existingID == videoID {
            shouldClearThumbnail = false
        }

        card.type = .youtube(videoID: videoID, aspectRatio: aspect)

        if shouldClearThumbnail {
            card.youtubeThumbnailTexture = nil
            card.youtubeThumbnailVideoID = nil
        }

        if aspect.isFinite, aspect > 0 {
            let newHeight = card.size.x / aspect
            if newHeight.isFinite, newHeight > 0 {
                card.size.y = newHeight
            }
        }
        card.rebuildGeometry()

        fetchYouTubeThumbnail(videoID: videoID)
    }

    private func applyPluginType(resetPayload: Bool) {
        let defs = CardPluginRegistry.shared.allDefinitions
        if pluginTypeID.isEmpty, let first = defs.first {
            pluginTypeID = first.typeID
        }

        guard !pluginTypeID.isEmpty else {
            pluginTypeButton?.setTitle("Choose Plugin", for: .normal)
            return
        }

        let payload: Data = {
            if resetPayload {
                return CardPluginRegistry.shared.definition(for: pluginTypeID)?.defaultPayload ?? Data()
            }
            if case .plugin(let existingTypeID, let existingPayload) = card.type,
               existingTypeID == pluginTypeID {
                return existingPayload
            }
            return CardPluginRegistry.shared.definition(for: pluginTypeID)?.defaultPayload ?? Data()
        }()

        card.pluginSnapshotTexture = nil
        card.type = .plugin(typeID: pluginTypeID, payload: payload)

        if let def = CardPluginRegistry.shared.definition(for: pluginTypeID) {
            pluginTypeButton?.setTitle(def.name, for: .normal)
        } else {
            pluginTypeButton?.setTitle("Choose Plugin", for: .normal)
        }
    }

    private func presentPluginPicker() {
        let defs = CardPluginRegistry.shared.allDefinitions
        let alert = UIAlertController(title: "Choose Plugin", message: nil, preferredStyle: .actionSheet)

        if defs.isEmpty {
            alert.addAction(UIAlertAction(title: "No plugins installed", style: .default))
        } else {
            for def in defs {
                alert.addAction(UIAlertAction(title: def.name, style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.pluginTypeID = def.typeID
                    self.applyPluginType(resetPayload: true)
                    let activate = self.onActivatePlugin
                    DispatchQueue.main.async { [weak self] in
                        self?.dismissPopover {
                            activate?()
                        }
                    }
                })
            }
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let pop = alert.popoverPresentationController {
            pop.sourceView = pluginTypeButton
            pop.sourceRect = pluginTypeButton?.bounds ?? .zero
        }

        present(alert, animated: true)
    }

    private func parseYouTubeVideoInfo(from input: String) -> (videoID: String, aspectRatio: Double)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let raw = trimmed

        // Allow pasting a bare video ID.
        if !raw.contains("://"),
           raw.range(of: #"^[A-Za-z0-9_-]{6,}$"#, options: .regularExpression) != nil {
            return (videoID: raw, aspectRatio: 16.0 / 9.0)
        }

        guard let url = URL(string: raw) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let host = (components.host ?? "").lowercased()
        let path = components.path

        // https://www.youtube.com/watch?v=VIDEOID
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
               !v.isEmpty {
                return (videoID: v, aspectRatio: 16.0 / 9.0)
            }
        }

        // https://youtu.be/VIDEOID
        if host.contains("youtu.be") {
            let parts = path.split(separator: "/")
            if let first = parts.first, !first.isEmpty {
                return (videoID: String(first), aspectRatio: 16.0 / 9.0)
            }
        }

        // https://www.youtube.com/embed/VIDEOID
        if let range = path.range(of: "/embed/") {
            let rest = path[range.upperBound...]
            let parts = rest.split(separator: "/")
            if let first = parts.first, !first.isEmpty {
                return (videoID: String(first), aspectRatio: 16.0 / 9.0)
            }
        }

        // https://www.youtube.com/shorts/VIDEOID
        if let range = path.range(of: "/shorts/") {
            let rest = path[range.upperBound...]
            let parts = rest.split(separator: "/")
            if let first = parts.first, !first.isEmpty {
                return (videoID: String(first), aspectRatio: 9.0 / 16.0)
            }
        }

        return nil
    }

    private func fetchYouTubeThumbnail(videoID: String) {
        guard !videoID.isEmpty else { return }

        let urlString = "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, let image = UIImage(data: data), let cgImg = image.cgImage else { return }
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            let loader = MTKTextureLoader(device: device)

            let texture: MTLTexture?
            do {
                texture = try loader.newTexture(
                    cgImage: cgImg,
                    options: [
                        .origin: MTKTextureLoader.Origin.bottomLeft,
                        .SRGB: false
                    ]
                )
            } catch {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard case .youtube(let currentID, _) = self.card.type, currentID == videoID else { return }
                self.card.youtubeThumbnailTexture = texture
                self.card.youtubeThumbnailVideoID = videoID
            }
        }.resume()
    }

    private func applySelectedImage(_ image: UIImage) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let loader = MTKTextureLoader(device: device)

        guard let cgImg = image.cgImage else { return }

        do {
            let texture = try loader.newTexture(
                cgImage: cgImg,
                options: [
                    .origin: MTKTextureLoader.Origin.bottomLeft,
                    .SRGB: false
                ]
            )

            card.type = .image(texture)

            // Resize card to match image aspect ratio.
            let aspect = Double(image.size.width / image.size.height)
            if aspect.isFinite, aspect > 0 {
                let newHeight = card.size.x / aspect
                if newHeight.isFinite, newHeight > 0 {
                    card.size.y = newHeight
                }
            }
            card.rebuildGeometry()
        } catch {
            print("Failed to load image texture: \(error)")
        }
    }

    private func presentImagePicker() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func backgroundColorTapped(_ sender: UIButton) {
        let color = Self.backgroundColors[sender.tag]
        card.backgroundColor = color
        if case .solidColor = card.type {
            card.type = .solidColor(color)
        }

        if #available(iOS 14.0, *) {
            backgroundColorWell?.selectedColor = UIColor(red: CGFloat(color.x),
                                                        green: CGFloat(color.y),
                                                        blue: CGFloat(color.z),
                                                        alpha: 1.0)
        }
    }

    private func simdColor(from color: UIColor) -> SIMD4<Float> {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let resolved = color.resolvedColor(with: traitCollection)
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    @available(iOS 14.0, *)
    @objc private func backgroundColorWellChanged(_ sender: UIColorWell) {
        guard let selected = sender.selectedColor else { return }
        let simd = simdColor(from: selected)
        card.backgroundColor = SIMD4<Float>(simd.x, simd.y, simd.z, 1.0)
        if case .solidColor = card.type {
            card.type = .solidColor(card.backgroundColor)
        }
    }

    @available(iOS 14.0, *)
    @objc private func lineColorWellChanged(_ sender: UIColorWell) {
        guard let selected = sender.selectedColor else { return }
        lineColor = simdColor(from: selected)
        updateCardType()
    }

    @objc private func typeChanged(_ sender: UISegmentedControl) {
        selectedTab = sender.selectedSegmentIndex
        lineSettingsStack.isHidden = !(selectedTab == 1 || selectedTab == 2)
        imageSettingsStack.isHidden = selectedTab != 3
        youtubeSettingsStack.isHidden = selectedTab != 4
        pluginSettingsStack.isHidden = selectedTab != 5
        if selectedTab == 4, case .youtube = card.type {
            // Keep existing YouTube card state.
        } else if selectedTab == 4 {
            card.type = .youtube(videoID: "", aspectRatio: 16.0 / 9.0)
            card.rebuildGeometry()
        }
        updateCardType()
    }

    @objc private func spacingChanged(_ sender: UISlider) {
        spacing = sender.value
        spacingLabel.text = "Spacing: \(Int(spacing)) pt"
        updateCardType()
    }

    @objc private func lineWidthChanged(_ sender: UISlider) {
        lineWidth = sender.value
        lineWidthLabel.text = "Line Width: \(String(format: "%.1f", lineWidth)) pt"
        updateCardType()
    }

    @objc private func opacityChanged(_ sender: UISlider) {
        cardOpacity = sender.value
        opacityLabel.text = "Opacity: \(Int(cardOpacity * 100))%"
        card.opacity = cardOpacity
    }

    @objc private func shadowsToggled(_ sender: UISwitch) {
        shadowsEnabled = sender.isOn
        onToggleShadows(sender.isOn)
    }

    @objc private func cardNamesToggled(_ sender: UISwitch) {
        cardNamesVisible = sender.isOn
        onToggleCardNames(sender.isOn)
    }

    @objc private func dismissMenu() {
        dismissPopover()
    }
}

extension CardSettingsFloatingMenu: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: containerView)
        return !containerView.bounds.contains(location)
    }
}

extension CardSettingsFloatingMenu: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === youtubeURLField {
            applyYouTubeFromField()
            return false
        }
        return true
    }
}

extension CardSettingsFloatingMenu: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let itemProvider = results.first?.itemProvider else { return }
        guard itemProvider.canLoadObject(ofClass: UIImage.self) else { return }

        itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage else { return }
            DispatchQueue.main.async {
                self.applySelectedImage(image)
            }
        }
    }
}
