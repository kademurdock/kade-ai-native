import SwiftUI
import UIKit

// MARK: - Family history: one zoomable picture (Sep 29 2026)
//
// DESIGN 1.5 and 4.1: a UIScrollView holding a UIImageView (not a hosted
// SwiftUI view), so pinching and panning a large scan stays smooth. Pinch or
// double tap to zoom, up to 4 times; a horizontal swipe moves to the next or
// previous picture only while the picture is not zoomed in (zoomed in, a drag
// pans it). The same zoom is on buttons in the viewer, because no gesture is
// the only way to do anything.
//
// It is hidden from VoiceOver on its own: the viewer wraps it in ONE
// adjustable element carrying the alt text (zooming is visual only).
// Smart Invert leaves the picture alone.
//
// `identity` names the picture (its media id and copy): a new identity goes
// back to the whole picture; a sharper file of the same picture replaces the
// old one where it is, at the same zoom.

struct FamilyZoomImage: UIViewRepresentable {
    let picture: UIImage?
    let identity: String
    @Binding var zoom: CGFloat
    let motionAllowed: Bool
    /// +1 for the next picture, -1 for the previous one.
    let onSwipe: (Int) -> Void

    static let maxZoom: CGFloat = 4

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> FamilyZoomScrollView {
        let scroll = FamilyZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = Self.maxZoom
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        scroll.isAccessibilityElement = false
        scroll.accessibilityElementsHidden = true
        scroll.accessibilityIgnoresInvertColors = true
        scroll.panGestureRecognizer.isEnabled = false

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let left = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
        left.direction = .left
        scroll.addGestureRecognizer(left)
        let right = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
        right.direction = .right
        scroll.addGestureRecognizer(right)
        return scroll
    }

    func updateUIView(_ scroll: FamilyZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.identity != identity {
            coordinator.identity = identity
            scroll.setZoomScale(1, animated: false)
            scroll.imageView.image = picture
            scroll.setNeedsLayout()
        } else if scroll.imageView.image !== picture {
            // A sharper file of the same picture: swapped in where it is.
            scroll.imageView.image = picture
        }
        let wanted: CGFloat = min(max(1, zoom), Self.maxZoom)
        if !scroll.isZooming && !scroll.isZoomBouncing && abs(scroll.zoomScale - wanted) > 0.01 {
            scroll.setZoomScale(wanted, animated: motionAllowed)
        }
        coordinator.updatePanning(scroll)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: FamilyZoomImage
        var identity: String?

        init(parent: FamilyZoomImage) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? FamilyZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updatePanning(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            updatePanning(scrollView)
            let reached: CGFloat = scale
            // Never write SwiftUI state inside UIKit's own layout pass.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if abs(self.parent.zoom - reached) > 0.01 { self.parent.zoom = reached }
            }
        }

        /// Zoomed in, a drag pans; at the whole picture, a swipe changes it.
        func updatePanning(_ scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? FamilyZoomScrollView else { return }
            let animated: Bool = parent.motionAllowed
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: animated)
                return
            }
            let point: CGPoint = gesture.location(in: scroll.imageView)
            let width: CGFloat = scroll.bounds.width / 2.5
            let height: CGFloat = scroll.bounds.height / 2.5
            let target = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            scroll.zoom(to: target, animated: animated)
        }

        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, scroll.zoomScale <= 1.01 else { return }
            parent.onSwipe(gesture.direction == .left ? 1 : -1)
        }
    }
}

/// The scroll view and its picture. At the whole picture, the image view is
/// exactly the scroll view's size (the picture fits inside it, letterboxed);
/// zooming scales that view, and it stays centred while smaller than the
/// screen.
final class FamilyZoomScrollView: UIScrollView {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.accessibilityIgnoresInvertColors = true
        imageView.isAccessibilityElement = false
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= minimumZoomScale + 0.001 {
            let whole = CGRect(origin: .zero, size: bounds.size)
            if imageView.frame != whole {
                imageView.frame = whole
                contentSize = bounds.size
            }
        }
        centreImage()
    }

    private func centreImage() {
        let size: CGSize = imageView.frame.size
        let x: CGFloat = max(0, (bounds.width - size.width) / 2)
        let y: CGFloat = max(0, (bounds.height - size.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
}
