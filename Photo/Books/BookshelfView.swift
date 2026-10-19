import SwiftUI

/// 书架上会弹的两张卡片。用一个 .sheet(item:) 统一管，
/// 比在同一个视图上挂两个 .sheet(isPresented:) 稳。
private enum ShelfSheet: String, Identifiable {
    case wifi
    case importer
    var id: String { rawValue }
}

struct BookshelfView: View {

    @Environment(BookLibrary.self) private var library
    @Environment(WiFiService.self) private var wifi
    @Environment(\.scenePhase) private var scenePhase

    @State private var sheet: ShelfSheet?
    @State private var openedBook: OpenedBook?
    @State private var renaming: Book?
    @State private var renameText = ""
    @State private var deleting: Book?
    @State private var errorMessage: String?
    @State private var failedFilePrompt: [BookReconciliation.FailedFile] = []
    @State private var isCollectingFiles = false
    @State private var toastItem: Toast?
    @State private var screenWidth: CGFloat = 0
    @State private var keyword = ""
    @ScaledMetric(relativeTo: .body) private var preferredCoverWidth: CGFloat = 100

    private var layout: CardGridLayout {
        let width = screenWidth > 0 ? screenWidth : ScreenMetrics.fallbackWidth
        return CardGridLayout(contentWidth: max(1, width - Theme.Metric.margin * 2),
                              gap: 16, preferredItemWidth: preferredCoverWidth, minimumColumns: 1)
    }

