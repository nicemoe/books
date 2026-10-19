import SwiftUI
import UIKit
import CoreText

/// 一页的行级排版。
///
/// 吃的是 PageSource 已经切好的页范围和同一份属性串，所以滚动模式里的
/// 每一行，和翻页模式那一页的每一行，逐行一致——不是两套排版，
/// 是一套排版两种呈现。
@MainActor
final class PageLayout {

    private(set) var totalHeight: CGFloat = 0

    private var lines: [CTLine] = []
    /// 每行顶部 y（自上而下）、基线到顶的距离、水平偏移、覆盖的字符范围
    private var lineTops: [CGFloat] = []
    private var lineAscents: [CGFloat] = []
    private var lineLefts: [CGFloat] = []
    private var lineRanges: [NSRange] = []

    init(attributed: NSAttributedString, width: CGFloat) {
        guard attributed.length > 0, width > 1 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        // 不要用 greatestFiniteMagnitude，CoreText 对它的处理不稳定
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: 1_000_000), nil)
        let height = ceil(suggested.height) + 2
        totalHeight = height

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        guard let ctLines = CTFrameGetLines(frame) as? [CTLine], !ctLines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        lines = ctLines
        for (i, line) in ctLines.enumerated() {
            var ascent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, nil, nil)
            lineAscents.append(ascent)
            // CoreText 原点在左下、y 轴向上，换算成自上而下的坐标
            lineTops.append(height - origins[i].y - ascent)
            lineLefts.append(origins[i].x)
            let r = CTLineGetStringRange(line)
            lineRanges.append(NSRange(location: r.location, length: r.length))
        }
    }

    /// ctx 已经翻成 y 轴向上，originY 是这段文字顶部在格子里的自上而下坐标
    func draw(in ctx: CGContext, originY: CGFloat, canvasHeight: CGFloat, x: CGFloat) {
        for (i, line) in lines.enumerated() {
            let baseline = originY + lineTops[i] + lineAscents[i]
            ctx.textPosition = CGPoint(x: x + lineLefts[i], y: canvasHeight - baseline)
            CTLineDraw(line, ctx)
        }
    }

    /// 顶部停在 y 时，对应本页内的第几个字
    func characterOffset(atY y: CGFloat) -> Int {
        guard !lineTops.isEmpty else { return 0 }
        var result = 0
        for (i, top) in lineTops.enumerated() {
            if top <= y + 1 { result = lineRanges[i].location } else { break }
        }
        return result
    }

    /// 本页内的某个字应该落在哪个 y
    func y(forCharacterOffset offset: Int) -> CGFloat {
        guard !lineTops.isEmpty else { return 0 }
        for (i, range) in lineRanges.enumerated() where offset < range.location + range.length {
            return lineTops[i]
        }
        return lineTops[lineTops.count - 1]
    }
}

/// 列表里的一格 = 翻页模式的一页
@MainActor
private struct PageItem {
    let chapter: Int
    let page: Int
    /// 本页在本章正文里的字符范围
    let range: NSRange
    let body: PageLayout
    /// 本章第一页在上方多留一截，让章首有点喘息
    let isChapterStart: Bool

    /// 章首上方的留白、页与页之间的间距
    static let titlePad: CGFloat = 28
    static let pageGap: CGFloat = 2

    /// 章节标题不再单独画一层。
    ///
    /// 标题现在是正文的第一行（见 ParsedChapter.text）——从目录点进来要能
    /// 看见自己在第几章，翻页模式那边也只能靠正文里的这一行。既然正文里
    /// 已经有了，这儿再画一遍就是重了。
    var bodyTop: CGFloat { isChapterStart ? Self.titlePad : 0 }

    var height: CGFloat { bodyTop + body.totalHeight + Self.pageGap }
}

private final class PageCell: UICollectionViewCell {

    static let reuseID = "page"

    fileprivate var item: PageItem? {
        didSet { setNeedsDisplay() }
    }
    var textX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let item, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        item.body.draw(in: ctx, originY: item.bodyTop,
                       canvasHeight: bounds.height, x: textX)
    }
}

