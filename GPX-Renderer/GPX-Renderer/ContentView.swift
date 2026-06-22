import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = GPXAppModel()

    var body: some View {
        ZStack {
            RouteMapView(track: model.track, trackColor: model.selectedColor, trackColorMode: model.trackColorMode)
                .ignoresSafeArea()

            if model.track == nil {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(spacing: 0) {
                if !model.isChromeHiddenForCapture {
                    topControls
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }

                Spacer()
            }

            VStack {
                Spacer()
                statsOverlay
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
            }
        }
        .task {
            model.loadInitialTrack()
        }
        .onOpenURL { url in
            model.handleOpenURL(url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            model.loadPendingImportIfAvailable()
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            trackTitle

            Spacer(minLength: 8)

            Menu {
                Toggle(isOn: $model.isDateTimeVisible) {
                    Label("Show Date/Time", systemImage: "calendar.badge.clock")
                }

                Toggle(isOn: $model.isHeightProfileVisible) {
                    Label("Show Height Profile", systemImage: "chart.line.uptrend.xyaxis")
                }

                Button {
                    model.saveHighResolutionImageToPhotos()
                } label: {
                    Label("Save High-Res Image", systemImage: "photo")
                }
                .disabled(model.isSavingScreenshot || model.track == nil)

                Menu {
                    ForEach(TrackColorMode.allCases) { mode in
                        Button {
                            model.trackColorMode = mode
                        } label: {
                            Label(mode.title, systemImage: mode == model.trackColorMode ? "checkmark.circle.fill" : mode.systemImage)
                        }
                    }
                } label: {
                    Label("Track Style", systemImage: "paintbrush.pointed")
                }

                Menu {
                    ForEach(TrackColor.allCases) { color in
                        Button {
                            model.selectedColor = color
                        } label: {
                            Label(color.title, systemImage: color == model.selectedColor ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                } label: {
                    Label("Track Color", systemImage: "paintpalette")
                }

                if !model.documents.isEmpty {
                    Menu {
                        ForEach(model.documents) { document in
                            Button {
                                model.loadDocument(document)
                            } label: {
                                Label(document.title, systemImage: "doc.text")
                            }
                        }
                    } label: {
                        Label("Documents", systemImage: "folder")
                    }
                }

                Button {
                    model.refreshDocuments()
                } label: {
                    Label("Refresh Documents", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Options")

            Button {
                model.saveScreenshotToPhotos()
            } label: {
                Image(systemName: model.isSavingScreenshot ? "hourglass.circle.fill" : "square.and.arrow.down.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
            }
            .disabled(model.isSavingScreenshot)
            .accessibilityLabel("Save to Photos")
        }
        .foregroundStyle(.primary)
    }

    private var trackTitle: some View {
        Text(model.track?.displayName ?? "GPX Renderer")
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isDateTimeVisible, let startDateTimeText = model.stats.startDateTimeText {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                    Text(startDateTimeText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.primary)
            }

            HStack(spacing: 12) {
                statBlock(value: model.stats.distanceText, label: "Kilometres")
                Divider()
                    .frame(height: 30)
                statBlock(value: model.stats.durationText, label: "Time")
            }

            if model.isHeightProfileVisible, let heightProfile = model.track?.heightProfile {
                HeightProfileView(
                    profile: heightProfile,
                    trackColor: model.selectedColor,
                    trackColorMode: model.trackColorMode
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HeightProfileView: View {
    let profile: GPXHeightProfile
    let trackColor: TrackColor
    let trackColorMode: TrackColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.semibold))
                Text("Height")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 12)
                Text(profile.elevationRangeText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)

            ZStack {
                HeightProfileGrid()
                    .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                ForEach(profile.lineSections(trackColor: trackColor, trackColorMode: trackColorMode)) { section in
                    let color = Color(uiColor: section.color)
                    HeightProfileLine(profile: profile, samples: section.samples)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: color.opacity(0.35), radius: 2, y: 1)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(height: 54)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Height profile, \(profile.elevationRangeText)")
    }
}

private struct HeightProfileGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let yPositions = [rect.minY, rect.midY, rect.maxY]

        for yPosition in yPositions {
            path.move(to: CGPoint(x: rect.minX, y: yPosition))
            path.addLine(to: CGPoint(x: rect.maxX, y: yPosition))
        }

        return path
    }
}

private struct HeightProfileLine: Shape {
    let profile: GPXHeightProfile
    let samples: [GPXHeightProfileSample]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let firstSample = samples.first else { return path }

        let elevationRange = profile.maxElevationMeters - profile.minElevationMeters
        let elevationPadding = elevationRange > 0 ? max(elevationRange * 0.08, 1) : 1
        let minElevation = profile.minElevationMeters - elevationPadding
        let maxElevation = profile.maxElevationMeters + elevationPadding
        let paddedElevationRange = max(maxElevation - minElevation, 1)
        let distanceRange = profile.maxDistanceMeters - profile.minDistanceMeters

        for (index, sample) in samples.enumerated() {
            let xProgress: Double
            if distanceRange > 0 {
                xProgress = (sample.distanceMeters - profile.minDistanceMeters) / distanceRange
            } else if samples.count > 1 {
                xProgress = Double(index) / Double(samples.count - 1)
            } else {
                xProgress = 0
            }

            let yProgress = (sample.elevationMeters - minElevation) / paddedElevationRange
            let point = CGPoint(
                x: rect.minX + rect.width * CGFloat(xProgress),
                y: rect.maxY - rect.height * CGFloat(yProgress)
            )

            if sample.id == firstSample.id {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }
}

#Preview {
    ContentView()
}
