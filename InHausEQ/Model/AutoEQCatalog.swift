//
//  AutoEQCatalog.swift
//  InHausEQ
//
//  Searches AutoEQ's list of ~8,800 measured headphones and downloads a correction profile.
//  Source: github.com/jaakkopasanen/AutoEq (results/INDEX.md + each model's ParametricEQ.txt).
//  The list is cached in Application Support and refreshed weekly.
//

import Foundation
import Observation
import os

struct AutoEQEntry: Identifiable, Hashable {
    let name: String        // "Sennheiser HD 660S2"
    let source: String      // who measured it, e.g. "oratory1990"
    let rig: String?        // measurement rig, e.g. "HMS II.3"
    let path: String        // percent-encoded, relative to results/
    let searchKey: String   // lowercased name
    let compactKey: String  // letters and digits only: "sennheiserhd660s2"

    var id: String { path }
    var sourceLabel: String { rig.map { "\(source) · \($0)" } ?? source }

    init(name: String, source: String, rig: String?, path: String) {
        self.name = name
        self.source = source
        self.rig = rig
        self.path = path
        self.searchKey = name.lowercased()
        self.compactKey = AutoEQCatalog.compact(name)
    }

    /// results/<path>/<last path component> ParametricEQ.txt
    var profileURL: URL? {
        guard let last = path.split(separator: "/").last else { return nil }
        return URL(string: AutoEQCatalog.resultsBase + path + "/" + last + "%20ParametricEQ.txt")
    }
}

@MainActor
@Observable
final class AutoEQCatalog {
    enum State: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var entries: [AutoEQEntry] = []

    nonisolated static let resultsBase = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    private static let indexURL = URL(string: resultsBase + "INDEX.md")
    /// Most trusted measurements first when the same headphone appears more than once.
    private static let preferredSources = ["oratory1990", "crinacle", "Rtings", "Innerfidelity", "Headphone.com Legacy"]
    private static let refreshAge: TimeInterval = 7 * 24 * 3600

    private let cacheURL: URL
    private let log = Logger(subsystem: "com.inhausrepair.eq", category: "AutoEQCatalog")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        cacheURL = base.appendingPathComponent("InHausEQ", isDirectory: true)
            .appendingPathComponent("autoeq-index.md")
    }

    /// Uses the cached list if there is one (refreshing it if it's over a week old),
    /// otherwise downloads it.
    func loadIfNeeded() async {
        switch state {
        case .loading, .ready: return
        case .idle, .failed: break
        }
        if let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
            let parsed = Self.parseIndex(text)
            if !parsed.isEmpty {
                entries = parsed
                state = .ready
                if cacheAge() > Self.refreshAge { await refresh(quietly: true) }
                return
            }
        }
        await refresh(quietly: false)
    }

    func refresh(quietly: Bool) async {
        guard let url = Self.indexURL else { return }
        if !quietly { state = .loading }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else {
                throw URLError(.badServerResponse)
            }
            let parsed = Self.parseIndex(text)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            entries = parsed
            state = .ready
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        } catch {
            log.error("AutoEQ list download failed: \(String(describing: error), privacy: .public)")
            if entries.isEmpty {
                state = .failed("Couldn't download the headphone list. Check your internet connection.")
            }
        }
    }

    /// Every query word must appear in the name, or the query squashed together must
    /// ("hd660s2" finds "HD 660S2"). Best-known measurement sources sort first.
    func search(_ query: String, limit: Int = 100) -> [AutoEQEntry] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return [] }
        let squashed = Self.compact(query)
        let hits = entries.filter { entry in
            words.allSatisfy { entry.searchKey.contains($0) }
                || (squashed.count >= 3 && entry.compactKey.contains(squashed))
        }
        let sorted = hits.sorted { a, b in
            if a.searchKey != b.searchKey { return a.searchKey < b.searchKey }
            return Self.rank(a.source) < Self.rank(b.source)
        }
        return Array(sorted.prefix(limit))
    }

    /// Downloads one model's ParametricEQ.txt and parses it.
    func fetchProfile(_ entry: AutoEQEntry) async throws -> HeadphoneProfile {
        guard let url = entry.profileURL else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw URLError(.fileDoesNotExist)
        }
        return try AutoEQParser.parse(text, name: "\(entry.name) · \(entry.source)")
    }

    // MARK: - Parsing

    /// Lines look like:
    /// - [Sennheiser HD 660S2](./oratory1990/over-ear/Sennheiser%20HD%20660S2) by oratory1990
    /// - [Name (ANC On)](./Src/Rig%20in-ear/Name%20(ANC%20On)) by Src on Rig
    static func parseIndex(_ text: String) -> [AutoEQEntry] {
        var result: [AutoEQEntry] = []
        result.reserveCapacity(9000)
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("- ["),
                  let nameEnd = line.range(of: "]("),
                  let byRange = line.range(of: ") by ", options: .backwards),
                  nameEnd.upperBound <= byRange.lowerBound else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<nameEnd.lowerBound])
            var path = String(line[nameEnd.upperBound..<byRange.lowerBound])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let tail = line[byRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let source: String
            let rig: String?
            if let on = tail.range(of: " on ") {
                source = String(tail[..<on.lowerBound])
                rig = String(tail[on.upperBound...])
            } else {
                source = tail
                rig = nil
            }
            guard !name.isEmpty, !path.isEmpty else { continue }
            result.append(AutoEQEntry(name: name, source: source, rig: rig, path: path))
        }
        return result
    }

    nonisolated static func compact(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func rank(_ source: String) -> Int {
        preferredSources.firstIndex(of: source) ?? preferredSources.count
    }

    private func cacheAge() -> TimeInterval {
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path(percentEncoded: false))
        guard let modified = attributes?[.modificationDate] as? Date else { return .infinity }
        return Date().timeIntervalSince(modified)
    }
}
