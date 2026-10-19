import SwiftUI

/// 两种书架布局共用独立的书封预览，避免预览继承整行的宽度和左侧留白。
struct BookContextPreview: View {
    let book: Book

    var body: some View {
        BookCover(book: book, width: 120, height: 120 * 1.48)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
