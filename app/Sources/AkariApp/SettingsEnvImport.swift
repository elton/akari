import Foundation

/// Reads a single variable out of a `.env` file.
///
/// The app needs this for two things the core cannot do for it, because the
/// core never sends a credential value to the app (docs/protocol.md §3.10 is
/// one-directional):
///
/// 1. **The import prompt.** "`.env` has it, the Keychain does not" is visible
///    from `settings.state` alone, but copying it into the Keychain needs the
///    value. The copy is never silent — the user presses a button.
/// 2. **Making a conflict visible.** When the Keychain wins, `settings.state`
///    reports the winner only; the losing `.env` value is not on the wire. The
///    app compares fingerprints locally so it can say "`.env` holds a
///    *different* value and it is being ignored" instead of nothing.
///
/// **Neither path ever writes to `.env`.**
@MainActor
protocol EnvFileReading: AnyObject {
    /// nil when the file has no such key, or the key is blank.
    func value(forKey key: String, atPath path: String) throws -> String?
}

enum EnvFileError: LocalizedError, CustomStringConvertible {
    case refused(String)

    var description: String {
        switch self {
        case .refused(let why): "拒绝读取这个 .env：\(why)"
        }
    }

    var errorDescription: String? { description }
}

final class EnvFileReader: EnvFileReading {
    /// A `.env` with more than this in it is not a `.env`.
    static let maxBytes = 256 * 1024

    func value(forKey key: String, atPath path: String) throws -> String? {
        try Self.checkPath(path)
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.parse(text, key: key)
    }

    /// The path comes from `settings.state.envFiles[].path` — i.e. from the
    /// core, which is the peer, not the operator. It is checked before being
    /// opened: a peer that could name any path could otherwise have the app
    /// read a file of its choosing and offer to store it as a credential.
    ///
    /// `attributesOfItem` does not follow symlinks, so a link pointing at
    /// somewhere else fails the "regular file" test rather than being followed.
    static func checkPath(_ path: String) throws {
        let url = URL(filePath: path)
        guard url.lastPathComponent == ".env" else {
            throw EnvFileError.refused("文件名不是 .env")
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw EnvFileError.refused("读不到这个文件")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw EnvFileError.refused("不是普通文件（软链接也不行）")
        }
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() else {
            throw EnvFileError.refused("不属于当前用户")
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maxBytes else {
            throw EnvFileError.refused("文件太大，不像 .env")
        }
    }

    /// Minimal dotenv reader: `KEY=VALUE`, optional `export `, `#` comments,
    /// single or double quotes. Deliberately not a full dotenv implementation —
    /// the authoritative parse is whatever the core's runtime does, and this one
    /// only ever has to recognise the four keys in `.env.example`.
    static func parse(_ text: String, key: String) -> String? {
        var found: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = String(value[value.startIndex..<hash.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            // Last assignment wins, matching how a shell and dotenv loaders
            // both behave.
            found = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let found, !found.isEmpty else { return nil }
        return found
    }
}
