//
//  HeadphonePicker.swift
//  InHausEQ
//
//  Compact headphone search for the menu bar panel: shows the current profile,
//  a search box, and results you click to download and apply.
//

import SwiftUI
import Foundation

struct HeadphonePicker: View {
    @Bindable var model: EQModel
    let catalog: AutoEQCatalog
    var maxResults = 8

    @State private var query = ""
    @State private var loadingID: AutoEQEntry.ID?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "headphones")
                    .foregroundStyle(.secondary)
                Text(model.headphoneTitle ?? "No headphone profile")
                    .lineLimit(1)
                    .foregroundStyle(model.headphone == nil ? Color.secondary : Color.primary)
                if let profile = model.headphone, model.isAdjusted {
                    Text("based on \(profile.name)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.headphone != nil {
                    Button {
                        model.headphone = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove the headphone profile")
                }
            }
            .font(.callout)

            TextField("Find headphones, e.g. HD 660S2", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                results
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await catalog.loadIfNeeded() }
    }

    @ViewBuilder
    private var results: some View {
        switch catalog.state {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading the headphone list…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            let matches = catalog.search(query, limit: maxResults)
            if matches.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(matches) { entry in
                        HeadphoneResultRow(entry: entry, isLoading: loadingID == entry.id) {
                            choose(entry)
                        }
                        .disabled(loadingID != nil)
                    }
                }
            }
        }
    }

    private func choose(_ entry: AutoEQEntry) {
        loadingID = entry.id
        errorText = nil
        Task {
            do {
                model.headphone = try await catalog.fetchProfile(entry)
                query = ""
            } catch {
                errorText = "Couldn't load \(entry.name): \(error.localizedDescription)"
            }
            loadingID = nil
        }
    }
}

/// One clickable search result with a hover highlight.
private struct HeadphoneResultRow: View {
    let entry: AutoEQEntry
    let isLoading: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(entry.source)
                        .font(.caption2)
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(entry.name), measured by \(entry.sourceLabel)")
    }
}
