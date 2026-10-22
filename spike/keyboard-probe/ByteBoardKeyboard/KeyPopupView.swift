import UIKit

/// The one popup the keyboard draws: a body growing out of the pressed key.
///
/// It serves both the key preview (one value) and the alternates menu (several values,
/// one selected), so the two can never drift apart visually. The outline is a single path —
/// body, inward joins, and the key itself as the neck — rather than a rounded rectangle
/// floating above the key, which is what makes it read as the key grown rather than a label
/// nearby.
final class KeyPopupView: UIView {

    private let shape = CAShapeLayer()
    private var items: [UILabel] = []
    private(set) var selectedIndex: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shape.fillColor = KeyboardStyle.popupFill.cgColor
        layer.addSublayer(shape)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the preview for one key: a single large value, nothing selected.
    func showPreview(_ value: String, keyFrame: CGRect, in container: CGRect) {
        let body = CGSize(width: keyFrame.width + 18, height: KeyboardStyle.previewBodyHeight)
        present(values: [value], font: KeyboardStyle.previewFont, itemWidth: body.width,
                anchorIndex: 0, keyFrame: keyFrame, bodySize: body,
                bodyHeight: KeyboardStyle.previewBodyHeight, inset: 0, in: container)
        select(nil)
    }

    /// Shows the alternates for one key, with `baseIndex` sitting over the key itself.
    func showAlternates(_ values: [String], baseIndex: Int, itemWidth: CGFloat,
                        keyFrame: CGRect, in container: CGRect) {
        let inset = KeyboardStyle.popupInset
        let body = CGSize(width: itemWidth * CGFloat(values.count) + inset * 2,
                          height: KeyboardStyle.popupBodyHeight)
        present(values: values, font: KeyboardStyle.popupFont, itemWidth: itemWidth,
                anchorIndex: baseIndex, keyFrame: keyFrame, bodySize: body,
                bodyHeight: KeyboardStyle.popupBodyHeight, inset: inset, in: container)
        select(baseIndex)
    }

    func dismiss() {
        isHidden = true
        items.forEach { $0.removeFromSuperview() }
        items = []
        selectedIndex = nil
    }

    func select(_ index: Int?) {
        selectedIndex = index
        for (position, item) in items.enumerated() {
            item.backgroundColor = position == index ? KeyboardStyle.accent : .clear
        }
    }

    /// The item nearest to a point, by horizontal distance only. Sliding sideways changes the
    /// choice immediately; requiring the finger to land inside an item feels broken.
    func nearestIndex(to point: CGPoint, from view: UIView) -> Int? {
        guard !items.isEmpty else { return nil }
        let local = view.convert(point, to: self)
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (position, item) in items.enumerated() {
            let distance = abs(local.x - item.frame.midX)
            if distance < bestDistance {
                bestDistance = distance
                best = position
            }
        }
        return best
    }

    // MARK: - layout

    private func present(values: [String], font: UIFont, itemWidth: CGFloat, anchorIndex: Int,
                         keyFrame: CGRect, bodySize: CGSize, bodyHeight: CGFloat,
                         inset: CGFloat, in container: CGRect) {
        // Body sits on the key's top edge, with the anchor item centred over the key.
        let anchorX = inset + itemWidth * (CGFloat(anchorIndex) + 0.5)
        var body = CGRect(x: keyFrame.midX - anchorX,
                          y: keyFrame.minY - bodyHeight,
                          width: bodySize.width, height: bodyHeight)
        body.origin.x = max(container.minX, min(body.minX, container.maxX - body.width))
        body.origin.y = max(container.minY, body.minY)
        // The key must stay under the body or the neck cannot join it.
        if body.minX > keyFrame.minX { body.origin.x = keyFrame.minX }
        if body.maxX < keyFrame.maxX { body.size.width = keyFrame.maxX - body.minX }

        let union = body.union(keyFrame)
        frame = union

        let localBody = body.offsetBy(dx: -union.minX, dy: -union.minY)
        let localKey = keyFrame.offsetBy(dx: -union.minX, dy: -union.minY)
        let path = Self.outline(body: localBody, neck: localKey)
        shape.fillColor = KeyboardStyle.popupFill.resolvedColor(with: traitCollection).cgColor
        shape.path = path
        KeyboardStyle.applyShadow(to: layer, path: path)

        items.forEach { $0.removeFromSuperview() }
        items = values.map { value in
            let label = UILabel()
            label.text = value
            label.font = font
            label.textColor = KeyboardStyle.text
            label.textAlignment = .center
            label.layer.cornerRadius = KeyboardStyle.keyRadius
            label.clipsToBounds = true
            addSubview(label)
            return label
        }
        let itemHeight = localBody.height - inset * 2
        for (position, label) in items.enumerated() {
            label.frame = CGRect(x: localBody.minX + inset + itemWidth * CGFloat(position),
                                 y: localBody.minY + inset,
                                 width: itemWidth, height: itemHeight)
        }

        isHidden = false
        superview?.bringSubviewToFront(self)
    }

    /// Body above, the key below as its neck, joined by small inward curves. Built as one
    /// outline so the shadow and fill have no internal seams.
    static func outline(body b: CGRect, neck n: CGRect) -> CGPath {
        let r = KeyboardStyle.popupRadius
        let k = KeyboardStyle.keyRadius
        // Lower body corners shrink to nothing where the key reaches the body's edge.
        let rightCorner = min(r, max(0, b.maxX - n.maxX))
        let leftCorner = min(r, max(0, n.minX - b.minX))
        let rightJoin = min(KeyboardStyle.popupJoinRadius, max(0, b.maxX - n.maxX - rightCorner))
        let leftJoin = min(KeyboardStyle.popupJoinRadius, max(0, n.minX - b.minX - leftCorner))

        let path = UIBezierPath()
        path.move(to: CGPoint(x: b.minX + r, y: b.minY))
        path.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        path.addArc(withCenter: CGPoint(x: b.maxX - r, y: b.minY + r), radius: r,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: b.maxX, y: b.maxY - rightCorner))
        path.addArc(withCenter: CGPoint(x: b.maxX - rightCorner, y: b.maxY - rightCorner),
                    radius: rightCorner, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: n.maxX + rightJoin, y: b.maxY))
        path.addQuadCurve(to: CGPoint(x: n.maxX, y: b.maxY + rightJoin),
                          controlPoint: CGPoint(x: n.maxX, y: b.maxY))
        path.addLine(to: CGPoint(x: n.maxX, y: n.maxY - k))
        path.addArc(withCenter: CGPoint(x: n.maxX - k, y: n.maxY - k), radius: k,
                    startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: n.minX + k, y: n.maxY))
        path.addArc(withCenter: CGPoint(x: n.minX + k, y: n.maxY - k), radius: k,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: n.minX, y: b.maxY + leftJoin))
        path.addQuadCurve(to: CGPoint(x: n.minX - leftJoin, y: b.maxY),
                          controlPoint: CGPoint(x: n.minX, y: b.maxY))
        path.addLine(to: CGPoint(x: b.minX + leftCorner, y: b.maxY))
        path.addArc(withCenter: CGPoint(x: b.minX + leftCorner, y: b.maxY - leftCorner),
                    radius: leftCorner, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        path.addArc(withCenter: CGPoint(x: b.minX + r, y: b.minY + r), radius: r,
                    startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        path.close()
        return path.cgPath
    }
}
