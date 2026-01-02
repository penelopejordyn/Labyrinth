import UIKit

struct CanvasLinkDestination: Hashable {
    enum Kind: String {
        case section
        case card
    }

    let kind: Kind
    let id: UUID
    let name: String
}

final class LinkDestinationPickerViewController: UITableViewController {
    private let allDestinations: [CanvasLinkDestination]
    private var filteredDestinations: [CanvasLinkDestination]
    private let onSelect: (CanvasLinkDestination) -> Void
    private let onCancel: (() -> Void)?
    private var didComplete: Bool = false

    private let searchController = UISearchController(searchResultsController: nil)

    init(destinations: [CanvasLinkDestination],
         onSelect: @escaping (CanvasLinkDestination) -> Void,
         onCancel: (() -> Void)? = nil) {
        let sorted = destinations.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        self.allDestinations = sorted
        self.filteredDestinations = sorted
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Link"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search sections or cards"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        tableView.keyboardDismissMode = .onDrag
    }

    @objc private func cancelTapped() {
        guard !didComplete else {
            dismiss(animated: true)
            return
        }
        didComplete = true
        onCancel?()
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredDestinations.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "LinkDestinationCell")
        let item = filteredDestinations[indexPath.row]
        cell.textLabel?.text = item.name.isEmpty ? "Untitled" : item.name
        cell.detailTextLabel?.text = item.kind == .section ? "Section" : "Card"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = filteredDestinations[indexPath.row]
        didComplete = true
        dismiss(animated: true) { [onSelect] in
            onSelect(item)
        }
    }
}

extension LinkDestinationPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            filteredDestinations = allDestinations
        } else {
            filteredDestinations = allDestinations.filter { dest in
                dest.name.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.reloadData()
    }
}

extension LinkDestinationPickerViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !didComplete else { return }
        didComplete = true
        onCancel?()
    }
}
