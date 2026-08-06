import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Shared plumbing for the Graph suites, which are split across several files
/// to stay inside the line limit. One definition of each, so the suites cannot
/// drift into testing subtly different providers.

/// One recorded Graph fixture's bytes.
func graphFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: FixtureBundleMarker.self)
        .url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

/// A provider whose access token is served from memory (no network refresh)
/// and whose requests go through `StubURLProtocol`.
@MainActor func makeGraphProvider(accountID: String = "a1") -> GraphProvider {
    let secrets = InMemorySecretStore()
    secrets.setSecret("refresh-token", forKey: "graph-refresh-\(accountID)")
    let auth = GraphAuth(secrets: secrets, clientID: "azure", tenantID: "tenant-abc",
                         session: StubURLProtocol.makeSession()) { _ in
        ("access-token", 3600)
    }
    return GraphProvider(accountID: accountID, auth: auth,
                         session: StubURLProtocol.makeSession())
}

/// Which of `graphBounded`'s two racers answered first. A top-level type
/// because a generic function cannot nest one.
enum GraphBoundedOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case failure(any Error)
    case timedOut
}

/// Thrown when `graphBounded`'s deadline wins, so the test FAILS at the
/// deadline instead of inheriting whatever the pending call eventually does.
struct GraphDeadlineExceeded: Error, CustomStringConvertible {
    let label: String
    var description: String { "\(label) never resolved within the deadline" }
}

/// Every network-shaped call gets a deadline, and the deadline **abandons** the
/// pending call rather than waiting it out.
///
/// The obvious version — start the work, start a timer, record an issue on
/// timeout, then `return try await work.value` — records the failure promptly
/// and then blocks anyway until the work finishes, because cancellation is
/// cooperative and nothing on this path checks it. That shape cost a 196-second
/// run during Task 19's mutation sweep (a mutant reached the real loopback
/// listener and sat through its full 180-second consent timeout) and it is the
/// hang-instead-of-fail shape this branch has filed three times already. A task
/// group is not the fix either: a group awaits its children before returning,
/// so it pays the same 180 seconds after reporting.
///
/// So: an `AsyncStream` race. Breaking out of the loop terminates the stream,
/// which cancels both tasks, and the helper returns at the deadline whether or
/// not the work ever answers.
@MainActor func graphBounded<T: Sendable>(_ label: String,
                                          sourceLocation: SourceLocation = #_sourceLocation,
                                          _ body: @MainActor @escaping () async throws -> T)
    async throws -> T {
    let stream = AsyncStream<GraphBoundedOutcome<T>> { continuation in
        let work = Task { @MainActor in
            do { continuation.yield(.value(try await body())) }
            catch { continuation.yield(.failure(error)) }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            continuation.yield(.timedOut)
        }
        continuation.onTermination = { _ in work.cancel(); deadline.cancel() }
    }
    for await first in stream {
        switch first {
        case .value(let value): return value
        case .failure(let error): throw error
        case .timedOut:
            Issue.record("\(label) never resolved within 10s", sourceLocation: sourceLocation)
            throw GraphDeadlineExceeded(label: label)
        }
    }
    throw GraphDeadlineExceeded(label: label)
}

/// What each intercepted request was, so a test can assert on the URL and the
/// Authorization header rather than only on the decoded result.
final class SeenRequests: @unchecked Sendable {
    struct Entry { let url: String; let authorization: String? }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ request: URLRequest) {
        let entry = Entry(url: request.url?.absoluteString ?? "",
                          authorization: request.value(forHTTPHeaderField: "Authorization"))
        lock.lock(); entries.append(entry); lock.unlock()
    }

    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
}

/// Collects request BODIES from inside `StubURLProtocol`, which hands a POST's
/// body over as a stream rather than on `httpBody`.
final class RecordedBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ request: URLRequest) {
        let body: String
        if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = String(decoding: data, as: UTF8.self)
        } else {
            body = ""
        }
        lock.lock(); entries.append(body); lock.unlock()
    }

    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}
