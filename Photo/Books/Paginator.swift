import UIKit
import CoreText
import SwiftUI

/// 章节正文 → 属性字符串。分页和渲染必须用同一份属性，否则行高差一点就会截字。
enum ReaderTypesetter {

    static func attributedText(_ text: String, settings: ReaderSettings, color: UIColor) -> NSAttributedString {
        let font = settings.font.uiFont(size: settings.fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = settings.lineSpacing
        paragraph.paragraphSpacing = settings.lineSpacing * 0.8
        paragraph.lineBreakMode = .byWordWrapping
        // 中文两端对齐更像纸书，但要允许标点压缩，否则会出现大片空隙
        paragraph.alignment = .justified
        paragraph.hyphenationFactor = 0

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: 0.2
        ])
    }
}

/// 按可视区域把一章切成若干页
enum Paginator {

    /// 返回每一页在字符串里的范围
    static func pageRanges(for attributed: NSAttributedString, size: CGSize) -> [NSRange] {
        pageRanges(for: attributed, size: size, from: 0, upTo: attributed.length)
    }

    /// 从 start 开始往后切页，切到 limit（不含）为止。
    /// 滚动切回翻页时用它把「当前这一行」变成新的页首。
    static func pageRanges(for attributed: NSAttributedString, size: CGSize,
                           from start: Int, upTo limit: Int) -> [NSRange] {
        let end = min(limit, attributed.length)
        guard attributed.length > 0, size.width > 1, size.height > 1,
              start >= 0, start < end else { return [] }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)

        var ranges: [NSRange] = []
        var location = start

        while location < end {
            let frame = CTFramesetterCreateFrame(framesetter,
                                                 CFRange(location: location, length: 0),
                                                 path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            // 一个字都放不下（比如容器太窄）就停下，避免死循环
            guard visible.length > 0 else { break }

            let length = min(visible.length, end - location)
            ranges.append(NSRange(location: location, length: length))
            location += length
        }

        return ranges
    }

    /// 字符偏移落在第几页——恢复进度时用
    static func pageIndex(containing offset: Int, in ranges: [NSRange]) -> Int {
        guard !ranges.isEmpty else { return 0 }
        for (i, range) in ranges.enumerated() where offset < range.location + range.length {
            return i
        }
        return ranges.count - 1
    }
}

// MARK: - CoreText 渲染

/// 用 CoreText 画一页。和 Paginator 同一个引擎，保证分到哪就画到哪。
final class CoreTextPageView: UIView {

    var attributed: NSAttributedString? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let attributed, attributed.length > 0,
              let context = UIGraphicsGetCurrentContext() else { return }

        // CoreText 的坐标系原点在左下，要翻过来
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }
}

struct CoreTextPage: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> CoreTextPageView {
        let view = CoreTextPageView()
        view.attributed = attributed
        return view
    }

    func updateUIView(_ view: CoreTextPageView, context: Context) {
        view.attributed = attributed
    }
}