/// 跨章连续滚动阅读。
///
/// 每一格就是翻页模式的一页，所以格子最高不过一屏——
/// 交给 UICollectionView 回收就行，不用自己管哪些该画、哪些该丢。
final class ChapterScrollContainer: UIView, UICollectionViewDataSource,
                                    UICollectionViewDelegateFlowLayout {

    var source: PageSource?
    var chapterTitles: [String] = []
    var settings = ReaderSettings()
    var textColor: UIColor = .label
    var chromeVisible = false

    /// 位置变了（章号，章内字符偏移）
    var onPositionChange: ((Int, Int) -> Void)?
    var onToggleChrome: (() -> Void)?
    /// 自动滚到全书末尾了
    var onReachEnd: (() -> Void)?

    /// 自动滚动。匀速往上推，不是一页页跳。
    var isAutoScrolling = false {
        didSet {
            guard isAutoScrolling != oldValue else { return }
            if isAutoScrolling { startAutoScroll() } else { stopAutoScroll() }
        }
    }
    /// 走完一屏用几秒，和翻页模式共用同一个设置
    var autoScrollInterval: Double = 8

    private let collectionView: UICollectionView
    private var items: [PageItem] = []
    /// items 里每一格的顶部，前缀和。改动 items 后重算。
    private var tops: [CGFloat] = []

    /// 想停在哪。宽度还没下来、排不了版的时候也先记着，等能排了再落实。
    private var desired = (chapter: 0, offset: 0)
    /// 程序改滚动位置时不要把它又当成用户滚动报回去
    private var isRestoring = false
    private var lastWidth: CGFloat = 0
    private var lastReported = (chapter: -1, offset: -1)
    private var reportedChapter = -1

    /// 最多留几章，再多就把离得远的那头丢掉
    private let maxChapters = 4

    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// 上次把位置报出去的时刻。自动滚动时每帧都报的话，
    /// SwiftIU 每帧重算一次 body，会明显掉帧。
    private var lastReportTime: CFTimeInterval = 0

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)

        collectionView.backgroundColor = .clear
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PageCell.self, forCellWithReuseIdentifier: PageCell.reuseID)
        addSubview(collectionView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
        guard bounds.width > 1, abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        // 必须照 desired 排。这里不能问「当前位置」——
        // 首次布局时一格都还没有，只会答「第 0 章第 0 字」，
        // 把外面要求跳转的位置吃掉。
        reflow()
    }

    // MARK: 装载

    /// 正文宽度直接取分页时用的那个，保证和翻页模式逐行一致
    private var textWidth: CGFloat {
        let width = source?.pageSize.width ?? 0
        return width > 1 ? width : max(1, bounds.width - CGFloat(settings.margin) * 2)
    }

    private var textX: CGFloat { max(0, (bounds.width - textWidth) / 2) }

    private func makeItems(chapter: Int) -> [PageItem] {
        guard let source, chapter >= 0, chapter < chapterTitles.count else { return [] }
        guard let full = source.attributed(chapter) else { return [] }
        let ranges = source.pages(chapter)
        let width = textWidth

        return ranges.enumerated().compactMap { index, range in
            guard range.location + range.length <= full.length else { return nil }
            return PageItem(chapter: chapter,
                            page: index,
                            range: range,
                            body: PageLayout(attributed: full.attributedSubstring(from: range),
                                             width: width),
                            isChapterStart: index == 0)
        }
    }

    /// 跳到某一章的某个字符。此刻排不了版也没关系，位置先记下。
    func rebuild(chapter: Int, offset: Int) {
        desired = (chapter, offset)
        reflow()
    }

    /// 照 desired 重新装载。宽度、字号、主题变了都走这里，位置不会丢。
    func reflow() {
        guard bounds.width > 1, source != nil, !chapterTitles.isEmpty else { return }
        items = makeItems(chapter: desired.chapter)
        fillForward()
        restack()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        applyDesired()
    }

    /// 往后多装几章，直到内容够高。
    ///
    /// 不能只等 scrollViewDidScroll 去装——序章那种短章排完还不到一屏，
    /// UICollectionView 压根滚不动，滚动事件一次都不会来，
    /// 于是永远装不上下一章，卡在那章里出不去。
    private func fillForward() {
        var height = items.reduce(0) { $0 + $1.height }
        var chapter = items.last?.chapter ?? desired.chapter
        var added = 0
        while height < bounds.height * 2.2, chapter + 1 < chapterTitles.count, added < 20 {
            let next = makeItems(chapter: chapter + 1)
            guard !next.isEmpty else { break }
            items.append(contentsOf: next)
            height += next.reduce(0) { $0 + $1.height }
            chapter += 1
            added += 1
        }
    }

    private func restack() {
        tops = []
        tops.reserveCapacity(items.count)
        var y: CGFloat = 0
        for item in items {
            tops.append(y)
            y += item.height
        }
    }

    private var contentHeight: CGFloat {
        guard let last = tops.last, let item = items.last else { return 0 }
        return last + item.height
    }

    // MARK: 位置换算

    private func itemIndex(atY y: CGFloat) -> Int {
        guard !tops.isEmpty else { return 0 }
        var result = 0
        for (i, top) in tops.enumerated() {
            if top <= y + 1 { result = i } else { break }
        }
        return result
    }

    private func currentPosition() -> (chapter: Int, offset: Int) {
        guard !items.isEmpty else { return desired }
        let y = collectionView.contentOffset.y
        let index = itemIndex(atY: y)
        let item = items[index]
        let local = y - tops[index] - item.bodyTop
        // 页内偏移 + 本页在章里的起点 = 章内偏移
        return (item.chapter, item.range.location + item.body.characterOffset(atY: max(0, local)))
    }

    private func applyDesired() {
        guard !items.isEmpty else { return }
        // 找到包含目标字符的那一页
        let index = items.lastIndex(where: {
            $0.chapter == desired.chapter && $0.range.location <= desired.offset
        }) ?? items.firstIndex(where: { $0.chapter == desired.chapter })
        guard let index else { return }

        let item = items[index]
        let inPage = max(0, desired.offset - item.range.location)
        let y = tops[index] + item.bodyTop + item.body.y(forCharacterOffset: inPage)

        isRestoring = true
        let maxY = max(0, contentHeight - bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(max(0, y), maxY)), animated: false)
        isRestoring = false
        report()
    }

    // MARK: 数据源

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageCell.reuseID,
                                                      for: indexPath)
        if let cell = cell as? PageCell, items.indices.contains(indexPath.item) {
            cell.textX = textX
            cell.item = items[indexPath.item]
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard items.indices.contains(indexPath.item) else { return .zero }
        return CGSize(width: bounds.width, height: items[indexPath.item].height)
    }

    // MARK: 滚动

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isRestoring else { return }
        extendIfNeeded()
        report()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { report(force: true) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        report(force: true)
    }

    private func report(force: Bool = false) {
        guard !items.isEmpty else { return }
        let pos = currentPosition()
        guard pos.chapter != lastReported.chapter || pos.offset != lastReported.offset else { return }
        desired = pos          // 用户滚到哪，重排时就回哪

        // 往外报会让 SwiftUI 重算一次 body。自动滚动时每帧都报的话
        // 一秒六十次，明显掉帧。换章要立刻报，其余的限到每秒四次。
        let now = CACurrentMediaTime()
        let changedChapter = pos.chapter != reportedChapter
        guard force || changedChapter || now - lastReportTime > 0.25 else { return }
        lastReported = pos
        lastReportTime = now
        reportedChapter = pos.chapter
        onPositionChange?(pos.chapter, pos.offset)
    }

    /// 快读到头就把下一章接上，往回滚就把上一章补上
    private func extendIfNeeded() {
        guard let first = items.first, let last = items.last else { return }
        let y = collectionView.contentOffset.y
        let lookahead = bounds.height * 1.5

        if y + bounds.height > contentHeight - lookahead, last.chapter + 1 < chapterTitles.count {
            let next = makeItems(chapter: last.chapter + 1)
            guard !next.isEmpty else { return }
            let anchor = currentPosition()
            items.append(contentsOf: next)
            // 只往后加的话前面没动，滚动位置不用碰——
            // 这时候去 setContentOffset 会把正在减速的滚动硬生生刹停
            let dropped = dropChapter(farthestFrom: anchor.chapter, fromFront: true)
            commit(restoringTo: dropped ? anchor : nil)
            return
        }

        if y < lookahead, first.chapter > 0 {
            let prev = makeItems(chapter: first.chapter - 1)
            guard !prev.isEmpty else { return }
            let anchor = currentPosition()
            items.insert(contentsOf: prev, at: 0)
            _ = dropChapter(farthestFrom: anchor.chapter, fromFront: false)
            // 前面插了一章，原来看的那格整体往下移了，必须补回去
            commit(restoringTo: anchor)
        }
    }

    /// 章节留太多就丢掉离得最远的那头。返回是否真的丢了。
    @discardableResult
    private func dropChapter(farthestFrom current: Int, fromFront: Bool) -> Bool {
        let chapters = Set(items.map(\.chapter))
        guard chapters.count > maxChapters else { return false }
        guard let drop = fromFront ? chapters.min() : chapters.max(),
              drop != current else { return false }   // 正在读的那章绝不能丢
        items.removeAll { $0.chapter == drop }
        return true
    }

    /// items 改完后落位。anchor 为 nil 表示前面没动，不要去碰滚动位置。
    private func commit(restoringTo anchor: (chapter: Int, offset: Int)?) {
        restack()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        guard let anchor,
              let index = items.lastIndex(where: {
                  $0.chapter == anchor.chapter && $0.range.location <= anchor.offset
              }) else { return }

        let item = items[index]
        let inPage = max(0, anchor.offset - item.range.location)
        isRestoring = true
        collectionView.setContentOffset(
            CGPoint(x: 0, y: max(0, tops[index] + item.bodyTop + item.body.y(forCharacterOffset: inPage))),
            animated: false)
        isRestoring = false
    }

    // MARK: 自动滚动

    private func startAutoScroll() {
        stopAutoScroll()
        lastTick = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard bounds.height > 1, !items.isEmpty else { return }
        // 手指还在屏幕上就先让开，松手接着走
        guard !collectionView.isTracking, !collectionView.isDragging else {
            lastTick = 0
            return
        }
        // 第一帧只记时间。用固定步长会随刷新率变速——
        // 120Hz 的机器上会正好快一倍。
        guard lastTick > 0 else {
            lastTick = link.timestamp
            return
        }
        let elapsed = link.timestamp - lastTick
        lastTick = link.timestamp

        let speed = bounds.height / CGFloat(max(1, autoScrollInterval))   // 每秒走多少点
        let maxY = max(0, contentHeight - bounds.height)
        let y = collectionView.contentOffset.y + speed * CGFloat(elapsed)

        let atLastChapter = items.last?.chapter == chapterTitles.count - 1
        if y >= maxY, atLastChapter {
            collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            report(force: true)
            isAutoScrolling = false
            onReachEnd?()
            return
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: min(y, maxY)), animated: false)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // 工具栏亮着时点哪儿都只收起它，和翻页模式一致
        if chromeVisible { onToggleChrome?(); return }
        let x = gesture.location(in: self).x
        let third = bounds.width / 3
        if x > third && x < third * 2 { onToggleChrome?() }
    }
}

