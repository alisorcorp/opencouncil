import Foundation
import XCTest

enum Fixtures {
    static var root: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }
    static var chatDir: URL { root.appendingPathComponent("chats/2026-09-10_113600_router") }
    static var runDir: URL { root.appendingPathComponent("runs/2026-09-09_152736_is-it-worth-adding-type-hints-to-a-5k-li") }

    /// A fresh temp directory; removed at test teardown by the caller.
    static func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("council-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies a fixture directory into a temp location so tests can write to it.
    static func copy(_ src: URL, as name: String) throws -> URL {
        let dst = try tempDir(name).appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// The installed `council` wrapper, when present, for CLI interop tests.
    static var councilCLI: URL? {
        ShellEnvironment.resolve(timeout: 10).which("council")
    }
}
import CouncilCore
