import SwiftUI
import UIKit

/// 一页的位置：第几章的第几页
struct PageLocator: Hashable {
    var chapter: Int
    var page: Int
}

/// 分页数据源。
///
/// UIPageViewController 随时会问「上一页/下一页是什么」，而分页是按章算的，
/// 跨章时得临时把相邻章加载并分页。这里做缓存，避免来回翻页反复读盘重排。
@MainActor
final class PageSource {

    let bookID: UUID
    let chapters: [ChapterMeta]
    private let library: BookLibrary

    var settings: ReaderSettings
    var textColor: UIColor
    /// 正文可用区域（已扣掉页边距）
    var pageSize: CGSize

    private var recentChapters: [Int] = []
    private(set) var failure: Error?

    private var textCache: [Int: String] = [:]
    private var attributedCache: [Int: NSAttributedString] = [:]
    private var pagesCache: [Int: [NSRange]] = [:]

    init(bookID: UUID, chapters: [ChapterMeta], library: BookLibrary,
         settings: ReaderSettings, textColor: UIColor, pageSize: CGSize) {
        self.bookID = bookID
        self.chapters = chapters
        self.library = library
        self.settings = settings
        self.textColor = textColor
        self.pageSize = pageSize
    }

    /// 字号、行距、字体、页面尺寸变了都要整体重排
    func invalidate(settings: ReaderSettings, textColor: UIColor, pageSize: CGSize) {
        self.settings = settings
        self.textColor = textColor
        self.pageSize = pageSize
        attributedCache.removeAll()
        pagesCache.removeAll()
    }

    private func touch(_ chapter: Int) {
        recentChapters.removeAll { $0 == chapter }
        recentChapters.append(chapter)
        if recentChapters.count > 6 {
            let oldest = recentChapters.removeFirst()
            textCache.removeValue(forKey: oldest)
            attributedCache.removeValue(forKey: oldest)
            pagesCache.removeValue(forKey: oldest)
        }
    }

    func text(_ chapter: Int) -> String? {
        guard failure == nil else { return nil }
        touch(chapter)
        if let hit = textCache[chapter] { return hit }
        do {
            let value = try library.chapterText(bookID: bookID, index: chapter)
            textCache[chapter] = value
            return value
        } catch {
            failure = error
            Task { @MainActor [library] in library.operationError = "无法读取正文：\(error.localizedDescription)" }
            return nil
        }
    }

    func attributed(_ chapter: Int) -> NSAttributedString? {
        touch(chapter)
        if let hit = attributedCache[chapter] { return hit }
        guard let text = text(chapter) else { return nil }
        let value = ReaderTypesetter.attributedText(text, settings: settings, color: textColor)
        attributedCache[chapter] = value
        return value
    }

    func pages(_ chapter: Int) -> [NSRange] {
        touch(chapter)
        if let hit = pagesCache[chapter] { return hit }
        guard let attributed = attributed(chapter) else { return [] }
        let value = Paginator.pageRanges(for: attributed, size: pageSize)
        pagesCache[chapter] = value
        return value
    }

    func pageCount(_ chapter: Int) -> Int { pages(chapter).count }

    /// 以某个字符为页首重排本章。
    ///
    /// 从滚动切回翻页时用：页边界本来是从章首固定切好的，
    /// 你正看的那一行多半在某页中部，直接落过去等于往回跳了半页。
    /// 把它顶成新的一页第一行，切换才是无损的。
    func anchor(chapter: Int, at offset: Int) {
        guard let full = attributed(chapter) else { return }
        guard offset > 0, offset < full.length else { return }
        let head = Paginator.pageRanges(for: full, size: pageSize, from: 0, upTo: offset)
        let tail = Paginator.pageRanges(for: full, size: pageSize, from: offset, upTo: full.length)
        guard !tail.isEmpty else { return }
        pagesCache[chapter] = head + tail
    }

