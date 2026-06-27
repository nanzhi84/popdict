import AppKit

// ============================================================
// 轻量 Markdown → NSAttributedString 渲染器(块级 + 行内)
// 块级:标题 # ~ ######、无序/有序列表、代码块 ```、分隔线 ---、引用 >、表格 | a | b |
// 行内:**粗体** *斜体* `行内代码` [链接](url)  ← 复用 Apple 的 inline 解析
// 自包含,无外部依赖,可单独编译做离屏测试。
// ============================================================

enum MD {

    // 代码块标记:LayoutManager 据此在整段后面画满宽圆角底
    static let codeBlockKey = NSAttributedString.Key("popdictCodeBlock")
    // 追问气泡标记:LayoutManager 据此画浅 accent 圆角底(区分用户追问与 AI 回答)
    static let userMsgKey = NSAttributedString.Key("popdictUserMsg")
    // 朗读段落标记:Speaker 据此扫描出某段正文的字符范围(取文字 + 逐句高亮定位)
    static let speakIdKey = NSAttributedString.Key("popdictSpeakId")

    // MARK: 主入口

    static func render(_ src: String,
                       width: CGFloat,
                       baseFont: NSFont = .systemFont(ofSize: 14),
                       textColor: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
                       .components(separatedBy: "\n")
        var i = 0
        var para: [String] = []

        func flushPara() {
            guard !para.isEmpty else { return }
            let text = para.joined(separator: "\n")
            para.removeAll()
            let a = NSMutableAttributedString(attributedString:
                inlineAttributed(text, baseFont: baseFont, color: textColor))
            a.addAttribute(.paragraphStyle, value: bodyStyle(),
                           range: NSRange(location: 0, length: a.length))
            out.append(a)
            out.append(NSAttributedString(string: "\n"))
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            // 代码块
            if t.hasPrefix("```") {
                flushPara()
                var code: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 } // 跳过结尾 ```
                out.append(codeBlock(code.joined(separator: "\n"), baseFont: baseFont))
                continue
            }
            // 空行
            if t.isEmpty { flushPara(); i += 1; continue }
            // 分隔线
            if isHR(t) {
                flushPara(); out.append(horizontalRule(width: width)); i += 1; continue
            }
            // 标题
            if let (level, content) = heading(t) {
                flushPara()
                out.append(headingAttr(content, level: level, baseFont: baseFont, color: textColor))
                i += 1; continue
            }
            // 表格(GFM):本行含 | 且下一行是 |---|---| 分隔行
            if t.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                flushPara()
                let header = splitTableRow(line)
                let aligns = tableAligns(lines[i + 1], columns: header.count)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let rt = lines[i].trimmingCharacters(in: .whitespaces)
                    if rt.isEmpty || !rt.contains("|") { break }
                    rows.append(splitTableRow(lines[i]))
                    i += 1
                }
                out.append(tableAttr(header: header, aligns: aligns, rows: rows, baseFont: baseFont, color: textColor))
                continue
            }
            // 引用
            if t.hasPrefix(">") {
                flushPara()
                let q = String(t.drop(while: { $0 == ">" || $0 == " " }))
                out.append(quoteAttr(q, baseFont: baseFont, color: textColor))
                i += 1; continue
            }
            // 列表项
            if let item = listItem(line) {
                flushPara()
                out.append(listAttr(item, baseFont: baseFont, color: textColor))
                i += 1; continue
            }
            // 普通段落(连续非空行合并为一段)
            para.append(t); i += 1
        }
        flushPara()

        // 去掉结尾多余换行
        while out.length > 0, (out.string as NSString).hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    // MARK: 行内(复用 Apple inline markdown)

    static func inlineAttributed(_ s: String, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? NSAttributedString(markdown: s, options: opts) else {
            return NSAttributedString(string: s, attributes: [.font: baseFont, .foregroundColor: color])
        }
        let m = NSMutableAttributedString(attributedString: parsed)
        let full = NSRange(location: 0, length: m.length)

        // 1) 字体统一到 baseFont 字号,保留粗/斜 traits
        m.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let d = baseFont.fontDescriptor.withSymbolicTraits(traits.intersection([.bold, .italic]))
            let f = NSFont(descriptor: d, size: baseFont.pointSize) ?? baseFont
            m.addAttribute(.font, value: f, range: range)
        }
        // 缺省字体的 run 兜底
        m.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil { m.addAttribute(.font, value: baseFont, range: range) }
        }
        // 2) 统一前景色
        m.addAttribute(.foregroundColor, value: color, range: full)
        // 3) 行内代码:等宽 + 浅底
        m.enumerateAttribute(.inlinePresentationIntent, in: full, options: []) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue ?? (value as? UInt) else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 0.5, weight: .regular)
                m.addAttribute(.font, value: mono, range: range)
                m.addAttribute(.backgroundColor, value: NSColor.secondaryLabelColor.withAlphaComponent(0.12), range: range)
            }
        }
        // 4) 链接:强调色 + 下划线
        m.enumerateAttribute(.link, in: full, options: []) { value, range, _ in
            if value != nil {
                m.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
                m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return m
    }

    // MARK: 段落样式

    static func bodyStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 9
        return p
    }

    // MARK: 标题

    private static func heading(_ s: String) -> (Int, String)? {
        var n = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", n < 6 { n += 1; idx = s.index(after: idx) }
        guard n > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        var content = String(s[s.index(after: idx)...])
        // 去掉 ATX 闭合井号:"## 标题 ##" → "标题"
        content = content.trimmingCharacters(in: .whitespaces)
        while content.hasSuffix("#") { content.removeLast() }
        content = content.trimmingCharacters(in: .whitespaces)
        return (n, content)
    }

    private static func headingAttr(_ content: String, level: Int, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let size: CGFloat
        let weight: NSFont.Weight
        let before: CGFloat, after: CGFloat
        switch level {
        case 1: size = 19;   weight = .bold;     before = 12; after = 5
        case 2: size = 16.5; weight = .bold;     before = 11; after = 4
        case 3: size = 14.5; weight = .semibold; before = 9;  after = 3
        default: size = 14;  weight = .semibold; before = 8;  after = 2
        }
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        let m = NSMutableAttributedString(attributedString: inlineAttributed(content, baseFont: f, color: color))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = 2
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    // MARK: 列表

    private struct Item { let level: Int; let marker: String; let text: String }

    private static func listItem(_ line: String) -> Item? {
        let leading = line.prefix(while: { $0 == " " }).count
        let s = String(line.dropFirst(leading))
        let level = leading / 2
        // 无序(含任务列表 [ ] / [x])
        if let first = s.first, "-*+".contains(first) {
            let rest = s.dropFirst()
            if rest.first == " " {
                var text = String(rest.drop(while: { $0 == " " }))
                var marker = "•"
                if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
                else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
                return Item(level: level, marker: marker, text: text)
            }
        }
        // 有序 1. / 1)(保留原始标点风格)
        var idx = s.startIndex
        var digits = ""
        while idx < s.endIndex, s[idx].isNumber { digits.append(s[idx]); idx = s.index(after: idx) }
        if !digits.isEmpty, idx < s.endIndex, s[idx] == "." || s[idx] == ")" {
            let punct = String(s[idx])
            let after = s.index(after: idx)
            if after < s.endIndex, s[after] == " " {
                return Item(level: level, marker: digits + punct, text: String(s[after...].drop(while: { $0 == " " })))
            }
        }
        return nil
    }

    private static func listAttr(_ item: Item, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let indent = 18 + CGFloat(item.level) * 18
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 4
        p.firstLineHeadIndent = max(0, indent - 16)
        p.headIndent = indent
        p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        let bulletColor = item.marker == "•" ? NSColor.secondaryLabelColor : color
        let m = NSMutableAttributedString(string: item.marker + "\t",
                                          attributes: [.font: baseFont, .foregroundColor: bulletColor, .paragraphStyle: p])
        let body = NSMutableAttributedString(attributedString: inlineAttributed(item.text, baseFont: baseFont, color: color))
        body.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: body.length))
        m.append(body)
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    // MARK: 表格(GFM → NSTextTable)

    // 判定是否为表格分隔行,如 |---|:--:|--:|(每格只含 - : 且至少一个 -)
    private static func isTableDelimiter(_ line: String) -> Bool {
        guard line.contains("-"), line.contains("|") else { return false }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.contains("-") && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    // 拆一行表格为单元格:去掉首尾 |,按 | 分(不处理转义 \| —— 罕见,够用)
    private static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // 从分隔行解析每列对齐(:--- 左 / :--: 中 / ---: 右)
    private static func tableAligns(_ line: String, columns: Int) -> [NSTextAlignment] {
        var a: [NSTextAlignment] = splitTableRow(line).map { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            return (l && r) ? .center : (r ? .right : .left)
        }
        while a.count < columns { a.append(.left) }
        return a
    }

    private static func tableAttr(header: [String], aligns: [NSTextAlignment], rows: [[String]],
                                  baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let cols = max(1, header.count)
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false

        func cell(_ text: String, row: Int, col: Int, isHeader: Bool) -> NSAttributedString {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: col, columnSpan: 1)
            block.setBorderColor(NSColor.separatorColor.withAlphaComponent(0.55))
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setWidth(7, type: .absoluteValueType, for: .padding)
            if isHeader { block.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12) }
            let p = NSMutableParagraphStyle()
            p.textBlocks = [block]
            p.alignment = col < aligns.count ? aligns[col] : .left
            p.lineSpacing = 2
            let f = isHeader ? NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold) : baseFont
            let m = NSMutableAttributedString(attributedString: inlineAttributed(text, baseFont: f, color: color))
            if m.length == 0 { m.append(NSAttributedString(string: " ", attributes: [.font: f, .foregroundColor: color])) }
            m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
            m.append(NSAttributedString(string: "\n"))
            return m
        }

        let out = NSMutableAttributedString()
        for c in 0..<cols { out.append(cell(c < header.count ? header[c] : "", row: 0, col: c, isHeader: true)) }
        for (ri, rowCells) in rows.enumerated() {
            for c in 0..<cols { out.append(cell(c < rowCells.count ? rowCells[c] : "", row: ri + 1, col: c, isHeader: false)) }
        }
        // 关闭表格段 + 与下文留白(不带 textBlocks 的普通换行)
        let tail = NSMutableAttributedString(string: "\n")
        let tp = NSMutableParagraphStyle(); tp.paragraphSpacingBefore = 4; tp.paragraphSpacing = 9
        tail.addAttribute(.paragraphStyle, value: tp, range: NSRange(location: 0, length: tail.length))
        out.append(tail)
        return out
    }

    // MARK: 引用

    private static func quoteAttr(_ s: String, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 8
        p.firstLineHeadIndent = 14
        p.headIndent = 14
        let bar = NSMutableAttributedString(string: "▎ ",
            attributes: [.font: baseFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: p])
        let body = NSMutableAttributedString(attributedString:
            inlineAttributed(s, baseFont: baseFont, color: NSColor.secondaryLabelColor))
        body.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: body.length))
        bar.append(body)
        bar.append(NSAttributedString(string: "\n"))
        return bar
    }

    // MARK: 代码块

    private static func codeBlock(_ code: String, baseFont: NSFont) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 12      // 内部左右留白(底块满宽,文字缩进)
        p.headIndent = 12
        p.tailIndent = -12
        p.lineSpacing = 3
        p.paragraphSpacingBefore = 18   // 与上文(标题/正文)拉开距离(边框外扩 5px 后仍留 ~13px)
        p.paragraphSpacing = 18         // 与下文拉开距离
        // 把每行的 \n 换成行分隔符 U+2028,使整块代码是「同一段落」——行间只走 lineSpacing,
        // 不再叠加段落间距(消除缝隙);满宽圆角底交给 CodeBlockLayoutManager 画(不再用碎的 .backgroundColor)。
        let oneParagraph = code.replacingOccurrences(of: "\n", with: "\u{2028}")
        let m = NSMutableAttributedString(string: oneParagraph, attributes: [
            .font: mono,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: p,
            codeBlockKey: true
        ])
        m.append(NSAttributedString(string: "\n"))   // 结束段落(不带 codeBlockKey)
        return m
    }

    // MARK: 分隔线

    private static func isHR(_ s: String) -> Bool {
        let body = s.filter { $0 != " " }
        guard body.count >= 3 else { return false }
        let set = Set(body)
        return set == ["-"] || set == ["*"] || set == ["_"]
    }

    static func horizontalRule(width: CGFloat) -> NSAttributedString {
        let cell = HRCell(width: width - 24)
        let att = NSTextAttachment()
        att.attachmentCell = cell
        let m = NSMutableAttributedString(attributedString: NSAttributedString(attachment: att))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 6
        p.paragraphSpacing = 8
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: "\n"))
        return m
    }
}

