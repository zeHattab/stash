import Foundation

/// Сопоставление домена запроса автозаполнения с адресами записи.
/// Совпадение — по границе метки домена: accounts.google.com ↔ google.com, но НЕ
/// evilgoogle.com ↔ google.com. Публичный суффикс-лист не используем (его нет офлайн),
/// поэтому берём строгое правило «тот же хост или его поддомен».
public enum DomainMatch {

    /// Хост из строки сервис-идентификатора или сохранённого адреса.
    public static func host(from string: String) -> String? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let withScheme = s.contains("://") ? s : "https://\(s)"
        if let url = URLComponents(string: withScheme), let host = url.host, !host.isEmpty {
            return strip(host)
        }
        // На случай «голого» хоста без валидного URL.
        let bare = s.split(separator: "/").first.map(String.init) ?? s
        return bare.isEmpty ? nil : strip(bare)
    }

    private static func strip(_ host: String) -> String {
        var h = host
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Хост запроса относится к тому же сайту, что и сохранённый (равен или поддомен).
    public static func hostsMatch(request: String, stored: String) -> Bool {
        let r = strip(request.lowercased()), s = strip(stored.lowercased())
        guard !r.isEmpty, !s.isEmpty else { return false }
        if r == s { return true }
        return r.hasSuffix("." + s) || s.hasSuffix("." + r)
    }

    /// Совпадает ли сервис-идентификатор запроса с любым из адресов записи.
    public static func matches(serviceIdentifier: String, urls: [String]) -> Bool {
        guard let reqHost = host(from: serviceIdentifier) else { return false }
        for u in urls {
            if let h = host(from: u), hostsMatch(request: reqHost, stored: h) { return true }
        }
        return false
    }
}
