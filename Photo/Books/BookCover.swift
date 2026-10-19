import SwiftUI

/// 简洁的平面书封；书名由书架和列表在封面外显示。
struct BookCover: View {
    let book: Book
    let width: CGFloat
    let height: CGFloat

    private var cornerRadius: CGFloat { width < 72 ? 3 : 6 }

    private static let colors: [UInt32] = [
        0x40594E, 0x44566D, 0x8E5651, 0x7C694F,
        0x3E6168, 0x67576B, 0x686C50, 0x70534C
    ]
    private var coverColor: Color {
        let index = ((book.colorIndex % Self.colors.count) + Self.colors.count) % Self.colors.count
        return Color(hex: Self.colors[index])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: width * 0.12)

            Rectangle()
                .fill(.white.opacity(0.45))
                .frame(width: width * 0.18, height: 1)

            if width >= 72, !book.author.isEmpty {
                Text(book.author)
                    .font(.system(size: width * 0.085, weight: .regular, design: .serif))
                    .lineLimit(1)
                    .padding(.top, width * 0.08)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(Color(hex: 0xFAF6EE))
        .padding(.horizontal, width * 0.14)
        .padding(.vertical, width * 0.17)
        .frame(width: width, height: height, alignment: .bottomLeading)
        .background(coverColor, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
