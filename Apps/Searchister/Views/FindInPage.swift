import HisterKit
import SwiftUI

/// Renders a document's text with its find-in-page matches marked.
///
/// The matching itself is `HisterKit.TextFinder`, which has no SwiftUI in it and is covered by
/// tests; this is the half that cannot be — turning ranges into highlighted `AttributedString`.
extension TextFinder {
    /// One paragraph, with every match marked and the current one marked more strongly.
    ///
    /// - Parameter current: index into `matches` of the occurrence the reader is on.
    func attributed(paragraph index: Int, current: Int?) -> AttributedString {
        var result = AttributedString(paragraphs[index])
        for (position, range) in matches(inParagraph: index) {
            guard let attributedRange = Range(range, in: result) else { continue }
            let isCurrent = position == current
            // Attributes are set by key type rather than through the `.backgroundColor` dynamic
            // member. That spelling forms a KeyPath into AttributeScopes.SwiftUIAttributes, which
            // is not Sendable — a warning today and an error in the Swift 6 language mode. Naming
            // the key directly forms no key path at all.
            result[attributedRange][BackgroundColor.self] = isCurrent ? .orange : .yellow
            result[attributedRange][ForegroundColor.self] = .black
            if isCurrent {
                result[attributedRange][Emphasis.self] = .stronglyEmphasized
            }
        }
        return result
    }

    private typealias BackgroundColor = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
    private typealias ForegroundColor = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
    private typealias Emphasis = AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute
}

/// The find bar: a field, a count, and the two buttons that move through the matches.
struct FindInPageBar: View {
    @Binding var needle: String
    @Binding var current: Int
    let matchCount: Int
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in page", text: $needle)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { step(by: 1) }

            if !needle.isEmpty {
                Text(matchCount == 0 ? "Not found" : "\(current + 1) of \(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(matchCount == 0 ? .orange : .secondary)
            }

            Button { step(by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(matchCount == 0)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match")

            Button { step(by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(matchCount == 0)
                .keyboardShortcut("g", modifiers: [.command])
                .help("Next match")

            Button("Done") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 6)
        .onAppear { isFocused = true }
    }

    private func step(by delta: Int) {
        guard matchCount > 0 else { return }
        current = ((current + delta) % matchCount + matchCount) % matchCount
    }
}
