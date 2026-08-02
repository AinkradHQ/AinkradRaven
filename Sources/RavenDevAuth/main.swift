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

// Output was being swallowed while the process ran (fully-buffered stdout is
// the default when stdout isn't a TTY, e.g. under `xcodebuild`/`make`), which
// made a stuck run indistinguishable from a silent one. Line-buffer stdout so
// every `print` shows up immediately.
setvbuf(stdout, nil, _IOLBF, 0)

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

    // A deliberately short timeout (`RAVEN_DEV_AUTH_TIMEOUT_SECONDS=5`) lets
    // the bind → ready → open-browser path be exercised and observed to
    // terminate with a definite error, without a human completing consent.
    // Unset, the real 180s production timeout applies.
    let timeoutOverride = ProcessInfo.processInfo
        .environment["RAVEN_DEV_AUTH_TIMEOUT_SECONDS"]
        .flatMap(Double.init)
        .map { Duration.seconds($0) }

    print("Credentials loaded from \(credentialsPath).")
    print("Callback timeout: \(timeoutOverride.map { "\($0) (override)" } ?? "default (180s)").")
    print("Requesting a loopback listener…")
    do {
        let result = try await auth.authorize(timeout: timeoutOverride) { url in
            // Fires once the listener is bound and ready, immediately before
            // `NSWorkspace.shared.open(url)` is attempted — so "ready and
            // waiting" is always visible even if the browser handoff itself
            // silently fails (the reason this hook exists: `NSWorkspace.
            // shared.open` is not guaranteed to reliably surface a browser
            // from a bare command-line tool with no app bundle).
            //
            // Safe to print in full: this URL carries only the client id,
            // requested scopes, `state`, the PKCE challenge, and the
            // `redirect_uri` — never the client secret, never a code or
            // token. Printing the `redirect_uri` specifically here (as part
            // of the full URL, and pulled out on its own line) is what makes
            // a Google `redirect_uri_mismatch` immediately diagnosable
            // instead of showing up as a silent hang.
            let redirectURI = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "redirect_uri" }?.value ?? "(unknown)"
            let port = URLComponents(string: redirectURI)?.port.map(String.init) ?? "(unknown)"
            print("Listener ready on port \(port). redirect_uri = \(redirectURI)")
            print("Opening the consent screen in your browser…")
            print("If no browser window appears, open this URL manually:")
            print(url.absoluteString)
        }
        print(result.address)
        print("Gmail authorization succeeded.")
        return 0
    } catch {
        // Never prints tokens or the client secret — GmailAuth's errors never
        // carry either, and this harness does not add any of its own.
        let description = "\(error)"
        if description.contains("timedOut") {
            print("Timed out waiting for the browser callback — the listener was up and " +
                  "waiting the whole time; the consent screen was never completed (or the " +
                  "callback never reached this process).")
        }
        FileHandle.standardError.write(Data("Gmail authorization failed: \(description)\n".utf8))
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
