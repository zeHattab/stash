import SwiftUI
import StashCore

/// Аватар без сети: первая буква на цветном круге; цвет детерминирован от seed.
struct Avatar: View {
    let title: String
    let seed: String

    private var letter: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return String(trimmed.first.map(String.init) ?? "•").uppercased()
    }

    private var color: Color {
        var hash: UInt64 = 5381
        for scalar in seed.unicodeScalars { hash = (hash &* 33) &+ UInt64(scalar.value) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.78)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 38, height: 38)
            .overlay(Text(letter).font(.headline).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

struct ItemRow: View {
    let item: VaultItem

    private var subtitle: String {
        switch item.kind {
        case let .login(username, _, urls, _):
            if !username.isEmpty { return username }
            if let first = urls.first, let d = VaultSearch.domain(from: first) { return d }
            return "Логин"
        case .secureNote:
            return "Заметка"
        case .document:
            return "Документ"
        }
    }

    private var seed: String {
        if case let .login(_, _, urls, _) = item.kind, let first = urls.first,
           let d = VaultSearch.domain(from: first) {
            return d
        }
        return item.title.isEmpty ? "stash" : item.title
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(title: item.title.isEmpty ? subtitle : item.title, seed: seed)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? subtitle : item.title)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.favorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .accessibilityLabel("В избранном")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
