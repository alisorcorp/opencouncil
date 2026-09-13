import Foundation
import CouncilCore

/// What launching a member needs beyond its chat: the resolved tools, the base environment and the bundled
/// pi extension. Built once at bootstrap. With `COUNCIL_FAKE_MEMBERS=1` every terminal backend runs the
/// scripted stand-in `app/Tools/fake-member.py`, so delivery and detection can be exercised without
/// spending anyone's model quota.
struct MemberLaunchEnvironment: Sendable {
    var tools: ToolLocations
    var baseEnvironment: [String: String]
    var piExtension: URL?
    var isFake: Bool

    static let fakeFlag = "COUNCIL_FAKE_MEMBERS"

    static func make(shell: ShellEnvironment, paths: CouncilPaths,
                     processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                     bundle: Bundle = .main) -> MemberLaunchEnvironment {
        var tools = ToolLocations(shell: shell)
        let fake = processEnvironment[fakeFlag] == "1"
        if fake {
            tools.redirectTerminalBackends(to: paths.root.appendingPathComponent("app/Tools/fake-member.py"))
        }
        return MemberLaunchEnvironment(tools: tools,
                                       baseEnvironment: shell.memberBaseEnvironment(from: processEnvironment),
                                       piExtension: locatePiExtension(in: bundle), isFake: fake)
    }

    /// `Resources` is copied into the bundle as a folder reference, so the file sits one level down.
    static func locatePiExtension(in bundle: Bundle) -> URL? {
        let name = (HookConfig.piExtensionFileName as NSString).deletingPathExtension
        let ext = (HookConfig.piExtensionFileName as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            ?? bundle.url(forResource: name, withExtension: ext)
    }
}
