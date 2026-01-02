import UIKit

// MARK: - Add URL Link Popover

final class AddLinkFloatingMenuViewController: UIViewController {

    private let initialText: String?
    private let onAdd: (String) -> Void
    private let onDismiss: () -> Void
    private let sourceRect: CGRect
    private let sourceView: UIView

    private let containerView = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let tintOverlayView = UIView()
    private let glossOverlayView = UIView()
    private let glossLayer = CAGradientLayer()

    private var leadingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?

    private let popoverScaleHidden: CGFloat = 0.96
    private var didNotifyDismiss = false

    private var keyboardFrameInView: CGRect = .null

    private let textField = UITextField()

    init(initialText: String?,
         onAdd: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void,
         sourceRect: CGRect,
         sourceView: UIView) {
        self.initialText = initialText
        self.onAdd = onAdd
        self.onDismiss = onDismiss
        self.sourceRect = sourceRect
        self.sourceView = sourceView
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification,
                                               object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateInIfNeeded()
        textField.becomeFirstResponder()
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

    private func setupContent() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -14)
        ])

        let title = UILabel()
        title.text = "Add Link"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        stack.addArrangedSubview(title)

        textField.borderStyle = .none
        textField.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        textField.layer.cornerRadius = 10
        textField.layer.masksToBounds = true
        textField.textColor = .white
        textField.tintColor = .white
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .done
        textField.clearButtonMode = .whileEditing
        textField.placeholder = "https://example.com"
        textField.text = initialText

        let padX: CGFloat = 10.0
        let leftPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        let rightPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        textField.leftView = leftPad
        textField.leftViewMode = .always
        textField.rightView = rightPad
        textField.rightViewMode = .always
        textField.delegate = self

        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textField.heightAnchor.constraint(equalToConstant: 40)
        ])
        stack.addArrangedSubview(textField)

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.alignment = .fill
        buttons.distribution = .fillEqually

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cancel.setTitleColor(.white.withAlphaComponent(0.92), for: .normal)
        cancel.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        cancel.layer.cornerRadius = 10
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let add = UIButton(type: .system)
        add.setTitle("Add", for: .normal)
        add.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        add.setTitleColor(.black, for: .normal)
        add.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.92)
        add.layer.cornerRadius = 10
        add.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(add)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 260)
        ])
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
        onDismiss()
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

        let keyboardTopY: CGFloat = {
            guard !keyboardFrameInView.isNull, keyboardFrameInView.height > 0 else { return bounds.maxY }
            return keyboardFrameInView.minY
        }()

        let minY = bounds.minY + padding
        let maxY = min(bounds.maxY - padding, keyboardTopY - padding) - containerSize.height
        let unclampedY = anchorRect.midY - containerSize.height * 0.5
        let targetY = max(minY, min(unclampedY, maxY))

        if leadingConstraint == nil || topConstraint == nil {
            let leading = containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: targetX)
            let top = containerView.topAnchor.constraint(equalTo: view.topAnchor, constant: targetY)
            NSLayoutConstraint.activate([leading, top])
            leadingConstraint = leading
            topConstraint = top
        } else {
            leadingConstraint?.constant = targetX
            topConstraint?.constant = targetY
        }
    }

    @objc private func dismissMenu() {
        dismissPopover()
    }

    @objc private func cancelTapped() {
        dismissPopover()
    }

    @objc private func addTapped() {
        let raw = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            dismissPopover()
            return
        }

        let normalized: String = {
            if raw.contains("://") { return raw }
            return "https://\(raw)"
        }()

        dismissPopover { [onAdd] in
            onAdd(normalized)
        }
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        let inView = view.convert(endFrame, from: nil)
        keyboardFrameInView = inView
        positionContainer()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardFrameInView = .null
        positionContainer()
    }
}

extension AddLinkFloatingMenuViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: containerView)
        return !containerView.bounds.contains(location)
    }
}

extension AddLinkFloatingMenuViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        addTapped()
        return false
    }
}

// MARK: - Internal Link Picker Popover

final class InternalLinkPickerFloatingMenuViewController: UIViewController {
    private let allDestinations: [CanvasLinkDestination]
    private var filteredDestinations: [CanvasLinkDestination]
    private let onSelect: (CanvasLinkDestination) -> Void
    private let onDismiss: () -> Void
    private let sourceRect: CGRect
    private let sourceView: UIView

    private let containerView = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let tintOverlayView = UIView()
    private let glossOverlayView = UIView()
    private let glossLayer = CAGradientLayer()

    private var leadingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?

    private let popoverScaleHidden: CGFloat = 0.96
    private var didNotifyDismiss = false

    private var keyboardFrameInView: CGRect = .null

    private let searchField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var tableHeightConstraint: NSLayoutConstraint?

