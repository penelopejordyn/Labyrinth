import UIKit

final class LayersFloatingMenuViewController: UIViewController {
    private weak var coordinator: Coordinator?
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

    private var allItems: [CanvasZItem] = []
    private var filteredItems: [CanvasZItem] = []
    private var cardNameByID: [UUID: String] = [:]
    private var cardHiddenByID: [UUID: Bool] = [:]
    private var renamingLayerID: UUID?

    private let titleLabel = UILabel()
    private let addLayerButton = UIButton(type: .system)
    private let searchField = UITextField()
    private let hitTestAllLayersSwitch = UISwitch()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var tableHeightConstraint: NSLayoutConstraint?

    init(coordinator: Coordinator,
         onDismiss: @escaping () -> Void,
         sourceRect: CGRect,
         sourceView: UIView) {
        self.coordinator = coordinator
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
        reloadFromCoordinator()
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -14)
        ])

        let header = UIStackView()
        header.axis = .horizontal
        header.spacing = 10
        header.alignment = .center

        titleLabel.text = "Layers"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white.withAlphaComponent(0.92)
        header.addArrangedSubview(titleLabel)

        header.addArrangedSubview(UIView())

        addLayerButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addLayerButton.tintColor = .white.withAlphaComponent(0.92)
        addLayerButton.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        addLayerButton.layer.cornerRadius = 10
        addLayerButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        addLayerButton.addTarget(self, action: #selector(addLayerTapped), for: .touchUpInside)
        header.addArrangedSubview(addLayerButton)

        stack.addArrangedSubview(header)

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
        searchField.placeholder = "Search layers or cards"

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

        let hitTestContainer = UIView()
        hitTestContainer.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        hitTestContainer.layer.cornerRadius = 10
        hitTestContainer.layer.masksToBounds = true
        hitTestContainer.translatesAutoresizingMaskIntoConstraints = false

        let hitTestRow = UIStackView()
        hitTestRow.axis = .horizontal
        hitTestRow.spacing = 10
        hitTestRow.alignment = .center
        hitTestRow.translatesAutoresizingMaskIntoConstraints = false
        hitTestContainer.addSubview(hitTestRow)

        NSLayoutConstraint.activate([
            hitTestRow.topAnchor.constraint(equalTo: hitTestContainer.topAnchor, constant: 6),
            hitTestRow.leadingAnchor.constraint(equalTo: hitTestContainer.leadingAnchor, constant: 10),
            hitTestRow.trailingAnchor.constraint(equalTo: hitTestContainer.trailingAnchor, constant: -10),
            hitTestRow.bottomAnchor.constraint(equalTo: hitTestContainer.bottomAnchor, constant: -6),
            hitTestContainer.heightAnchor.constraint(equalToConstant: 36)
        ])

        let hitTestLabel = UILabel()
        hitTestLabel.text = "Hit test all layers"
        hitTestLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hitTestLabel.textColor = .white.withAlphaComponent(0.92)
        hitTestRow.addArrangedSubview(hitTestLabel)
        hitTestRow.addArrangedSubview(UIView())

        hitTestAllLayersSwitch.onTintColor = UIColor.systemGreen.withAlphaComponent(0.90)
        hitTestAllLayersSwitch.addTarget(self, action: #selector(hitTestAllLayersChanged(_:)), for: .valueChanged)
        hitTestAllLayersSwitch.isOn = coordinator?.brushSettings.hitTestAllLayers ?? false
        hitTestRow.addArrangedSubview(hitTestAllLayersSwitch)

        stack.addArrangedSubview(hitTestContainer)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.12)
        tableView.rowHeight = 44
        tableView.keyboardDismissMode = .onDrag
        tableView.layer.cornerRadius = 12
        tableView.clipsToBounds = true
        tableView.allowsSelection = true
        tableView.allowsSelectionDuringEditing = true
        tableView.register(LayersMenuItemCell.self, forCellReuseIdentifier: LayersMenuItemCell.reuseIdentifier)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = tableView.heightAnchor.constraint(equalToConstant: 200)
        heightConstraint.isActive = true
        tableHeightConstraint = heightConstraint
        stack.addArrangedSubview(tableView)

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 280)
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
        view.endEditing(true)
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

    private func updateTableHeight() {
        let count = filteredItems.count
        let desired = min(CGFloat(count) * tableView.rowHeight, 320)
        tableHeightConstraint?.constant = max(120, desired)
    }

    private func reloadFromCoordinator() {
        guard let coordinator else { return }

        coordinator.normalizeZOrder()

        hitTestAllLayersSwitch.isOn = coordinator.brushSettings.hitTestAllLayers
        allItems = coordinator.zOrder

        cardNameByID.removeAll(keepingCapacity: true)
        cardHiddenByID.removeAll(keepingCapacity: true)
        func walk(_ frame: Frame) {
            for card in frame.cards {
                cardNameByID[card.id] = card.name
                cardHiddenByID[card.id] = card.isHidden
            }
            for child in frame.children.values {
                walk(child)
            }
        }
        walk(coordinator.rootFrame)

        applySearchFilter()
    }

    private func name(for item: CanvasZItem) -> String {
        guard let coordinator else { return "" }
        switch item {
        case .layer(let id):
            return coordinator.layers.first(where: { $0.id == id })?.name ?? "Layer"
        case .card(let id):
            return cardNameByID[id] ?? "Card"
        }
    }

    private func applySearchFilter() {
        let text = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            filteredItems = allItems
            tableView.isEditing = true
        } else {
            filteredItems = allItems.filter { item in
                name(for: item).localizedCaseInsensitiveContains(text)
            }
            tableView.isEditing = false
        }

        if renamingLayerID != nil,
           let id = renamingLayerID,
           !filteredItems.contains(.layer(id)) {
            renamingLayerID = nil
        }

        updateTableHeight()
        tableView.reloadData()
        positionContainer()
    }

    private func commitRenameLayerIfNeeded(_ layerID: UUID, newName: String) {
        guard let coordinator else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? (coordinator.layers.first(where: { $0.id == layerID })?.name ?? "Layer") : trimmed
        coordinator.renameLayer(id: layerID, to: finalName)
        renamingLayerID = nil
        reloadFromCoordinator()
    }

    @objc private func searchChanged() {
        applySearchFilter()
    }

    @objc private func addLayerTapped() {
        coordinator?.addLayer()
        renamingLayerID = nil
        reloadFromCoordinator()
    }

    @objc private func hitTestAllLayersChanged(_ sender: UISwitch) {
        coordinator?.brushSettings.hitTestAllLayers = sender.isOn
    }

    @objc private func dismissMenu() {
        dismissPopover()
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frame = frameValue.cgRectValue
        keyboardFrameInView = view.convert(frame, from: nil)
        positionContainer()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardFrameInView = .null
        positionContainer()
    }
}

