import Foundation

/// Голосование по символам между кадрами живого считывания: для самой частой длины строки
/// берём в каждой позиции самый частый символ. Сводит шум OCR разных кадров к одной строке.
public enum MRZVote {
    public static func consensus(_ lines: [String]) -> String? {
        let cleaned = lines.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        // Доминирующая длина.
        var byLength: [Int: [String]] = [:]
        for l in cleaned { byLength[l.count, default: []].append(l) }
        guard let group = byLength.max(by: { $0.value.count < $1.value.count })?.value else { return nil }
        let n = group[0].count
        guard n > 0 else { return nil }
        let arrays = group.map(Array.init)
        var result: [Character] = []
        for i in 0..<n {
            var counts: [Character: Int] = [:]
            for a in arrays { counts[a[i], default: 0] += 1 }
            // При равенстве предпочитаем не-'<' (значимый символ важнее заполнителя).
            let best = counts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key == "<" && rhs.key != "<"
            }
            if let ch = best?.key { result.append(ch) }
        }
        return String(result)
    }
}
