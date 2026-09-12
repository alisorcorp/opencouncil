import SwiftUI

struct EmptyState: View {
    let title: String
    let detail: String
    var icon: Icon = .chatPlain

    var body: some View {
        VStack(spacing: 10) {
            IconView(icon, size: 56).foregroundStyle(.tertiary)
            Text(title).font(Typography.font(18, .bold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
