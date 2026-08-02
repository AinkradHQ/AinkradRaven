import Foundation
import RavenFeature
import AinkradAppKit

// RavenDevAuth — a dev-only, human-in-the-loop CLI harness for exercising the
// REAL `GmailAuth` code end to end against real Google traffic.
//
// `RavenPlugin` is a code-signed bundle loaded by the host; it cannot be run
// directly, which is exactly why `GmailAuth`'s loopback OAuth flow has never
// actually been verified against Google. This target links `RavenFeature`
// (the library `GmailAuth` lives in) directly, as a plain command-line tool,
// so a human can run it, click through the real consent screen, and see
// whether the flow really completes.
//
// This target is NOT a dependency of `RavenPlugin` and is never embedded in
// it — `project.yml` wires it as a sibling `RavenFeature` consumer, the same
// way `RavenFeatureTests` is, not as a `RavenPlugin` dependency. Verified
// after building by inspecting `RavenPlugin.bundle`'s contents.
//
// Usage: `make dev-auth` (or run the built binary directly), optionally with
// the OAuth client JSON path as the first argument.

let defaultCredentialsPath = ("~/.config/ainkrad-raven/oauth-client.json" as NSString)
    .expandingTildeInPath
let credentialsPath = CommandLine.arguments.count > 1
    ? (CommandLine.arguments[1] as NSString).expandingTildeInPath
    : defaultCredentialsPath

struct InstalledClientCredentials: Decodable {
    let client_id: String
    let client_secret: String
}

struct OAuthClientFile: Decodable {
    let installed: InstalledClientCredentials
}

func loadCredentials(path: String) throws -> InstalledClientCredentials {
    guard FileManager.default.fileExists(atPath: path) else {
        throw DevAuthError.missingCredentialsFile(path)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let file = try JSONDecoder().decode(OAuthClientFile.self, from: data)
    return file.installed
}

enum DevAuthError: Error, CustomStringConvertible {
    case missingCredentialsFile(String)

    var description: String {
        switch self {
        case .missingCredentialsFile(let path):
            // Deliberately prints only the path, never any file contents.
            return "No OAuth client JSON found at \(path)."
        }
    }
}

/// A tiny file-backed `PluginSecretStore` for this harness only. There is no
/// `HostServices`/Keychain outside the real plugin host, so this stands in
/// for it. Deliberately lives here (not in the plugin target) and deliberately
/// writes only under `~/.config/ainkrad-raven/`, never into the repo — the
/// same directory the OAuth client JSON itself lives in, which is already
/// outside the repo and already gitignored. The file is created (or
/// re-chmod'd) at 0600 on every write so the refresh token is never
/// world/group readable.
final class FileBackedSecretStore: PluginSecretStore {
    private let path: String
    private var storage: [String: String]

    init(path: String) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.storage = decoded
        } else {
            self.storage = [:]
        }
    }

    func secret(forKey key: String) -> String? { storage[key] }

    func setSecret(_ value: String?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        FileManager.default.createFile(atPath: path, contents: data,
                                        attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

@MainActor
func runHarness() async -> Int32 {
    let credentials: InstalledClientCredentials
    do {
        credentials = try loadCredentials(path: credentialsPath)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 1
    }

    let secretsPath = ("~/.config/ainkrad-raven/dev-auth-secrets.json" as NSString)
        .expandingTildeInPath
    let secrets = FileBackedSecretStore(path: secretsPath)
    let auth = GmailAuth(secrets: secrets, clientID: credentials.client_id,
                         clientSecret: credentials.client_secret)

    print("Opening the consent screen in your browser — sign in and approve access…")
    do {
        let result = try await auth.authorize()
        print(result.address)
        print("Gmail authorization succeeded.")
        return 0
    } catch {
        // Never prints tokens or the client secret — GmailAuth's errors never
        // carry either, and this harness does not add any of its own.
        FileHandle.standardError.write(Data("Gmail authorization failed: \(error)\n".utf8))
        return 1
    }
}

// `authorize()` drives an `NWListener` whose callbacks are dispatched on
// `queue: .main`, so this process needs an actual running RunLoop for those
// callbacks to ever fire — a bare `Task { … }` followed by falling off the
// end of `main` would exit before the listener ever got a chance to bind.
// `exitCode` is set exactly once (success, failure, or the internal
// authorization timeout inside `GmailAuth` itself surfacing as a thrown
// error) and its assignment is what stops the loop.
nonisolated(unsafe) var exitCode: Int32?

Task { @MainActor in
    exitCode = await runHarness()
}

while exitCode == nil {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
exit(exitCode!)
