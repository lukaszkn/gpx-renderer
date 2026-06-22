import CoreLocation
import MapKit
import UIKit

struct RoutePolyline {
    let coordinates: [CLLocationCoordinate2D]
    let polyline: MKPolyline
    let style: RoutePolylineStyle

    init(coordinates: [CLLocationCoordinate2D], style: RoutePolylineStyle) {
        self.coordinates = coordinates
        self.polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.style = style
    }

    var outlineCopy: RoutePolyline {
        RoutePolyline(coordinates: coordinates, style: .outline)
    }
}

enum RoutePolylineStyle {
    private static let trackLineWidth: CGFloat = 5.5
    private static let outlineLineWidth: CGFloat = 9.5

    case outline
    case track(color: UIColor)

    var color: UIColor {
        switch self {
        case .outline:
            return .white
        case .track(let color):
            return color
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .outline:
            return Self.outlineLineWidth
        case .track:
            return Self.trackLineWidth
        }
    }
}

enum RoutePolylineFactory {
    static func makeRoutePolylines(
        for track: GPXTrack?,
        trackColor: TrackColor,
        trackColorMode: TrackColorMode
    ) -> [RoutePolyline] {
        guard let track else { return [] }

        switch trackColorMode {
        case .single:
            return makeSingleColorPolylines(for: track, trackColor: trackColor)
        case .multiDay:
            let calendar = Calendar.current
            let days = TrackColorStyling.trackDays(in: track, calendar: calendar)
            guard days.count > 1 else {
                return makeSingleColorPolylines(for: track, trackColor: trackColor)
            }

            let colorsByDay = TrackColorStyling.colorsByDay(for: days, baseColor: trackColor.uiColor)

            return track.segments.flatMap { segment in
                makeMultiDayPolylines(
                    for: segment,
                    trackColor: trackColor,
                    colorsByDay: colorsByDay,
                    calendar: calendar
                )
            }
        }
    }

    private static func makeSingleColorPolylines(for track: GPXTrack, trackColor: TrackColor) -> [RoutePolyline] {
        track.segments.compactMap { segment in
            makePolyline(from: segment.points, color: trackColor.uiColor)
        }
    }

    private static func makeMultiDayPolylines(
        for segment: GPXSegment,
        trackColor: TrackColor,
        colorsByDay: [Date: UIColor],
        calendar: Calendar
    ) -> [RoutePolyline] {
        var polylines: [RoutePolyline] = []
        var currentPoints: [GPXPoint] = []
        var currentDay: Date?

        for point in segment.points {
            let pointDay = point.time.map { calendar.startOfDay(for: $0) }
            let resolvedDay = pointDay ?? currentDay

            if let activeDay = currentDay, let nextDay = resolvedDay, nextDay != activeDay {
                if let polyline = makePolyline(
                    from: currentPoints,
                    color: colorsByDay[activeDay] ?? trackColor.uiColor
                ) {
                    polylines.append(polyline)
                }

                currentPoints = currentPoints.last.map { [$0, point] } ?? [point]
                currentDay = nextDay
            } else {
                currentPoints.append(point)
                if currentDay == nil {
                    currentDay = resolvedDay
                }
            }
        }

        let color = currentDay.flatMap { colorsByDay[$0] } ?? trackColor.uiColor
        if let polyline = makePolyline(from: currentPoints, color: color) {
            polylines.append(polyline)
        }

        return polylines
    }

    private static func makePolyline(from points: [GPXPoint], color: UIColor) -> RoutePolyline? {
        let coordinates = points.map(\.coordinate)
        guard coordinates.count > 1 else { return nil }
        return RoutePolyline(coordinates: coordinates, style: .track(color: color))
    }
}