// MARK: - UITableView

extension LayersFloatingMenuViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: LayersMenuItemCell.reuseIdentifier,
                                                       for: indexPath) as? LayersMenuItemCell else {
            return UITableViewCell()
        }

        let item = filteredItems[indexPath.row]
        let isRenaming = {
            if case .layer(let id) = item {
                return id == renamingLayerID
            }
            return false
        }()

        let selectedLayerID = coordinator?.selectedLayerID
        let isSelectedLayer: Bool = {
            guard case .layer(let id) = item else { return false }
            return selectedLayerID == id
        }()

        let isLayer: Bool = {
            if case .layer = item { return true }
            return false
        }()

        let isCard: Bool = {
            if case .card = item { return true }
            return false
        }()

        let isHiddenLayer: Bool = {
            guard isLayer else { return false }
            guard case .layer(let id) = item else { return false }
            return coordinator?.layers.first(where: { $0.id == id })?.isHidden ?? false
        }()

        let isHiddenCard: Bool = {
            guard isCard else { return false }
            guard case .card(let id) = item else { return false }
            return cardHiddenByID[id] ?? false
        }()

        cell.configure(title: name(for: item),
                       iconName: isLayer ? "square.3.layers.3d" : "rectangle.fill",
                       showsSelection: isLayer,
                       isSelected: isSelectedLayer,
                       isRenaming: isRenaming,
                       showsVisibilityToggle: isLayer || isCard,
                       isHidden: isLayer ? isHiddenLayer : isHiddenCard)

        cell.onRenameCommit = { [weak self] text in
            guard let self else { return }
            guard case .layer(let id) = item else { return }
            self.commitRenameLayerIfNeeded(id, newName: text)
        }

        cell.onVisibilityToggle = { [weak self] in
            guard let self else { return }
            guard let coordinator = self.coordinator else { return }
            switch item {
            case .layer(let id):
                coordinator.toggleLayerHidden(id: id)
            case .card(let id):
                coordinator.toggleCardHidden(id: id)
            }
            self.reloadFromCoordinator()
        }

        if isRenaming {
            DispatchQueue.main.async {
                cell.beginRenaming()
            }
        }

        let searchText = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        cell.showsReorderControl = searchText.isEmpty
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let coordinator else { return }

        let item = filteredItems[indexPath.row]
        switch item {
        case .layer(let id):
            if renamingLayerID == id {
                return
            }
            coordinator.selectLayer(id: id)
            reloadFromCoordinator()
        case .card:
            break
        }
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        let text = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard let coordinator else { return }
        coordinator.moveZOrderItem(from: sourceIndexPath.row, to: destinationIndexPath.row)
        reloadFromCoordinator()
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let coordinator else { return nil }
        let item = filteredItems[indexPath.row]
        guard case .layer(let layerID) = item else { return nil }

        let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            self.renamingLayerID = layerID
            self.applySearchFilter()
            completion(true)
        }
        rename.backgroundColor = .systemBlue

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            if coordinator.layers.count <= 1 {
                completion(false)
                return
            }
            coordinator.deleteLayer(id: layerID)
            self.renamingLayerID = nil
            self.reloadFromCoordinator()
            completion(true)
        }

        let config = UISwipeActionsConfiguration(actions: [delete, rename])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard let coordinator else { return nil }
        let item = filteredItems[indexPath.row]
        guard case .layer(let layerID) = item else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let rename = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in
                guard let self else { return }
                self.renamingLayerID = layerID
                self.applySearchFilter()
            }

            let delete = UIAction(title: "Delete",
                                  image: UIImage(systemName: "trash"),
                                  attributes: coordinator.layers.count <= 1 ? [.disabled] : [.destructive]) { _ in
                guard let self else { return }
                guard coordinator.layers.count > 1 else { return }
                coordinator.deleteLayer(id: layerID)
                self.renamingLayerID = nil
                self.reloadFromCoordinator()
            }

            return UIMenu(title: "", children: [rename, delete])
        }
    }
}

