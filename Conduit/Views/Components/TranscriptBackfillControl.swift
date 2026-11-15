import SwiftUI

/// Transcript-top affordance for bounded history: "Load earlier messages",
/// or a progress row while the older page is on its way. Shared by Chat and
/// the LAA Work session page so both read and look the same. Label-exposed
/// for accessibility — never icon-only — and the loading state is announced
/// by the combined progress row. The caller owns the fetch, the single-flight
/// guard and keeping the reader's rows in place when the page lands.
struct TranscriptBackfillControl: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading earlier messages")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                Button(action: action) {
                    Label("Load earlier messages", systemImage: "clock.arrow.circlepath")
                        .font(.footnote.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.12))
                .accessibilityLabel("Load earlier messages")
                .accessibilityHint("Fetches the next older page of this conversation")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }
}
