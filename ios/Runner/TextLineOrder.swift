import CoreGraphics

/// Reading order for recognised text lines, in the text's own frame rather
/// than the page's.
///
/// Vision reports one observation per visual line, in no order, each carrying
/// the corners of the quadrilateral it actually found — and those corners are
/// named in the *text's* frame, so `topRight - topLeft` points along the
/// reading direction whichever way up the picture is. Sorting on the page's
/// vertical axis instead (a bare `boundingBox.midY`) is only reading order
/// while the page happens to be upright: a photograph taken sideways with no
/// EXIF orientation tag recognises every line and returns them shuffled, days
/// interleaved, which a careless person accepts as their trip.
///
/// So the axes are measured, never assumed. This file is pure geometry — no
/// Vision, no Flutter — which is what lets `RunnerTests` cover the rotated
/// case that no automated test could otherwise reach.
enum TextLineOrder {
  /// The corners of one recognised line, named in the text's own frame, in
  /// Vision's normalized bottom-left-origin space.
  struct Quad {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint

    var center: CGPoint {
      CGPoint(
        x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
        y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4
      )
    }
  }

  /// Two lines whose across-lines positions differ by less than this are one
  /// line, ordered along the reading direction. Normalized units, and the
  /// same tolerance the upright-only sort used.
  static let sameLineTolerance: CGFloat = 0.01

  /// Sorts [items] into reading order: down the lines in the text's own
  /// frame, then along each line.
  ///
  /// A picture with no usable orientation to measure (no lines, or lines with
  /// no width) falls back to the upright axes, which is exactly the sort this
  /// replaced.
  static func readingOrder<T>(_ items: [T], quad: (T) -> Quad) -> [T] {
    let quads = items.map(quad)
    let (along, down) = axes(of: quads)
    return zip(items, quads)
      .enumerated()
      .sorted { lhs, rhs in
        let lhsDown = dot(lhs.element.1.center, down)
        let rhsDown = dot(rhs.element.1.center, down)
        if abs(lhsDown - rhsDown) > sameLineTolerance { return lhsDown < rhsDown }
        let lhsAlong = dot(lhs.element.1.topLeft, along)
        let rhsAlong = dot(rhs.element.1.topLeft, along)
        // Vision's own order is arbitrary, so the index tiebreak is only here
        // to keep the sort total and the result reproducible.
        if lhsAlong != rhsAlong { return lhsAlong < rhsAlong }
        return lhs.offset < rhs.offset
      }
      .map { $0.element.0 }
  }

  /// The reading direction and the across-lines direction, measured off the
  /// quads: the baselines are what the text is written along, and lines stack
  /// perpendicular to them. Longer lines weigh more, being the ones whose
  /// direction is measured over the longest arm.
  private static func axes(of quads: [Quad]) -> (along: CGPoint, down: CGPoint) {
    let uprightAxes = (along: CGPoint(x: 1, y: 0), down: CGPoint(x: 0, y: -1))
    var alongSum = CGPoint.zero
    var downSum = CGPoint.zero
    for quad in quads {
      alongSum = alongSum
        .adding(quad.topRight.subtracting(quad.topLeft))
        .adding(quad.bottomRight.subtracting(quad.bottomLeft))
      downSum = downSum
        .adding(quad.bottomLeft.subtracting(quad.topLeft))
        .adding(quad.bottomRight.subtracting(quad.topRight))
    }
    guard let along = unit(alongSum) else { return uprightAxes }
    // Perpendicular to the baseline, turned the way the measured glyph sides
    // point — a slanted quad tilts the letters, never the stack of lines.
    let perpendicular = CGPoint(x: along.y, y: -along.x)
    guard dot(perpendicular, downSum) < 0 else { return (along, perpendicular) }
    return (along, CGPoint(x: -perpendicular.x, y: -perpendicular.y))
  }

  private static func unit(_ vector: CGPoint) -> CGPoint? {
    let length = (vector.x * vector.x + vector.y * vector.y).squareRoot()
    guard length > 1e-9 else { return nil }
    return CGPoint(x: vector.x / length, y: vector.y / length)
  }

  private static func dot(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    lhs.x * rhs.x + lhs.y * rhs.y
  }
}

extension CGPoint {
  fileprivate func adding(_ other: CGPoint) -> CGPoint {
    CGPoint(x: x + other.x, y: y + other.y)
  }

  fileprivate func subtracting(_ other: CGPoint) -> CGPoint {
    CGPoint(x: x - other.x, y: y - other.y)
  }
}