extension LayersFloatingMenuViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: containerView)
        return !containerView.bounds.contains(location)
    }
}

extension LayersFloatingMenuViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
}

private final class LayersMenuItemCell: UITableViewCell, UITextFieldDelegate {
    static let reuseIdentifier = "LayersMenuItemCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let renameField = UITextField()
    private let selectedView = UIImageView()
    private let visibilityButton = UIButton(type: .system)
    private var titleTrailingToContentConstraint: NSLayoutConstraint?
    private var titleTrailingToVisibilityConstraint: NSLayoutConstraint?
    private var renameTrailingToContentConstraint: NSLayoutConstraint?
    private var renameTrailingToVisibilityConstraint: NSLayoutConstraint?
    private var didCommit = false

    var onRenameCommit: ((String) -> Void)?
    var onVisibilityToggle: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        backgroundColor = UIColor(white: 1.0, alpha: 0.02)
        contentView.backgroundColor = .clear
        selectionStyle = .none
        // Ensure we don't accidentally display the default `UITableViewCell` content.
        textLabel?.text = nil
        detailTextLabel?.text = nil
        textLabel?.isHidden = true
        detailTextLabel?.isHidden = true
        imageView?.image = nil
        imageView?.isHidden = true

        iconView.tintColor = .white.withAlphaComponent(0.9)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        selectedView.tintColor = UIColor.systemYellow.withAlphaComponent(0.95)
        selectedView.contentMode = .scaleAspectFit
        selectedView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white.withAlphaComponent(0.92)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        renameField.font = titleLabel.font
        renameField.textColor = titleLabel.textColor
        renameField.tintColor = .white
        renameField.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        renameField.layer.cornerRadius = 8
        renameField.layer.masksToBounds = true
        renameField.borderStyle = .none
        renameField.returnKeyType = .done
        renameField.clearButtonMode = .whileEditing
        renameField.autocapitalizationType = .sentences
        renameField.autocorrectionType = .default
        renameField.isHidden = true
        renameField.delegate = self
        renameField.translatesAutoresizingMaskIntoConstraints = false

