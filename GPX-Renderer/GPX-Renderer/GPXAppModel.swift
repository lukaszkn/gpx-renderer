import Combine
import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class GPXAppModel: ObservableObject {
    @Published var track: GPXTrack?
    @Published var stats = GPXStats.empty
    @Published var selectedColor: TrackColor {
        didSet {
            UserDefaults.standard.set(selectedColor.rawValue, forKey: Self.trackColorDefaultsKey)
        }
    }
    @Published var trackColorMode: TrackColorMode {
        didSet {
            UserDefaults.standard.set(trackColorMode.rawValue, forKey: Self.trackColorModeDefaultsKey)
        }
    }
    @Published var isDateTimeVisible: Bool {
        didSet {
            UserDefaults.standard.set(isDateTimeVisible, forKey: Self.dateTimeVisibleDefaultsKey)
        }
    }
    @Published var isHeightProfileVisible: Bool {
        didSet {
            UserDefaults.standard.set(isHeightProfileVisible, forKey: Self.heightProfileVisibleDefaultsKey)
        }
    }
    @Published var documents: [GPXDocumentEntry] = []
    @Published var notice: AppNotice?
    @Published var isSavingScreenshot = false
    @Published var isChromeHiddenForCapture = false

    private static let trackColorDefaultsKey = "selectedTrackColor"
    private static let trackColorModeDefaultsKey = "trackColorMode"
    private static let dateTimeVisibleDefaultsKey = "isDateTimeVisible"
    private static let heightProfileVisibleDefaultsKey = "isHeightProfileVisible"

    private let parser = GPXParser()
    private let fileStore = GPXFileStore()
    private var didLoadInitialTrack = false

    init() {
        let savedColor = UserDefaults.standard.string(forKey: Self.trackColorDefaultsKey)
            .flatMap(TrackColor.init(rawValue:))
        selectedColor = savedColor ?? .flame
        let savedColorMode = UserDefaults.standard.string(forKey: Self.trackColorModeDefaultsKey)
            .flatMap(TrackColorMode.init(rawValue:))
        trackColorMode = savedColorMode ?? .multiDay
        isDateTimeVisible = UserDefaults.standard.object(forKey: Self.dateTimeVisibleDefaultsKey) as? Bool ?? true
        isHeightProfileVisible = UserDefaults.standard.object(forKey: Self.heightProfileVisibleDefaultsKey) as? Bool ?? false
        refreshDocuments()
    }

    func loadInitialTrack() {
        guard !didLoadInitialTrack else { return }
        didLoadInitialTrack = true
        refreshDocuments()

        if loadPendingImportIfAvailable(errorTitle: "Import Failed") {
            return
        }

        for document in documents {
            do {
                try loadTrack(from: document.url)
                return
            } catch {
                continue
            }
        }

        do {
            guard let sampleURL = fileStore.sampleURL else {
                throw GPXImportError.missingSample
            }

            try loadTrack(from: sampleURL)
        } catch {
            showError(title: "Could Not Load Track", error: error)
        }
    }

    func refreshDocuments() {
        documents = fileStore.documentEntries()
    }

    @discardableResult
    func loadPendingImportIfAvailable(errorTitle: String = "Could Not Open Shared GPX") -> Bool {
        do {
            guard let pendingImport = try fileStore.consumePendingImport() else {
                return false
            }

            try loadTrack(from: pendingImport)
            return true
        } catch {
            showError(title: errorTitle, error: error)
            return false
        }
    }

    func loadDocument(_ document: GPXDocumentEntry) {
        do {
            try loadTrack(from: document.url)
        } catch {
            showError(title: "Could Not Load GPX", error: error)
        }
    }

    func handleOpenURL(_ url: URL) {
        if url.scheme == "gpxrenderer" {
            handleAppURL(url)
            return
        }

        importExternalFile(from: url)
    }

    func saveScreenshotToPhotos() {
        guard !isSavingScreenshot else { return }

        Task {
            await saveScreenshot()
        }
    }

    func saveHighResolutionImageToPhotos() {
        guard !isSavingScreenshot else { return }

        Task {
            await saveHighResolutionImage()
        }
    }

    private func handleAppURL(_ url: URL) {
        guard url.host == "import" || url.path.contains("import") else {
            return
        }

        loadPendingImportIfAvailable()
    }

    private func importExternalFile(from url: URL) {
        let canAccess = url.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let importedURL = try fileStore.copyIntoDocuments(from: url)
            try loadTrack(from: importedURL)
        } catch {
            showError(title: "Could Not Import GPX", error: error)
        }
    }

    private func loadTrack(from url: URL) throws {
        let parsedTrack = try parser.parse(contentsOf: url)
        track = parsedTrack
        stats = GPXStats(track: parsedTrack)
        refreshDocuments()
    }

    private func saveScreenshot() async {
        isSavingScreenshot = true
        defer {
            isSavingScreenshot = false
        }

        do {
            guard await requestPhotoAddPermission() else {
                notice = AppNotice(
                    title: "Photos Access Needed",
                    message: "Allow Photos add access to save GPX map screenshots."
                )
                return
            }

            isChromeHiddenForCapture = true
            try await Task.sleep(nanoseconds: 250_000_000)
            guard let image = ScreenshotCapture.currentWindowImage() else {
                throw GPXImportError.screenshotUnavailable
            }
            isChromeHiddenForCapture = false

            try await saveImageToPhotos(image)
            notice = AppNotice(title: "Saved", message: "The map screenshot was saved to Photos.")
        } catch {
            isChromeHiddenForCapture = false
            showError(title: "Could Not Save Screenshot", error: error)
        }
    }

    private func saveHighResolutionImage() async {
        isSavingScreenshot = true
        defer {
            isSavingScreenshot = false
        }

        do {
            guard await requestPhotoAddPermission() else {
                notice = AppNotice(
                    title: "Photos Access Needed",
                    message: "Allow Photos add access to save GPX map images."
                )
                return
            }

            guard let track else {
                throw GPXImportError.emptyTrack
            }

            let image = try await HighResolutionRouteImageRenderer().render(
                track: track,
                stats: stats,
                trackColor: selectedColor,
                trackColorMode: trackColorMode,
                isDateTimeVisible: isDateTimeVisible,
                isHeightProfileVisible: isHeightProfileVisible
            )

            try await saveImageToPhotos(image)
            notice = AppNotice(title: "Saved", message: "The high-resolution map image was saved to Photos.")
        } catch {
            showError(title: "Could Not Save High-Res Image", error: error)
        }
    }

    private func requestPhotoAddPermission() async -> Bool {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch currentStatus {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
            return newStatus == .authorized || newStatus == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func saveImageToPhotos(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: GPXImportError.screenshotUnavailable)
                }
            }
        }
    }

    private func showError(title: String, error: Error) {
        notice = AppNotice(title: title, message: error.localizedDescription)
    }
}

enum ScreenshotCapture {
    @MainActor
    static func currentWindowImage() -> UIImage? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.keyWindowForCapture else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true

        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

private extension UIWindowScene {
    var keyWindowForCapture: UIWindow? {
        windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
