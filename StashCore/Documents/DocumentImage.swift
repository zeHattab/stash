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

    /// Пиксельный прямоугольник нижней полосы (где MRZ) — чистая функция, тестируется.
    public static func bottomBandRect(_ pixelSize: CGSize, fraction: CGFloat) -> CGRect {
        let f = min(max(fraction, 0.05), 1)
        let h = (pixelSize.height * f).rounded()
        return CGRect(x: 0, y: pixelSize.height - h, width: pixelSize.width, height: h)
    }

    /// Нижняя полоса страницы (MRZ), увеличенная в `scale` раз — мелкий текст читается лучше.
    public static func cropBottom(_ image: UIImage, fraction: CGFloat = 0.22, scale: CGFloat = 2.5) -> UIImage? {
        let norm = normalized(image)
        let rect = bottomBandRect(norm.pixelSize, fraction: fraction)
        guard let cg = norm.image.cgImage?.cropping(to: rect) else { return nil }
        let base = UIImage(cgImage: cg)
        let target = CGSize(width: (CGFloat(cg.width) * scale).rounded(),
                            height: (CGFloat(cg.height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// JPEG нормализованного изображения.
    public static func jpeg(_ image: UIImage, maxSide: CGFloat = 2500, quality: CGFloat = 0.8) -> (data: Data, pixelSize: CGSize)? {
        let norm = normalized(image, maxSide: maxSide)
        guard let data = norm.image.jpegData(compressionQuality: quality) else { return nil }
        return (data, norm.pixelSize)
    }
}
#endif
