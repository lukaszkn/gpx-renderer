import CoreLocation
import Foundation

final class GPXParser: NSObject, XMLParserDelegate {
    private enum TextTarget {
        case trackName
        case elevation
        case time
    }

    private struct PointDraft {
        let latitude: Double
        let longitude: Double
        var elevation: Double?
        var time: Date?
    }

    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let standardDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var parsedName: String?
    private var parsedSegments: [GPXSegment] = []
    private var currentSegmentPoints: [GPXPoint] = []
    private var currentPoint: PointDraft?
    private var textTarget: TextTarget?
    private var textBuffer = ""
    private var isInsideTrack = false

    func parse(contentsOf url: URL) throws -> GPXTrack {
        let data = try Data(contentsOf: url)
        return try parse(data: data, sourceURL: url)
    }

    func parse(data: Data, sourceURL: URL? = nil) throws -> GPXTrack {
        reset()

        guard let parser = XMLParser(data: data) as XMLParser? else {
            throw GPXImportError.emptyTrack
        }

        parser.delegate = self
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            throw parser.parserError ?? GPXImportError.emptyTrack
        }

        let track = GPXTrack(name: parsedName, sourceURL: sourceURL, segments: parsedSegments)
        guard !track.allPoints.isEmpty else {
            throw GPXImportError.emptyTrack
        }

        return track
    }

    private func reset() {
        parsedName = nil
        parsedSegments = []
        currentSegmentPoints = []
        currentPoint = nil
        textTarget = nil
        textBuffer = ""
        isInsideTrack = false
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "trk":
            isInsideTrack = true
        case "name" where isInsideTrack && parsedName == nil:
            beginCapturing(.trackName)
        case "trkseg":
            currentSegmentPoints = []
        case "trkpt":
            guard let latitudeText = attributeDict["lat"],
                  let longitudeText = attributeDict["lon"],
                  let latitude = Double(latitudeText),
                  let longitude = Double(longitudeText) else {
                currentPoint = nil
                return
            }

            currentPoint = PointDraft(latitude: latitude, longitude: longitude)
        case "ele" where currentPoint != nil:
            beginCapturing(.elevation)
        case "time" where currentPoint != nil:
            beginCapturing(.time)
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        guard textTarget != nil else { return }
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName.lowercased() {
        case "name" where textTarget == .trackName:
            parsedName = trimmedText()
            endCapturing()
        case "ele" where textTarget == .elevation:
            currentPoint?.elevation = Double(trimmedText())
            endCapturing()
        case "time" where textTarget == .time:
            currentPoint?.time = parseDate(trimmedText())
            endCapturing()
        case "trkpt":
            if let currentPoint {
                let point = GPXPoint(
                    coordinate: CLLocationCoordinate2D(latitude: currentPoint.latitude, longitude: currentPoint.longitude),
                    elevation: currentPoint.elevation,
                    time: currentPoint.time
                )
                currentSegmentPoints.append(point)
            }
            currentPoint = nil
        case "trkseg":
            if !currentSegmentPoints.isEmpty {
                parsedSegments.append(GPXSegment(points: currentSegmentPoints))
            }
            currentSegmentPoints = []
        case "trk":
            isInsideTrack = false
        default:
            break
        }
    }

    private func beginCapturing(_ target: TextTarget) {
        textTarget = target
        textBuffer = ""
    }

    private func endCapturing() {
        textTarget = nil
        textBuffer = ""
    }

    private func trimmedText() -> String {
        textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ text: String) -> Date? {
        fractionalDateFormatter.date(from: text) ?? standardDateFormatter.date(from: text)
    }
}
