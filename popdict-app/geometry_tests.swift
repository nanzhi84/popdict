import AppKit

// Geometry.swift 的单测(不进 App 打包;跑法:
//   swiftc -o /tmp/popdict_geo_test Geometry.swift geometry_tests.swift -framework AppKit && /tmp/popdict_geo_test)

@main
struct GeoTests {
    static var failures = 0
    static func expect(_ cond: Bool, _ name: String) {
        if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
    }

    static func main() {
        // —— plausibleSelectionBounds(Quartz 左上原点)——

        // 正常:单行选中,从左往右拖,选区就在拖拽轨迹上
        expect(plausibleSelectionBounds(CGRect(x: 100, y: 500, width: 220, height: 22),
                                        down: CGPoint(x: 105, y: 510), up: CGPoint(x: 315, y: 512)),
               "单行正向选中 → 可信")

        // 正常:从下往上反向选中三行
        expect(plausibleSelectionBounds(CGRect(x: 80, y: 430, width: 500, height: 66),
                                        down: CGPoint(x: 400, y: 490), up: CGPoint(x: 90, y: 435)),
               "多行反向(下→上)选中 → 可信")

        // 正常:单行输入框的整体 frame(m3 兜底的合法场景:小输入框)
        expect(plausibleSelectionBounds(CGRect(x: 300, y: 300, width: 400, height: 28),
                                        down: CGPoint(x: 320, y: 314), up: CGPoint(x: 500, y: 314)),
               "单行输入框 frame → 可信")

        // 垃圾:整块网页区域的 frame(高约 900,拖拽只有几十像素)→ 拒绝
        expect(!plausibleSelectionBounds(CGRect(x: 0, y: 80, width: 1600, height: 900),
                                         down: CGPoint(x: 400, y: 600), up: CGPoint(x: 700, y: 560)),
               "整元素 frame(网页区域)→ 拒绝")

        // 垃圾:矩形远离拖拽轨迹(比如报到了屏幕右上角)→ 拒绝
        expect(!plausibleSelectionBounds(CGRect(x: 1300, y: 80, width: 200, height: 24),
                                         down: CGPoint(x: 300, y: 700), up: CGPoint(x: 500, y: 660)),
               "远离拖拽轨迹的矩形 → 拒绝")

        // 边界:选区比拖拽略高(选中整段但拖拽只扫过大半)→ 仍可信
        expect(plausibleSelectionBounds(CGRect(x: 80, y: 400, width: 500, height: 120),
                                        down: CGPoint(x: 100, y: 500), up: CGPoint(x: 560, y: 420)),
               "选区略高于拖拽跨度 → 可信")

        // —— rectBesideSelection(AppKit 左下原点)——
        let vf = NSRect(x: 0, y: 0, width: 1800, height: 1100)   // 简化的可视区

        // 常规:右侧放得下 → 贴选区右侧、顶边对齐选区上沿
        let r1 = rectBesideSelection(NSRect(x: 200, y: 600, width: 400, height: 60), visible: vf, w: 150, h: 32)
        expect(abs(r1.minX - (600 + 12)) < 0.5 && abs(r1.maxY - 660) < 0.5, "选区右侧、顶边对齐")

        // 选区贴屏右缘:右侧放不下 → 放左侧
        let r2 = rectBesideSelection(NSRect(x: 1400, y: 600, width: 380, height: 60), visible: vf, w: 150, h: 32)
        expect(abs(r2.maxX - (1400 - 12)) < 0.5 && abs(r2.maxY - 660) < 0.5, "右侧放不下 → 左侧")

        // 选区横跨全屏:左右都放不下 → 贴屏右边,但必须完全在屏内
        let r3 = rectBesideSelection(NSRect(x: 10, y: 600, width: 1780, height: 60), visible: vf, w: 150, h: 32)
        expect(r3.maxX <= vf.maxX && r3.minX >= vf.minX && r3.maxY <= vf.maxY, "全屏宽选区 → 夹紧屏内")

        // 选区顶到屏幕顶:浮窗不能超出可视区上沿
        let r4 = rectBesideSelection(NSRect(x: 200, y: 1090, width: 400, height: 60), visible: vf, w: 150, h: 32)
        expect(r4.maxY <= vf.maxY, "选区贴顶 → 不超屏")

        // —— rectNearPoint(AppKit 左下原点)——

        // 常规:浮窗在释放点上方、水平居中
        let p1 = rectNearPoint(NSPoint(x: 900, y: 500), visible: vf, w: 150, h: 32)
        expect(p1.minY > 500 && abs(p1.midX - 900) < 0.5, "释放点上方、水平居中")

        // 释放点贴屏顶:上方放不下 → 放下方
        let p2 = rectNearPoint(NSPoint(x: 900, y: 1090), visible: vf, w: 150, h: 32)
        expect(p2.maxY < 1090 && p2.maxY <= vf.maxY, "贴顶 → 放下方")

        // 释放点贴屏左缘:水平夹紧
        let p3 = rectNearPoint(NSPoint(x: 10, y: 500), visible: vf, w: 150, h: 32)
        expect(p3.minX >= vf.minX && p3.minY > 500, "贴左缘 → 水平夹紧")

        // 释放点在右下角:全部夹紧进屏内
        let p4 = rectNearPoint(NSPoint(x: 1795, y: 5), visible: vf, w: 150, h: 32)
        expect(p4.maxX <= vf.maxX && p4.minY >= vf.minY && p4.maxY <= vf.maxY, "右下角 → 全夹紧")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
