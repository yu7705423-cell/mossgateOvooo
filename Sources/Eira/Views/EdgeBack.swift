import SwiftUI
import UIKit

/// 从屏幕左缘往右滑返回（网页版 shell/goback.js 的顺序）：
///     弹出来的那一层（表单、图片、面板）开着    先关它
///     这一层里推进去过页面                      退一级，归系统自己的手势管，这里不动
///     已经在 app 的第一页                        回到主屏
/// 系统的边缘手势只管「退一级」，另外两种由这里补上。挂在打开的 app 外面（AppHost）。
struct EdgeBack: UIViewRepresentable {
    var close: () -> Void

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