        let padX: CGFloat = 8.0
        renameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        renameField.leftViewMode = .always
        renameField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: padX, height: 1))
        renameField.rightViewMode = .always

        visibilityButton.tintColor = .white.withAlphaComponent(0.92)
        visibilityButton.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        visibilityButton.layer.cornerRadius = 10
        visibilityButton.layer.masksToBounds = true
        visibilityButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        visibilityButton.addTarget(self, action: #selector(visibilityTapped), for: .touchUpInside)
        visibilityButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(selectedView)
        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(renameField)
        contentView.addSubview(visibilityButton)

        let titleTrailingToContent = titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
        let titleTrailingToVisibility = titleLabel.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -10)
        titleTrailingToContent.isActive = true
        titleTrailingToContentConstraint = titleTrailingToContent
        titleTrailingToVisibilityConstraint = titleTrailingToVisibility

        let renameTrailingToContent = renameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
        let renameTrailingToVisibility = renameField.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -10)
        renameTrailingToContent.isActive = true
        renameTrailingToContentConstraint = renameTrailingToContent
        renameTrailingToVisibilityConstraint = renameTrailingToVisibility

        NSLayoutConstraint.activate([
            selectedView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            selectedView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            selectedView.widthAnchor.constraint(equalToConstant: 16),
            selectedView.heightAnchor.constraint(equalToConstant: 16),

            iconView.leadingAnchor.constraint(equalTo: selectedView.trailingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            renameField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            renameField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            renameField.heightAnchor.constraint(equalToConstant: 34),

            visibilityButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            visibilityButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            visibilityButton.heightAnchor.constraint(equalToConstant: 28),
            visibilityButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRenameCommit = nil
        onVisibilityToggle = nil
        didCommit = false
        renameField.resignFirstResponder()
    }

    func configure(title: String,
                   iconName: String,
                   showsSelection: Bool,
                   isSelected: Bool,
                   isRenaming: Bool,
                   showsVisibilityToggle: Bool,
                   isHidden: Bool) {
        iconView.image = UIImage(systemName: iconName)
        titleLabel.text = title

        if showsSelection {
            selectedView.isHidden = false
            selectedView.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        } else {
            selectedView.isHidden = true
            selectedView.image = nil
        }

        visibilityButton.isHidden = !showsVisibilityToggle || isRenaming
        if showsVisibilityToggle && !isRenaming {
            visibilityButton.setImage(UIImage(systemName: isHidden ? "eye.slash" : "eye"), for: .normal)
            titleTrailingToContentConstraint?.isActive = false
            renameTrailingToContentConstraint?.isActive = false
            titleTrailingToVisibilityConstraint?.isActive = true
            renameTrailingToVisibilityConstraint?.isActive = true
        } else {
            titleTrailingToVisibilityConstraint?.isActive = false
            renameTrailingToVisibilityConstraint?.isActive = false
            titleTrailingToContentConstraint?.isActive = true
            renameTrailingToContentConstraint?.isActive = true
        }

        titleLabel.isHidden = isRenaming
        renameField.isHidden = !isRenaming
        if isRenaming {
            renameField.text = title
        } else {
            renameField.text = nil
        }
    }

    @objc private func visibilityTapped() {
        onVisibilityToggle?()
    }

    func beginRenaming() {
        didCommit = false
        renameField.becomeFirstResponder()
        renameField.selectAll(nil)
    }

    private func commitIfNeeded() {
        guard !didCommit else { return }
        didCommit = true
        onRenameCommit?(renameField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commitIfNeeded()
        textField.resignFirstResponder()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        commitIfNeeded()
    }
}
