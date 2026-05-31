import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let viewModel = ShareImportViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = ShareImportView(
            viewModel: viewModel,
            openAction: { [weak self] in
                self?.openContainingApp()
            },
            cancelAction: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: ShareImportError.cancelled)
            }
        )

        let hostingController = UIHostingController(rootView: rootView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)

        viewModel.importFirstGPX(from: extensionContext)
    }

    private func openContainingApp() {
        guard let url = URL(string: "gpxrenderer://import/latest") else { return }
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let currentResponder = responder {
            if currentResponder.responds(to: selector) {
                _ = currentResponder.perform(selector, with: url)
                extensionContext?.completeRequest(returningItems: nil)
                return
            }

            responder = currentResponder.next
        }

        extensionContext?.completeRequest(returningItems: nil)
    }
}

private struct ShareImportView: View {
    @ObservedObject var viewModel: ShareImportViewModel
    let openAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: viewModel.iconName)
                .font(.system(size: 48, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            Text(viewModel.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(viewModel.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Cancel", action: cancelAction)
                    .buttonStyle(.bordered)

                Button("Open", action: openAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canOpen)
            }
        }
        .padding(24)
    }
}

@MainActor
final class ShareImportViewModel: ObservableObject {
    @Published var title = "Importing GPX"
    @Published var message = "Preparing the shared track."
    @Published var iconName = "map"
    @Published var canOpen = false

    private let importer = SharedGPXImporter()

    func importFirstGPX(from extensionContext: NSExtensionContext?) {
        guard let providers = extensionContext?.inputItems
            .compactMap({ $0 as? NSExtensionItem })
            .flatMap({ $0.attachments ?? [] }),
              !providers.isEmpty else {
            fail(message: "No shared file was found.")
            return
        }

        let identifiers = [
            "com.topografix.gpx",
            UTType.xml.identifier,
            UTType.data.identifier,
            UTType.fileURL.identifier
        ]

        for provider in providers {
            for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, error in
                    guard let self else { return }
                    Task { @MainActor in
                        self.handleLoadedItem(item, error: error)
                    }
                }
                return
            }
        }

        fail(message: "Share a .gpx file to import it.")
    }

    private func handleLoadedItem(_ item: NSSecureCoding?, error: Error?) {
        if let error {
            fail(message: error.localizedDescription)
            return
        }

        do {
            try importer.savePendingImport(from: item)
            title = "GPX Ready"
            message = "Open GPX Renderer to view the shared track."
            iconName = "checkmark.circle"
            canOpen = true
        } catch {
            fail(message: error.localizedDescription)
        }
    }

    private func fail(message: String) {
        title = "Import Failed"
        self.message = message
        iconName = "exclamationmark.triangle"
        canOpen = false
    }
}

private struct SharedGPXImporter {
    private let appGroupIdentifier = "group.com.knapsoft.GPXRenderer"

    func savePendingImport(from item: NSSecureCoding?) throws {
        let payload = try payloadData(from: item)
        guard isLikelyGPX(payload.data, fileName: payload.fileName) else {
            throw ShareImportError.notGPX
        }

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw ShareImportError.appGroupUnavailable
        }

        let pendingDirectory = container.appendingPathComponent("PendingImports", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)

        let pendingURL = pendingDirectory.appendingPathComponent("latest.gpx")
        let nameURL = pendingDirectory.appendingPathComponent("latest-name.txt")

        if FileManager.default.fileExists(atPath: pendingURL.path) {
            try FileManager.default.removeItem(at: pendingURL)
        }

        try payload.data.write(to: pendingURL, options: .atomic)
        try payload.fileName.write(to: nameURL, atomically: true, encoding: .utf8)
    }

    private func payloadData(from item: NSSecureCoding?) throws -> (data: Data, fileName: String) {
        if let url = item as? URL {
            return (try Data(contentsOf: url), url.lastPathComponent)
        }

        if let url = item as? NSURL, let swiftURL = url as URL? {
            return (try Data(contentsOf: swiftURL), swiftURL.lastPathComponent)
        }

        if let data = item as? Data {
            return (data, "Shared GPX.gpx")
        }

        if let text = item as? String, let data = text.data(using: .utf8) {
            return (data, "Shared GPX.gpx")
        }

        throw ShareImportError.notGPX
    }

    private func isLikelyGPX(_ data: Data, fileName: String) -> Bool {
        if fileName.lowercased().hasSuffix(".gpx") {
            return true
        }

        guard let prefix = String(data: data.prefix(4096), encoding: .utf8) else {
            return false
        }

        return prefix.localizedCaseInsensitiveContains("<gpx")
    }
}

private enum ShareImportError: LocalizedError {
    case appGroupUnavailable
    case cancelled
    case notGPX

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "The shared import container is not available."
        case .cancelled:
            return "Import cancelled."
        case .notGPX:
            return "Share a valid .gpx file."
        }
    }
}
