//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// One line on what the folder index is doing, shown in the folder pane and its settings.
struct FolderIndexStatusView: View {

    @ObservedObject
    var store: FolderIndexStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                indicator

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var indicator: some View {
        switch store.status {
        case .updating, .savingThumbnails:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            Circle()
                .fill(store.snapshot == nil ? Color.secondary : Color.green)
                .frame(width: 8, height: 8)
        }
    }

    private var title: String {
        switch store.status {
        case .updating:
            return store.snapshot == nil ? L10n.buildingIndex : L10n.updatingIndex
        case let .savingThumbnails(done, total):
            return L10n.savingThumbnails(done.formatted(), total.formatted())
        case let .failed(message):
            return L10n.indexFailed(message)
        case .idle:
            guard store.snapshot != nil else { return L10n.noIndexYet }

            return L10n.indexSummary(store.itemCount.formatted(), store.folderCount.formatted())
        }
    }

    private var detail: String? {
        guard let date = store.snapshot?.date else { return nil }

        return L10n.indexUpdated(date.formatted(.relative(presentation: .named)))
    }
}
