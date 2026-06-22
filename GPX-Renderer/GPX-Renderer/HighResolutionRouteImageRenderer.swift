import CoreGraphics
import MapKit
import UIKit

private struct ScreenMetrics {
    let sizeInPoints: CGSize
    let scale: CGFloat

    var shortestSideInPoints: CGFloat {
        min(sizeInPoints.width, sizeInPoints.height)
    }
}

@MainActor
struct HighResolutionRouteImageRenderer {
    private let outputAspectRatio: CGFloat = 1.25
    private let minimumOutputWidthPixels: CGFloat = 1_800
    private let maximumOutputHeightPixels: CGFloat = 4_096
    private let decorationScaleMultiplier: CGFloat = 0.62

    func render(
        track: GPXTrack,
        stats: GPXStats,
        trackColor: TrackColor,
        trackColorMode: TrackColorMode,
        isDateTimeVisible: Bool,
        isHeightProfileVisible: Bool
    ) async throws -> UIImage {
        let routePolylines = RoutePolylineFactory.makeRoutePolylines(
            for: track,
            trackColor: trackColor,
            trackColorMode: trackColorMode
        )
        guard !routePolylines.isEmpty else {
            throw GPXImportError.emptyTrack
        }

        let screenMetrics = currentScreenMetrics()
        let outputScale = screenMetrics.scale
        let imageSize = targetImageSize(screenMetrics: screenMetrics)
        let layoutScale = imageSize.width / max(screenMetrics.shortestSideInPoints, 1)
        let decorationScale = decorationScale(for: layoutScale)
        let heightProfile = isHeightProfileVisible ? track.heightProfile : nil
        let mapRect = visibleMapRect(
            for: routePolylines,
            imageSize: imageSize,
            decorationScale: decorationScale,
            hasHeightProfile: heightProfile != nil,
            hasDateTime: isDateTimeVisible && stats.startDateTimeText != nil
        )

        let snapshot = try await makeSnapshot(imageSize: imageSize, outputScale: outputScale, mapRect: mapRect)
        return drawImage(
            snapshot: snapshot,
            routePolylines: routePolylines,
            stats: stats,
            trackColor: trackColor,
            trackColorMode: trackColorMode,
            heightProfile: heightProfile,
            imageSize: imageSize,
            outputScale: outputScale,
            decorationScale: decorationScale,
            isDateTimeVisible: isDateTimeVisible
        )
    }

