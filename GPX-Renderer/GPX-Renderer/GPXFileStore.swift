import Foundation

struct GPXFileStore {
    static let appGroupIdentifier = "group.com.knapsoft.GPXRenderer"

    private let fileManager = FileManager.default

    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var sampleURL: URL? {
        Bundle.main.url(
            forResource: "2026_05_20_skuter_krynica",
            withExtension: "gpx",
            subdirectory: "Sample"
        ) ?? Bundle.main.url(forResource: "2026_05_20_skuter_krynica", withExtension: "gpx")
    }

    var appGroupContainer: URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    }

    var pendingImportURL: URL? {
        appGroupContainer?
            .appendingPathComponent("PendingImports", isDirectory: true)
            .appendingPathComponent("latest.gpx")
    }

    var pendingImportNameURL: URL? {
        appGroupContainer?
            .appendingPathComponent("PendingImports", isDirectory: true)
            .appendingPathComponent("latest-name.txt")
    }

    func documentEntries() -> [GPXDocumentEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "gpx" }
            .map { url in
                let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return GPXDocumentEntry(id: url, url: url, modifiedAt: modifiedAt)
            }
            .sorted {
                ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
    }

    func copyIntoDocuments(from sourceURL: URL, suggestedName: String? = nil) throws -> URL {
        guard sourceURL.pathExtension.lowercased() == "gpx" else {
            throw GPXImportError.unsupportedFile
        }

        let standardizedSource = sourceURL.standardizedFileURL
        let standardizedDocuments = documentsDirectory.standardizedFileURL
        if standardizedSource.path.hasPrefix(standardizedDocuments.path + "/") {
            return standardizedSource
        }

        try fileManager.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)

        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent
        let baseName = sanitizedBaseName(suggestedName ?? fallbackName)
        let destination = uniqueDestinationURL(baseName: baseName, extension: "gpx")

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func consumePendingImport() throws -> URL? {
        guard let pendingImportURL, fileManager.fileExists(atPath: pendingImportURL.path) else {
            return nil
        }

        let suggestedName = pendingImportNameURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let copiedURL = try copyIntoDocuments(from: pendingImportURL, suggestedName: suggestedName)
        try? fileManager.removeItem(at: pendingImportURL)

        if let pendingImportNameURL {
            try? fileManager.removeItem(at: pendingImportNameURL)
        }

        return copiedURL
    }

    private func sanitizedBaseName(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutExtension = trimmed.lowercased().hasSuffix(".gpx") ? String(trimmed.dropLast(4)) : trimmed

        let safe = withoutExtension.replacingOccurrences(
            of: "[^A-Za-z0-9 _-]+",
            with: "_",
            options: .regularExpression
        )

        return safe.isEmpty ? "Imported GPX" : safe
    }

    private func uniqueDestinationURL(baseName: String, extension fileExtension: String) -> URL {
        var candidate = documentsDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)

        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = documentsDirectory
                .appendingPathComponent("\(baseName) \(index)")
                .appendingPathExtension(fileExtension)
            index += 1
        }

        return candidate
    }
}
