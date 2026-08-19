import Testing

@testable import AkariApp

/// The app half of `clipboard.read` (protocol.md §3.7).
///
/// What is being pinned down is a disclosure rule, not a feature: on the
/// concealed path the pasteboard text must never be read, and must never reach
/// the wire. `pbpaste` — the fallback this replaces — cannot see the markers at
/// all, so a core-side read hands a copied master password straight to a cloud
/// model. These tests assert the marker is honoured *and* that the closure which
/// would read the secret is never called.
@Suite("Clipboard concealment")
struct ClipboardTests {
    private static let request = ClipboardReadRequestPayload(requestId: "cb-1", maxChars: nil)

    @Test("plain text is passed through")
    func plainTextTravels() {
        let answer = Clipboard.response(
            requestId: "cb-1", types: ["public.utf8-plain-text"], maxChars: nil,
            text: { "https://example.com" })
        #expect(answer.concealed == false)
        #expect(answer.text == "https://example.com")
    }

    @Test("a ConcealedType marker stops the read before it happens")
    func concealedIsNeverRead() {
        var reads = 0
        let answer = Clipboard.response(
            requestId: "cb-1",
            types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            maxChars: nil,
            text: {
                reads += 1
                return "correct-horse-battery-staple"
            })
        #expect(answer.concealed)
        #expect(answer.text == nil)
        // Not merely "the text was dropped": it was never looked at.
        #expect(reads == 0)
    }

    @Test("TransientType is treated the same as ConcealedType")
    func transientIsAlsoWithheld() {
        let answer = Clipboard.response(
            requestId: "cb-1",
            types: ["org.nspasteboard.TransientType"],
            maxChars: nil,
            text: { "one-time code 402913" })
        #expect(answer.concealed)
        #expect(answer.text == nil)
    }

    /// The payload initialiser is the last line of defence: even a caller that
    /// hands it both must not put the text on the wire.
    @Test("concealed and text together cannot be encoded")
    func theInitialiserRefusesToCarryBoth() {
        let payload = ClipboardReadResponsePayload(
            requestId: "cb-1", concealed: true, text: "hunter2")
        #expect(payload.text == nil)
    }

    @Test("an empty or non-text pasteboard answers with no text and no marker")
    func noTextFlavour() {
        let empty = Clipboard.response(
            requestId: "cb-1", types: ["public.png"], maxChars: nil, text: { nil })
        #expect(empty.concealed == false)
        #expect(empty.text == nil)
    }

    @Test("maxChars truncates on this side, as the request asked")
    func truncation() {
        let answer = Clipboard.response(
            requestId: Self.request.requestId, types: ["public.utf8-plain-text"], maxChars: 5,
            text: { "0123456789" })
        #expect(answer.text == "01234")
    }

    @Test("the marker is matched exactly, not by prefix")
    func lookalikeTypesDoNotConceal() {
        #expect(!Clipboard.isConcealed(types: ["org.nspasteboard.ConcealedTypeX"]))
        #expect(!Clipboard.isConcealed(types: ["org.nspasteboard"]))
        #expect(Clipboard.isConcealed(types: ["org.nspasteboard.ConcealedType"]))
    }
}
