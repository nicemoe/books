import SwiftUI

struct ReaderView: View {

    let bookID: UUID

    @Environment(BookLibrary.self) private var library
    @Environment(WiFiService.self) private var wifi
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    /// 翻页模式的当前位置。分页交给 PageSource，这里只记「第几章第几页」。
    @State private var locator = PageLocator(chapter: 0, page: 0)
    @State private var pageSource: PageSource?
    /// 排版版本号。设置一变就 +1，靠它驱动翻页容器刷新当前页——
    /// 当前页是个已经创建好的控制器，背景色和属性串都是创建时烘焙的，
    /// 不主动重建的话要等翻页才会变。
    @State private var styleRevision = 0

    /// 滚动模式当前读到的章内字符偏移。和翻页模式同一个量纲，
    /// 两边共用一套 CoreText 排版，换算不会错位。容器自己上报，这里只记。
    @State private var scrollCharacterOffset = 0
    /// 要求滚动容器跳到某处。token 让「跳到同一处」也能再触发一次。
    @State private var scrollJump = ScrollJump(chapter: 0, offset: 0, token: 0)
    /// 从滚动切回翻页时，要顶成页首的那个字符。
    /// 不能在切换那一刻就用掉——紧接着的 rebuildSource 会清掉分页缓存，
    /// 刚排好的锚点分页会被冲掉。留到重排之后再落实。
    @State private var pendingAnchor: Int?

    @State private var showChrome = false
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showSearch = false

    /// 自动翻页
    @State private var isAutoFlipping = false
    /// 每 +1 让翻页容器往前翻一页。用计数器而不是布尔，
    /// 连续自动翻页时每次都是新值，容器才知道要再翻一次。
    @State private var autoAdvanceToken = 0

    /// 进入阅读器之前的系统亮度，退出时还回去，
    /// 免得把用户整台设备的亮度改了还不还
    @State private var systemBrightness: CGFloat?

    /// 这本书的章节表。不在 books.json 里，打开书的时候单独取一次——
    /// 一千本书的章节表加起来几百 MB，没道理为了画书架就全装进内存。
    /// 取到之前正文没法排版，先摆一个「正在整理章节」。
    @State private var chapters: [ChapterMeta] = []
    @State private var readingReady = false
    @State private var loadingError: String?

    private var book: Book? { library.book(bookID) }
    private var settings: ReaderSettings { library.settings }
    private var theme: ReaderTheme { settings.theme }

    /// 顶部信息条高度，正文可用区域要扣掉它
    private let headerHeight: CGFloat = 26

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            if let book, !chapters.isEmpty {
                // 不要 ignoresSafeArea：机身是圆角的，正文铺到物理边缘的话
                // 最后一行和页码会被圆角切掉。只让背景色铺满，文字待在安全区内。
                content(book)
            } else if let loadingError {
                VStack(spacing: 16) {
                    Text(loadingError).multilineTextAlignment(.center)
                    Button("返回书架") { dismiss() }
                }.padding()
            } else if book != nil {
                // 章节表还在路上。通常是读一个几十 KB 的文件，一闪而过；
                // 只有第一次打开一本还没拆过的书（从旧版本升上来、或者内部
                // 目录被清过）才要真等一下，那时候是在照着正文重拆。
                ProgressView()
                    .tint(theme.text.opacity(0.5))
            }

