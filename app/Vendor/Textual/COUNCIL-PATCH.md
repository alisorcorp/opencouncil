# Textual 0.5.0: local macOS selection patch

Source: https://github.com/gonzalezreal/textual at
`01b51875a5406eefc95f52a058cb059e7bc94dc4` (tag `0.5.0`).
The upstream MIT license is preserved in `LICENSE` and bundled with Council in
`Resources/ThirdParty/Textual-LICENSE.txt`.

This directory contains the upstream `Sources` tree. The package manifest omits
the upstream test target and its snapshot-testing dependency; runtime dependencies
and compiler settings are unchanged. Council's rendering regression test lives in
`Council/Tests/TextSelectionRenderingTests.swift`.

Three source files differ from that revision:

- `TextSelectionBackground.swift`: read the selection model outside the geometry
  callback and pass it explicitly to the highlight view. Omit the geometry reader
  when no model exists (selection is disabled).
- `AppKitTextSelectionView.swift`: accept that model as a value and derive highlight
  rectangles in `body`, instead of writing `@State` from two initial `onChange`
  callbacks during layout. Selection remains enabled in Council.
- `AttachmentOverlay.swift`: omit attachment geometry when the attachment set is
  empty. Ordinary prose needs no attachment canvas or anchor conversion.

The first two changes address paths identified in upstream
[issue 26](https://github.com/gonzalezreal/textual/issues/26) and
[PR 67](https://github.com/gonzalezreal/textual/pull/67). Council's captured stall
has a matching SwiftUI/GeometryReader/selection stack, but a matching stack alone
does not prove that this patch eliminates the intermittent stall.

The local package makes the patch reproducible in clean builds; editing a SwiftPM
checkout in DerivedData would lose it on the next dependency resolution. Replace
this directory with an upstream version once the relevant fix is released and
verified against Council's rendering test and `--render-replay ... --stress`.
