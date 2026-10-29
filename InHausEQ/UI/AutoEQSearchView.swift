//
//  AutoEQSearchView.swift
//  InHausEQ
//
//  Sheet for finding a headphone in AutoEQ's database and loading its correction profile.
//

import SwiftUI
import Foundation

struct AutoEQSearchView: View {
    let catalog: AutoEQCatalog
    let onPick: (HeadphoneProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: AutoEQEntry.ID?
    @State private var downloading = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find your headphones")
                .font(.title3.weight(.semibold))
            Text("Correction profiles come from AutoEQ, which covers about 8,800 headphones and earbuds. If a model appears more than once, oratory1990 measurements are the most trusted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search, e.g. HD 660S2 or AirPods Pro", text: $query)
                .textFieldStyle(.roundedBorder)

            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(downloading ? "Loading…" : "Use This Profile") { pick() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedEntry == nil || downloading)
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .task { await catalog.loadIfNeeded() }
    }

    @ViewBuilder
    private var results: some View {
        switch catalog.state {
        case .idle, .loading:
            ProgressView("Downloading the headphone list…")
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await catalog.refresh(quietly: false) }
                }
            }
        case .ready:
            let matches = catalog.search(query)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type a headphone name to search.")
                    .foregroundStyle(.secondary)
            } else if matches.isEmpty {
                Text("No matches for “\(query)”.")
                    .foregroundStyle(.secondary)
            } else {
                List(matches, selection: $selection) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        Text(entry.sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: AutoEQEntry.ID.self, menu: { _ in }) { ids in
                    // Double-click or Return on a row picks it.
                    if let id = ids.first {
                        selection = id
                        pick()
                    }
                }
            }
        }
    }

    private var selectedEntry: AutoEQEntry? {
        guard let selection else { return nil }
        return catalog.entries.first { $0.id == selection }
    }

    private func pick() {
        guard let entry = selectedEntry, !downloading else { return }
        downloading = true
        errorText = nil
        Task {
            do {
                let profile = try await catalog.fetchProfile(entry)
                onPick(profile)
                dismiss()
            } catch {
                errorText = "Couldn't load \(entry.name): \(error.localizedDescription)"
            }
            downloading = false
        }
    }
}