            if showChrome, let book {
                chrome(book)
            }
        }
        .statusBarHidden(!showChrome)
        .navigationBarHidden(true)
        .task(id: library.contentRevision) {
            readingReady = false
            chapters = []
            pageSource = nil
            loadingError = nil
            do {
                let loaded = try await library.chapters(of: bookID)
                try Task.checkCancellation()
                pageSource = nil
                chapters = loaded
                restoreProgress()
                readingReady = true
            } catch is CancellationError { }
            catch { loadingError = error.localizedDescription }
        }
        .alert("阅读失败", isPresented: Binding(get: { library.operationError != nil },
            set: { if !$0 { library.operationError = nil } })) {
            Button("返回书架") { library.operationError = nil; dismiss() }
        } message: { Text(library.operationError ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { applyBrightness() }
            else {
                saveProgress()
                library.saveNow()
                isAutoFlipping = false
                restoreBrightness()
            }
        }
        // 正读着的这本被抽走了就退出去。网页那边删书、或者在访达里删了 txt
        // 之后对账清掉，都会走到这儿。不退的话屏幕上只剩一片背景色——
        // 工具栏也要 book 才画得出来，连返回键都没有。
        .onChange(of: book == nil) { _, gone in
            if gone { dismiss() }
        }
        .onChange(of: locator) { _, _ in saveProgress() }
        .onChange(of: settings.mode) { _, mode in
            if mode == .scroll {
                // 从翻页切过来：把当前页的字符偏移带过去。
                // 自动播放不用停，滚动模式下它变成匀速自动滚动。
                requestScroll(chapter: locator.chapter,
                              offset: pageSource?.characterOffset(of: locator) ?? 0)
            } else {
                // 从滚动切回来：把当前这一行顶成页首，落到 rebuildSource 里做
                pendingAnchor = scrollCharacterOffset
            }
        }
        // 自动翻页：isAutoFlipping 变 false 时 task 自动取消
        .task(id: isAutoFlipping) {
            guard isAutoFlipping, scenePhase == .active else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = wifi.isRunning }

            while !Task.isCancelled && isAutoFlipping {
                // 滚动模式是匀速推进，由容器的 CADisplayLink 驱动，
                // 这里只剩「别让屏幕自己锁掉」这一件事
                guard settings.mode == .paged else {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                do { try await Task.sleep(for: .seconds(settings.autoFlipInterval)) } catch { return }
                guard !Task.isCancelled, isAutoFlipping else { return }
                guard let source = pageSource, source.next(locator) != nil else {
                    isAutoFlipping = false   // 到全书末尾了
                    return
                }
                autoAdvanceToken &+= 1
            }
        }
        .onAppear { applyBrightness() }
        .onChange(of: settings.brightness) { _, _ in applyBrightness() }
        .onDisappear {
            saveProgress()
            library.saveNow()
            isAutoFlipping = false
            restoreBrightness()
        }
        .sheet(isPresented: $showChapters) {
            if let book {
                ChapterListSheet(book: book, chapters: chapters, current: locator.chapter) { index in
                    jump(chapter: index, offset: 0, dismissingChrome: true)
                } onPickBookmark: { mark in
                    jump(chapter: mark.chapterIndex, offset: mark.characterOffset, dismissingChrome: true)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSearch) {
            if let book {
                BookSearchSheet(book: book, chapters: chapters) { hit in
                    jump(chapter: hit.chapterIndex, offset: hit.offset, dismissingChrome: true)
                }
            }
        }
    }

    // MARK: 正文

    @ViewBuilder
    private func content(_ book: Book) -> some View {
        switch settings.mode {
        case .paged:  pagedContent(book)
        case .scroll: scrollContent
        }
    }

    private func pagedContent(_ book: Book) -> some View {
        GeometryReader { geo in
            let inset = settings.margin
            // 交给 PageSource 的是「正文可用区域」，页边距由每页控制器自己加
            let contentSize = CGSize(width: max(1, geo.size.width - inset * 2),
                                     height: max(1, geo.size.height - headerHeight))

            VStack(spacing: 0) {
                // 信息条留在翻页容器外面，翻页时它不跟着卷，和纸书的书眉一样
                header
                    .padding(.horizontal, inset)

                if let source = pageSource {
                    // transitionStyle 在 UIPageViewController 初始化之后就改不了了，
                    // 换翻页效果必须让 SwiftUI 把容器整个拆掉重建。
                    // 光靠 .id() 不够可靠（实测要切好几次才生效），改用 switch：
                    // 两个分支在 SwiftUI 里是不同的视图类型，切换必然重建。
                    switch settings.pageAnimation {
                    case .curl:
                        // 自己画的仿真翻页：从右上/右下角起翻，跟手
                        SimulatedFlipReader(source: source,
                                            margin: inset,
                                            background: UIColor(theme.background),
                                            chromeVisible: showChrome,
                                            revision: styleRevision,
                                            autoAdvance: autoAdvanceToken,
                                            locator: $locator,
                                            onToggleChrome: toggleChrome)
                    case .slide:
                        pageContainer(source: source, animation: .slide, inset: inset)
                    }
                } else {
                    Spacer()
                }
            }
            .onAppear { rebuildSource(book: book, contentSize: contentSize) }
            .onChange(of: chapters) { _, _ in rebuildSource(book: book, contentSize: contentSize) }
            .onChange(of: contentSize) { _, size in rebuildSource(book: book, contentSize: size) }
            .onChange(of: settings.layout) { _, _ in rebuildSource(book: book, contentSize: contentSize) }
        }
    }

    private func pageContainer(source: PageSource, animation: PageAnimation, inset: CGFloat) -> some View {
        PageCurlReader(source: source,
                       animation: animation,
                       margin: inset,
                       background: UIColor(theme.background),
                       chromeVisible: showChrome,
                       revision: styleRevision,
                       autoAdvance: autoAdvanceToken,
                       locator: $locator,
                       onToggleChrome: toggleChrome)
    }

    private var scrollContent: some View {
        GeometryReader { geo in
            let inset = settings.margin
            let contentSize = CGSize(width: max(1, geo.size.width - inset * 2),
                                     height: max(1, geo.size.height - headerHeight))

            VStack(spacing: 0) {
                // 信息条和翻页模式一样留在容器外面，不跟着正文卷走
                header
                    .padding(.horizontal, inset)

                if let source = pageSource, let book {
                    ChapterScrollReader(
                        source: source,
                        chapterTitles: chapters.map(\.title),
                        settings: settings,
                        textColor: UIColor(theme.text),
                        chromeVisible: showChrome,
                        revision: styleRevision,
                        jump: scrollJump,
                        autoScrolling: isAutoFlipping,
                        autoScrollInterval: settings.autoFlipInterval,
                        onPositionChange: { chapter, offset in
                            scrollCharacterOffset = offset
                            library.updateProgress(bookID: bookID, chapterIndex: chapter, characterOffset: offset)
                            // 滚过章界了，把当前章同步过来，信息条和目录才跟得上
                            if locator.chapter != chapter {
                                locator = PageLocator(chapter: chapter, page: 0)
                            }
                        },
                        onToggleChrome: toggleChrome,
                        onReachEnd: { isAutoFlipping = false })
                } else {
                    Spacer()
                }
            }
            .onAppear { if let book { rebuildSource(book: book, contentSize: contentSize) } }
            .onChange(of: chapters) { _, _ in
                if let book { rebuildSource(book: book, contentSize: contentSize) }
            }
            .onChange(of: contentSize) { _, size in
                if let book { rebuildSource(book: book, contentSize: size) }
            }
            .onChange(of: settings.layout) { _, _ in
                if let book { rebuildSource(book: book, contentSize: contentSize) }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(currentChapterTitle)
                .lineLimit(1)
            Spacer()
            // 右边这个数报的是「本章读到哪儿」——认得出章节的书才说得通。
            //
            // 认不出章节的那种，「本章」其实是我们按字数切的片，于是
            // 「3/12」说的是「这一片的第 3 页，共 12 页」。片是内部的东西，
            // 那个分母对人没有意义，摆出来还像是书真的分了这么多节。
            // 那种书报全书读到哪儿，那才是人想知道的。
            if let book, !book.hasRealChapters {
                Text("\(Int((book.progressRatio * 100).rounded()))%")
                    .monospacedDigit()
            } else if settings.mode == .scroll {
                Text("\(chapterPercent)%")
                    .monospacedDigit()
            } else if let source = pageSource {
                let total = source.pageCount(locator.chapter)
                if total > 0 {
                    Text("\(locator.page + 1)/\(total)")
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondary)
        .frame(height: headerHeight)
    }

    // MARK: 工具栏

    private func chrome(_ book: Book) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { saveProgress(); dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(currentChapterTitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                Spacer()

                bookmarkButton
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.background.opacity(0.98))

            Spacer()

            HStack(spacing: 0) {
                toolButton("目录", "list.bullet") { showChapters = true }
                toolButton("搜索", "magnifyingglass") { showSearch = true }
                // 两种模式下都叫「自动」：翻页模式是自动翻页，滚动模式是自动滚动。
                // 也是两个字，和旁边几个按钮宽度一致。
                toolButton(isAutoFlipping ? "停止" : "自动",
                           isAutoFlipping ? "pause.circle" : "play.circle",
                           highlighted: isAutoFlipping) {
                    isAutoFlipping.toggle()
                }
                // 翻页/滚动的切换放在「设置」里就够了。摆在工具栏上显示的是
                // 当前模式名，看着像个动作，容易读成「点它会翻页」。
                toolButton(theme.isDark ? "日间" : "夜间", theme.isDark ? "sun.max" : "moon") {
                    var s = library.settings
                    s.theme = s.theme == .night ? .paper : .night
                    library.settings = s
                }
                toolButton("设置", "textformat.size") { showSettings = true }
            }
            .padding(.top, 8)
            .padding(.bottom, 26)
            .background(theme.background.opacity(0.98))
        }
        .transition(.opacity)
    }

    private var bookmarkButton: some View {
        let isMarked = currentBookmark != nil
        let color = isMarked
            ? Color(hex: theme.isDark ? 0xD59080 : 0xA55346)
            : theme.text.opacity(0.72)
        return Button(action: toggleBookmark) {
            BookmarkRibbon()
                .fill(isMarked ? color : .clear)
                .overlay {
                    BookmarkRibbon()
                        .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
                .frame(width: 15, height: 22)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMarked ? "移除书签" : "添加书签")
        .accessibilityValue(isMarked ? "当前页已收藏" : "当前页未收藏")
    }

    private func toolButton(_ title: String, _ icon: String,
                           highlighted: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(highlighted ? Theme.accent : theme.text)
            .contentShape(Rectangle())
        }
    }

    private func toggleChrome() {
        withAnimation(.easeOut(duration: 0.18)) { showChrome.toggle() }
    }

    // MARK: 亮度

    /// 只在阅读器内接管亮度。进来先记下系统值，出去还回去——
    /// 看本书把整台设备的亮度改了不还，是很讨厌的行为。
    private func applyBrightness() {
        guard let value = settings.brightness else {
            restoreBrightness()
            return
        }
        if systemBrightness == nil { systemBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = CGFloat(value)
    }

    private func restoreBrightness() {
        if let original = systemBrightness {
            UIScreen.main.brightness = original
            systemBrightness = nil
        }
    }

    // MARK: 书签

    /// 当前读到的章内字符位置。两种模式统一走这里，别再各问各的。
    private var currentOffset: Int {
        settings.mode == .scroll
            ? scrollCharacterOffset
            : (pageSource?.characterOffset(of: locator) ?? 0)
    }

    /// 本章读到百分之几
    private var chapterPercent: Int {
        guard chapters.indices.contains(locator.chapter) else { return 0 }
        let total = max(1, chapters[locator.chapter].characterCount)
        return min(100, max(0, currentOffset * 100 / total))
    }

    /// 当前屏覆盖的字符范围，用来判断这一处是否已被收藏
    private var currentPageRange: Range<Int> {
        if settings.mode == .scroll {
            // 滚动模式没有页，用大约一屏的字数当窗口
            return currentOffset..<(currentOffset + 500)
        }
        guard let source = pageSource else {
            return locator.chapter..<(locator.chapter + 1)
        }
        let start = source.characterOffset(of: locator)
        let ranges = source.pages(locator.chapter)
        let length = ranges.indices.contains(locator.page) ? ranges[locator.page].length : 1
        return start..<(start + max(1, length))
    }

    private var currentBookmark: Bookmark? {
        library.bookmark(bookID: bookID, chapter: locator.chapter, pageRange: currentPageRange)
    }

    private func toggleBookmark() {
        if let existing = currentBookmark {
            library.removeBookmark(bookID: bookID, markID: existing.id)
            return
        }
        let offset = currentOffset
        let snippet: String
        do { snippet = BookText.snippet(try library.chapterText(bookID: bookID, index: locator.chapter), at: offset) }
        catch { library.operationError = error.localizedDescription; return }

        library.addBookmark(bookID: bookID,
                            chapter: locator.chapter,
                            offset: offset,
                            title: currentChapterTitle,
                            snippet: snippet)
    }

    // MARK: 数据

    /// 顶栏和书签上显示的「现在在哪一章」。
    ///
    /// 认不出章节的书不报片号。那些「第 N 段」是内部分片的编号，
    /// 不是书里的东西——摆出来只会让人以为作者真这么分的。那种书就报书名。
    private var currentChapterTitle: String {
        guard let book else { return "" }
        guard book.hasRealChapters else { return book.title }
        guard chapters.indices.contains(locator.chapter) else { return "" }
        return chapters[locator.chapter].title
    }

    /// 建立/重建分页数据源。字号、行距、字体、页面尺寸变了都要重来，
    /// 重来之后按字符偏移把位置找回去，而不是保留页码。
    private func rebuildSource(book: Book, contentSize: CGSize) {
        guard contentSize.width > 1, contentSize.height > 1 else { return }

        // 滚动模式的位置在 scrollCharacterOffset 里，locator.page 恒为 0，问它只会拿到章首
        let offset = pendingAnchor
            ?? (settings.mode == .scroll
                ? scrollCharacterOffset
                : (pageSource?.characterOffset(of: locator) ?? book.progress.characterOffset))
        let color = UIColor(theme.text)

        if let existing = pageSource {
            existing.invalidate(settings: settings, textColor: color, pageSize: contentSize)
        } else {
            pageSource = PageSource(bookID: bookID,
                                    chapters: chapters,
                                    library: library,
                                    settings: settings,
                                    textColor: color,
                                    pageSize: contentSize)
        }
        // 分页缓存这时已经清干净了，锚点必须在这之后才排
        if let anchor = pendingAnchor {
            pageSource?.anchor(chapter: locator.chapter, at: anchor)
            pendingAnchor = nil
        }
        locator = pageSource?.locator(chapter: locator.chapter, offset: offset) ?? locator
        styleRevision &+= 1
    }

    private func restoreProgress() {
        guard let book else { return }
        guard !chapters.isEmpty else { return }
        let chapter = min(max(0, book.progress.chapterIndex), chapters.count - 1)
        let offset = min(max(0, book.progress.characterOffset), chapters[chapter].characterCount)
        pendingAnchor = offset
        locator = PageLocator(chapter: chapter, page: 0)
        requestScroll(chapter: chapter, offset: offset)
    }

    /// 让滚动容器跳到指定位置
    private func requestScroll(chapter: Int, offset: Int) {
        scrollCharacterOffset = offset
        scrollJump = ScrollJump(chapter: chapter, offset: offset, token: scrollJump.token &+ 1)
    }

    /// 跳章。
    ///
    /// - Parameter dismissingChrome: 只有「明确指定了目的地」的跳转才收工具栏
    ///   （目录、搜索）。上一章/下一章是可重复的顺序浏览，用户可能连点好几次
    ///   找位置，替他收起来等于替他断定「你不会再点了」。
    private func jump(chapter: Int, offset: Int, dismissingChrome: Bool = false) {
        guard chapters.indices.contains(chapter) else { return }
        if let source = pageSource {
            locator = source.locator(chapter: chapter, offset: offset)
        } else {
            locator = PageLocator(chapter: chapter, page: 0)
        }
        if settings.mode == .scroll { requestScroll(chapter: chapter, offset: offset) }
        saveProgress()

        if dismissingChrome, showChrome {
            withAnimation(.easeOut(duration: 0.18)) { showChrome = false }
        }
    }

    private func saveProgress() {
        guard readingReady, pageSource?.failure == nil,
              settings.mode == .scroll || pageSource != nil else { return }
        let offset = currentOffset
        library.updateProgress(bookID: bookID, chapterIndex: locator.chapter, characterOffset: offset)
    }
}

/// 细长的纸质书签轮廓，顶部微圆角，底部保留剪口。
private struct BookmarkRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width * 0.12
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.22))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