    func attributed(at locator: PageLocator) -> NSAttributedString? {
        let ranges = pages(locator.chapter)
        guard ranges.indices.contains(locator.page) else { return nil }
        guard let full = attributed(locator.chapter) else { return nil }
        let range = ranges[locator.page]
        guard range.location + range.length <= full.length else { return nil }
        return full.attributedSubstring(from: range)
    }

    /// 章内偏移 → 页码
    func locator(chapter: Int, offset: Int) -> PageLocator {
        PageLocator(chapter: chapter, page: Paginator.pageIndex(containing: offset, in: pages(chapter)))
    }

    func characterOffset(of locator: PageLocator) -> Int {
        let ranges = pages(locator.chapter)
        guard ranges.indices.contains(locator.page) else { return 0 }
        return ranges[locator.page].location
    }

    func next(_ locator: PageLocator) -> PageLocator? {
        if locator.page + 1 < pageCount(locator.chapter) {
            return PageLocator(chapter: locator.chapter, page: locator.page + 1)
        }
        let nextChapter = locator.chapter + 1
        guard chapters.indices.contains(nextChapter), pageCount(nextChapter) > 0 else { return nil }
        return PageLocator(chapter: nextChapter, page: 0)
    }

    func previous(_ locator: PageLocator) -> PageLocator? {
        if locator.page > 0 {
            return PageLocator(chapter: locator.chapter, page: locator.page - 1)
        }
        let prevChapter = locator.chapter - 1
        guard chapters.indices.contains(prevChapter) else { return nil }
        let count = pageCount(prevChapter)
        guard count > 0 else { return nil }
        return PageLocator(chapter: prevChapter, page: count - 1)
    }
}

// MARK: - 单页控制器

final class ReaderPageController: UIViewController {

    let locator: PageLocator
    private let attributed: NSAttributedString?
    private let margin: CGFloat
    private let background: UIColor
    /// 0 = 左侧，1 = 中间，2 = 右侧
    var onTap: ((Int) -> Void)?

    private let pageView = CoreTextPageView()

    init(locator: PageLocator, attributed: NSAttributedString?, margin: CGFloat, background: UIColor) {
        self.locator = locator
        self.attributed = attributed
        self.margin = margin
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // pageCurl 要求页面不透明，否则卷起来能看穿到后面
        view.backgroundColor = background
        view.isOpaque = true

        pageView.attributed = attributed
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            pageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            pageView.topAnchor.constraint(equalTo: view.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: view).x
        let third = view.bounds.width / 3
        onTap?(x < third ? 0 : (x > third * 2 ? 2 : 1))
    }
}

// MARK: - 翻页容器

struct PageCurlReader: UIViewControllerRepresentable {

    let source: PageSource
    let animation: PageAnimation
    let margin: CGFloat
    let background: UIColor
    /// 工具栏是否正显示着。显示时任何位置的点击都只收起它，不翻页。
    let chromeVisible: Bool
    /// 排版版本号。变了就说明字号/主题/行距改过，当前页要重建。
    let revision: Int
    /// 自动翻页的计数器，每 +1 往前翻一页
    let autoAdvance: Int
    @Binding var locator: PageLocator
    var onToggleChrome: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: animation.transitionStyle,
            navigationOrientation: .horizontal,
            options: animation == .curl ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : nil
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.isDoubleSided = false
        controller.view.backgroundColor = background

        if let first = context.coordinator.makePage(locator) {
            controller.setViewControllers([first], direction: .forward, animated: false)
        }
        context.coordinator.disableBuiltInTaps(on: controller)
        context.coordinator.appliedRevision = revision
        context.coordinator.appliedAutoAdvance = autoAdvance
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        controller.view.backgroundColor = background
        // view 加载之后才有手势，所以放在这里而不是 make 里
        context.coordinator.disableBuiltInTaps(on: controller)

