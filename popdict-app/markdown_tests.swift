import AppKit

// Markdown.swift 列表渲染的单测(不进 App 打包;跑法:
//   swiftc -o /tmp/popdict_md_test Markdown.swift markdown_tests.swift -framework AppKit && /tmp/popdict_md_test)

@main
struct MDTests {
    static var failures = 0
    static func expect(_ cond: Bool, _ name: String) {
        if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
    }

    // 渲染后找到包含 needle 的那一行,取其段落样式的 headIndent(即该列表项的缩进层级体现)
    static func headIndent(of needle: String, in src: String) -> CGFloat? {
        let a = MD.render(src, width: 400)
        let s = a.string as NSString
        let r = s.range(of: needle)
        guard r.location != NSNotFound else { return nil }
        guard let p = a.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        return p.headIndent
    }

    static func main() {
        let lv0: CGFloat = 18, lv1: CGFloat = 36, lv2: CGFloat = 54

        // 顶层列表项 → 一级缩进
        expect(headIndent(of: "苹果", in: "- 苹果\n- 香蕉") == lv0, "顶层无序项 → 18")

        // 模型最常见:有序项下嵌 4 空格的无序项 → 应是二级(36),不是三级(54)
        expect(headIndent(of: "子项甲", in: "1. 标题一\n    - 子项甲\n2. 标题二") == lv1, "4 空格嵌套 → 36")

        // 2 空格与 3 空格的嵌套同样算二级
        expect(headIndent(of: "子项乙", in: "- 父项\n  - 子项乙") == lv1, "2 空格嵌套 → 36")
        expect(headIndent(of: "子项丙", in: "1. 父项\n   - 子项丙") == lv1, "3 空格嵌套 → 36")

        // tab 缩进也算二级
        expect(headIndent(of: "子项丁", in: "- 父项\n\t- 子项丁") == lv1, "tab 嵌套 → 36")

        // 三层嵌套(0/4/8 空格)→ 逐级 18/36/54
        let deep = "- 一层\n    - 二层\n        - 三层"
        expect(headIndent(of: "一层", in: deep) == lv0 &&
               headIndent(of: "二层", in: deep) == lv1 &&
               headIndent(of: "三层", in: deep) == lv2, "0/4/8 空格 → 18/36/54")

        // 回退:嵌套后回到顶层,层级要弹回
        expect(headIndent(of: "又回顶层", in: "1. 父项\n    - 子项\n2. 又回顶层") == lv0, "回退到顶层 → 18")

        // 段落打断后新列表重新计层:即使首项自带缩进也算顶层
        expect(headIndent(of: "新列表", in: "- 老列表\n\n中间一段话\n\n   - 新列表") == lv0, "段落打断后重新计层 → 18")

        // 空行不打断同一列表的层级关系(宽松列表)
        expect(headIndent(of: "隔行子项", in: "- 父项\n\n    - 隔行子项") == lv1, "空行不打断嵌套 → 36")

        // 有序号的嵌套项与无序一致
        expect(headIndent(of: "编号子项", in: "1. 父项\n    1. 编号子项") == lv1, "嵌套有序项 → 36")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