    private func makeSnapshot(
        imageSize: CGSize,
        outputScale: CGFloat,
        mapRect: MKMapRect
    ) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.size = imageSize
        options.scale = outputScale
        options.mapRect = mapRect
        options.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)

        return try await MKMapSnapshotter(options: options).start()
    }

    private func drawImage(
        snapshot: MKMapSnapshotter.Snapshot,
        routePolylines: [RoutePolyline],
        stats: GPXStats,
        trackColor: TrackColor,
        trackColorMode: TrackColorMode,
        heightProfile: GPXHeightProfile?,
        imageSize: CGSize,
        outputScale: CGFloat,
        decorationScale: CGFloat,
        isDateTimeVisible: Bool
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = outputScale
        format.opaque = true

        return UIGraphicsImageRenderer(size: imageSize, format: format).image { rendererContext in
            snapshot.image.draw(in: CGRect(origin: .zero, size: imageSize))

            let context = rendererContext.cgContext
            drawRoute(
                routePolylines.map(\.outlineCopy) + routePolylines,
                on: context,
                snapshot: snapshot,
                decorationScale: decorationScale
            )

            HighResolutionStatsOverlayRenderer.draw(
                stats: stats,
                trackColor: trackColor,
                trackColorMode: trackColorMode,
                heightProfile: heightProfile,
                isDateTimeVisible: isDateTimeVisible,
                in: CGRect(origin: .zero, size: imageSize),
                decorationScale: decorationScale
            )
        }
    }

    private func drawRoute(
        _ polylines: [RoutePolyline],
        on context: CGContext,
        snapshot: MKMapSnapshotter.Snapshot,
        decorationScale: CGFloat
    ) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for routePolyline in polylines {
            guard let firstCoordinate = routePolyline.coordinates.first else { continue }

            let path = CGMutablePath()
            path.move(to: snapshot.point(for: firstCoordinate))

            for coordinate in routePolyline.coordinates.dropFirst() {
                path.addLine(to: snapshot.point(for: coordinate))
            }

            context.addPath(path)
            context.setStrokeColor(routePolyline.style.color.cgColor)
            context.setLineWidth(routePolyline.style.lineWidth * decorationScale)
            context.strokePath()
        }

        context.restoreGState()
    }

    private func targetImageSize(screenMetrics: ScreenMetrics) -> CGSize {
        let rawWidth = screenMetrics.shortestSideInPoints * screenMetrics.scale * 2
        let cappedWidth = min(max(rawWidth, minimumOutputWidthPixels), maximumOutputHeightPixels / outputAspectRatio)
        let roundedWidth = cappedWidth.rounded(.toNearestOrAwayFromZero)
        let roundedHeight = (roundedWidth * outputAspectRatio).rounded(.toNearestOrAwayFromZero)
        return CGSize(width: roundedWidth / screenMetrics.scale, height: roundedHeight / screenMetrics.scale)
    }

    private func decorationScale(for layoutScale: CGFloat) -> CGFloat {
        max(1, layoutScale * decorationScaleMultiplier)
    }

    private func currentScreenMetrics() -> ScreenMetrics {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        guard let window = windowScene?.windows.first(where: \.isKeyWindow) ?? windowScene?.windows.first else {
            return ScreenMetrics(sizeInPoints: CGSize(width: 390, height: 844), scale: 3)
        }

        return ScreenMetrics(sizeInPoints: window.bounds.size, scale: window.screen.scale)
    }

    private func visibleMapRect(
        for polylines: [RoutePolyline],
        imageSize: CGSize,
        decorationScale: CGFloat,
        hasHeightProfile: Bool,
        hasDateTime: Bool
    ) -> MKMapRect {
        let routeRect = normalizedMapRect(
            polylines.reduce(MKMapRect.null) { rect, routePolyline in
                rect.union(routePolyline.polyline.boundingMapRect)
            }
        )

        let overlayHeight = HighResolutionStatsOverlayRenderer.height(
            hasHeightProfile: hasHeightProfile,
            hasDateTime: hasDateTime,
            decorationScale: decorationScale
        )
        let leftPadding = 34 * decorationScale
        let rightPadding = 34 * decorationScale
        let topPadding = 70 * decorationScale
        let requestedBottomPadding = max(120 * decorationScale, overlayHeight + 34 * decorationScale)
        let bottomPadding = min(requestedBottomPadding, imageSize.height * 0.42)

        return paddedMapRect(
            routeRect,
            imageSize: imageSize,
            padding: UIEdgeInsets(
                top: topPadding,
                left: leftPadding,
                bottom: bottomPadding,
                right: rightPadding
            )
        )
    }

    private func normalizedMapRect(_ rect: MKMapRect) -> MKMapRect {
        guard !rect.isNull, !rect.isEmpty else { return rect }

        let largestSpan = max(rect.width, rect.height)
        let minimumSpan = max(largestSpan * 0.02, 400)
        let width = max(rect.width, minimumSpan)
        let height = max(rect.height, minimumSpan)
        let originX = rect.midX - width / 2
        let originY = rect.midY - height / 2

        return MKMapRect(x: originX, y: originY, width: width, height: height)
    }

    private func paddedMapRect(
        _ routeRect: MKMapRect,
        imageSize: CGSize,
        padding: UIEdgeInsets
    ) -> MKMapRect {
        guard !routeRect.isNull, !routeRect.isEmpty else { return routeRect }

        let contentWidth = max(imageSize.width - padding.left - padding.right, 1)
        let contentHeight = max(imageSize.height - padding.top - padding.bottom, 1)
        let mapPointsPerPixel = max(routeRect.width / contentWidth, routeRect.height / contentHeight)
        let visibleWidth = imageSize.width * mapPointsPerPixel
        let visibleHeight = imageSize.height * mapPointsPerPixel
        let contentCenterX = padding.left + contentWidth / 2
        let contentCenterY = padding.top + contentHeight / 2
        let originX = routeRect.midX - contentCenterX * mapPointsPerPixel
        let originY = routeRect.midY - contentCenterY * mapPointsPerPixel

        return clampedWorldRect(
            MKMapRect(x: originX, y: originY, width: visibleWidth, height: visibleHeight)
        )
    }

    private func clampedWorldRect(_ rect: MKMapRect) -> MKMapRect {
        let world = MKMapRect.world
        let width = min(rect.width, world.width)
        let height = min(rect.height, world.height)
        let maxX = world.maxX - width
        let maxY = world.maxY - height
        let x = min(max(rect.origin.x, world.minX), maxX)
        let y = min(max(rect.origin.y, world.minY), maxY)

        return MKMapRect(x: x, y: y, width: width, height: height)
    }
}

