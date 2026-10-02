import Foundation

/// Фрагмент текста с геометрией (нормализованные координаты Vision: начало в левом
/// НИЖНЕМ углу, оси 0…1). Одна строка MRZ часто приходит несколькими наблюдениями —
/// Vision рвёт её на сериях «<<<<».
public struct MRZFragment: Sendable, Equatable {
    public var text: String
    public var minX: Double
    public var maxX: Double
    public var minY: Double
    public var maxY: Double
    public init(text: String, minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.text = text; self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
    }
}

/// Склейка фрагментов по геометрии: группировка по вертикали (близкий центр Y),
/// сортировка слева направо. Возвращает КУСКИ каждой строки в порядке слева направо —
/// промежутки (всегда заполнители '<') достраивает уже парсер, зная точную длину формата
/// (так не нужно угадывать число '<' по ширине — это ломало выравнивание).
public enum MRZLineAssembler {

    public static func assemble(_ fragments: [MRZFragment]) -> (rows: [[String]], joins: Int) {
        let frags = fragments.filter { !$0.text.isEmpty }
        guard !frags.isEmpty else { return ([], 0) }

        let heights = frags.map { $0.maxY - $0.minY }.sorted()
        let medianH = heights[heights.count / 2]
        let tol = max(medianH * 0.6, 0.004)

        // Кластеризуем по центру Y (сверху вниз — по убыванию Y).
        var clusters: [[MRZFragment]] = []
        for f in frags.sorted(by: { ($0.minY + $0.maxY) > ($1.minY + $1.maxY) }) {
            let cy = (f.minY + f.maxY) / 2
            if let idx = clusters.firstIndex(where: { cl in
                let ccy = cl.map { ($0.minY + $0.maxY) / 2 }.reduce(0, +) / Double(cl.count)
                return abs(ccy - cy) <= tol
            }) {
                clusters[idx].append(f)
            } else {
                clusters.append([f])
            }
        }

        var rows: [[String]] = []
        var joins = 0
        for cluster in clusters {
            let sorted = cluster.sorted { $0.minX < $1.minX }
            if sorted.count > 1 { joins += sorted.count - 1 }
            rows.append(sorted.map(\.text))
        }
        return (rows, joins)
    }
}