        let current = (controller.viewControllers?.first as? ReaderPageController)?.locator

        // 自动翻页：走动画，和手动翻一致
        if context.coordinator.appliedAutoAdvance != autoAdvance {
            context.coordinator.appliedAutoAdvance = autoAdvance
            if let from = current,
               let target = source.next(from),
               let page = context.coordinator.makePage(target) {
                controller.setViewControllers([page], direction: .forward, animated: true) { done in
                    if done { locator = target }
                }
            }
            return
        }

        // 排版变了：当前页的背景色和属性串是创建时烘焙的，必须重建，
        // 否则改主题/字号后要等翻页才生效
        if context.coordinator.appliedRevision != revision {
            context.coordinator.appliedRevision = revision
            if let page = context.coordinator.makePage(locator) {
                controller.setViewControllers([page], direction: .forward, animated: false)
            }
            return
        }

        // 只有当外部把位置改到了别处（目录跳转、搜索跳转）才需要重设，
        // 否则会和用户正在进行的手势打架
        guard current != locator, let page = context.coordinator.makePage(locator) else { return }

        let forward = current.map { locator.chapter > $0.chapter
            || (locator.chapter == $0.chapter && locator.page > $0.page) } ?? true
        controller.setViewControllers([page], direction: forward ? .forward : .reverse, animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {

        var parent: PageCurlReader
        /// 点击翻页时要用它来播动画，数据源回调里顺手记下来
        weak var container: UIPageViewController?
        var appliedRevision = -1
        var appliedAutoAdvance = 0
        private var tapsDisabled = false

        init(_ parent: PageCurlReader) { self.parent = parent }

        /// 关掉 UIPageViewController 自带的点击翻页，只留拖拽。
        /// 否则它和我们自己的左右三分之一逻辑会同时触发，一次点击翻两页。
        /// 注意手势要等 view 加载后才存在，makeUIViewController 里拿到的是空数组。
        func disableBuiltInTaps(on controller: UIPageViewController) {
            guard !tapsDisabled, controller.isViewLoaded else { return }
            let taps = controller.gestureRecognizers.filter { $0 is UITapGestureRecognizer }
            guard !taps.isEmpty else { return }
            taps.forEach { $0.isEnabled = false }
            tapsDisabled = true
        }

        func makePage(_ locator: PageLocator) -> ReaderPageController? {
            guard let attributed = parent.source.attributed(at: locator) else { return nil }
            let controller = ReaderPageController(locator: locator,
                                                  attributed: attributed,
                                                  margin: parent.margin,
                                                  background: parent.background)
            controller.onTap = { [weak self] zone in
                guard let self else { return }
                // 工具栏亮着的时候，点哪儿都只是把它收起来
                if self.parent.chromeVisible {
                    self.parent.onToggleChrome()
                    return
                }
                switch zone {
                case 0: self.turn(from: locator, forward: false)
                case 2: self.turn(from: locator, forward: true)
                default: self.parent.onToggleChrome()
                }
            }
            return controller
        }

        private func turn(from locator: PageLocator, forward: Bool) {
            guard let target = forward ? parent.source.next(locator) : parent.source.previous(locator),
                  let page = makePage(target) else { return }

            guard let container else {
                parent.locator = target
                return
            }
            container.setViewControllers([page],
                                         direction: forward ? .forward : .reverse,
                                         animated: true) { [weak self] finished in
                if finished { self?.parent.locator = target }
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            container = pageViewController
            guard let current = viewController as? ReaderPageController,
                  let target = parent.source.previous(current.locator) else { return nil }
            return makePage(target)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            container = pageViewController
            guard let current = viewController as? ReaderPageController,
                  let target = parent.source.next(current.locator) else { return nil }
            return makePage(target)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            container = pageViewController
            guard completed,
                  let current = pageViewController.viewControllers?.first as? ReaderPageController else { return }
            parent.locator = current.locator
        }
    }
}
