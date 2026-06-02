import MapKit
import SwiftUI
import UIKit

struct RouteMapView: UIViewRepresentable {
    let track: GPXTrack?
    let trackColor: TrackColor
    let trackColorMode: TrackColorMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = false
        mapView.isPitchEnabled = true
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.trackColor = trackColor

        let currentTrackID = track?.id
        if context.coordinator.renderedTrackID != currentTrackID {
            renderTrack(on: mapView, coordinator: context.coordinator, fitRoute: true)
            return
        }

        if context.coordinator.renderedTrackColor != trackColor || context.coordinator.renderedTrackColorMode != trackColorMode {
            renderTrack(on: mapView, coordinator: context.coordinator, fitRoute: false)
        }
    }

    private func renderTrack(on mapView: MKMapView, coordinator: Coordinator, fitRoute: Bool) {
        mapView.removeOverlays(mapView.overlays)

        let routePolylines = makeRoutePolylines()
        let outlinePolylines = routePolylines.map(\.outlineCopy)
        let overlayPolylines = outlinePolylines + routePolylines
        let polylines = routePolylines.map(\.polyline)
        coordinator.overlayStyles = Dictionary(
            uniqueKeysWithValues: overlayPolylines.map { routePolyline in
                (ObjectIdentifier(routePolyline.polyline), routePolyline.style)
            }
        )

        mapView.addOverlays(overlayPolylines.map(\.polyline))
        coordinator.renderedTrackID = track?.id
        coordinator.renderedTrackColor = trackColor
        coordinator.renderedTrackColorMode = trackColorMode

        guard fitRoute else { return }
        fit(polylines: polylines, on: mapView)
    }

    private func makeRoutePolylines() -> [RoutePolyline] {
        guard let track else { return [] }

        switch trackColorMode {
        case .single:
            return makeSingleColorPolylines(for: track)
        case .multiDay:
            let calendar = Calendar.current
            let days = TrackColorStyling.trackDays(in: track, calendar: calendar)
            guard days.count > 1 else {
                return makeSingleColorPolylines(for: track)
            }

            let colorsByDay = TrackColorStyling.colorsByDay(for: days, baseColor: trackColor.uiColor)

            return track.segments.flatMap { segment in
                makeMultiDayPolylines(for: segment, colorsByDay: colorsByDay, calendar: calendar)
            }
        }
    }

    private func makeSingleColorPolylines(for track: GPXTrack) -> [RoutePolyline] {
        track.segments.compactMap { segment in
            makePolyline(from: segment.points, color: trackColor.uiColor)
        }
    }

    private func makeMultiDayPolylines(
        for segment: GPXSegment,
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

    private func makePolyline(from points: [GPXPoint], color: UIColor) -> RoutePolyline? {
        let coordinates = points.map(\.coordinate)
        guard coordinates.count > 1 else { return nil }
        return RoutePolyline(coordinates: coordinates, style: .track(color: color))
    }

    private func fit(polylines: [MKPolyline], on mapView: MKMapView) {
        let routeRect = polylines.reduce(MKMapRect.null) { rect, polyline in
            rect.union(polyline.boundingMapRect)
        }

        guard !routeRect.isNull, !routeRect.isEmpty else { return }

        mapView.setVisibleMapRect(
            routeRect,
            edgePadding: UIEdgeInsets(top: 90, left: 34, bottom: 120, right: 34),
            animated: false
        )
    }

    private struct RoutePolyline {
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

    final class Coordinator: NSObject, MKMapViewDelegate {
        var trackColor: TrackColor = .flame
        var overlayStyles: [ObjectIdentifier: RoutePolylineStyle] = [:]
        var renderedTrackID: UUID?
        var renderedTrackColor: TrackColor?
        var renderedTrackColorMode: TrackColorMode?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            let style = overlayStyles[ObjectIdentifier(polyline)] ?? .track(color: trackColor.uiColor)
            renderer.strokeColor = style.color
            renderer.lineWidth = style.lineWidth
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
    }
}
