import SwiftUI

struct ContentView: View {
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

#Preview {
    ContentView()
}
