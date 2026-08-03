import Testing
@testable import RavenFeature

@Suite("LocalThreading")
struct LocalThreadingTests {
    @Test("a reply chain A -> B (references A) -> C (references A, B) threads into one")
    func replyChainThreads() {
        let nodes = [
            LocalThreading.Node(messageID: "A", references: [], inReplyTo: nil),
            LocalThreading.Node(messageID: "B", references: ["A"], inReplyTo: "A"),
            LocalThreading.Node(messageID: "C", references: ["A", "B"], inReplyTo: "B"),
        ]
        let groups = LocalThreading.group(nodes)
        #expect(groups.count == 1)
        #expect(Set(groups[0]) == Set(["A", "B", "C"]))
    }

    @Test("two unrelated messages sharing a subject but no References/In-Reply-To do not merge")
    func unrelatedSameSubjectDoesNotMerge() {
        // LocalThreading.Node carries no subject at all — proving it groups
        // purely from Message-ID linkage, subject is not even inputable here.
        let nodes = [
            LocalThreading.Node(messageID: "X", references: [], inReplyTo: nil),
            LocalThreading.Node(messageID: "Y", references: [], inReplyTo: nil),
        ]
        let groups = LocalThreading.group(nodes)
        #expect(groups.count == 2)
        #expect(Set(groups.flatMap { $0 }) == Set(["X", "Y"]))
    }

    @Test("a reference to an id outside the batch does not spuriously merge two unrelated messages")
    func unseenAncestorDoesNotMerge() {
        let nodes = [
            LocalThreading.Node(messageID: "P", references: ["ghost@x.com"], inReplyTo: "ghost@x.com"),
            LocalThreading.Node(messageID: "Q", references: ["ghost@x.com"], inReplyTo: "ghost@x.com"),
        ]
        let groups = LocalThreading.group(nodes)
        #expect(groups.count == 2)
    }
}
