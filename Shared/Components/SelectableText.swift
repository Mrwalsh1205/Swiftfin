//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)
import SwiftUI
import UIKit

/// Read-only text where part of the text can be selected and copied
///
/// SwiftUI's `textSelection(.enabled)` only copies the whole text on iOS,
/// so this wraps a non-editable, selectable `UITextView` that sizes itself to its text.
struct SelectableText: UIViewRepresentable {

    let text: String
    let textStyle: UIFont.TextStyle
    let weight: UIFont.Weight
    let isSecondary: Bool
    let alignment: NSTextAlignment

    init(
        _ text: String,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        isSecondary: Bool = false,
        alignment: NSTextAlignment = .natural
    ) {
        self.text = text
        self.textStyle = textStyle
        self.weight = weight
        self.isSecondary = isSecondary
        self.alignment = alignment
    }

    /// The text style's font at the given weight, scaled with Dynamic Type
    private var font: UIFont {
        let defaultSize = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize

        return UIFontMetrics(forTextStyle: textStyle)
            .scaledFont(for: UIFont.systemFont(ofSize: defaultSize, weight: weight))
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping

        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let userInterfaceStyle: UIUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        let textColor = (isSecondary ? UIColor.secondaryLabel : UIColor.label)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: userInterfaceStyle))
        let resolvedFont = self.font

        // Reassigning unchanged text would clear the user's selection
        if textView.text != text {
            textView.text = text
        }

        if textView.font != resolvedFont {
            textView.font = resolvedFont
        }

        if textView.textColor != textColor {
            textView.textColor = textColor
        }

        if textView.textAlignment != alignment {
            textView.textAlignment = alignment
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let unlimited = CGFloat.greatestFiniteMagnitude

        guard let width = proposal.width, width.isFinite else {
            // Ideal size: the text on as few lines as it needs
            let size = uiView.sizeThatFits(CGSize(width: unlimited, height: unlimited))
            return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        }

        guard width > 0 else { return .zero }

        let size = uiView.sizeThatFits(CGSize(width: width, height: unlimited))
        return CGSize(width: width, height: size.height.rounded(.up))
    }
}
#endif
