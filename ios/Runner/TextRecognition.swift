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

    /// Renders each page white-backed at print resolution and recognizes
    /// it, top-to-bottom, reporting progress per page. One aggregate answer,
    /// in page order — the person sees the whole scan land in the box.
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
        // Long-edge target keeps photographed text inside what accurate
        // mode wants while bounding memory: a hair over retina for a
        // letter-size scan.
        let longEdge: CGFloat = 2400
        let longest = max(mediaBox.width, mediaBox.height)
        let scale = min(longEdge / max(longest, 1), 4)
        let width = max(1, Int(mediaBox.width * scale))
        let height = max(1, Int(mediaBox.height * scale))

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
        context.scaleBy(x: scale, y: scale)
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
    /// sorted top-to-bottom — Vision reports one observation per visual
    /// line, in no order, with boxes in a bottom-left-origin space.
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
        // whatever language the family writes in.
        request.automaticallyDetectsLanguage = true
      }
      do {
        // What this device can actually recognize, asked at runtime rather
        // than hardcoded (the import plan §3).
        request.recognitionLanguages = try request.supportedRecognitionLanguages()
      } catch {
        throw ReadError.refused("This device cannot read text from pictures.")
      }

      try handler.perform([request])
      if failure != nil {
        throw ReadError.refused("This device couldn't read text from that picture.")
      }

      // Screenshots are single-column, so a vertical pass with a same-line
      // left-to-right tiebreak is the whole ordering problem here (the
      // import plan §3).
      return observations.sorted { lhs, rhs in
        let lhsY = lhs.boundingBox.midY
        let rhsY = rhs.boundingBox.midY
        if abs(lhsY - rhsY) > 0.01 { return lhsY > rhsY }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
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
