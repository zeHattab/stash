import Foundation

/// Поиск по записям — в памяти, регистронезависимо, без учёта ё/е и диакритики.
public enum VaultSearch {

    /// Нормализация: нижний регистр, сворачивание диакритики, ё → е.
    public static func normalize(_ string: String) -> String {
        let folded = string.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                    locale: Locale(identifier: "ru_RU"))
        return folded
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "е")
            .lowercased()
    }

    /// Домен (host без www) из строки URL.
    public static func domain(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: withScheme)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Строки, по которым ищем для данной записи.
    static func searchableStrings(_ item: VaultItem) -> [String] {
        var parts = [item.title, item.notes]
        switch item.kind {
        case let .login(username, _, urls, _):
            parts.append(username)
            for url in urls {
                parts.append(url)
                if let d = domain(from: url) { parts.append(d) }
            }
        case .secureNote:
            break
        case let .document(_, fields, _, _):
            parts.append(contentsOf: fields.values)
        }
        return parts
    }

    public static func matches(_ item: VaultItem, query: String) -> Bool {
        let q = normalize(query)
        guard !q.isEmpty else { return true }
        return searchableStrings(item).contains { normalize($0).contains(q) }
    }

    public static func filter(_ items: [VaultItem], query: String) -> [VaultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { matches($0, query: q) }
    }
}
