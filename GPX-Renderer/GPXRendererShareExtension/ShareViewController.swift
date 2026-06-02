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
            closeAction: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
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
        guard let url = URL(string: "gpxrenderer://import/latest") else {
            viewModel.showOpenFailure(message: "Could not create the GPX Renderer import URL.")
            return
        }

        guard let extensionContext else {
            viewModel.showOpenFailure(message: "The share extension context is not available.")
            return
        }

        viewModel.markOpening()

        extensionContext.open(url) { [weak self] success in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if success {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.viewModel.showOpenFailure(
                        message: """
                        The GPX import was saved, but iOS refused to open GPX Renderer from this share extension.

                        Close this sheet and open GPX Renderer manually. The app will load the shared track automatically.

                        Debug:
                        URL: \(url.absoluteString)
                        Scheme: \(url.scheme ?? "(none)")
                        Host: \(url.host ?? "(none)")
                        """
                    )
                }
            }
        }
    }
}

private struct ShareImportView: View {
    @ObservedObject var viewModel: ShareImportViewModel
    let openAction: () -> Void
    let closeAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: viewModel.iconName)
                .font(.system(size: 48, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            Text(viewModel.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            ScrollView {
                Text(viewModel.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 320)

            HStack(spacing: 12) {
                Button("Cancel", action: cancelAction)
                    .buttonStyle(.bordered)

                Button(viewModel.primaryButtonTitle) {
                    if viewModel.shouldCloseOnPrimaryAction {
                        closeAction()
                    } else {
                        openAction()
                    }
                }
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
    @Published var primaryButtonTitle = "Open"
    @Published var shouldCloseOnPrimaryAction = false

    private let importer = SharedGPXImporter()

    func importFirstGPX(from extensionContext: NSExtensionContext?) {
        guard let providers = extensionContext?.inputItems
            .compactMap({ $0 as? NSExtensionItem })
            .flatMap({ $0.attachments ?? [] }),
              !providers.isEmpty else {
            fail(message: "No shared file was found.")
            return
        }

        for provider in providers {
            for identifier in candidateIdentifiers(for: provider) where provider.hasItemConformingToTypeIdentifier(identifier) {
                let debugContext = ShareImportDebugContext(
                    requestedIdentifier: identifier,
                    providerIdentifiers: provider.registeredTypeIdentifiers
                )

                provider.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, error in
                    guard let self else { return }
                    Task { @MainActor in
                        self.handleLoadedItem(item, error: error, debugContext: debugContext)
                    }
                }
                return
            }
        }

        fail(message: unsupportedProvidersMessage(for: providers))
    }

    private func candidateIdentifiers(for provider: NSItemProvider) -> [String] {
        var identifiers = [
            "com.topografix.gpx",
            UTType.fileURL.identifier,
            UTType.xml.identifier
        ]

        if provider.registeredTypeIdentifiers.contains(UTType.data.identifier) {
            identifiers.append(UTType.data.identifier)
        }

        return identifiers
    }

    private func unsupportedProvidersMessage(for providers: [NSItemProvider]) -> String {
        let providerDetails = providers.enumerated().map { index, provider in
            "Provider \(index + 1): \(provider.registeredTypeIdentifiers.joined(separator: ", "))"
        }
        .joined(separator: "\n")

        return """
        Share a valid .gpx file.
        Reason: The shared item did not expose a GPX file, file URL, XML, or explicit data payload.

        Debug:
        \(providerDetails)
        """
    }

    private func handleLoadedItem(
        _ item: NSSecureCoding?,
        error: Error?,
        debugContext: ShareImportDebugContext
    ) {
        if let error {
            fail(message: debugMessage(for: error, item: item, debugContext: debugContext))
            return
        }

        do {
            try importer.savePendingImport(from: item)
            title = "GPX Ready"
            message = "Open GPX Renderer to view the shared track."
            iconName = "checkmark.circle"
            canOpen = true
            primaryButtonTitle = "Open"
            shouldCloseOnPrimaryAction = false
        } catch {
            fail(message: debugMessage(for: error, item: item, debugContext: debugContext))
        }
    }

    func markOpening() {
        title = "Opening GPX Renderer"
        message = "Loading the shared track in the app."
        iconName = "arrow.up.forward.app"
        canOpen = false
        primaryButtonTitle = "Open"
        shouldCloseOnPrimaryAction = false
    }

    func showOpenFailure(message: String) {
        title = "GPX Saved"
        self.message = message
        iconName = "exclamationmark.triangle"
        canOpen = true
        primaryButtonTitle = "Close"
        shouldCloseOnPrimaryAction = true
    }

    private func fail(message: String) {
        title = "Import Failed"
        self.message = message
        iconName = "exclamationmark.triangle"
        canOpen = false
        primaryButtonTitle = "Open"
        shouldCloseOnPrimaryAction = false
    }

    private func debugMessage(
        for error: Error,
        item: NSSecureCoding?,
        debugContext: ShareImportDebugContext
    ) -> String {
        """
        \(error.localizedDescription)

        Debug:
        \(ShareImportDebugFormatter.describe(item: item, context: debugContext))
        """
    }
}

private struct ShareImportDebugContext {
    let requestedIdentifier: String
    let providerIdentifiers: [String]
}

private struct SharedGPXImporter {
    private struct Payload {
        let data: Data
        let fileName: String?
    }

    private let appGroupIdentifier = "group.com.knapsoft.GPXRenderer"

    func savePendingImport(from item: NSSecureCoding?) throws {
        let payload = try payloadData(from: item)
        guard isLikelyGPX(payload.data, fileName: payload.fileName) else {
            throw ShareImportError.notGPX(reason: "The loaded payload did not have a .gpx name and its first bytes did not contain a <gpx> element.")
        }

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw ShareImportError.appGroupUnavailable
        }

        let pendingDirectory = container.appendingPathComponent("PendingImports", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)

        let pendingURL = pendingDirectory.appendingPathComponent("latest.gpx")
        let nameURL = pendingDirectory.appendingPathComponent("latest-name.txt")
        let fileName = payload.fileName ?? "Shared GPX.gpx"

        if FileManager.default.fileExists(atPath: pendingURL.path) {
            try FileManager.default.removeItem(at: pendingURL)
        }

        try payload.data.write(to: pendingURL, options: .atomic)
        try fileName.write(to: nameURL, atomically: true, encoding: .utf8)
    }

    private func payloadData(from item: NSSecureCoding?) throws -> Payload {
        if let url = item as? URL {
            return try payloadData(fromFileAt: url)
        }

        if let url = item as? NSURL {
            return try payloadData(fromFileAt: url as URL)
        }

        if let data = item as? Data {
            return try payloadData(fromData: data)
        }

        if let text = item as? String {
            return try payloadData(fromText: text)
        }

        if let text = item as? NSString {
            return try payloadData(fromText: text as String)
        }

        throw ShareImportError.notGPX(reason: "Unsupported item type: \(item.map { String(reflecting: type(of: $0)) } ?? "nil").")
    }

    private func payloadData(fromData data: Data) throws -> Payload {
        if let text = String(data: data, encoding: .utf8),
           let filePayload = try payloadDataIfTextIsFileReference(text) {
            return filePayload
        }

        return Payload(data: data, fileName: nil)
    }

    private func payloadData(fromText text: String) throws -> Payload {
        if let filePayload = try payloadDataIfTextIsFileReference(text) {
            return filePayload
        }

        guard let data = text.data(using: .utf8) else {
            throw ShareImportError.notGPX(reason: "The text item could not be converted to UTF-8 data.")
        }

        return Payload(data: data, fileName: nil)
    }

    private func payloadDataIfTextIsFileReference(_ text: String) throws -> Payload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed), url.isFileURL {
            return try payloadData(fromFileAt: url)
        }

        if trimmed.lowercased().hasPrefix("file://") {
            let rawPath = String(trimmed.dropFirst("file://".count))
            let decodedPath = rawPath.removingPercentEncoding ?? rawPath
            let fileURL = URL(fileURLWithPath: decodedPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return try payloadData(fromFileAt: fileURL)
            }
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try payloadData(fromFileAt: fileURL)
        }

        return nil
    }

    private func payloadData(fromFileAt url: URL) throws -> Payload {
        guard url.isFileURL else {
            throw ShareImportError.notGPX(reason: "The provided URL is not a file URL: \(url.absoluteString).")
        }

        let fileURL = url.standardizedFileURL
        let canAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        var coordinatedData: Data?
        var readError: Error?
        var coordinationError: NSError?

        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: fileURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                coordinatedData = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let readError {
            throw readError
        }

        if let coordinationError {
            throw coordinationError
        }

        guard let coordinatedData else {
            throw ShareImportError.notGPX(reason: "File coordination did not return data for \(fileURL.lastPathComponent).")
        }

        return Payload(data: coordinatedData, fileName: fileURL.lastPathComponent)
    }

    private func isLikelyGPX(_ data: Data, fileName: String?) -> Bool {
        if fileName?.lowercased().hasSuffix(".gpx") == true {
            return true
        }

        return decodedPrefixes(from: data).contains { prefix in
            prefix.localizedCaseInsensitiveContains("<gpx")
        }
    }

    private func decodedPrefixes(from data: Data) -> [String] {
        let prefixData = Data(data.prefix(8192))
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
            .ascii
        ]

        return encodings.compactMap { encoding in
            String(data: prefixData, encoding: encoding)
        }
    }
}