private enum HighResolutionStatsOverlayRenderer {
    static func height(hasHeightProfile: Bool, hasDateTime: Bool, decorationScale: CGFloat) -> CGFloat {
        var contentHeight = 44 * decorationScale

        if hasDateTime {
            contentHeight += 20 * decorationScale + 10 * decorationScale
        }

        if hasHeightProfile {
            contentHeight += 10 * decorationScale + 76 * decorationScale
        }

        return contentHeight + 24 * decorationScale
    }

    static func draw(
        stats: GPXStats,
        trackColor: TrackColor,
        trackColorMode: TrackColorMode,
        heightProfile: GPXHeightProfile?,
        isDateTimeVisible: Bool,
        in imageRect: CGRect,
        decorationScale: CGFloat
    ) {
        let marginX = 14 * decorationScale
        let bottomMargin = 18 * decorationScale
        let hasDateTime = isDateTimeVisible && stats.startDateTimeText != nil
        let overlayHeight = height(
            hasHeightProfile: heightProfile != nil,
            hasDateTime: hasDateTime,
            decorationScale: decorationScale
        )
        let overlayRect = CGRect(
            x: marginX,
            y: imageRect.maxY - bottomMargin - overlayHeight,
            width: imageRect.width - marginX * 2,
            height: overlayHeight
        )
        let cornerRadius = 8 * decorationScale

        let path = UIBezierPath(roundedRect: overlayRect, cornerRadius: cornerRadius)
        UIColor.white.withAlphaComponent(0.84).setFill()
        path.fill()
        UIColor.white.withAlphaComponent(0.45).setStroke()
        path.lineWidth = decorationScale
        path.stroke()

        let contentRect = overlayRect.insetBy(dx: 16 * decorationScale, dy: 12 * decorationScale)
        var y = contentRect.minY

        if hasDateTime, let startDateTimeText = stats.startDateTimeText {
            drawIconTextRow(
                symbolName: "calendar.badge.clock",
                text: startDateTimeText,
                rect: CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 20 * decorationScale),
                font: UIFont.systemFont(ofSize: 13 * decorationScale, weight: .semibold),
                decorationScale: decorationScale
            )
            y += 30 * decorationScale
        }

