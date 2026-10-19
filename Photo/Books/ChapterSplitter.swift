import Foundation

/// 切分出来的一章。
struct ParsedChapter {
    /// 目录里显示的标题
    var title: String
    /// 这一章的全文。
    ///
    /// 正文里本来就有标题行的（小说 txt 基本都有），第一行就是那行标题——
    /// 从目录点进来，得能一眼看见自己在第几章，光有正文是认不出来的。
    ///
    /// 反过来，标题是我们自己编号编出来的（整本没有章节标记、只能按字数
    /// 硬切的那种），就不往里塞。那是我们的记账，不是书的内容，写进去等于
    /// 把人的文件改脏了——之前那一版正是这么干的，「第 1 节」「第 2 节」
    /// 现在还留在那些 txt 里。
    var text: String
}

/// TXT 章节切分。
enum ChapterSplitter {

    /// 分章规则的版本。规则改了就 +1，旧书会被重新拆一遍（见 BookLibrary）。
    ///
    /// 1：第一版真正能用的规则。在这之前整个正则编译不过（见下），所有书
    ///    其实都是按字数硬切的，标题全是「第 N 节」。
    /// 2：标题行留在正文里，从目录点进来能看见自己在第几章；
    ///    我们自己编的号不再写进文件。
    /// 3：分出「真章节」和「硬切的片」——认不出章节的书，目录只给一条，
    ///    不再拿编号去充数。
    /// 4：清掉上一版塞进正文的编号行。3 里也写了这段清理，但正则少了 (?m)，
    ///    一行都没清着，等于空转。
    /// 5：认「第一章 XXX……」后面直接跟正文、一行写到底的那种。
    /// 6：找边界和取名字拆成两步，正则只管找编号。
    /// 7：保留短开篇及原文中形似历史编号的标题行。
    static let version = 7

    /// 编号。一行开头的「第一章」「楔子」「Chapter 1」这些。
    ///
    /// 这条正则**只干一件事**：找出一章从哪儿开始。名字叫什么不归它管。
    ///
    /// 分开是因为这两件事的把握程度差得远。编号是硬的——「第一章」就是
    /// 第一章，认错的余地很小。名字是软的——「第一章 陨落的天才」和
    /// 「第一章 陨落的天才　　斗气大陆，分为斗者、斗师……」前面一模一样，
    /// 从哪儿算名字的结尾，没有可靠答案。
    ///
    /// 混在一条正则里的下场，之前试过了：为了把后一种也认出来，得放宽尾部
    /// 的限制，而一放宽，正文里一段话开头写「第三章节的内容让他很失望」
    /// 就被当成了标题。为了凑名字，把边界也弄丢了。
    ///
    /// 所以边界归正则、名字归下面那个函数，各自用各自的判据。
    ///
    /// 结尾那个前瞻是必须的：编号后面得是行尾、空白或者分隔标点。不这么
    /// 卡的话，「第三章节」里的「第三章」也会被当成编号——而它只是个词。
    ///
    /// 全角空格写 \u3000 而不是 \u{3000}。后者是 Swift 的转义写法，而这里是
    /// 双反斜杠，字符串里装的是字面的那六个字符，交给正则引擎的也是它们。
    /// ICU 只认 \uhhhh 四位十六进制，碰上 \u{ 直接判「转义不完整」，整个
    /// 模式编译失败——而构造那儿是 try?，错误被吞掉返回 nil，于是一个标题
    /// 都找不到，每本书都掉进按字数硬切的兜底路。这个坑埋了很久。
    private static let markerPattern = "^[ \\t\\u3000]{0,8}(?:"
        + "第[0-9０-９一二三四五六七八九十百千零两]{1,12}[章节節回卷篇集部幕]"
        + "|[序楔]\\s*[章子]|楔子|引子|前言|序言|后记|後記|尾声|尾聲|终章|終章"
        + "|番外篇?[0-9０-９一二三四五六七八九十]{0,3}|Chapter\\s+[0-9IVXivx]{1,6}"
        + ")(?=$|[ \\t\\u3000：:、．·\\-—])"

    private static let headingRegex: NSRegularExpression = {
        do { return try NSRegularExpression(pattern: markerPattern, options: [.anchorsMatchLines]) }
        catch { preconditionFailure("Invalid chapter heading pattern: \(error)") }
    }()

    /// 名字最多这么长。再长的多半已经是正文了。
    private static let titleLimit = 30

    /// 句子里才有的标点。名字里出现这些，说明认到正文里去了。
    private static let proseMarks = Set<Character>("。！？；…，,;!?“”\"")

    /// 编号和名字之间可能隔着这些
    private static let titleSeparators = CharacterSet(charactersIn: " \t\u{3000}：:、．·-—")

    /// 一本书里章节太少（比如整本一坨），就按固定字数切，
    /// 否则单章几十万字，分页和滚动都会卡。
    private static let chunkSize = 4000
    private static let minChapterCount = 2

