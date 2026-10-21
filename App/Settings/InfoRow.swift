import SwiftUI

/// An SF Symbol next to a short title and an explanation. The shared building block of the plain-words explanations in
/// onboarding, the Live mode consent sheet and the Data settings.
struct InfoRow: View {
    let symbol: String
    var title: LocalizedStringKey?
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).fontWeight(.semibold)
                }
                Text(text)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