    init(destinations: [CanvasLinkDestination],
         onSelect: @escaping (CanvasLinkDestination) -> Void,
         onDismiss: @escaping () -> Void,
         sourceRect: CGRect,
         sourceView: UIView) {
        let sorted = destinations.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        self.allDestinations = sorted
        self.filteredDestinations = sorted
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self.sourceRect = sourceRect
        self.sourceView = sourceView
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification,
                                               object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateInIfNeeded()
        searchField.becomeFirstResponder()
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

    private func setupContent() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -14)
        ])

        let title = UILabel()
        title.text = "Link"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        stack.addArrangedSubview(title)

        searchField.borderStyle = .none
        searchField.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        searchField.layer.cornerRadius = 10
        searchField.layer.masksToBounds = true
        searchField.textColor = .white
        searchField.tintColor = .white
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .done
        searchField.clearButtonMode = .whileEditing
        searchField.placeholder = "Search sections or cards"

        let padX: CGFloat = 10.0
        let leftPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        let rightPad = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        searchField.leftView = leftPad
        searchField.leftViewMode = .always
        searchField.rightView = rightPad
        searchField.rightViewMode = .always
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.delegate = self

        searchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchField.heightAnchor.constraint(equalToConstant: 36)
        ])
        stack.addArrangedSubview(searchField)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.12)
        tableView.rowHeight = 44
        tableView.keyboardDismissMode = .onDrag
        tableView.layer.cornerRadius = 12
        tableView.clipsToBounds = true
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }

        tableView.translatesAutoresizingMaskIntoConstraints = false
        let tableHeight = min(CGFloat(allDestinations.count) * tableView.rowHeight, 280)
        let heightConstraint = tableView.heightAnchor.constraint(equalToConstant: max(120, tableHeight))
        heightConstraint.isActive = true
        tableHeightConstraint = heightConstraint
        stack.addArrangedSubview(tableView)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cancel.setTitleColor(.white.withAlphaComponent(0.92), for: .normal)
        cancel.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        cancel.layer.cornerRadius = 10
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        stack.addArrangedSubview(cancel)

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 280),
            cancel.heightAnchor.constraint(equalToConstant: 40)
        ])
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
        onDismiss()
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

        let keyboardTopY: CGFloat = {
            guard !keyboardFrameInView.isNull, keyboardFrameInView.height > 0 else { return bounds.maxY }
            return keyboardFrameInView.minY
        }()

        let minY = bounds.minY + padding
        let maxY = min(bounds.maxY - padding, keyboardTopY - padding) - containerSize.height
        let unclampedY = anchorRect.midY - containerSize.height * 0.5
        let targetY = max(minY, min(unclampedY, maxY))

        if leadingConstraint == nil || topConstraint == nil {
            let leading = containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: targetX)
            let top = containerView.topAnchor.constraint(equalTo: view.topAnchor, constant: targetY)
            NSLayoutConstraint.activate([leading, top])
            leadingConstraint = leading
            topConstraint = top
        } else {
            leadingConstraint?.constant = targetX
            topConstraint?.constant = targetY
        }
    }

    @objc private func dismissMenu() {
        dismissPopover()
    }

    @objc private func cancelTapped() {
        dismissPopover()
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardFrameInView = view.convert(endFrame, from: nil)
        positionContainer()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardFrameInView = .null
        positionContainer()
    }

    @objc private func searchChanged() {
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredDestinations = allDestinations
        } else {
            filteredDestinations = allDestinations.filter { dest in
                dest.name.localizedCaseInsensitiveContains(query)
            }
        }

        if let heightConstraint = tableHeightConstraint {
            let targetHeight = min(CGFloat(filteredDestinations.count) * tableView.rowHeight, 280)
            heightConstraint.constant = max(120, targetHeight)
        }

        tableView.reloadData()
        positionContainer()
    }
}

extension InternalLinkPickerFloatingMenuViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: containerView)
        return !containerView.bounds.contains(location)
    }
}

extension InternalLinkPickerFloatingMenuViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
}

extension InternalLinkPickerFloatingMenuViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredDestinations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "InternalLinkCell")
        cell.backgroundColor = UIColor(white: 0.0, alpha: 0.18)

        let item = filteredDestinations[indexPath.row]
        cell.textLabel?.text = item.name.isEmpty ? "Untitled" : item.name
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cell.detailTextLabel?.text = item.kind == .section ? "Section" : "Card"
        cell.detailTextLabel?.textColor = UIColor.white.withAlphaComponent(0.6)
        cell.detailTextLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        cell.accessoryType = .disclosureIndicator
        cell.tintColor = UIColor.white.withAlphaComponent(0.55)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = filteredDestinations[indexPath.row]
        dismissPopover { [onSelect] in
            onSelect(item)
        }
    }
}
