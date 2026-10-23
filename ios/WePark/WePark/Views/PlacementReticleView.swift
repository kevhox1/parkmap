//
//  PlacementReticleView.swift
//  WePark
//
//  Stream A2 (curb-pin placement map layer): the fixed needle pin, the snap ghost and the
//  tether - ONE non-interactive UIKit view added over the map for the life of the mode, so the
//  three elements are drawn in one coordinate space and cannot misalign (spec A.3 "Reticle").
//  NOT an MKAnnotation: the pin is fixed on screen while the map moves under it.
//
//  Numbers are the Stream B design review's (docs/design/curb-pin-placement-design.md section 1),
//  which supersede the amendment's:
//    Needle    44 pt head (white fill, 2 pt black outline), 20 pt stem tapering 4 -> 1 pt (white,
//              1.5 pt black outline). 64 pt total; the TIP is exactly `tipPoint` (40% of height).
//    Ground    12x5 black ellipse centred on the tip (16x7 while lifted). The honest location
//    mark     while the needle is lifted; it never moves.
//    Lift      needle translates up 8 pt while a finger is down, drops on settle
//              (UIView.animate 0.12 s, spring damping 0.8). Under Reduce Motion no translation;
//              the ground mark still grows as the "you are moving" cue.
//    Ghost     white 16 pt circle, 2.5 pt black ring (21 pt outer) ON the snapped curb point.
//    Tether    black 5 pt under white 3 pt, round caps, tip -> ghost, hidden under 4 pt, solid.
//    Alpha     none on any element (a shadow's alpha is allowed). Chrome is monochrome - the
//              severity colour appears ONLY on the highlight core, as data.
//
//  Updates are IMPERATIVE: `update(ghost:)` runs every display-link tick and touches CALayers
//  only (implicit animations disabled) - never SwiftUI state (spec A.4 / A23; FT-17a).
//
//  Decorative for accessibility: the VoiceOver face of the pin is the adjustable summary element
//  in the card (design section 4), not this view.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode on this machine - Kevin verifies on his Mac.
//

import UIKit

final class PlacementReticleView: UIView {

    // MARK: Design constants (points)

    static let needleHeadDiameter: CGFloat = 44
    static let needleHeadOutline: CGFloat = 2
    static let needleStemLength: CGFloat = 20
    static let needleStemTopWidth: CGFloat = 4
    static let needleStemTipWidth: CGFloat = 1
    static let needleStemOutline: CGFloat = 1.5
    static let liftOffset: CGFloat = 8
    static let liftDuration: TimeInterval = 0.12
    static let liftSpringDamping: CGFloat = 0.8
    static let revealDuration: TimeInterval = 0.15

    static let groundMarkSize = CGSize(width: 12, height: 5)
    static let groundMarkLiftedSize = CGSize(width: 16, height: 7)

    static let ghostFillDiameter: CGFloat = 16
    static let ghostRingWidth: CGFloat = 2.5

    static let tetherCasingWidth: CGFloat = 5
    static let tetherCoreWidth: CGFloat = 3
    static let tetherHideBelowPoints: CGFloat = 4

    // MARK: Layers

    /// Hosts the needle layers so the lift is a plain `UIView` transform animation.
    private let needleView = UIView()
    private let stemLayer = CAShapeLayer()
    private let headLayer = CAShapeLayer()
    private let groundMarkLayer = CAShapeLayer()
    private let ghostLayer = CAShapeLayer()
    private let tetherCasingLayer = CAShapeLayer()
    private let tetherCoreLayer = CAShapeLayer()

