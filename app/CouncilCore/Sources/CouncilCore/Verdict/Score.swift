import Foundation

/// Consensus score parsing, a port of `parse_score` in council.py (`Score: NN/100` anywhere in the verdict,
/// clamped to 0…100) that also tolerates Markdown bold around the number, e.g. `Score: **85**/100`.
public enum ConsensusScore {
    nonisolated(unsafe) private static let regex = try! NSRegularExpression(pattern: #"Score:\s*\**\s*(\d{1,3})\s*\**\s*/\s*100"#)

    public static func parse(_ text: String) -> Int? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let n = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        return max(0, min(100, n))
    }
}