// MARK: - SwiftUI 包装

/// 外部要求跳到某个位置。token 保证「跳到同一处」也能再触发一次。
struct ScrollJump: Equatable {
    var chapter: Int
    var offset: Int
    var token: Int
}

struct ChapterScrollReader: UIViewRepresentable {

    let source: PageSource
    let chapterTitles: [String]
    let settings: ReaderSettings
    let textColor: UIColor
    let chromeVisible: Bool
    let revision: Int
    let jump: ScrollJump
    let autoScrolling: Bool
    let autoScrollInterval: Double
    var onPositionChange: (Int, Int) -> Void
    var onToggleChrome: () -> Void
    var onReachEnd: () -> Void

    func makeUIView(context: Context) -> ChapterScrollContainer {
        let view = ChapterScrollContainer()
        configure(view)
        context.coordinator.appliedRevision = revision
        context.coordinator.appliedJump = jump
        view.rebuild(chapter: jump.chapter, offset: jump.offset)
        return view
    }

    func updateUIView(_ view: ChapterScrollContainer, context: Context) {
        configure(view)

        // 目录、搜索、书签、切模式过来的跳转
        if context.coordinator.appliedJump != jump {
            context.coordinator.appliedJump = jump
            view.rebuild(chapter: jump.chapter, offset: jump.offset)
            return
        }

        // 排版变了（字号/行距/主题/字体）：原地重排，位置由容器自己守着
        if context.coordinator.appliedRevision != revision {
            context.coordinator.appliedRevision = revision
            view.reflow()
        }
    }

    private func configure(_ view: ChapterScrollContainer) {
        view.source = source
        view.chapterTitles = chapterTitles
        view.settings = settings
        view.textColor = textColor
        view.chromeVisible = chromeVisible
        view.onToggleChrome = onToggleChrome
        view.onPositionChange = onPositionChange
        view.onReachEnd = onReachEnd
        view.autoScrollInterval = autoScrollInterval
        view.isAutoScrolling = autoScrolling
    }

    /// CADisplayLink 会持有 target，视图被拆掉时不停就永远释放不了
    static func dismantleUIView(_ view: ChapterScrollContainer, coordinator: Coordinator) {
        view.isAutoScrolling = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedRevision = -1
        var appliedJump = ScrollJump(chapter: -1, offset: -1, token: -1)
    }
}