// 在标记段落(代码块 / 追问气泡)后面画一块满宽圆角底,行间连续无缝
final class CodeBlockLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let ts = textStorage {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawBlocks(MD.codeBlockKey, in: charRange, origin: origin, ts: ts,
                       fill: NSColor.secondaryLabelColor.withAlphaComponent(0.13),
                       stroke: NSColor.secondaryLabelColor.withAlphaComponent(0.30))
            drawBlocks(MD.userMsgKey, in: charRange, origin: origin, ts: ts,
                       fill: NSColor.controlAccentColor.withAlphaComponent(0.12),
                       stroke: NSColor.controlAccentColor.withAlphaComponent(0.28))
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawBlocks(_ key: NSAttributedString.Key, in charRange: NSRange, origin: NSPoint,
                            ts: NSTextStorage, fill: NSColor, stroke: NSColor) {
        ts.enumerateAttribute(key, in: charRange, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let gr = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard let container = self.textContainer(forGlyphAt: gr.location, effectiveRange: nil) else { return }
            // 用 usedRect(实际文字范围),不用 lineFragment rect——后者把段落上/下间距算进去会让边框吃进相邻文字;
            // 用 usedRect 后,段落间距留在边框外,成为真正的间隔。
            var block = CGRect.null
            self.enumerateLineFragments(forGlyphRange: gr) { _, usedRect, _, _, _ in
                block = block.isNull ? usedRect : block.union(usedRect)
            }
            guard !block.isNull else { return }
            let w = container.size.width
            var r = CGRect(x: 3, y: block.minY, width: max(10, w - 6), height: block.height)
            r = r.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -7)   // 边框紧贴文字,留 7px 内边距
            let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            fill.setFill(); path.fill()
            stroke.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}

// 画一条满宽细线的附件 cell(给 markdown 的 --- 用)
final class HRCell: NSTextAttachmentCell {
    private let w: CGFloat
    init(width: CGFloat) { self.w = max(10, width); super.init() }
    required init(coder: NSCoder) { fatalError() }
    override func cellSize() -> NSSize { NSSize(width: w, height: 9) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let y = cellFrame.midY.rounded() + 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cellFrame.minX, y: y))
        path.line(to: NSPoint(x: cellFrame.minX + w, y: y))
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}
