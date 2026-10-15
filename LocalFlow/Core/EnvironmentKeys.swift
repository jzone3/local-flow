import Foundation

/// Finds API keys the user already has on this Mac: the process environment plus `export NAME=value` lines in
/// the usual shell startup files. Nothing is sent anywhere; the user chooses whether to use what was found.
enum EnvironmentKeys {
    struct Found: Equatable {
        let name: String
        let value: String
        let source: String
    }

    static let knownNames = ["OPENAI_API_KEY", "ELEVENLABS_API_KEY", "ELEVEN_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"]

    static let shellFiles = [".zshenv", ".zshrc", ".zprofile", ".bash_profile", ".bashrc", ".profile", ".config/fish/config.fish", ".env"]

    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> [Found] {
        var found: [Found] = []
        var seen = Set<String>()
        for name in knownNames {
            if let value = environment[name], !value.isEmpty, seen.insert(name).inserted {
                found.append(Found(name: name, value: value, source: "environment"))
            }
        }
        for file in shellFiles {
            let url = home.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for item in parse(text, source: "~/" + file) where seen.insert(item.name).inserted {
                found.append(item)
            }
        }
        return found
    }

    /// Matches `export NAME=value`, `NAME="value"`, `set -x NAME value` (fish), ignoring commented lines.
    static func parse(_ text: String, source: String) -> [Found] {
        let names = knownNames.joined(separator: "|")
        let patterns = [
            #"^\s*(?:export\s+)?("# + names + #")\s*=\s*["']?([A-Za-z0-9_\-\.]{8,})["']?\s*(?:#.*)?$"#,
            #"^\s*set\s+-g?x\s+("# + names + #")\s+["']?([A-Za-z0-9_\-\.]{8,})["']?\s*$"#,
        ]
        var out: [Found] = []
        for line in text.components(separatedBy: .newlines) {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let nameRange = Range(match.range(at: 1), in: line),
                      let valueRange = Range(match.range(at: 2), in: line) else { continue }
                out.append(Found(name: String(line[nameRange]), value: String(line[valueRange]), source: source))
                break
            }
        }
        return out
    }

    static func masked(_ value: String) -> String {
        guard value.count > 8 else { return "••••" }
        return value.prefix(4) + "…" + value.suffix(4)
    }
}