private enum ShareImportDebugFormatter {
    static func describe(item: NSSecureCoding?, context: ShareImportDebugContext) -> String {
        var lines = [
            "Requested identifier: \(context.requestedIdentifier)",
            "Provider identifiers: \(context.providerIdentifiers.joined(separator: ", "))"
        ]

        guard let item else {
            lines.append("Item: nil")
            return lines.joined(separator: "\n")
        }

        lines.append("Item type: \(String(reflecting: type(of: item)))")

        if let url = item as? URL {
            lines.append(contentsOf: describe(url: url))
        } else if let url = item as? NSURL {
            lines.append(contentsOf: describe(url: url as URL))
        } else if let data = item as? Data {
            lines.append(contentsOf: describe(data: data))
        } else if let text = item as? String {
            lines.append(contentsOf: describe(text: text))
        } else if let text = item as? NSString {
            lines.append(contentsOf: describe(text: text as String))
        }

        return lines.joined(separator: "\n")
    }

    private static func describe(url: URL) -> [String] {
        [
            "URL: \(url.absoluteString)",
            "Path: \(url.path)",
            "File exists: \(FileManager.default.fileExists(atPath: url.path))",
            "Extension: \(url.pathExtension.isEmpty ? "(none)" : url.pathExtension)"
        ]
    }

