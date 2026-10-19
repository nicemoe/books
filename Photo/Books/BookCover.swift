import SwiftUI

/// 同一套书封用于书架和目录；颜色来自书籍的稳定索引。
struct BookCover: View {
    let book: Book
    let width: CGFloat

    private static let papers: [UInt32] = [
        0xE9DFD0, 0xD7E0D6, 0xD7DFE8, 0xE6D5D2,
        0xE3DECA, 0xDCD8E4, 0xD1E0DE, 0xE6DCCF
    ]
    private var paper: Color {
        let index = ((book.colorIndex % Self.papers.count) + Self.papers.count) % Self.papers.count
        return Color(hex: Self.papers[index])
    }
    private let ink = Color(hex: 0x34332F)

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: 0xF6F2E9))
                .padding(.leading, 3)
                .padding(.top, 3)

            RoundedRectangle(cornerRadius: 3)
                .fill(paper)
                .padding(.trailing, 3)
                .padding(.bottom, 3)

            Rectangle()
                .fill(ink.opacity(0.09))
                .frame(width: max(4, width * 0.055))
                .padding(.bottom, 3)

            Rectangle()
                .fill(.white.opacity(0.45))
                .frame(width: 1)
                .padding(.leading, max(5, width * 0.065))
                .padding(.vertical, 4)

            VStack(spacing: width * 0.09) {
                Text(book.title)
                    .font(.system(size: width * 0.15, weight: .medium, design: .serif))
                    .lineLimit(4)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(ink.opacity(0.28))
                    .frame(width: width * 0.23, height: 1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: width * 0.075, design: .serif))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
                Text(book.format.label)
                    .font(.system(size: max(6, width * 0.065), weight: .medium))
                    .tracking(1.5)
                    .opacity(0.55)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, width * 0.14)
            .padding(.top, width * 0.23)
            .padding(.bottom, width * 0.13)
        }
        .frame(width: width, height: width * 1.46)
        .shadow(color: .black.opacity(0.12), radius: 3, x: 1, y: 3)
        .accessibilityHidden(true)
    }
}
