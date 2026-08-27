import CoreGraphics
import XCTest

/// Reading order, including the case the whole file exists for: a plan
/// photographed sideways with no EXIF orientation tag.
///
/// `TextLineOrder` is pure geometry, so it is compiled into this bundle
/// directly and tested without Vision. What the quads here stand for was
/// measured off real Vision output for the report's Bali screenshot, upright
/// and physically rotated (`sips -r 90`): Vision recognises every line either
/// way up and names each quadrilateral's corners in the *text's* frame, which
/// is the fact the fix rests on.
final class TextLineOrderTests: XCTestCase {
  /// A plan of the shape the scout's reproduction used: day headers and
  /// stops, single column, top to bottom.
  private let plan = [
    "Bali - 4 days",
    "Day 1 - Ubud",
    "9:00 Tegalalang rice terraces",
    "Sacred Monkey Forest",
    "Day 2 - Ubud",
    "6:00 Mount Batur sunrise hike",
    "Day 3 - Uluwatu",
    "18:30 Kecak dance at the temple",
    "Day 4 - Seminyak",
    "21:55 Flight home",
  ]

  func testUprightPageReadsTopToBottom() {
    XCTAssertEqual(ordered(page(quarterTurns: 0)), plan)
  }

  func testSidewaysPageReadsInOrderRatherThanScrambled() {
    // The defect: sorting on the page's own vertical axis puts every line of
    // a quarter-turned plan in a meaningless order, days interleaved.
    XCTAssertNotEqual(byPageMidY(page(quarterTurns: 1)), plan)
    XCTAssertEqual(ordered(page(quarterTurns: 1)), plan)
  }

  func testUpsideDownPageReadsInOrder() {
    XCTAssertEqual(ordered(page(quarterTurns: 2)), plan)
  }

  func testSidewaysTheOtherWayReadsInOrder() {
    XCTAssertEqual(ordered(page(quarterTurns: 3)), plan)
  }

  func testSlightSkewIsStillOneColumn() {
    // The scout's -7 degree case, which the upright sort already handled and
    // which must keep working.
    XCTAssertEqual(ordered(page(quarterTurns: 0, skewedBy: -7 * .pi / 180)), plan)
  }

  func testLinesSideBySideReadLeftToRight() {
    let left = line(text: "09:00", top: 0.9, left: 0.1, width: 0.2)
    let right = line(text: "Fushimi Inari", top: 0.9, left: 0.4, width: 0.4)
    XCTAssertEqual(ordered([right, left]), ["09:00", "Fushimi Inari"])
  }

  func testSidewaysLinesSideBySideStillReadLeftToRight() {
    let left = line(text: "09:00", top: 0.9, left: 0.1, width: 0.2)
    let right = line(text: "Fushimi Inari", top: 0.9, left: 0.4, width: 0.4)
    let turned = [right, left].map { turn($0, quarterTurns: 1) }
    XCTAssertEqual(ordered(turned), ["09:00", "Fushimi Inari"])
  }

  func testNothingRecognizedIsNoLines() {
    XCTAssertEqual(ordered([]), [])
  }

  func testZeroWidthQuadsFallBackToTheUprightAxes() {
    // Nothing to measure an orientation from: the upright sort is the
    // fallback, not a crash and not an arbitrary order.
    let point = { (y: CGFloat, text: String) in
      Recognized(
        text: text,
        quad: TextLineOrder.Quad(
          topLeft: CGPoint(x: 0.5, y: y),
          topRight: CGPoint(x: 0.5, y: y),
          bottomLeft: CGPoint(x: 0.5, y: y),
          bottomRight: CGPoint(x: 0.5, y: y)
        )
      )
    }
    XCTAssertEqual(ordered([point(0.2, "lower"), point(0.8, "upper")]), ["upper", "lower"])
  }

  // MARK: - The page, and the turns of it

  private struct Recognized {
    let text: String
    let quad: TextLineOrder.Quad
  }

  private func ordered(_ items: [Recognized]) -> [String] {
    TextLineOrder.readingOrder(items) { $0.quad }.map(\.text)
  }

  /// The ordering this replaced: the page's own vertical axis, which is
  /// reading order only while the page is upright.
  private func byPageMidY(_ items: [Recognized]) -> [String] {
    items
      .sorted { lhs, rhs in
        let lhsY = midY(lhs.quad)
        let rhsY = midY(rhs.quad)
        if abs(lhsY - rhsY) > 0.01 { return lhsY > rhsY }
        return min(lhs.quad.topLeft.x, lhs.quad.bottomLeft.x)
          < min(rhs.quad.topLeft.x, rhs.quad.bottomLeft.x)
      }
      .map(\.text)
  }

  private func midY(_ quad: TextLineOrder.Quad) -> CGFloat {
    let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomLeft.y, quad.bottomRight.y]
    return (ys.min()! + ys.max()!) / 2
  }

  /// The plan laid out as Vision would report it, then turned a quarter at a
  /// time — the same thing a physical rotation of the pixels does to the
  /// corners Vision hands back.
  private func page(quarterTurns: Int, skewedBy skew: CGFloat = 0) -> [Recognized] {
    plan
      .enumerated()
      .map { index, text in
        line(
          text: text,
          top: 0.95 - CGFloat(index) * 0.09,
          left: 0.06,
          // Longer stops than headers, so the measured axes are weighted the
          // way a real page weights them.
          width: text.hasPrefix("Day ") ? 0.24 : 0.46,
          skew: skew
        )
      }
      .map { turn($0, quarterTurns: quarterTurns) }
  }

  private func line(
    text: String,
    top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    skew: CGFloat = 0
  ) -> Recognized {
    let height: CGFloat = 0.03
    let rise = width * tan(skew)
    return Recognized(
      text: text,
      quad: TextLineOrder.Quad(
        topLeft: CGPoint(x: left, y: top),
        topRight: CGPoint(x: left + width, y: top + rise),
        bottomLeft: CGPoint(x: left, y: top - height),
        bottomRight: CGPoint(x: left + width, y: top - height + rise)
      )
    )
  }

  /// A quarter turn of the picture, in the normalized bottom-left-origin
  /// space Vision reports in: (x, y) becomes (y, 1 - x). The corner *names*
  /// travel with the text, which is exactly what Vision does.
  private func turn(_ item: Recognized, quarterTurns: Int) -> Recognized {
    var quad = item.quad
    for _ in 0..<quarterTurns {
      let rotated = { (p: CGPoint) in CGPoint(x: p.y, y: 1 - p.x) }
      quad = TextLineOrder.Quad(
        topLeft: rotated(quad.topLeft),
        topRight: rotated(quad.topRight),
        bottomLeft: rotated(quad.bottomLeft),
        bottomRight: rotated(quad.bottomRight)
      )
    }
    return Recognized(text: item.text, quad: quad)
  }
}
