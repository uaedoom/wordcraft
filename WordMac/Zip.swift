import Foundation
import Compression

/// Minimal ZIP reader/writer (deflate + stored), enough for Office Open XML packages.
enum Zip {
    struct Entry { var name: String; var data: Data }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func inflate(_ d: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == size ? out : nil
    }

    private static func deflate(_ d: Data) -> Data? {
        if d.isEmpty { return nil }
        var out = Data(count: d.count + 1024)
        let cap = out.count
        let n = out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < d.count else { return nil }
        return out.prefix(n)
    }

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    // MARK: Reading

    static func read(_ data: Data) -> [String: Data]? {
        guard data.count > 22 else { return nil }
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 65557) {
            if u32(data, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(data, eocd + 10)
        var p = u32(data, eocd + 16)
        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(data, p) == 0x02014b50 else { break }
            let method = u16(data, p + 10)
            let csize = u32(data, p + 20), usize = u32(data, p + 24)
            let nlen = u16(data, p + 28), elen = u16(data, p + 30), clen = u16(data, p + 32)
            let lho = u32(data, p + 42)
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nlen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            p += 46 + nlen + elen + clen
            guard lho + 30 <= data.count, u32(data, lho) == 0x04034b50 else { continue }
            let start = lho + 30 + u16(data, lho + 26) + u16(data, lho + 28)
            guard start + csize <= data.count else { continue }
            let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + csize))
            if method == 0 { out[name] = raw }
            else if method == 8, let d = inflate(raw, size: usize) { out[name] = d }
        }
        return out
    }

    // MARK: Writing

    static func write(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func le32(_ v: Int) -> Data { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
        let dosTime = 0x6000, dosDate = 0x5A21      // 2025-01-01 12:00
        for e in entries {
            let crc = Int(crc32(e.data))
            let packed = deflate(e.data)
            let method = packed == nil ? 0 : 8
            let body = packed ?? e.data
            let name = Data(e.name.utf8)
            let offset = out.count
            out += le32(0x04034b50) + le16(20) + le16(0x0800) + le16(method) + le16(dosTime) + le16(dosDate)
            out += le32(crc) + le32(body.count) + le32(e.data.count) + le16(name.count) + le16(0) + name + body
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0x0800) + le16(method) + le16(dosTime) + le16(dosDate)
            central += le32(crc) + le32(body.count) + le32(e.data.count) + le16(name.count) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let cdOffset = out.count
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
        out += le32(central.count) + le32(cdOffset) + le16(0)
        return out
    }
}

/// A tiny XML tree built with XMLParser. Element names keep their prefixes ("w:p").
final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""
    weak var parent: XNode?

    init(_ name: String, _ attrs: [String: String] = [:]) { self.name = name; self.attrs = attrs }

    func child(_ n: String) -> XNode? { children.first { $0.name == n } }
    func kids(_ n: String) -> [XNode] { children.filter { $0.name == n } }
    func attr(_ n: String) -> String? { attrs[n] }
    var val: String? { attrs["w:val"] }

    /// All descendants with this name, depth-first.
    func descendants(_ n: String) -> [XNode] {
        var out: [XNode] = []
        for c in children { if c.name == n { out.append(c) }; out += c.descendants(n) }
        return out
    }

    static func parse(_ data: Data) -> XNode? {
        final class Delegate: NSObject, XMLParserDelegate {
            var root: XNode?
            var stack: [XNode] = []
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
                let n = XNode(elementName, attributeDict)
                if let top = stack.last { n.parent = top; top.children.append(n) } else { root = n }
                stack.append(n)
            }
            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
            func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        }
        let d = Delegate()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.shouldResolveExternalEntities = false
        p.delegate = d
        return p.parse() ? d.root : d.root
    }
}

func xmlEscape(_ s: String) -> String {
    var o = ""
    o.reserveCapacity(s.count)
    for c in s.unicodeScalars {
        switch c {
        case "&": o += "&amp;"
        case "<": o += "&lt;"
        case ">": o += "&gt;"
        case "\"": o += "&quot;"
        default:
            if c.value < 0x20 && c != "\t" && c != "\n" && c != "\r" { continue }   // illegal in XML 1.0
            o.unicodeScalars.append(c)
        }
    }
    return o
}