    /// 切分的结果。
    ///
    /// 目录和分片是两回事，这里必须分清楚：
    ///
    /// - **分片**是为了不把几十万字一次排版、一次读进内存，纯属内部的事，
    ///   认不出章节时按字数切也无妨。
    /// - **目录**是给人看的索引，只该有作者真正写下的那些章节。
    ///
    /// 把两者混成一个列表，就会拿「第 1 节」这种我们自己编的号去充数，
    /// 目录里一排假章节，人还以为书就长这样。fromHeadings 记的就是这个差别。
    struct Split {
        var chapters: [ParsedChapter]
        /// true = 这些是从正文里认出来的真章节；false = 认不出，按字数切的片
        var fromHeadings: Bool
    }

    static func split(_ text: String) -> Split {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return Split(chapters: [], fromHeadings: false) }

        let matches = headingRanges(in: normalized)
        if matches.count >= minChapterCount {
            return Split(chapters: chapters(from: normalized, headings: matches),
                         fromHeadings: true)
        }
        return Split(chapters: chunk(normalized), fromHeadings: false)
    }

    // MARK: 归一化

    /// 统一换行、去掉零宽字符、压掉过多空行
    private static func normalize(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
        // 连着三个以上的换行一律压成两个，一次正则扫完。
        // 原来是 while contains("\n\n\n") 反复替换：每轮都要把整串扫一遍再
        // 复制一遍，碰上连着几十个空行的文件就得来回复制几十次。
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 第一步 —— 找出一章从哪儿开始

    private static func headingRanges(in text: String) -> [Range<String.Index>] {
        // 不要 .allowCommentsAndWhitespace。
        //
        // 这个模式是靠行尾续行拼成一行的，里面本来就没有换行、也没有注释，
        // 开着那个选项什么都不多做，坏处却实打实：ICU 在那个模式下连字符类
        // 里的空格都一起吃掉，于是缩进用普通空格的标题行会匹配不上。
        let regex = headingRegex

        let ns = text as NSString
        let all = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return all.compactMap { Range($0.range, in: text) }
    }

    // MARK: 第二步 —— 这一章叫什么

    /// 目录里显示的标题。
    ///
    /// 编号一定要，名字只在看得清的时候才要。
    ///
    /// 「第一章 陨落的天才」这种整行就是标题的，连名字一起报。而
    /// 「第一章 陨落的天才　　斗气大陆，分为斗者、斗师……」这种名字和正文
    /// 挤在一行的，就只报「第一章」——从哪儿算名字的结尾没有可靠答案，
    /// 猜错的代价是目录里摆着半句正文，比少一个名字难受得多。
    ///
    /// 名字没丢：正文是从编号那一行开始的，点进去第一行还是完整的原文。
    private static func title(in text: String, marker: Range<String.Index>) -> String {
        let number = String(text[marker]).trimmingCharacters(in: .whitespaces)
        let lineEnd = text[marker.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let rest = String(text[marker.upperBound..<lineEnd])
            .trimmingCharacters(in: titleSeparators)

        guard !rest.isEmpty else { return number }
        // 太长、或者带着句子里才有的标点，说明已经读到正文里去了
        guard rest.count <= titleLimit,
              !rest.contains(where: proseMarks.contains) else { return number }
        return number + " " + rest
    }

    private static func chapters(from text: String, headings: [Range<String.Index>]) -> [ParsedChapter] {
        var result: [ParsedChapter] = []

        // 第一个标题之前的内容（作者的话、简介之类）单独作为一章
        if let first = headings.first, first.lowerBound > text.startIndex {
            let intro = String(text[text.startIndex..<first.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !intro.isEmpty {
                result.append(ParsedChapter(title: "开篇", text: intro))
            }
        }

        for (i, heading) in headings.enumerated() {
            // 从标题那一行开始，不是从标题之后。
            //
            // 一章的第一行就该是它的标题——目录点进来，正文劈头就是内容的话，
            // 人根本认不出这是不是自己要的那一章。
            let start = heading.lowerBound
            let end = i + 1 < headings.count ? headings[i + 1].lowerBound : text.endIndex
            guard start <= end else { continue }

            let name = title(in: text, marker: heading)
            let whole = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ParsedChapter(title: name.isEmpty ? "第 \(i + 1) 章" : name,
                                        text: whole))
        }
        return result
    }

    // MARK: 没有章节标题时按字数切

    private static func chunk(_ text: String) -> [ParsedChapter] {
        guard text.count > chunkSize else {
            return [ParsedChapter(title: "正文", text: text)]
        }

        var result: [ParsedChapter] = []
        var cursor = text.startIndex
        var index = 1

        while cursor < text.endIndex {
            let hardEnd = text.index(cursor, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            // 尽量断在段落边界上，别把句子劈开
            var end = hardEnd
            if hardEnd < text.endIndex,
               let breakPoint = text[cursor..<hardEnd].lastIndex(of: "\n") {
                let candidate = text.index(after: breakPoint)
                if text.distance(from: cursor, to: candidate) > chunkSize / 2 {
                    end = candidate
                }
            }
            let body = String(text[cursor..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                // 编号只是个内部标签，既不写进正文，也不会出现在目录里
                // （见 Split.fromHeadings）。凭空塞进人的文件、或者摆进目录
                // 冒充章节，都是把「我们怎么分片」当成了「书是怎么写的」。
                result.append(ParsedChapter(title: "第 \(index) 段", text: body))
                index += 1
            }
            cursor = end
        }
        return result
    }
}
