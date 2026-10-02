import Foundation

#if canImport(UIKit)
import UIKit

/// Нормализация изображения скана: ориентация → .up, уменьшение ДЛИННОЙ стороны до
/// `maxSide` пикселей (без апскейла), JPEG. Одна и та же картинка идёт и во вложение,
/// и в OCR. Раньше рендер шёл с экранным scale (×3) — получался раздутый/мусорный
/// битмап; здесь scale = 1, то есть 1 pt == 1 px.
public enum DocumentImage {

    /// Размер в пикселях после уменьшения длинной стороны до maxSide. Меньшие — без изменений.
    public static func targetPixelSize(_ pixelSize: CGSize, maxSide: CGFloat) -> CGSize {
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > maxSide, longest > 0 else { return pixelSize }
        let k = maxSide / longest
        return CGSize(width: (pixelSize.width * k).rounded(),
                      height: (pixelSize.height * k).rounded())
    }

    /// Истинный размер изображения в пикселях (с учётом scale).
    public static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// Нормализованная копия: ориентация .up, длинная сторона ≤ maxSide, scale = 1.
    public static func normalized(_ image: UIImage, maxSide: CGFloat = 2500) -> (image: UIImage, pixelSize: CGSize) {
        let target = targetPixelSize(pixelSize(of: image), maxSide: maxSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // 1 pt == 1 px, без домножения на экранный scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            // draw(in:) рисует с учётом imageOrientation → результат уже .up
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return (rendered, target)
    }

    /// JPEG нормализованного изображения.
    public static func jpeg(_ image: UIImage, maxSide: CGFloat = 2500, quality: CGFloat = 0.8) -> (data: Data, pixelSize: CGSize)? {
        let norm = normalized(image, maxSide: maxSide)
        guard let data = norm.image.jpegData(compressionQuality: quality) else { return nil }
        return (data, norm.pixelSize)
    }
}
#endif
