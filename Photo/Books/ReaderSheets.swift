import SwiftUI

// MARK: - 章节目录

struct ChapterListSheet: View {

    let book: Book
    /// 章节表从阅读页传进来。它不在 books.json 里，是打开书时单独取的，
    /// 这儿再去取一遍等于多读一次盘。
    let chapters: [ChapterMeta]
    let current: Int
    var onPick: (Int) -> Void
    var onPickBookmark: (Bookmark) -> Void

    @Environment(BookLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var reversed = false
    /// 目录和书签放同一个面板，用分段切换，不额外占工具栏位置
    @State private var tab = 0

    /// 目录里摆什么。
    ///
    /// 认不出章节的书（整本没有「第 X 章」这类标记）只给一条。
    ///
    /// 那种书现在是按字数切成片的，但那是**内部分片**——为了不把几十万字
    /// 一次排版、一次读进内存。目录是给人看的索引，只该有作者真正写下的
    /// 章节。把分片摆进目录，就是拿「第 1 段」这种我们自己编的号去充数，
    /// 人还以为书本来就长这样。
    private var visibleChapters: [ChapterMeta] {
        guard book.hasRealChapters else { return Array(chapters.prefix(1)) }
        let base = keyword.isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        return reversed ? base.reversed() : base
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("目录").tag(0)
                    Text("书签").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.vertical, 10)

                if tab == 0 { chapterList } else { bookmarkList }
            }
            .background(Theme.background)
            // 认不出章节的书别报章数——那个数是内部分了几片，不是书有几章
            .navigationTitle(tab == 0
                             ? (book.hasRealChapters ? "共 \(book.chapterCount) 章" : "目录")
                             : "书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if tab == 0 {
                        Button(reversed ? "正序" : "倒序") { reversed.toggle() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var bookmarkList: some View {
        let marks = library.bookmarks(bookID: book.id)
        return Group {
            if marks.isEmpty {
                EmptyState(title: "还没有书签",
                           message: "阅读时点右上角的书签图标，就能把当前这页记下来")
            } else {
                List {
                    ForEach(marks) { mark in
                        Button {
                            onPickBookmark(mark)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mark.chapterTitle)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                Text(mark.snippet)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.label)
                                    .lineLimit(2)
                            }
                            .tappableArea()
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            library.removeBookmark(bookID: book.id, markID: marks[index].id)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var chapterList: some View {
            ScrollViewReader { proxy in
                List {
                    ForEach(visibleChapters) { chapter in
                        Button {
                            onPick(chapter.index)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text(book.hasRealChapters ? chapter.title : "正文")
                                    .font(.system(size: 15, weight: chapter.index == current ? .semibold : .regular))
                                    .foregroundStyle(chapter.index == current ? Theme.accent : Theme.label)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(book.hasRealChapters ? chapter.characterCount : book.totalCharacters) 字")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.tertiaryLabel)
                            }
                            .tappableArea()
                        }
                        .listRowBackground(Theme.surface)
                        .id(chapter.index)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .onAppear {
                    // 打开目录时直接定位到当前章
                    proxy.scrollTo(current, anchor: .center)
                }
            }
            .searchable(text: $keyword, prompt: "搜索章节")
    }
}

// MARK: - 全文搜索

struct BookSearchSheet: View {

    let book: Book
    let chapters: [ChapterMeta]
    var onPick: (BookLibrary.SearchHit) -> Void

    @Environment(BookLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var hits: [BookLibrary.SearchHit] = []
    @State private var searching = false
    @State private var searched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Group {
                if searching {
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.accent)
                        Text("正在搜索全书…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hits.isEmpty {
                    EmptyState(title: searched ? "没有找到" : "搜索全书",
                               message: searched ? "换个词试试" : "输入关键词，会在所有章节里查找")
                } else {
                    List(hits) { hit in
                        Button {
                            onPick(hit)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.chapterTitle)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                Text(hit.snippet)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.label)
                                    .lineLimit(3)
                            }
                            .tappableArea()
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .searchable(text: $keyword, prompt: "搜索正文")
            // 边打边搜会把长篇卡死，等用户停手再搜
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: keyword) { _, value in
                searchTask?.cancel()
                searching = false
                hits = []
                searched = false
            }
            .onDisappear { searchTask?.cancel() }
            .alert("搜索失败", isPresented: Binding(get: { searchError != nil }, set: { if !$0 { searchError = nil } })) {
                Button("知道了") { searchError = nil }
            } message: { Text(searchError ?? "") }
            .navigationTitle(hits.isEmpty ? "全文搜索" : "找到 \(hits.count) 处")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func runSearch() {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        searchTask?.cancel()
        searching = true
        searched = true
        searchTask = Task {
            do {
                let found = try await library.search(fileName: book.sourceName, chapters: chapters, keyword: key)
                try Task.checkCancellation()
                hits = found
                searching = false
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
                searching = false
            }
        }
    }
}

// MARK: - 阅读设置

struct ReaderSettingsSheet: View {

    @Environment(BookLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var library = library

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    row("字号") {
                        HStack(spacing: 14) {
                            stepButton("textformat.size.smaller") {
                                adjust { $0.fontSize = max(ReaderSettings.fontSizeRange.lowerBound, $0.fontSize - 1) }
                            }
                            Text("\(Int(library.settings.fontSize))")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .frame(width: 34)
                            stepButton("textformat.size.larger") {
                                adjust { $0.fontSize = min(ReaderSettings.fontSizeRange.upperBound, $0.fontSize + 1) }
                            }
                        }
                    }

                    row("行距") {
                        HStack(spacing: 14) {
                            stepButton("minus") {
                                adjust { $0.lineSpacing = max(ReaderSettings.lineSpacingRange.lowerBound, $0.lineSpacing - 1) }
                            }
                            Text("\(Int(library.settings.lineSpacing))")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .frame(width: 34)
                            stepButton("plus") {
                                adjust { $0.lineSpacing = min(ReaderSettings.lineSpacingRange.upperBound, $0.lineSpacing + 1) }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        label("背景")
                        HStack(spacing: 10) {
                            ForEach(ReaderTheme.allCases) { theme in
                                Button {
                                    adjust { $0.theme = theme }
                                } label: {
                                    Text(theme.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(theme.text)
                                        .frame(width: 46, height: 40)
                                        .background(theme.background,
                                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .strokeBorder(library.settings.theme == theme ? Theme.accent : Theme.hairline,
                                                              lineWidth: library.settings.theme == theme ? 2 : 1)
                                        }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        label("字体")
                        Picker("", selection: Binding(
                            get: { library.settings.font },
                            set: { value in adjust { $0.font = value } }
                        )) {
                            ForEach(ReaderFont.allCases) { font in
                                Text(font.title).tag(font)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        label("阅读方式")
                        Picker("", selection: Binding(
                            get: { library.settings.mode },
                            set: { value in adjust { $0.mode = value } }
                        )) {
                            ForEach(ReadingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if library.settings.mode == .paged {
                        VStack(alignment: .leading, spacing: 10) {
                            label("翻页效果")
                            Picker("", selection: Binding(
                                get: { library.settings.pageAnimation },
                                set: { value in adjust { $0.pageAnimation = value } }
                            )) {
                                ForEach(PageAnimation.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            label("亮度")
                            Spacer()
                            if library.settings.brightness != nil {
                                Button("跟随系统") { adjust { $0.brightness = nil } }
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "sun.min").foregroundStyle(Theme.secondaryLabel)
                            Slider(value: Binding(
                                get: { library.settings.brightness ?? Double(UIScreen.main.brightness) },
                                set: { value in adjust { $0.brightness = value } }
                            ), in: 0.05...1)
                            Image(systemName: "sun.max").foregroundStyle(Theme.secondaryLabel)
                        }
                        .font(.system(size: 13))
                        Text("只在阅读时生效，退出后会还原系统亮度")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryLabel)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            HStack {
                                label(library.settings.mode == .scroll ? "自动滚动一屏用时" : "自动翻页间隔")
                                Spacer()
                                Text("\(Int(library.settings.autoFlipInterval)) 秒")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.label)
                            }
                            Slider(value: Binding(
                                get: { library.settings.autoFlipInterval },
                                set: { value in adjust { $0.autoFlipInterval = value.rounded() } }
                            ), in: ReaderSettings.autoFlipRange, step: 1)
                        }
                    }
                }
                .padding(Theme.Metric.margin)
            }
            .background(Theme.background)
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    private func adjust(_ change: (inout ReaderSettings) -> Void) {
        var settings = library.settings
        change(&settings)
        library.settings = settings
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryLabel)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            label(title)
            Spacer()
            content()
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 34)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
