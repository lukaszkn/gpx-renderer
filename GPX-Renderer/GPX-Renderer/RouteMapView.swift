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

        let routePolylines = RoutePolylineFactory.makeRoutePolylines(
            for: track,
            trackColor: trackColor,
            trackColorMode: trackColorMode
        )
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
