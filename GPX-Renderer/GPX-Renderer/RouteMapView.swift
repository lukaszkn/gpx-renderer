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
        let polylines = routePolylines.map(\.polyline)
        coordinator.overlayColors = Dictionary(
            uniqueKeysWithValues: routePolylines.map { routePolyline in
                (ObjectIdentifier(routePolyline.polyline), routePolyline.color)
            }
        )

        mapView.addOverlays(polylines)
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
            let days = trackDays(in: track, calendar: calendar)
            guard days.count > 1 else {
                return makeSingleColorPolylines(for: track)
            }

            let colorsByDay = Dictionary(
                uniqueKeysWithValues: days.enumerated().map { index, day in
                    (day, multiDayColor(forDayAt: index))
                }
            )

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
        return RoutePolyline(polyline: MKPolyline(coordinates: coordinates, count: coordinates.count), color: color)
    }

    private func trackDays(in track: GPXTrack, calendar: Calendar) -> [Date] {
        let days = Set(track.allPoints.compactMap { point in
            point.time.map { calendar.startOfDay(for: $0) }
        })
        return days.sorted()
    }

    private func multiDayColor(forDayAt index: Int) -> UIColor {
        guard index > 0 else { return trackColor.uiColor }

        let baseHue = hue(from: trackColor.uiColor)
        let hue = (baseHue + CGFloat(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        let saturation: CGFloat = index.isMultiple(of: 2) ? 0.88 : 0.78
        let brightness: CGFloat = index.isMultiple(of: 3) ? 0.88 : 0.98

        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private func hue(from color: UIColor) -> CGFloat {
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
        let polyline: MKPolyline
        let color: UIColor
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var trackColor: TrackColor = .flame
        var overlayColors: [ObjectIdentifier: UIColor] = [:]
        var renderedTrackID: UUID?
        var renderedTrackColor: TrackColor?
        var renderedTrackColorMode: TrackColorMode?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = overlayColors[ObjectIdentifier(polyline)] ?? trackColor.uiColor
            renderer.lineWidth = 5.5
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
    }
}
