import CoreGraphics

// 纯几何:算「翻译/解释」小按钮的原点。
// 紧贴选区右侧、顶边对齐选区上沿;按按钮自身尺寸(w/h)判断,放不下就夹回屏内(仍贴近选区),
// 不按未来会话面板宽度预留——否则选区靠右时按钮会被远远甩到左边(漂移)。
func popupButtonOrigin(selAK: CGRect, w: CGFloat, h: CGFloat, gap: CGFloat, vf: CGRect) -> CGPoint {
    let margin: CGFloat = 6
    var x = selAK.maxX + gap                       // 默认贴选区右侧
    if x + w > vf.maxX - margin { x = vf.maxX - w - margin }   // 右侧放不下:贴屏右边(仍在选区右端附近)
    if x < vf.minX + margin { x = vf.minX + margin }
    var y = selAK.maxY - h                         // 顶边对齐选区上沿
    if y + h > vf.maxY - margin { y = vf.maxY - margin - h }
    if y < vf.minY + margin { y = vf.minY + margin }
    return CGPoint(x: x, y: y)
}
