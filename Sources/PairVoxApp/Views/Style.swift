// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The shapes every card, banner and field share (variant B of the 2026-10-16 review: radius 12, fields padded
/// 10 pt above and below the text and 16 pt at its ends, banners 16 by 20).
enum Style {
    static let radius: CGFloat = 12
    static let innerRadius: CGFloat = 8
    static let fieldVertical: CGFloat = 10
    static let fieldHorizontal: CGFloat = 16
    static let bannerVertical: CGFloat = 16
    static let bannerHorizontal: CGFloat = 20
    /// The toolbar tint and badge colour while the microphone is asleep.
    static let asleep = Color(nsColor: .systemOrange)
}

/// A text field with room around the text and the shared corner radius. The stock rounded-border style pads the
/// text by 3 by 7 points, so a sentence sat against its left edge.
struct RoundedFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.vertical, Style.fieldVertical)
            .padding(.horizontal, Style.fieldHorizontal)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Style.radius))
            .overlay(RoundedRectangle(cornerRadius: Style.radius).stroke(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

extension View {
    /// A banner or card: padded, filled, outlined, with the shared radius.
    func banner(fill: Color = Color(nsColor: .controlBackgroundColor), stroke: Color = Color.primary.opacity(0.5)) -> some View {
        padding(.vertical, Style.bannerVertical)
            .padding(.horizontal, Style.bannerHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Style.radius))
            .overlay(RoundedRectangle(cornerRadius: Style.radius).stroke(stroke, lineWidth: 1))
    }
}
