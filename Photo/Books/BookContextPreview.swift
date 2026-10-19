import SwiftUI

/// 两种书架布局共用独立的书封预览，避免预览继承整行的宽度和左侧留白。
struct BookContextPreview: View {
    let book: Book

    var body: some View {
        BookCover(book: book, width: 120, height: 120 * 1.48)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct BookGridPreviewShape: Shape {
    let side: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = side * 0.9
        return RoundedRectangle(cornerRadius: width < 72 ? 3 : 6, style: .continuous)
            .path(in: CGRect(origin: rect.origin, size: CGSize(width: width, height: width * 1.48)))
    }
}

struct BookRowPreviewShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cover = CGRect(x: rect.minX, y: rect.minY + BookRow.verticalPadding,
                           width: BookRow.coverWidth, height: rect.height - BookRow.verticalPadding * 2)
        return RoundedRectangle(cornerRadius: 3, style: .continuous).path(in: cover)
    }
}
