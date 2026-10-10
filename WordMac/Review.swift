import AppKit
import CryptoKit

extension NSAttributedString.Key {
    /// "i|Author|epoch" for a tracked insertion, "d|Author|epoch" for a tracked deletion.
    static let wcRevision = NSAttributedString.Key("wc.revision")
    /// Id of the comment anchored to this text.
    static let wcComment = NSAttributedString.Key("wc.comment")
}

struct RevisionInfo: Equatable {
    enum Kind: String { case insert = "i", delete = "d" }
    var kind: Kind
    var author: String
    var date: Date

    var encoded: String { "\(kind.rawValue)|\(author.replacingOccurrences(of: "|", with: "/"))|\(Int(date.timeIntervalSince1970))" }

    static func decode(_ v: Any?) -> RevisionInfo? {
        guard let s = v as? String else { return nil }
        let p = s.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, let k = Kind(rawValue: p[0]), let t = Double(p[2]) else { return nil }
        return RevisionInfo(kind: k, author: p[1], date: Date(timeIntervalSince1970: t))
    }

    /// Same author gets the same colour everywhere.
    static func color(for author: String) -> NSColor {
        let palette: [NSColor] = [
            NSColor(calibratedRed: 0.80, green: 0.10, blue: 0.15, alpha: 1), NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.80, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.25, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.20, blue: 0.70, alpha: 1),
            NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.05, alpha: 1), NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.60, alpha: 1)]
        var h = 5381
        for u in author.unicodeScalars { h = (h &* 33) &+ Int(u.value) }
        return palette[abs(h) % palette.count]
    }
}

struct CommentReply: Codable, Equatable {
    var author: String
    var text: String
    var date: Double
}

struct CommentRec: Codable, Equatable {
    var author: String
    var initials: String
    var date: Double
    var text: String
    var resolved = false
    var replies: [CommentReply] = []
}

/// Restrict-editing settings. The password check uses Word's SHA-512 scheme so protection interoperates with .docx.
struct Protection: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case none, readOnly, comments, trackedChanges, forms
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "No protection"
            case .readOnly: "No changes (read only)"
            case .comments: "Comments only"
            case .trackedChanges: "Tracked changes only"
            case .forms: "Filling in forms only"
            }
        }
    }
    var mode: Mode = .none
    var salt: String?
    var hash: String?
    var spin = 100000

    var hasPassword: Bool { hash != nil }

    static func digest(_ password: String, salt: Data, spin: Int) -> Data {
        var pw = Data()
        for u in password.utf16 { pw.append(UInt8(u & 0xFF)); pw.append(UInt8(u >> 8)) }
        var h = Data(SHA512.hash(data: salt + pw))
        for i in 0..<spin {
            var d = h
            var n = UInt32(i).littleEndian
            withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
            h = Data(SHA512.hash(data: d))
        }
        return h
    }

    mutating func setPassword(_ p: String) {
        guard !p.isEmpty else { salt = nil; hash = nil; return }
        var s = Data(count: 16)
        _ = s.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        salt = s.base64EncodedString()
        hash = Self.digest(p, salt: s, spin: spin).base64EncodedString()
    }

    func check(_ p: String) -> Bool {
        guard let salt, let hash, let s = Data(base64Encoded: salt) else { return true }
        return Self.digest(p, salt: s, spin: spin).base64EncodedString() == hash
    }
}

struct RevisionItem: Identifiable, Equatable {
    var id: Int { range.location }
    var range: NSRange
    var info: RevisionInfo
    var preview: String
}

struct CommentItem: Identifiable, Equatable {
    var id: String
    var range: NSRange
    var preview: String
    var rec: CommentRec
}
