import SwiftUI
import UIKit

/// Observes touches at the window without cancelling, delaying, or preventing
/// the controls and scroll gestures that actually own them.
struct StudyActivityObserver: UIViewRepresentable {
    var onActivity: () -> Void

    func makeUIView(context: Context) -> StudyActivityWindowProbe {
        StudyActivityWindowProbe(frame: .zero)
    }

    func updateUIView(_ view: StudyActivityWindowProbe, context: Context) {
        view.onActivity = onActivity
        view.attachIfNeeded()
    }

    static func dismantleUIView(_ view: StudyActivityWindowProbe, coordinator: ()) {
        view.detach()
    }
}

final class StudyActivityWindowProbe: UIView {
    var onActivity: (() -> Void)?
    private weak var observedWindow: UIWindow?
    private let observer = StudyActivityGestureRecognizer(target: nil, action: nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        observer.onActivity = { [weak self] in self?.onActivity?() }
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard observedWindow !== window else { return }
        detach()
        guard let window else { return }
        window.addGestureRecognizer(observer)
        observedWindow = window
    }

    func detach() {
        observedWindow?.removeGestureRecognizer(observer)
        observedWindow = nil
    }
}

private final class StudyActivityGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onActivity: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    required init?(coder: NSCoder) { return nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if !touches.isEmpty { onActivity?() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if !touches.isEmpty { onActivity?() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if !touches.isEmpty { onActivity?() }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
