import CoreLocation
import Foundation
import SwiftUI
import UIKit

struct GPXPoint {
    let coordinate: CLLocationCoordinate2D
    let elevation: Double?
    let time: Date?
}

struct GPXSegment: Identifiable {
    let id = UUID()
    let points: [GPXPoint]

    var timedDuration: TimeInterval {
        guard let first = points.first(where: { $0.time != nil })?.time,
              let last = points.last(where: { $0.time != nil })?.time,
              last >= first else {
            return 0
        }

        return last.timeIntervalSince(first)
    }

    var distanceMeters: CLLocationDistance {
        points.adjacentPairs().reduce(0) { total, pair in
            total + GPXDistance.haversineMeters(from: pair.0.coordinate, to: pair.1.coordinate)
        }
    }
}

struct GPXTrack: Identifiable {
    let id = UUID()
    let name: String?
    let sourceURL: URL?
    let segments: [GPXSegment]

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return sourceURL?.deletingPathExtension().lastPathComponent ?? "GPX Track"
    }

    var allPoints: [GPXPoint] {
        segments.flatMap(\.points)
    }
}

struct GPXStats {
    static let empty = GPXStats(distanceMeters: 0, duration: 0, pointCount: 0, segmentCount: 0, startDate: nil)

    let distanceMeters: CLLocationDistance
    let duration: TimeInterval
    let pointCount: Int
    let segmentCount: Int
    let startDate: Date?

    private static let startDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(track: GPXTrack) {
        distanceMeters = track.segments.reduce(0) { $0 + $1.distanceMeters }
        duration = track.segments.reduce(0) { $0 + $1.timedDuration }
        pointCount = track.segments.reduce(0) { $0 + $1.points.count }
        segmentCount = track.segments.count
        startDate = track.segments
            .flatMap(\.points)
            .first?
            .time
    }

    private init(distanceMeters: CLLocationDistance, duration: TimeInterval, pointCount: Int, segmentCount: Int, startDate: Date?) {
        self.distanceMeters = distanceMeters
        self.duration = duration
        self.pointCount = pointCount
        self.segmentCount = segmentCount
        self.startDate = startDate
    }

    var distanceText: String {
        let kilometres = distanceMeters / 1000
        return String(format: "%.1f km", kilometres)
    }

    var durationText: String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }

    var startDateTimeText: String? {
        startDate.map { Self.startDateFormatter.string(from: $0) }
    }
}

struct GPXDocumentEntry: Identifiable {
    let id: URL
    let url: URL
    let modifiedAt: Date?

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum TrackColor: String, CaseIterable, Identifiable {
    case flame
    case alpine
    case volt
    case magenta
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flame:
            return "Flame"
        case .alpine:
            return "Alpine"
        case .volt:
            return "Volt"
        case .magenta:
            return "Magenta"
        case .graphite:
            return "Graphite"
        }
    }

    var swiftUIColor: Color {
        Color(uiColor: uiColor)
    }

    var uiColor: UIColor {
        switch self {
        case .flame:
            return UIColor(red: 1.00, green: 0.32, blue: 0.08, alpha: 1)
        case .alpine:
            return UIColor(red: 0.00, green: 0.54, blue: 0.96, alpha: 1)
        case .volt:
            return UIColor(red: 0.67, green: 0.93, blue: 0.16, alpha: 1)
        case .magenta:
            return UIColor(red: 0.94, green: 0.17, blue: 0.76, alpha: 1)
        case .graphite:
            return UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        }
    }
}

enum TrackColorMode: String, CaseIterable, Identifiable {
    case multiDay
    case single

    var id: String { rawValue }

    var title: String {
        switch self {
        case .multiDay:
            return "Multi-Day Colors"
        case .single:
            return "Single Color"
        }
    }

    var systemImage: String {
        switch self {
        case .multiDay:
            return "paintpalette"
        case .single:
            return "paintbrush"
        }
    }
}

enum GPXImportError: LocalizedError {
    case missingSample
    case emptyTrack
    case unsupportedFile
    case appGroupUnavailable
    case screenshotUnavailable

    var errorDescription: String? {
        switch self {
        case .missingSample:
            return "The bundled GPX sample could not be found."
        case .emptyTrack:
            return "This GPX file does not contain any track points."
        case .unsupportedFile:
            return "Please choose a .gpx file."
        case .appGroupUnavailable:
            return "The shared import container is not available."
        case .screenshotUnavailable:
            return "The app window could not be captured."
        }
    }
}

enum GPXDistance {
    static func haversineMeters(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDistance {
        let radius = 6_371_000.0
        let startLat = start.latitude * .pi / 180
        let endLat = end.latitude * .pi / 180
        let deltaLat = (end.latitude - start.latitude) * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(startLat) * cos(endLat) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return radius * c
    }
}

extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count > 1 else { return [] }
        return zip(self, dropFirst()).map { ($0, $1) }
    }
}