        drawStatsRow(
            distanceText: stats.distanceText,
            durationText: stats.durationText,
            rect: CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 44 * decorationScale),
            decorationScale: decorationScale
        )
        y += 44 * decorationScale

        if let heightProfile {
            y += 10 * decorationScale
            drawHeightProfile(
                heightProfile,
                trackColor: trackColor,
                trackColorMode: trackColorMode,
                rect: CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 76 * decorationScale),
                decorationScale: decorationScale
            )
        }
    }

    private static func drawIconTextRow(
        symbolName: String,
        text: String,
        rect: CGRect,
        font: UIFont,
        decorationScale: CGFloat
    ) {
        let color = UIColor.black.withAlphaComponent(0.86)
        let iconSize = 17 * decorationScale
        let iconRect = CGRect(
            x: rect.minX,
            y: rect.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        drawSymbol(named: symbolName, in: iconRect, pointSize: 15 * decorationScale, tintColor: color)

        let textRect = CGRect(
            x: iconRect.maxX + 8 * decorationScale,
            y: rect.minY,
            width: rect.width - iconSize - 8 * decorationScale,
            height: rect.height
        )
        drawText(text, in: textRect, font: font, color: color, verticalAlignment: .center)
    }

    private static func drawStatsRow(
        distanceText: String,
        durationText: String,
        rect: CGRect,
        decorationScale: CGFloat
    ) {
        let spacing = 12 * decorationScale
        let dividerWidth = max(decorationScale, 1)
        let blockWidth = (rect.width - spacing * 2 - dividerWidth) / 2
        let leftRect = CGRect(x: rect.minX, y: rect.minY, width: blockWidth, height: rect.height)
        let dividerRect = CGRect(
            x: leftRect.maxX + spacing,
            y: rect.midY - 15 * decorationScale,
            width: dividerWidth,
            height: 30 * decorationScale
        )
        let rightRect = CGRect(
            x: dividerRect.maxX + spacing,
            y: rect.minY,
            width: blockWidth,
            height: rect.height
        )

        drawStatBlock(value: distanceText, label: "Kilometres", rect: leftRect, decorationScale: decorationScale)
        UIColor.black.withAlphaComponent(0.18).setFill()
        UIBezierPath(rect: dividerRect).fill()
        drawStatBlock(value: durationText, label: "Time", rect: rightRect, decorationScale: decorationScale)
    }

    private static func drawStatBlock(value: String, label: String, rect: CGRect, decorationScale: CGFloat) {
        drawText(
            value,
            in: CGRect(x: rect.minX, y: rect.minY - 2 * decorationScale, width: rect.width, height: 30 * decorationScale),
            font: roundedFont(ofSize: 24 * decorationScale, weight: .bold),
            color: .black,
            verticalAlignment: .center
        )
        drawText(
            label,
            in: CGRect(x: rect.minX, y: rect.minY + 29 * decorationScale, width: rect.width, height: 15 * decorationScale),
            font: UIFont.systemFont(ofSize: 12 * decorationScale, weight: .semibold),
            color: UIColor.black.withAlphaComponent(0.58),
            verticalAlignment: .center
        )
    }

    private static func drawHeightProfile(
        _ profile: GPXHeightProfile,
        trackColor: TrackColor,
        trackColorMode: TrackColorMode,
        rect: CGRect,
        decorationScale: CGFloat
    ) {
        let labelColor = UIColor.black.withAlphaComponent(0.58)
        let headerHeight = 16 * decorationScale
        let iconSize = 12 * decorationScale
        let iconRect = CGRect(x: rect.minX, y: rect.minY + 2 * decorationScale, width: iconSize, height: iconSize)
        drawSymbol(named: "chart.line.uptrend.xyaxis", in: iconRect, pointSize: 11 * decorationScale, tintColor: labelColor)
        drawText(
            "Height",
            in: CGRect(
                x: iconRect.maxX + 8 * decorationScale,
                y: rect.minY,
                width: rect.width * 0.45,
                height: headerHeight
            ),
            font: UIFont.systemFont(ofSize: 12 * decorationScale, weight: .semibold),
            color: labelColor,
            verticalAlignment: .center
        )
        drawText(
            profile.elevationRangeText,
            in: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: headerHeight),
            font: UIFont.systemFont(ofSize: 12 * decorationScale, weight: .semibold),
            color: labelColor,
            alignment: .right,
            verticalAlignment: .center
        )

        let chartBackgroundRect = CGRect(
            x: rect.minX,
            y: rect.minY + 22 * decorationScale,
            width: rect.width,
            height: 54 * decorationScale
        )
        UIColor.black.withAlphaComponent(0.055).setFill()
        UIBezierPath(roundedRect: chartBackgroundRect, cornerRadius: 6 * decorationScale).fill()

        let chartRect = chartBackgroundRect.insetBy(dx: 4 * decorationScale, dy: 5 * decorationScale)
        drawHeightGrid(in: chartRect, decorationScale: decorationScale)
        drawHeightLines(
            profile: profile,
            sections: profile.lineSections(trackColor: trackColor, trackColorMode: trackColorMode),
            in: chartRect,
            decorationScale: decorationScale
        )
    }

    private static func drawHeightGrid(in rect: CGRect, decorationScale: CGFloat) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.saveGState()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(max(decorationScale, 1))
        context.setLineDash(phase: 0, lengths: [3 * decorationScale, 5 * decorationScale])

        for y in [rect.minY, rect.midY, rect.maxY] {
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.strokePath()
        context.restoreGState()
    }

    private static func drawHeightLines(
        profile: GPXHeightProfile,
        sections: [GPXHeightProfileLineSection],
        in rect: CGRect,
        decorationScale: CGFloat
    ) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(2.5 * decorationScale)

        for section in sections {
            guard let firstSample = section.samples.first else { continue }

            let path = CGMutablePath()
            path.move(to: point(for: firstSample, at: 0, sampleCount: section.samples.count, profile: profile, rect: rect))

            for (index, sample) in section.samples.dropFirst().enumerated() {
                path.addLine(to: point(for: sample, at: index + 1, sampleCount: section.samples.count, profile: profile, rect: rect))
            }

            context.addPath(path)
            context.setShadow(
                offset: CGSize(width: 0, height: decorationScale),
                blur: 2 * decorationScale,
                color: section.color.withAlphaComponent(0.35).cgColor
            )
            context.setStrokeColor(section.color.cgColor)
            context.strokePath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }

        context.restoreGState()
    }

    private static func point(
        for sample: GPXHeightProfileSample,
        at index: Int,
        sampleCount: Int,
        profile: GPXHeightProfile,
        rect: CGRect
    ) -> CGPoint {
        let elevationRange = profile.maxElevationMeters - profile.minElevationMeters
        let elevationPadding = elevationRange > 0 ? max(elevationRange * 0.08, 1) : 1
        let minElevation = profile.minElevationMeters - elevationPadding
        let maxElevation = profile.maxElevationMeters + elevationPadding
        let paddedElevationRange = max(maxElevation - minElevation, 1)
        let distanceRange = profile.maxDistanceMeters - profile.minDistanceMeters

        let xProgress: Double
        if distanceRange > 0 {
            xProgress = (sample.distanceMeters - profile.minDistanceMeters) / distanceRange
        } else if sampleCount > 1 {
            xProgress = Double(index) / Double(sampleCount - 1)
        } else {
            xProgress = 0
        }

        let yProgress = (sample.elevationMeters - minElevation) / paddedElevationRange
        return CGPoint(
            x: rect.minX + rect.width * CGFloat(xProgress),
            y: rect.maxY - rect.height * CGFloat(yProgress)
        )
    }

    private static func roundedFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else {
            return font
        }

        return UIFont(descriptor: descriptor, size: size)
    }

    private static func drawSymbol(named name: String, in rect: CGRect, pointSize: CGFloat, tintColor: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let image = UIImage(systemName: name, withConfiguration: configuration) else { return }

        image
            .withTintColor(tintColor, renderingMode: .alwaysOriginal)
            .draw(in: rect)
    }

    private enum VerticalAlignment {
        case top
        case center
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        verticalAlignment: VerticalAlignment = .top
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let measuredHeight = min(font.lineHeight, rect.height)
        let drawRect: CGRect
        switch verticalAlignment {
        case .top:
            drawRect = rect
        case .center:
            drawRect = CGRect(x: rect.minX, y: rect.midY - measuredHeight / 2, width: rect.width, height: measuredHeight)
        }

        (text as NSString).draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ],
            context: nil
        )
    }
}
