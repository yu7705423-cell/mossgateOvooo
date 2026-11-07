import SwiftUI
import UIKit

/// 从屏幕左缘往右滑返回（网页版 shell/goback.js 的顺序）：
///     弹出来的那一层（表单、图片、面板）开着    先关它
///     这一层里推进去过页面                      退一级，归系统自己的手势管，这里不动
///     已经在 app 的第一页                        回到主屏
/// 系统的边缘手势只管「退一级」，另外两种由这里补上。挂在打开的 app 外面（AppHost）。
struct EdgeBack: UIViewRepresentable {
    var close: () -> Void

    /// 正在拒绝左缘右滑的页面数（`RefuseEdgeBack`）。大于 0 时这里不关浮层、不回主屏
    @MainActor static var refusals = 0

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ v: Probe, context: Context) { context.coordinator.close = close }

    static func dismantleUIView(_ v: Probe, coordinator: Coordinator) { coordinator.detach() }

    /// 只为拿到所在的窗口：手势挂在窗口上，弹出来的那几层也在同一个窗口里
    final class Probe: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let w = window { coordinator?.attach(to: w) }
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var close: () -> Void
        private var pan: UIScreenEdgePanGestureRecognizer?

        init(close: @escaping () -> Void) { self.close = close }

        func attach(to w: UIWindow) {
            guard pan == nil else { return }
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(fire(_:)))
            g.edges = .left
            g.delegate = self
            g.cancelsTouchesInView = false
            w.addGestureRecognizer(g)
            pan = g
        }

        func detach() {
            if let g = pan { g.view?.removeGestureRecognizer(g) }
            pan = nil
        }

        // 和系统的退一级手势、页面里的横滑一起认，不抢
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func fire(_ g: UIScreenEdgePanGestureRecognizer) {
            guard g.state == .ended, let w = g.view as? UIWindow else { return }
            // 自己用左边缘的页面（美化预览放大之后）：一律不离开这一页（网页版 4.1024，用户定的「完全不退出」）
            if EdgeBack.refusals > 0 { return }
            let t = g.translation(in: w), v = g.velocity(in: w)
            guard t.x > 60 || v.x > 600, abs(t.y) < max(80, t.x) else { return }
            // 打开的 app 是根上弹出来的第一层；再往上是 app 里弹出来的
            guard let host = w.rootViewController?.presentedViewController, !host.isBeingDismissed else { return }
            var top = host
            while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
            if top is UIAlertController { return }
            if Self.depth(top) > 1 { return }
            if top !== host { top.dismiss(animated: true); return }
            close()
        }

        /// 这一层当前看得见的导航栈有几页
        static func depth(_ vc: UIViewController) -> Int {
            if let n = vc as? UINavigationController {
                return max(n.viewControllers.count, n.topViewController.map(depth) ?? 0)
            }
            if let t = vc as? UITabBarController, let s = t.selectedViewController { return depth(s) }
            return vc.children.map(depth).max() ?? 0
        }
    }
}

/// 这一块挂着时左缘右滑一律不离开这一页（网页版 4.1024 的 data-edge="off"）：系统的退一级手势停用，
/// EdgeBack 也不关浮层、不回主屏。active 变假或这一块卸下时恢复
struct RefuseEdgeBack: UIViewRepresentable {
    var active: Bool

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ v: Probe, context: Context) { v.set(active) }

    static func dismantleUIView(_ v: Probe, coordinator: ()) { v.set(false) }

    final class Probe: UIView {
        private var on = false
        private weak var nav: UINavigationController?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { set(false) } else if on { apply(true) }
        }

        @MainActor func set(_ v: Bool) {
            guard v != on else { return }
            on = v
            EdgeBack.refusals = max(0, EdgeBack.refusals + (v ? 1 : -1))
            apply(v)
        }

        private func apply(_ v: Bool) {
            if nav == nil { nav = Self.findNav(from: self) }
            nav?.interactivePopGestureRecognizer?.isEnabled = !v
        }

        /// 往上找最近的导航控制器（SwiftUI 的 NavigationStack 底下是它）
        static func findNav(from view: UIView) -> UINavigationController? {
            var r: UIResponder? = view
            while let cur = r {
                if let vc = cur as? UIViewController, let n = vc.navigationController ?? (vc as? UINavigationController) { return n }
                r = cur.next
            }
            return nil
        }
    }
}
