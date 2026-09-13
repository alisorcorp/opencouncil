#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(AppKit) && !targetEnvironment(macCatalyst)
  import SwiftUI

  // MARK: - Overview
  //
  // `AppKitTextSelectionView` renders selection highlights for a single `Text.Layout`.
  //
  // Each text fragment provides its own resolved layout, origin, and selection model. This view
  // computes selection rectangles for the current
  // range within this layout, and paints them in a `Canvas` behind the text.

  struct AppKitTextSelectionView: View {
    private let textSelectionModel: TextSelectionModel

    private let layout: Text.Layout
    private let origin: CGPoint

    init(layout: Text.Layout, origin: CGPoint, textSelectionModel: TextSelectionModel) {
      self.layout = layout
      self.origin = origin
      self.textSelectionModel = textSelectionModel
    }

    var body: some View {
      let selectionRects = selectionRects
      Group {
        if selectionRects.isEmpty {
          Color.clear
        } else {
          Canvas { context, _ in
            context.translateBy(x: origin.x, y: origin.y)
            for selectionRect in selectionRects {
              context.fill(
                Path(selectionRect.rect.integral),
                with: .color(.init(nsColor: .selectedTextBackgroundColor))
              )
            }
          }
        }
      }
    }

    // Derive the highlight during rendering. Writing @State from onChange(initial: true) here feeds
    // another update into the geometry/preference pass that is still resolving the text layout.
    private var selectionRects: [TextSelectionRect] {
      guard let selectedRange = textSelectionModel.selectedRange else { return [] }
      return textSelectionModel.selectionRects(for: selectedRange, layout: layout)
    }
  }
#endif
