import Foundation
import Testing
@testable import AkariApp

// The `.env` reader. It exists for two things the wire cannot do: the import
// prompt, and making a Keychain/.env conflict visible. No real credential
// appears here.

@MainActor
@Suite("env file reader")
struct SettingsEnvImportTests {
    @Test("reads a plain assignment")
    func plain() {
        let text = "DASHSCOPE_API_KEY=sk-example\nOTHER=1\n"
        #expect(EnvFileReader.parse(text, key: "DASHSCOPE_API_KEY") == "sk-example")
        #expect(EnvFileReader.parse(text, key: "MISSING") == nil)
    }

    @Test("ignores comments, blank lines and the export prefix")
    func comments() {
        let text = """
        # DASHSCOPE_API_KEY=sk-commented-out

        export CLOUDFLARE_ACCOUNT_ID=abc123
        """
        #expect(EnvFileReader.parse(text, key: "DASHSCOPE_API_KEY") == nil)
        #expect(EnvFileReader.parse(text, key: "CLOUDFLARE_ACCOUNT_ID") == "abc123")
    }

    @Test("strips matching quotes, and a trailing comment only when unquoted")
    func quoting() {
        #expect(EnvFileReader.parse("K=\"a b\"", key: "K") == "a b")
        #expect(EnvFileReader.parse("K='a b'", key: "K") == "a b")
        #expect(EnvFileReader.parse("K=value # trailing", key: "K") == "value")
        // A `#` inside quotes belongs to the value: some tokens contain one.
        #expect(EnvFileReader.parse("K=\"va#lue\"", key: "K") == "va#lue")
    }

    @Test("an empty assignment reads as absent")
    func emptyIsAbsent() {
        #expect(EnvFileReader.parse("HF_TOKEN=\n", key: "HF_TOKEN") == nil)
        #expect(EnvFileReader.parse("HF_TOKEN=   \n", key: "HF_TOKEN") == nil)
    }

    @Test("the last assignment wins, like a shell")
    func lastWins() {
        #expect(EnvFileReader.parse("K=first\nK=second\n", key: "K") == "second")
    }

    @Test("reads a real file from the reported path")
    func readsFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: ".env").path(percentEncoded: false)
        try "CLOUDFLARE_API_TOKEN=token-value\n".write(toFile: path, atomically: true, encoding: .utf8)

        let reader = EnvFileReader()
        #expect(try reader.value(forKey: "CLOUDFLARE_API_TOKEN", atPath: path) == "token-value")
        #expect(try reader.value(forKey: "HF_TOKEN", atPath: path) == nil)
    }

    @Test("refuses a path that is not called .env")
    func refusesOtherNames() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "id_rsa").path(percentEncoded: false)
        try "K=v\n".write(toFile: path, atomically: true, encoding: .utf8)

        // The path comes from the peer over the socket. Without this check a
        // core could point the app at any file and have it offered as a
        // credential to store.
        #expect(throws: EnvFileError.self) {
            try EnvFileReader().value(forKey: "K", atPath: path)
        }
    }

    @Test("refuses a symlink even when it is called .env")
    func refusesSymlink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.txt")
        try "K=v\n".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appending(path: ".env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: EnvFileError.self) {
            try EnvFileReader().value(forKey: "K", atPath: link.path(percentEncoded: false))
        }
    }

    @Test("a missing file is refused rather than read as empty")
    func refusesMissing() {
        #expect(throws: EnvFileError.self) {
            try EnvFileReader().value(forKey: "K", atPath: "/nonexistent/akari-test/.env")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "akari-env-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
