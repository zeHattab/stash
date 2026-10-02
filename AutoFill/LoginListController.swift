import UIKit
import StashCore

/// Список логинов в расширении: сначала подходящие к домену запроса, затем остальные.
final class LoginListController: UIViewController {

    private let matching: [AutoFillLogin]
    private let others: [AutoFillLogin]
    private let onSelect: (AutoFillLogin) -> Void
    private let onCancel: () -> Void
    private let table = UITableView(frame: .zero, style: .insetGrouped)

    init(logins: [AutoFillLogin], serviceIdentifier: String?,
         mode: CredentialProviderMode,
         onSelect: @escaping (AutoFillLogin) -> Void, onCancel: @escaping () -> Void) {
        let usable = (mode == .oneTimeCode) ? logins.filter { $0.totpSecret != nil } : logins
        if let sid = serviceIdentifier, !sid.isEmpty {
            let m = usable.filter { $0.matches(serviceIdentifier: sid) }
            matching = m
            let ids = Set(m.map(\.id))
            others = usable.filter { !ids.contains($0.id) }
        } else {
            matching = []
            others = usable
        }
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Stash"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    @objc private func cancelTapped() { onCancel() }

    private func sections() -> [(title: String?, rows: [AutoFillLogin])] {
        var s: [(String?, [AutoFillLogin])] = []
        if !matching.isEmpty { s.append((String(localized: "На этом сайте"), matching)) }
        if !others.isEmpty { s.append((matching.isEmpty ? nil : String(localized: "Остальные"), others)) }
        if s.isEmpty { s.append((nil, [])) }
        return s.map { (title: $0.0, rows: $0.1) }
    }
}

extension LoginListController: @preconcurrency UITableViewDataSource, @preconcurrency UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { sections().count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections()[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections()[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let login = sections()[indexPath.section].rows[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = login.title.isEmpty ? login.username : login.title
        config.secondaryText = login.username
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let login = sections()[indexPath.section].rows[indexPath.row]
        onSelect(login)
    }
}
