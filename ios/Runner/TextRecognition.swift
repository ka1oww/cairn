import CoreGraphics
import Flutter
import Foundation
import Vision

/// The OCR edge: Apple Vision behind the one hand-written method channel
/// (`cairn/text_recognition`) of the file-import feature's slice D.
///
/// Bytes in — a photograph, a screenshot, or a scanned PDF — ordered lines
/// out. Accurate mode with language correction on; recognition languages
/// queried from Vision at runtime rather than hardcoded. A `%PDF` payload is
/// rendered page by page through Core Graphics first (the scanned-PDF door),
/// reporting progress per page over the same channel as it goes.
///
/// Judged on a device only: nothing here is exercised by the automated
/// suite, which binds a fake edge (lib/app_state/text_recognition_edge.dart).
enum TextRecognition {
  static let channelName = "cairn/text_recognition"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let reader = Reader(channel: channel)
    channel.setMethodCallHandler(reader.handle)
  }

  // MARK: - How large a scanned page is drawn

  /// The long edge a scanned page is drawn to when nothing bounds it from
  /// below: a hair over retina for a letter-size scan, which keeps
  /// photographed text inside what accurate mode wants while bounding memory.
  static let renderLongEdgeTarget: CGFloat = 2400

  /// The scale a scanned page is rendered at.
  ///
  /// [renderLongEdgeTarget] is a *ceiling*, never a floor. A scan carries
  /// exactly the detail the scanner wrote and not one pixel more, so drawing
  /// a 700x900pt page that wraps a 700x900px image onto a 1867x2400 canvas
  /// invents 2.7x the pixels it has — and Vision reads invented softness
  /// worse than it reads the original, dropping whole legible lines without
  /// saying so (the simulator torture-test's W2; the same picture through
  /// the photo door, which never resamples, read perfectly). So a page whose
  /// own pixels are coarser than the target is drawn at its own resolution.
  /// A 300dpi letter scan is unaffected: its native long edge is already far
  /// past the target, and the target still bounds it.
  ///
  /// Never below 1: a page drawn from an image smaller than its own box is
  /// being enlarged by the PDF itself, and rendering under the box's points
  /// would throw away what the page's own layout has. In practice
  /// `nativePixelLongEdge(of:uprightSize:)` never hands this function a
  /// value below the page's own long edge, so the floor does not bind for
  /// that caller today — it stays here because this function must be
  /// correct on its own terms for any caller, not just its current one.
  static func renderScale(
    uprightLongEdge: CGFloat,
    nativePixelLongEdge: CGFloat?,
    longEdgeTarget: CGFloat = TextRecognition.renderLongEdgeTarget,
    maxScale: CGFloat = 4
  ) -> CGFloat {
    let edge = max(uprightLongEdge, 1)
    let target = min(longEdgeTarget / edge, maxScale)
    guard let native = nativePixelLongEdge, native > 0 else { return target }
    return min(target, max(native / edge, 1))
  }

  /// The pixel long edge of the single image a scanned page *is*, or nil
  /// when the page is not one — in which case nothing here knows better than
  /// [renderLongEdgeTarget].
  ///
  /// The largest image the page's resources reach (recursing into Form
  /// XObjects) must clear two tests before it is trusted, regardless of how
  /// many other images the page also holds. First, its proportions must be
  /// the page's own (`proportionsAgree`), so a logo sitting beside vector
  /// text can never drag a whole page down to its box's resolution. Second,
  /// it must carry at least one pixel per point of the page's long edge
  /// (>= 72dpi) — every genuine scan clears this by a wide margin (real
  /// scans run 150-300dpi), while a low-resolution, page-proportioned
  /// full-bleed background or watermark sitting behind outlined vector text
  /// does not, so that page keeps [renderLongEdgeTarget] instead of being
  /// dragged down to the watermark's resolution. Failing either test, or the
  /// page not being a single full-page picture at all, falls back to nil.
  static func nativePixelLongEdge(of page: CGPDFPage, uprightSize: CGSize) -> CGFloat? {
    guard let pageDictionary = page.dictionary else { return nil }
    var resources: CGPDFDictionaryRef?
    guard
      CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
      let resources
    else { return nil }

    let collector = ImageSizeCollector()
    collectImageSizes(in: resources, into: collector)
    guard
      let largest = collector.sizes.max(by: { $0.width * $0.height < $1.width * $1.height }),
      largest.width > 0,
      largest.height > 0,
      proportionsAgree(largest, uprightSize)
    else { return nil }
    let nativeLongEdge = max(largest.width, largest.height)
    let pageLongEdge = max(uprightSize.width, uprightSize.height)
    guard nativeLongEdge >= pageLongEdge else { return nil }
    return nativeLongEdge
  }

  /// Whether two boxes have the same shape, to within a tolerance that
  /// forgives a scanner's rounding. Compared as long-edge-over-short-edge so
  /// the answer does not depend on which way either box is turned.
  static func proportionsAgree(
    _ image: CGSize,
    _ page: CGSize,
    tolerance: CGFloat = 0.15
  ) -> Bool {
    let imageRatio = max(image.width, image.height) / max(min(image.width, image.height), 1)
    let pageRatio = max(page.width, page.height) / max(min(page.width, page.height), 1)
    guard pageRatio > 0 else { return false }
    return abs(imageRatio - pageRatio) / pageRatio <= tolerance
  }

  /// Gathers the pixel sizes of every image a page's resources reach.
  /// Mutable state behind a class because `CGPDFDictionaryApplyFunction`
  /// takes a C function pointer, which can capture nothing.
  private final class ImageSizeCollector {
    var sizes: [CGSize] = []
    var depth = 0
  }

  /// Form XObjects nest; four levels is far past anything a scanner emits
  /// and keeps a cyclic resource graph from spinning.
  private static let maxFormDepth = 4

  private static func collectImageSizes(
    in resources: CGPDFDictionaryRef,
    into collector: ImageSizeCollector
  ) {
    var xobjects: CGPDFDictionaryRef?
    guard
      CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
      let xobjects
    else { return }
    CGPDFDictionaryApplyFunction(
      xobjects,
      collectImageSize,
      Unmanaged.passUnretained(collector).toOpaque()
    )
  }

  private static let collectImageSize: CGPDFDictionaryApplierFunction = { _, value, info in
    guard let info else { return }
    let collector = Unmanaged<ImageSizeCollector>.fromOpaque(info).takeUnretainedValue()
    var stream: CGPDFStreamRef?
    guard
      CGPDFObjectGetValue(value, .stream, &stream),
      let stream,
      let dictionary = CGPDFStreamGetDictionary(stream)
    else { return }
    var subtype: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
    switch String(cString: subtype) {
    case "Image":
      var pixelWidth: CGPDFInteger = 0
      var pixelHeight: CGPDFInteger = 0
      guard
        CGPDFDictionaryGetInteger(dictionary, "Width", &pixelWidth),
        CGPDFDictionaryGetInteger(dictionary, "Height", &pixelHeight)
      else { return }
      collector.sizes.append(
        CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
      )
    case "Form" where collector.depth < TextRecognition.maxFormDepth:
      var nested: CGPDFDictionaryRef?
      guard
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested),
        let nested
      else { return }
      collector.depth += 1
      TextRecognition.collectImageSizes(in: nested, into: collector)
      collector.depth -= 1
    default:
      return
    }
  }

  private final class Reader {
    private let channel: FlutterMethodChannel

    /// Recognition is seconds-long work; it never runs on the platform
    /// thread. Progress hops back to main, where channels live.
    private let queue = DispatchQueue(label: "app.cairn.text-recognition", qos: .userInitiated)

    /// The plan's risk 7: a scan cap, so a 500-page fax cannot pin this
    /// queue for minutes. Itineraries live far under it.
    private static let maxPdfPages = 100

    init(channel: FlutterMethodChannel) {
      self.channel = channel
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      switch call.method {
      case "recognizeLines":
        guard
          let args = call.arguments as? [String: Any],
          let typed = args["bytes"] as? FlutterStandardTypedData
        else {
          refuse(result, "That picture couldn't be read.")
          return
        }
        let data = typed.data
        guard !data.isEmpty else {
          refuse(result, "That picture couldn't be read.")
          return
        }
        queue.async { self.read(data, result: result) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    private func refuse(_ result: @escaping FlutterResult, _ message: String) {
      DispatchQueue.main.async {
        result(FlutterError(code: "refused", message: message, details: nil))
      }
    }

    private func report(_ page: Int, of pageCount: Int) {
      DispatchQueue.main.async {
        self.channel.invokeMethod("onPage", arguments: ["page": page, "of": pageCount])
      }
    }

    // MARK: - Reading

    private func read(_ data: Data, result: @escaping FlutterResult) {
      if data.starts(with: Data("%PDF".utf8)) {
        readScannedPdf(data, result: result)
      } else {
        readSingleImage(data, result: result)
      }
    }

    private func readSingleImage(_ data: Data, result: @escaping FlutterResult) {
      do {
        let handler = VNImageRequestHandler(data: data, options: [:])
        let lines = try recognizedLines(handler: handler)
        finish(result, lines: lines, pages: 1)
      } catch ReadError.refused(let message) {
        refuse(result, message)
      } catch {
        refuse(result, "This device couldn't read text from that picture.")
      }
    }

    /// Renders each page white-backed at print resolution, or at the page's
    /// own where that is coarser (see `renderScale`), and recognizes it,
    /// top-to-bottom,
    /// reporting progress per page. One aggregate answer, in page order —
    /// the person sees the whole scan land in the box.
    private func readScannedPdf(_ data: Data, result: @escaping FlutterResult) {
      guard
        let provider = CGDataProvider(data: data as CFData),
        let pdf = CGPDFDocument(provider)
      else {
        refuse(result, "That PDF couldn't be opened.")
        return
      }
      let pageCount = pdf.numberOfPages
      guard pageCount > 0 else {
        refuse(result, "That PDF has no pages in it.")
        return
      }
      guard pageCount <= Reader.maxPdfPages else {
        refuse(
          result,
          "That scanned PDF is too long to read — over \(Reader.maxPdfPages) pages."
        )
        return
      }

      var allLines: [String] = []
      for pageNumber in 1...pageCount {
        report(pageNumber, of: pageCount)
        guard let page = pdf.page(at: pageNumber) else { continue }
        let mediaBox = page.getBoxRect(.mediaBox)
        // The page's own /Rotate decides the shape of the canvas: scanners
        // routinely emit /Rotate 90, and Vision straightens nothing, so a
        // page drawn into an unrotated box lands sideways and clipped.
        let quarterTurned = abs(page.rotationAngle % 180) == 90
        let uprightSize = quarterTurned
          ? CGSize(width: mediaBox.height, height: mediaBox.width)
          : CGSize(width: mediaBox.width, height: mediaBox.height)
        let scale = TextRecognition.renderScale(
          uprightLongEdge: max(uprightSize.width, uprightSize.height),
          nativePixelLongEdge: TextRecognition.nativePixelLongEdge(
            of: page,
            uprightSize: uprightSize
          )
        )
        let width = max(1, Int(uprightSize.width * scale))
        let height = max(1, Int(uprightSize.height * scale))

        guard
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
        else {
          refuse(result, "This device couldn't render that scan.")
          return
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CoreGraphics' own fit: it carries the page rotation and a non-zero
        // mediaBox origin (a cropped page) into the canvas for us.
        context.concatenate(
          page.getDrawingTransform(
            .mediaBox,
            rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            rotate: 0,
            preserveAspectRatio: true
          )
        )
        context.drawPDFPage(page)
        guard let rendered = context.makeImage() else {
          refuse(result, "This device couldn't render that scan.")
          return
        }

        do {
          let handler = VNImageRequestHandler(cgImage: rendered, options: [:])
          allLines.append(contentsOf: try recognizedLines(handler: handler))
        } catch ReadError.refused(let message) {
          refuse(result, message)
          return
        } catch {
          refuse(result, "This device couldn't read text from that scan.")
          return
        }
      }
      finish(result, lines: allLines, pages: pageCount)
    }

    private func finish(_ result: @escaping FlutterResult, lines: [String], pages: Int) {
      DispatchQueue.main.async {
        result(["lines": lines, "pages": pages])
      }
    }

    // MARK: - Vision

    /// Performs recognition on [handler] and returns the visible text lines
    /// in reading order — Vision reports one observation per visual line, in
    /// no order, with corners in a bottom-left-origin space, and
    /// `TextLineOrder` is what turns those into an order.
    private func recognizedLines(handler: VNImageRequestHandler) throws -> [String] {
      var observations: [VNRecognizedTextObservation] = []
      var failure: Error?
      // The completion runs synchronously inside perform(), so gathering
      // into captured locals is safe.
      let request = VNRecognizeTextRequest { req, error in
        if let error { failure = error }
        observations = (req.results as? [VNRecognizedTextObservation]) ?? []
      }
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      if #available(iOS 16.0, *) {
        // Revision 3's language auto-detection: chat screenshots arrive in
        // whatever language the family writes in. `recognitionLanguages` is
        // deliberately left alone on this path — a non-empty list takes
        // precedence over auto-detection and would make it inert, and a
        // whole supported-language list handed over as an ordered priority
        // costs accuracy against a language Vision would have detected.
        request.automaticallyDetectsLanguage = true
      } else {
        do {
          // Older systems detect nothing, so the fallback is what this
          // device says it can read — asked at runtime rather than
          // hardcoded (the import plan §3).
          request.recognitionLanguages = try request.supportedRecognitionLanguages()
        } catch {
          throw ReadError.refused("This device cannot read text from pictures.")
        }
      }

      try handler.perform([request])
      if failure != nil {
        throw ReadError.refused("This device couldn't read text from that picture.")
      }

      // Screenshots are single-column, so a pass down the lines with a
      // same-line tiebreak along them is the whole ordering problem here (the
      // import plan §3) — but *down* is the text's own direction, not the
      // page's. Vision names each quadrilateral's corners in the text's
      // frame, and `TextLineOrder` measures the axes off them, so a
      // photograph taken sideways with no EXIF orientation reads in order
      // rather than shuffled.
      return TextLineOrder
        .readingOrder(observations) { observation in
          TextLineOrder.Quad(
            topLeft: observation.topLeft,
            topRight: observation.topRight,
            bottomLeft: observation.bottomLeft,
            bottomRight: observation.bottomRight
          )
        }
        .compactMap { $0.topCandidates(1).first?.string }
    }
  }

  /// Errors this file raises on purpose, each already carrying its
  /// person-readable sentence.
  private enum ReadError: Error {
    case refused(String)
  }
}
