import AppKit

/// The app half of `clipboard.read` (protocol.md §3.7).
///
/// This lives in the app and not in the core for one reason: `pbpaste` cannot
/// see the pasteboard's type list. Password managers stamp what they copy with
/// `org.nspasteboard.ConcealedType` (secret) or `org.nspasteboard.TransientType`
/// (do not archive), and only AppKit can read those markers. A core-side read
/// therefore cannot tell a copied URL from a copied master password — and on
/// macOS the pasteboard is the main channel a password travels through, sitting
/// there for the 30-90s the manager leaves it.
///
/// When the markers are present the text is never read at all, so there is
/// nothing for the core, the model, or the model's logs to leak.
enum Clipboard {
    /// The two UTIs of the org.nspasteboard convention.
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    static func isConcealed(types: [String]) -> Bool {
        types.contains { concealedTypes.contains($0) }
    }

    /// Build the answer from an already-inspected pasteboard.
    ///
    /// Split out from `read(request:)` so the decision — and above all the
    /// "concealed means the text does not travel" half of it — is testable
    /// without touching the user's real pasteboard.
    ///
    /// `text` is a closure, not a value: on the concealed path it must never be
    /// called, and a parameter would have forced the caller to read the secret
    /// before this function could decline it.
    static func response(
        requestId: String,
        types: [String],
        maxChars: Int?,
        text: () -> String?
    ) -> ClipboardReadResponsePayload {
        if isConcealed(types: types) {
            return ClipboardReadResponsePayload(requestId: requestId, concealed: true)
        }
        guard var value = text(), !value.isEmpty else {
            // No text flavour: an image, a file promise, or an empty pasteboard.
            return ClipboardReadResponsePayload(requestId: requestId, concealed: false)
        }
        if let maxChars, maxChars >= 0, value.count > maxChars {
            value = String(value.prefix(maxChars))
        }
        return ClipboardReadResponsePayload(requestId: requestId, concealed: false, text: value)
    }

    /// Read the real pasteboard. Main-actor because `NSPasteboard` is.
    @MainActor
    static func read(_ request: ClipboardReadRequestPayload) -> ClipboardReadResponsePayload {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        return response(
            requestId: request.requestId,
            types: types,
            maxChars: request.maxChars,
            text: { pasteboard.string(forType: .string) })
    }
}
