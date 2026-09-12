// swift app/Tools/icon-sheet.swift <Icons.xcassets> <out.png>
import AppKit
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: icon-sheet <Icons.xcassets> <out.png>"); exit(2) }
let catalog = URL(fileURLWithPath: args[1])
let sets = (try? FileManager.default.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "imageset" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
let cols = 8, cell = CGFloat(120), icon = CGFloat(40), pad = CGFloat(12)
let rows = Int(ceil(Double(sets.count) / Double(cols)))
let size = CGSize(width: CGFloat(cols) * cell, height: CGFloat(rows) * cell)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray]
for (i, set) in sets.enumerated() {
    let name = set.deletingPathExtension().lastPathComponent
    guard let svg = (try? FileManager.default.contentsOfDirectory(at: set, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "svg" }),
          let image = NSImage(contentsOf: svg) else { continue }
    let x = CGFloat(i % cols) * cell, y = size.height - CGFloat(i / cols + 1) * cell
    image.draw(in: NSRect(x: x + (cell - icon) / 2, y: y + cell - pad - icon, width: icon, height: icon))
    let label = NSAttributedString(string: name, attributes: attrs)
    let w = min(label.size().width, cell - 8)
    label.draw(in: NSRect(x: x + (cell - w) / 2, y: y + pad, width: w, height: 30))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) with \(sets.count) icons")