    private var matchedBooks: [Book] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return library.sortedBooks }
        return library.sortedBooks.filter {
            $0.title.localizedCaseInsensitiveContains(key)
                || $0.author.localizedCaseInsensitiveContains(key)
        }
    }

    var body: some View {
        // 数据已在书库中；只算一次排序和搜索，由懒布局按需创建书籍视图。
        let displayedBooks = matchedBooks
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !library.failedFiles.isEmpty {
                        Button {
                            failedFilePrompt = library.failedFiles
                        } label: {
                            Label("\(library.failedFiles.count) 个文件解析失败，点击处理", systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                    if library.books.isEmpty {
                        EmptyState(
                            title: "书架是空的",
                            message: "支持 TXT 和 EPUB。\n可以从「文件」导入，也可以用 WiFi 上传。",
                            actionTitle: "从文件导入"
                        ) {
                            sheet = .importer
                        }
                        .padding(.top, 40)
                    } else if displayedBooks.isEmpty {
                        EmptyState(title: "没有匹配的书",
                                   message: "试试书名或作者的其他关键词")
                            .padding(.top, 40)
                    } else if library.shelfLayout == .grid {
                        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: 26) {
                            ForEach(displayedBooks) { book in
                                Button {
                                    open(book)
                                } label: {
                                    BookCard(book: book, side: layout.side) {
                                        menu(for: book)
                                    }
                                }
                                .buttonStyle(PressableCardStyle())
                                .accessibilityActions {
                                    menu(for: book)
                                }
                            }
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(displayedBooks) { book in
                                Button {
                                    open(book)
                                } label: {
                                    BookRow(book: book) {
                                        menu(for: book)
                                    }
                                }
                                .buttonStyle(PressableCardStyle())
                                .accessibilityActions {
                                    menu(for: book)
                                }
                            }
                        }
                    }
                    if !displayedBooks.isEmpty {
                        Text("共 \(displayedBooks.count) 本")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, 40)
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .readingWidth($screenWidth)
            .searchable(text: $keyword, prompt: "搜索书名或作者")
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if wifi.isRunning {
                        Button {
                            sheet = .wifi
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: 0x2FBF5B)).frame(width: 6, height: 6)
                                Text("传输中")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(Theme.secondaryLabel)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.fill, in: Capsule())
                        }
                    }
                }
                // 两个按钮放进同一个 ToolbarItem 里用 HStack 摆，间距才可控；
                // 交给 ToolbarItemGroup 排的话由系统决定，会偏大。
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        addMenu
                        pageMenu
                    }
                }
            }
        }
        // 阅读器用全屏覆盖，不走导航 push。
        //
        // push 的话要靠 .toolbar(.hidden, for: .tabBar) 藏标签栏，
        // 而 SwiftUI 要等退场动画整个走完才把它放回来——退出小说后
        // 底部会空一下才冒出来。盖上去就没这问题，标签栏根本没被藏过。
        // 顺带也不会和「从左边往右滑翻上一页」抢边缘返回手势。
        .fullScreenCover(item: $openedBook) { opened in
            ReaderView(bookID: opened.id)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .wifi:
                WiFiTransferView()
            case .importer:
                DocumentPicker { urls in
                    handleImport(urls)
                } onFinish: {
                    sheet = nil
                }
                .ignoresSafeArea()
            }
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("书名", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                do { if let book = renaming { try library.rename(bookID: book.id, to: renameText) } }
                catch { errorMessage = error.localizedDescription }
                renaming = nil
            }
        }
        .confirmationDialog(deleting.map { "删除《\($0.title)》" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { if let book = deleting { try library.delete(bookID: book.id) } }
                catch { errorMessage = error.localizedDescription }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("书和阅读进度都会被移除。")
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("删除解析失败的文件？", isPresented: Binding(
            get: { !failedFilePrompt.isEmpty && errorMessage == nil && openedBook == nil && sheet == nil },
            set: { if !$0 { failedFilePrompt = [] } }), presenting: failedFilePrompt) { files in
            Button("删除这 \(files.count) 个文件", role: .destructive) {
                Task {
                    do { try await library.deleteFailedFiles(files) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button("保留文件", role: .cancel) { }
        } message: { files in
            Text(files.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n")
                 + "\n\n删除会移除书库内的这些文件及对应阅读记录。选择保留后，文件未修改时不会再次自动解析，可从书架的失败提示继续处理。")
        }
        .overlay {
            if let progress = library.importing {
                ImportingOverlay(progress: progress)
            }
        }
        .toast($toastItem)
        // 电脑上把书丢进 Books 文件夹后，回到 App 就收走。
        // 只在切回前台时扫一次——文件是在 App 不活跃的时候放进来的，
        // 常驻监听目录只会白耗电。
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if let error = library.operationError { errorMessage = error; library.operationError = nil }
            await collectLooseFiles()
        }
        .onChange(of: library.operationError) { _, error in
            if !isCollectingFiles, openedBook == nil, let error {
                errorMessage = error
                library.operationError = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                // 退到后台之后人很可能直接上划把 App 杀了。翻页时的保存是
                // 攒 300ms 一起写的，不趁这一下落盘，最后翻的那几页就没了。
                library.saveNow()
            }
        }
    }

    /// 和书库对一次账：新丢进来的收走，文件被删掉的那些书也跟着走，
    /// 在电脑上改过的重新拆一遍
    private func collectLooseFiles() async {
        guard !isCollectingFiles else { return }
        isCollectingFiles = true
        defer {
            isCollectingFiles = false
            if openedBook == nil, let error = library.operationError {
                errorMessage = [errorMessage, error].compactMap { $0 }.joined(separator: "\n\n")
                library.operationError = nil
            }
        }
        let changes = await library.reconcileFiles()
        if !changes.parseFailures.isEmpty { failedFilePrompt = changes.parseFailures }
        let saved = changes.added
        let gone = changes.removed
        let redone = changes.rebuilt
        guard saved > 0 || gone > 0 || redone > 0 else { return }

        let parts = [saved > 0 ? "收进 \(saved) 本" : nil,
                     gone > 0 ? "移除 \(gone) 本" : nil,
                     redone > 0 ? "重新分章 \(redone) 本" : nil].compactMap { $0 }
        toastItem = Toast(icon: "arrow.triangle.2.circlepath",
                          text: parts.joined(separator: "，"))
    }

    private func open(_ book: Book) {
        if let failure = library.failedFiles.first(where: { $0.id == book.sourceName.lowercased() }) {
            failedFilePrompt = [failure]
        } else {
            openedBook = OpenedBook(id: book.id)
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                sheet = .importer
            } label: {
                Label("从文件导入", systemImage: "folder")
            }

            Divider()

            Button {
                sheet = .wifi
            } label: {
                Label("WiFi 上传", systemImage: "wifi")
            }
        } label: {
            // 加号比默认细一档：那一横一竖比旁边的三条杠粗，摆一起不齐
            Image(systemName: "plus").circleIcon(weight: .medium)
        }
    }

    /// 三条杠：书架布局 + 外观。
    ///
    /// 布局用菜单 + 对勾而不是单键切换：两种布局的图标谁代表「当前」谁代表
    /// 「点了会变成」很容易读反，菜单里打勾没有歧义。
    private var pageMenu: some View {
        @Bindable var library = library

        return Menu {
            Menu {
                Picker("", selection: $library.shelfLayout) {
                    ForEach(ShelfLayout.allCases) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(library.shelfLayout.title, systemImage: library.shelfLayout.icon)
            }

            Divider()

            // 外观作为一个条目收在这里，点开才是三个选项。
            // 一级条目直接显示当前选中的值（跟随系统 / 浅色 / 深色），
            // 不要再加「外观」前缀——展开后的对勾已经说明了它是什么。
            Menu {
                Picker("", selection: $library.appearance) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.title, systemImage: theme.icon).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(library.appearance.title, systemImage: library.appearance.icon)
            }
        } label: {
            // 三条杠是自己画的，宽度/线宽/行距各自独立可调，见 HamburgerIcon
            HamburgerIcon().circleIcon()
        }
    }

    private func handleImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let (ok, failures) = await library.importBooks(from: urls)
            if ok > 0 {
                toastItem = Toast(icon: "books.vertical.fill", text: "已导入 \(ok) 本")
            }
            if !failures.isEmpty {
                // 选取器刚关掉就弹 alert 有概率被丢掉，等它的退场动画走完
                try? await Task.sleep(for: .milliseconds(400))
                errorMessage = failures.joined(separator: "\n")
            }
        }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        Button {
            renameText = book.title
            renaming = book
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            deleting = book
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

// MARK: - 书架与书目

struct BookCard<MenuItems: View>: View {
    let book: Book
    let side: CGFloat
    @ViewBuilder var menu: MenuItems

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            BookCover(book: book, width: side * 0.9, height: side * 0.9 * 1.48)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: side * 0.9 < 72 ? 3 : 6, style: .continuous))
                .contextMenu {
                    menu
                } preview: {
                    BookContextPreview(book: book)
                }
            Text(book.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(book.progressText)
                .font(.caption)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .frame(width: side, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct BookRow<MenuItems: View>: View {
    let book: Book
    @ViewBuilder var menu: MenuItems

    private static var coverWidth: CGFloat { 44 }
    private static var verticalPadding: CGFloat { 12 }
    private static var textInset: CGFloat { coverWidth + 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(book.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(book.sizeText)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryLabel)
                .lineLimit(1)
            HStack(spacing: 8) {
                if book.progressRatio > 0 {
                    ProgressView(value: book.progressRatio)
                        .tint(Theme.secondaryLabel)
                        .frame(width: 40)
                }
                Text(book.progressText)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.leading, Self.textInset)
        .overlay(alignment: .leading) {
            // 用文字实际高度确定书封高度，随系统字号一起调整。
            GeometryReader { geometry in
                BookCover(book: book, width: Self.coverWidth, height: geometry.size.height)
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .contextMenu {
                        menu
                    } preview: {
                        BookContextPreview(book: book)
                    }
            }
            .frame(width: Self.coverWidth)
        }
        .padding(.vertical, Self.verticalPadding)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Self.textInset)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 导入中

struct ImportingOverlay: View {
    let progress: BookLibrary.ImportProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                // 一本的时候没有「几分之几」可言，转圈就够了；
                // 一批的时候要能看出还剩多少
                if progress.total > 1 {
                    ProgressView(value: progress.ratio).tint(Theme.accent).frame(width: 190)
                    Text("正在解析 \(progress.done) / \(progress.total)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                } else {
                    ProgressView().tint(Theme.accent)
                }

                if !progress.title.isEmpty {
                    Text("《\(progress.title)》")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                }
            }
            .padding(28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// fullScreenCover(item:) 要 Identifiable，UUID 本身不是
private struct OpenedBook: Identifiable {
    let id: UUID
}