    private var tip: CGPoint = .zero
    private var ghostPoint: CGPoint?
    private(set) var isLifted = false

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        // Decorative; see header.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Z-order, bottom to top (design section 1): tether < ghost < ground mark < needle.
        for layer in [tetherCasingLayer, tetherCoreLayer] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }
        tetherCasingLayer.strokeColor = UIColor.black.cgColor
        tetherCasingLayer.lineWidth = PlacementReticleView.tetherCasingWidth
        tetherCoreLayer.strokeColor = UIColor.white.cgColor
        tetherCoreLayer.lineWidth = PlacementReticleView.tetherCoreWidth

        ghostLayer.fillColor = UIColor.white.cgColor
        ghostLayer.strokeColor = UIColor.black.cgColor
        ghostLayer.lineWidth = PlacementReticleView.ghostRingWidth
        // Ring path is centred on (0,0) and the layer is moved with `position`. The path radius
        // sits half a ring-width OUTSIDE the 16 pt fill so the fill stays 16 pt and the outer
        // diameter is 21 pt.
        let ghostRadius = PlacementReticleView.ghostFillDiameter / 2 + PlacementReticleView.ghostRingWidth / 2
        ghostLayer.path = CGPath(
            ellipseIn: CGRect(x: -ghostRadius, y: -ghostRadius, width: ghostRadius * 2, height: ghostRadius * 2),
            transform: nil
        )
        ghostLayer.isHidden = true
        self.layer.addSublayer(ghostLayer)

        groundMarkLayer.fillColor = UIColor.black.cgColor
        self.layer.addSublayer(groundMarkLayer)

        needleView.isUserInteractionEnabled = false
        needleView.backgroundColor = .clear
        needleView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(needleView)
        for layer in [stemLayer, headLayer] {
            layer.fillColor = UIColor.white.cgColor
            layer.strokeColor = UIColor.black.cgColor
            // Hard shadow (spec A.5): reads on a tan day map and a black night map.
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.45
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: 2)
            needleView.layer.addSublayer(layer)
        }
        stemLayer.lineWidth = PlacementReticleView.needleStemOutline
        headLayer.lineWidth = PlacementReticleView.needleHeadOutline
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        needleView.frame = bounds
        tip = CurbPlacementMapPolicy.tipPoint(in: bounds)
        rebuildStaticGeometry()
        applyGhost()
    }

    /// The tip in this view's coordinate space (== the map view's, since this view is pinned to
    /// its bounds). Exposed for the controller and the tests of alignment.
    var tipPoint: CGPoint { tip }

    private func rebuildStaticGeometry() {
        withoutImplicitAnimations {
            // Head: circle whose OUTER diameter is 44 (stroke is centred on the path, so the
            // path radius is 44/2 minus half the outline).
            let headRadius = PlacementReticleView.needleHeadDiameter / 2 - PlacementReticleView.needleHeadOutline / 2
            let headCentre = CGPoint(
                x: tip.x,
                y: tip.y - PlacementReticleView.needleStemLength - PlacementReticleView.needleHeadDiameter / 2
            )
            headLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: headCentre.x - headRadius, y: headCentre.y - headRadius,
                    width: headRadius * 2, height: headRadius * 2
                ),
                transform: nil
            )

            // Stem: trapezoid 4 pt wide where it leaves the head, 1 pt at the tip. It starts
            // slightly INSIDE the head (which is drawn above it) so there is no seam.
            let overlap: CGFloat = 6
            let topY = tip.y - PlacementReticleView.needleStemLength - overlap
            let topHalf = PlacementReticleView.needleStemTopWidth / 2
            let tipHalf = PlacementReticleView.needleStemTipWidth / 2
            let stem = CGMutablePath()
            stem.move(to: CGPoint(x: tip.x - topHalf, y: topY))
            stem.addLine(to: CGPoint(x: tip.x + topHalf, y: topY))
            stem.addLine(to: CGPoint(x: tip.x + tipHalf, y: tip.y))
            stem.addLine(to: CGPoint(x: tip.x - tipHalf, y: tip.y))
            stem.closeSubpath()
            stemLayer.path = stem

            groundMarkLayer.path = groundMarkPath(lifted: isLifted)
        }
    }

    private func groundMarkPath(lifted: Bool) -> CGPath {
        let size = lifted ? PlacementReticleView.groundMarkLiftedSize : PlacementReticleView.groundMarkSize
        return CGPath(
            ellipseIn: CGRect(x: tip.x - size.width / 2, y: tip.y - size.height / 2,
                              width: size.width, height: size.height),
            transform: nil
        )
    }

    // MARK: Imperative updates (every display-link tick; CALayers only)

    /// Moves the ghost (nil = no snapped curb: ghost and tether hidden). `ghost` is in this
    /// view's coordinate space.
    func update(ghost: CGPoint?) {
        ghostPoint = ghost
        applyGhost()
    }

    private func applyGhost() {
        withoutImplicitAnimations {
            guard let ghost = ghostPoint, ghost.x.isFinite, ghost.y.isFinite else {
                ghostLayer.isHidden = true
                tetherCasingLayer.isHidden = true
                tetherCoreLayer.isHidden = true
                return
            }
            ghostLayer.isHidden = false
            ghostLayer.position = ghost

            let length = hypot(ghost.x - tip.x, ghost.y - tip.y)
            let showTether = length >= PlacementReticleView.tetherHideBelowPoints
            tetherCasingLayer.isHidden = !showTether
            tetherCoreLayer.isHidden = !showTether
            if showTether {
                let path = CGMutablePath()
                path.move(to: tip)
                path.addLine(to: ghost)
                tetherCasingLayer.path = path
                tetherCoreLayer.path = path
            }
        }
    }

    // MARK: Lift / drop / reveal

    /// Lift while a finger is down, drop on settle (design section 1 "Lift"). Reduce Motion: no
    /// translation; the ground mark still grows (instant) as the "you are moving" cue.
    func setLifted(_ lifted: Bool, reduceMotion: Bool) {
        guard lifted != isLifted else { return }
        isLifted = lifted
        withoutImplicitAnimations {
            groundMarkLayer.path = groundMarkPath(lifted: lifted)
        }
        let transform = lifted
            ? CGAffineTransform(translationX: 0, y: -PlacementReticleView.liftOffset)
            : CGAffineTransform.identity
        if reduceMotion {
            needleView.transform = .identity
        } else {
            UIView.animate(
                withDuration: PlacementReticleView.liftDuration,
                delay: 0,
                usingSpringWithDamping: PlacementReticleView.liftSpringDamping,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.needleView.transform = transform
            }
        }
    }

    /// Fades the reticle in once the entry camera has landed (opacity only - also the Reduce
    /// Motion form; the fly-in is the camera's, not the pin's).
    func reveal(animated: Bool) {
        if animated {
            UIView.animate(withDuration: PlacementReticleView.revealDuration) {
                self.alpha = 1
            }
        } else {
            alpha = 1
        }
    }

    // MARK: Helpers

    /// CALayer property changes animate implicitly (0.25 s) - fatal for a per-frame ghost.
    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