    private static func describe(data: Data) -> [String] {
        var lines = [
            "Data bytes: \(data.count)",
            "Data text prefix: \(textPrefix(from: data))",
            "Data hex prefix: \(hexPrefix(from: data))"
        ]

        if let text = String(data: data.prefix(512), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(contentsOf: fileReferenceHints(for: trimmed))
        }

        return lines
    }

    private static func describe(text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "Text length: \(text.count)",
            "Text prefix: \(printable(trimmed, limit: 240))"
        ]
        lines.append(contentsOf: fileReferenceHints(for: trimmed))
        return lines
    }

    private static func fileReferenceHints(for text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }

        var lines: [String] = []

        if let url = URL(string: text) {
            lines.append("Parsed URL: \(url.absoluteString)")
            lines.append("Parsed URL is file: \(url.isFileURL)")
            if url.isFileURL {
                lines.append("Parsed URL file exists: \(FileManager.default.fileExists(atPath: url.path))")
            }
        } else {
            lines.append("Parsed URL: nil")
        }

        let fileURL = URL(fileURLWithPath: text)
        lines.append("Path exists: \(FileManager.default.fileExists(atPath: fileURL.path))")

        return lines
    }

    private static func textPrefix(from data: Data) -> String {
        let prefixData = Data(data.prefix(512))
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .ascii]

        for encoding in encodings {
            if let text = String(data: prefixData, encoding: encoding), !text.isEmpty {
                return printable(text, limit: 240)
            }
        }

        return "(not text)"
    }

    private static func hexPrefix(from data: Data) -> String {
        data.prefix(32)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }

    private static func printable(_ text: String, limit: Int) -> String {
        let escaped = text
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")

        if escaped.count <= limit {
            return escaped
        }

        return "\(escaped.prefix(limit))..."
    }
}

private enum ShareImportError: LocalizedError {
    case appGroupUnavailable
    case cancelled
    case notGPX(reason: String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "The shared import container is not available."
        case .cancelled:
            return "Import cancelled."
        case .notGPX(let reason):
            return "Share a valid .gpx file.\nReason: \(reason)"
        }
    }
}
