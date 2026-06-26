import AppKit
import CoreGraphics

// ============================================================
// 框选截图组件:全屏遮罩拖选 → 截「遮罩下方」真实画面 → PNG/base64 编码
// 给 popdict 的「截图解释」用:截到的图发给 MiMo(mimo-v2.5)多模态看图讲解。
// ============================================================

// 可成为 key 的无边框遮罩窗口(为了能收到 Esc 键)
private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// 全屏遮罩:拖动框选,选区外压暗、选区内透明,显示像素尺寸;Esc 取消,松手确认。
private final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?   // 选区(本视图坐标);nil = 取消
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var finished = false

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func finish(_ rect: NSRect?) {
        if finished { return }
        finished = true
        onFinish?(rect)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let r = currentRect
        if r.width > 8 && r.height > 8 { finish(r) } else { finish(nil) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }   // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        // 先把整块清成透明(消除上一帧残留)
        NSColor.clear.setFill()
        bounds.fill(using: .copy)

        let dim = NSColor.black.withAlphaComponent(0.35)
        dim.setFill()
        let sel = currentRect
        if sel.width < 1 || sel.height < 1 {
            bounds.fill()
            return
        }
        // 选区外四块压暗,选区内保持透明
        let b = bounds
        NSRect(x: b.minX, y: sel.maxY, width: b.width, height: b.maxY - sel.maxY).fill()       // 上
        NSRect(x: b.minX, y: b.minY, width: b.width, height: sel.minY - b.minY).fill()         // 下
        NSRect(x: b.minX, y: sel.minY, width: sel.minX - b.minX, height: sel.height).fill()    // 左
        NSRect(x: sel.maxX, y: sel.minY, width: b.maxX - sel.maxX, height: sel.height).fill()  // 右

        // 边框
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: sel); path.lineWidth = 1.5; path.stroke()

        // 尺寸标签(像素;乘以 backingScale 更贴近真实截图分辨率)
        let scale = window?.backingScaleFactor ?? 2
        let label = "\(Int(sel.width * scale)) × \(Int(sel.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        let lx = sel.minX
        var ly = sel.maxY + 4
        if ly + size.height + 4 > b.maxY { ly = sel.minY - size.height - 6 }
        let bg = NSRect(x: lx - 4, y: ly - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        (label as NSString).draw(at: NSPoint(x: lx, y: ly), withAttributes: attrs)
    }
}

final class RegionCapture {
    private var window: CaptureWindow?

    // 所有屏幕并集(AppKit 坐标)
    private static func unionFrame() -> NSRect {
        NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
    }

    // 弹出全屏遮罩让用户框选;完成回调在主线程,取消时为 nil。
    func capture(completion: @escaping (NSImage?) -> Void) {
        let union = RegionCapture.unionFrame()
        let win = CaptureWindow(contentRect: union, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = SelectionView(frame: NSRect(origin: .zero, size: union.size))
        win.contentView = view
        window = win

        view.onFinish = { [weak self] localRect in
            guard let self = self, let win = self.window else { completion(nil); return }
            guard let localRect = localRect else {
                win.orderOut(nil); self.window = nil; completion(nil); return
            }
            // 本视图坐标 → AppKit 全局 → Quartz 全局(左上原点)
            let globalAK = NSRect(x: union.minX + localRect.minX,
                                  y: union.minY + localRect.minY,
                                  width: localRect.width, height: localRect.height)
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let quartz = CGRect(x: globalAK.minX, y: primaryH - globalAK.maxY,
                                width: globalAK.width, height: globalAK.height)
            // 截遮罩窗口「下方」的真实画面(压暗层不会进图);此刻窗口仍在屏上
            let winID = CGWindowID(win.windowNumber)
            let cg = CGWindowListCreateImage(quartz, .optionOnScreenBelowWindow, winID,
                                             [.bestResolution, .boundsIgnoreFraming])
            win.orderOut(nil); self.window = nil
            guard let cg = cg, cg.width > 0, cg.height > 0 else { completion(nil); return }
            let img = NSImage(cgImage: cg, size: NSSize(width: quartz.width, height: quartz.height))
            completion(img)
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
    }

    // NSImage → 缩放(最长边 ≤ 2048)→ PNG → base64 data URL
    static func encodeToDataURL(_ image: NSImage) -> String? {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide = 2048
        let w = cg.width, h = cg.height
        if max(w, h) > maxSide {
            let scale = CGFloat(maxSide) / CGFloat(max(w, h))
            let nw = max(1, Int(CGFloat(w) * scale)), nh = max(1, Int(CGFloat(h) * scale))
            if let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                if let scaled = ctx.makeImage() { cg = scaled }
            }
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    // 屏幕录制权限(与「辅助功能」彼此独立)
    static func hasScreenRecordingPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }
}
