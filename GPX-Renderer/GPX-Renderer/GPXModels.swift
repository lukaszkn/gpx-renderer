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

struct GPXHeightProfile {
    let samples: [GPXHeightProfileSample]
    let minElevationMeters: Double
    let maxElevationMeters: Double
    let minDistanceMeters: CLLocationDistance
    let maxDistanceMeters: CLLocationDistance
    let trackDays: [Date]

    init?(track: GPXTrack, calendar: Calendar = .current) {
        var samples: [GPXHeightProfileSample] = []
        var cumulativeDistance: CLLocationDistance = 0
        var sampleIndex = 0

        for segment in track.segments {
            var previousPoint: GPXPoint?

            for point in segment.points {
                if let previousPoint {
                    cumulativeDistance += GPXDistance.haversineMeters(
                        from: previousPoint.coordinate,
                        to: point.coordinate
                    )
                }

                if let elevation = point.elevation, elevation.isFinite {
                    samples.append(
                        GPXHeightProfileSample(
                            id: sampleIndex,
                            distanceMeters: cumulativeDistance,
                            elevationMeters: elevation,
                            day: point.time.map { calendar.startOfDay(for: $0) }
                        )
                    )
                    sampleIndex += 1
                }

                previousPoint = point
            }
        }

        guard samples.count >= 2,
              let minElevation = samples.map(\.elevationMeters).min(),
              let maxElevation = samples.map(\.elevationMeters).max(),
              let minDistance = samples.first?.distanceMeters,
              let maxDistance = samples.last?.distanceMeters else {
            return nil
        }

        self.samples = samples
        minElevationMeters = minElevation
        maxElevationMeters = maxElevation
        minDistanceMeters = minDistance
        maxDistanceMeters = maxDistance
        trackDays = TrackColorStyling.trackDays(in: track, calendar: calendar)
    }

    var elevationRangeText: String {
        let minText = Int(minElevationMeters.rounded())
        let maxText = Int(maxElevationMeters.rounded())

        guard minText != maxText else {
            return "\(minText) m"
        }

        return "\(minText)-\(maxText) m"
    }

    func lineSections(trackColor: TrackColor, trackColorMode: TrackColorMode) -> [GPXHeightProfileLineSection] {
        switch trackColorMode {
        case .single:
            return singleColorLineSections(trackColor: trackColor)
        case .multiDay:
            guard trackDays.count > 1 else {
                return singleColorLineSections(trackColor: trackColor)
            }

            let colorsByDay = TrackColorStyling.colorsByDay(for: trackDays, baseColor: trackColor.uiColor)
            var sections: [GPXHeightProfileLineSection] = []
            var currentSamples: [GPXHeightProfileSample] = []
            var currentDay: Date?

            func appendSection(samples: [GPXHeightProfileSample], day: Date?) {
                guard samples.count > 1 else { return }

                let color = day.flatMap { colorsByDay[$0] } ?? trackColor.uiColor
                sections.append(
                    GPXHeightProfileLineSection(
                        id: sections.count,
                        samples: samples,
                        color: color
                    )
                )
            }

            for sample in samples {
                let resolvedDay = sample.day ?? currentDay

                if let activeDay = currentDay, let nextDay = resolvedDay, nextDay != activeDay {
                    appendSection(samples: currentSamples, day: activeDay)
                    currentSamples = currentSamples.last.map { [$0, sample] } ?? [sample]
                    currentDay = nextDay
                } else {
                    currentSamples.append(sample)
                    if currentDay == nil {
                        currentDay = resolvedDay
                    }
                }
            }

            appendSection(samples: currentSamples, day: currentDay)
            return sections.isEmpty ? singleColorLineSections(trackColor: trackColor) : sections
        }
    }

    private func singleColorLineSections(trackColor: TrackColor) -> [GPXHeightProfileLineSection] {
        [
            GPXHeightProfileLineSection(
                id: 0,
                samples: samples,
                color: trackColor.uiColor
            )
        ]
    }
}

struct GPXHeightProfileSample: Identifiable {
    let id: Int
    let distanceMeters: CLLocationDistance
    let elevationMeters: Double
    let day: Date?
}

struct GPXHeightProfileLineSection: Identifiable {
    let id: Int
    let samples: [GPXHeightProfileSample]
    let color: UIColor
}

extension GPXTrack {
    var heightProfile: GPXHeightProfile? {
        GPXHeightProfile(track: self)
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
    case violet = "volt"
    case magenta
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flame:
            return "Flame"
        case .alpine:
            return "Alpine"
        case .violet:
            return "Violet"
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
        case .violet:
            return UIColor(red: 0.38, green: 0.22, blue: 1.00, alpha: 1)
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

enum TrackColorStyling {
    private static let multiDayHueOffsets: [CGFloat] = [
        0.00, 0.50, 0.10, 0.60, 0.20, 0.70, 0.30, 0.80, 0.40, 0.90
    ]

    static func trackDays(in track: GPXTrack, calendar: Calendar) -> [Date] {
        let days = Set(track.allPoints.compactMap { point in
            point.time.map { calendar.startOfDay(for: $0) }
        })
        return days.sorted()
    }

    static func colorsByDay(for days: [Date], baseColor: UIColor) -> [Date: UIColor] {
        Dictionary(
            uniqueKeysWithValues: days.enumerated().map { index, day in
                (day, multiDayColor(forDayAt: index, baseColor: baseColor))
            }
        )
    }

    private static func multiDayColor(forDayAt index: Int, baseColor: UIColor) -> UIColor {
        guard index > 0 else { return baseColor }

        let baseHue = hue(from: baseColor)
        let hue = (baseHue + multiDayHueOffset(forDayAt: index)).truncatingRemainder(dividingBy: 1)
        let saturation: CGFloat = index.isMultiple(of: 2) ? 0.88 : 0.78
        let brightness: CGFloat = index.isMultiple(of: 3) ? 0.88 : 0.98

        return UIColor(hue: mapFriendlyHue(hue), saturation: saturation, brightness: brightness, alpha: 1)
    }

    private static func multiDayHueOffset(forDayAt index: Int) -> CGFloat {
        if index < multiDayHueOffsets.count {
            return multiDayHueOffsets[index]
        }

        let offset = multiDayHueOffsets[index % multiDayHueOffsets.count]
        let repeatShift = CGFloat(index / multiDayHueOffsets.count) * 0.05
        return (offset + repeatShift).truncatingRemainder(dividingBy: 1)
    }

    private static func mapFriendlyHue(_ hue: CGFloat) -> CGFloat {
        let greenAndLimeRange: ClosedRange<CGFloat> = 0.16...0.43
        guard greenAndLimeRange.contains(hue) else { return hue }

        return (hue + 0.66).truncatingRemainder(dividingBy: 1)
    }

    private static func hue(from color: UIColor) -> CGFloat {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        if color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha),
           saturation > 0.2 {
            return hue
        }

        return 0.03
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
