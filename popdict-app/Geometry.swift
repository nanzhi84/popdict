import AppKit

// ============================================================
// 浮窗定位的纯几何逻辑(不碰 NSScreen/NSEvent,便于单测:见 geometry_tests.swift)
// ============================================================

let kScreenEdgeGap: CGFloat = 6   // 浮窗与可视区边缘的最小间距

// AX 返回的选区矩形是否可信(全部 Quartz 左上原点坐标)。
// 不少 App(Chrome/Electron 系,尤其对「从下往上」的反向选区)会返回空矩形或干脆给出
// 整个焦点元素的 frame(比如整块网页区域)。盲信后者会把浮窗顶到窗口右上角——即「漂移」的根因。
// 判据:选区矩形必须挨着本次拖拽的轨迹,且高度不能远超拖拽的竖直跨度。
func plausibleSelectionBounds(_ r: CGRect, down: CGPoint, up: CGPoint) -> Bool {
    let drag = CGRect(x: min(down.x, up.x), y: min(down.y, up.y),
                      width: abs(down.x - up.x), height: abs(down.y - up.y))
    guard r.intersects(drag.insetBy(dx: -80, dy: -80)) else { return false }
    return r.height <= drag.height + 160
}

// 有可信选区(AppKit 左下原点坐标):浮窗放选区右侧、顶边对齐选区上沿(会话向下生长);
// 右侧放不下放左侧;都放不下贴屏右边;最后夹紧进可视区。
func rectBesideSelection(_ selAK: CGRect, visible vf: CGRect, w: CGFloat, h: CGFloat) -> NSRect {
    let gap: CGFloat = 12
    var x = selAK.maxX + gap
    if x + w > vf.maxX - kScreenEdgeGap {
        let leftX = selAK.minX - gap - w
        x = leftX >= vf.minX + kScreenEdgeGap ? leftX : vf.maxX - w - kScreenEdgeGap
    }
    x = max(x, vf.minX + kScreenEdgeGap)
    var y = selAK.maxY - h                            // 顶边对齐选区上沿
    y = min(y, vf.maxY - h - kScreenEdgeGap)
    y = max(y, vf.minY + kScreenEdgeGap)
    return NSRect(x: x, y: y, width: w, height: h)
}

// 无可信选区(AppKit 坐标):浮窗水平居中于鼠标释放点、优先放释放点上方(不遮选区);
// 上方放不下放下方;水平/垂直都夹紧进可视区。
func rectNearPoint(_ pt: NSPoint, visible vf: CGRect, w: CGFloat, h: CGFloat) -> NSRect {
    let gap: CGFloat = 12
    var x = pt.x - w / 2
    x = min(max(x, vf.minX + kScreenEdgeGap), vf.maxX - w - kScreenEdgeGap)
    var y = pt.y + gap
    if y + h > vf.maxY - kScreenEdgeGap { y = pt.y - gap - h }   // 上方放不下 → 放下方
    y = min(max(y, vf.minY + kScreenEdgeGap), vf.maxY - h - kScreenEdgeGap)
    return NSRect(x: x, y: y, width: w, height: h)
}
