import CoreGraphics
import Flutter
import UIKit
import XCTest

@testable import Runner

/// The one thing on the OCR edge that is arithmetic rather than judgement:
/// how large a scanned PDF page is drawn before Vision reads it.
///
/// Recognition *quality* is judged on a device against a real corpus, as
/// CLAUDE.md says. This is the other half — the render decision that fed
/// Vision pixels no scanner ever wrote, and silently cost whole legible
/// lines (the simulator torture-test's W2).
class TextRecognitionRenderScaleTests: XCTestCase {

  // MARK: - The bug

  /// The report's page: a 700x900px screenshot wrapped by `sips` into a
  /// 350x450pt PDF page. The old rule asked for a 4x draw of a picture with
  /// 2x the pixels, and Vision came back with 5 of the 17 lines — losing
  /// "18:30 Kecak dance at the temple" among them. Nothing above native.
  func testASmallScanIsNeverDrawnLargerThanItsOwnPixels() {
    let scale = TextRecognition.renderScale(
      uprightLongEdge: 450,
      nativePixelLongEdge: 900
    )
    XCTAssertEqual(scale, 2, accuracy: 0.001)
    XCTAssertEqual(450 * scale, 900, accuracy: 0.001, "drawn at exactly its own pixels")
  }

  /// The same page under the old rule, stated so the regression is legible:
  /// with nothing known about the page's own pixels the long-edge target
  /// (capped at 4x) is what it gets, and that is a 2x invention.
  func testTheOldRuleWouldHaveUpscaledThatPage() {
    let unbounded = TextRecognition.renderScale(
      uprightLongEdge: 450,
      nativePixelLongEdge: nil
    )
    XCTAssertEqual(unbounded, 4, accuracy: 0.001)
    XCTAssertGreaterThan(
      450 * unbounded, 900,
      "this is the invention the fix removes"
    )
  }

  /// A page whose media box already matches its pixels one-for-one is drawn
  /// at 1x, not at the target's 2.67x.
  func testAPageWhosePointsAreItsPixelsIsDrawnAtOne() {
    XCTAssertEqual(
      TextRecognition.renderScale(uprightLongEdge: 900, nativePixelLongEdge: 900),
      1,
      accuracy: 0.001
    )
  }

  // MARK: - What must not change

  /// A 300dpi letter scan has far more pixels than the target asks for, so
  /// the target still bounds it and the fix costs it nothing.
  func testARealScanStillRendersAtTheLongEdgeTarget() {
    let target = TextRecognition.renderScale(
      uprightLongEdge: 792,
      nativePixelLongEdge: nil
    )
    let bounded = TextRecognition.renderScale(
      uprightLongEdge: 792,
      nativePixelLongEdge: 3300
    )
    XCTAssertEqual(bounded, target, accuracy: 0.001)
    XCTAssertEqual(bounded, TextRecognition.renderLongEdgeTarget / 792, accuracy: 0.001)
  }

  /// A page drawn from an image *smaller* than its own box is already being
  /// enlarged by the PDF; drawing under the box's own points would throw
  /// away what the page's layout has.
  func testAnUndersizedImageNeverPushesTheDrawBelowOne() {
    XCTAssertEqual(
      TextRecognition.renderScale(uprightLongEdge: 900, nativePixelLongEdge: 300),
      1,
      accuracy: 0.001
    )
  }

  /// Knowing nothing about the page leaves the previous behaviour exactly
  /// where it was.
  func testAPageWithNoImageKeepsTheTarget() {
    XCTAssertEqual(
      TextRecognition.renderScale(uprightLongEdge: 792, nativePixelLongEdge: nil),
      TextRecognition.renderLongEdgeTarget / 792,
      accuracy: 0.001
    )
  }

  func testTheMemoryBoundStillCapsATinyPage() {
    XCTAssertEqual(
      TextRecognition.renderScale(uprightLongEdge: 100, nativePixelLongEdge: nil),
      4,
      accuracy: 0.001
    )
  }

  // MARK: - Reading a page's own resolution

  func testAFullPageImageReportsItsPixelLongEdge() throws {
    let pdf = try singleImagePdf(
      pageSize: CGSize(width: 350, height: 450),
      imagePixels: CGSize(width: 700, height: 900),
      drawnInto: CGRect(x: 0, y: 0, width: 350, height: 450)
    )
    let page = try XCTUnwrap(pdf.page(at: 1))
    XCTAssertEqual(
      TextRecognition.nativePixelLongEdge(
        of: page,
        uprightSize: CGSize(width: 350, height: 450)
      ),
      900
    )
  }

  /// A logo beside vector text must never drag a whole page down to its
  /// box's 72dpi, so only an image shaped like its page counts.
  func testASmallImageOfADifferentShapeIsNotThePage() throws {
    let pdf = try singleImagePdf(
      pageSize: CGSize(width: 350, height: 450),
      imagePixels: CGSize(width: 64, height: 64),
      drawnInto: CGRect(x: 10, y: 400, width: 32, height: 32)
    )
    let page = try XCTUnwrap(pdf.page(at: 1))
    XCTAssertNil(
      TextRecognition.nativePixelLongEdge(
        of: page,
        uprightSize: CGSize(width: 350, height: 450)
      )
    )
  }

  func testProportionsAgreeIgnoresWhichWayEachBoxIsTurned() {
    XCTAssertTrue(
      TextRecognition.proportionsAgree(
        CGSize(width: 900, height: 700),
        CGSize(width: 350, height: 450)
      )
    )
    XCTAssertFalse(
      TextRecognition.proportionsAgree(
        CGSize(width: 64, height: 64),
        CGSize(width: 350, height: 450)
      )
    )
  }

  // MARK: - Fixtures

  /// A one-page PDF carrying exactly one image XObject — the shape every
  /// scanner and every `sips -s format pdf` emits.
  private func singleImagePdf(
    pageSize: CGSize,
    imagePixels: CGSize,
    drawnInto rect: CGRect
  ) throws -> CGPDFDocument {
    let bitmap = try XCTUnwrap(
      CGContext(
        data: nil,
        width: Int(imagePixels.width),
        height: Int(imagePixels.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    bitmap.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    bitmap.fill(CGRect(origin: .zero, size: imagePixels))
    let image = try XCTUnwrap(bitmap.makeImage())

    let output = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    pdf.beginPDFPage(nil)
    pdf.draw(image, in: rect)
    pdf.endPDFPage()
    pdf.closePDF()

    let provider = try XCTUnwrap(CGDataProvider(data: output as CFData))
    return try XCTUnwrap(CGPDFDocument(provider))
  }
}
