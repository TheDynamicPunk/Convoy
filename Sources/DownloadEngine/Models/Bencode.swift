import Foundation

/// A reader for bencode, the encoding inside `.torrent` files.
///
/// Two things set it apart from a plain decoder. A torrent's identity is the
/// SHA-1 of the exact bytes of its `info` dictionary as they appear in the
/// file, so `decode` also reports where each top-level value sits in the
/// input; re-encoding a parsed copy would change the bytes whenever the file
/// was written with its keys out of order. And its input comes off the
/// internet, so it is built to refuse a hostile file: bounded input size,
/// bounded nesting, every length checked against what is actually there before
/// anything is allocated, and duplicate keys refused so two readings of one
/// file cannot disagree about which `info` they mean.
enum Bencode {

    /// Far larger than any real `.torrent`, which is rarely over a few MB.
    static let maxInputSize = 16 << 20
    /// Real torrents nest about six deep.
    static let maxDepth = 64

    enum DecodeError: Error, Equatable {
        case empty
        case tooLarge
        /// The input ended in the middle of a value.
        case truncated
        /// A complete value, followed by more bytes.
        case trailingData
        case tooDeep
        /// Not valid bencode at this byte offset.
        case malformed(offset: Int)
        case duplicateKey(String)
    }

    enum Value: Equatable, Sendable {
        case integer(Int64)
        case bytes(Data)
        case list([Value])
        case dictionary([String: Value])

        subscript(key: String) -> Value? {
            if case .dictionary(let entries) = self { return entries[key] }
            return nil
        }

        var integer: Int64? {
            if case .integer(let value) = self { return value }
            return nil
        }

        var bytes: Data? {
            if case .bytes(let value) = self { return value }
            return nil
        }

        /// The bytes as text, when they are valid UTF-8.
        var string: String? {
            bytes.flatMap { String(data: $0, encoding: .utf8) }
        }

        var list: [Value]? {
            if case .list(let value) = self { return value }
            return nil
        }
    }

    struct Decoded {
        let value: Value
        /// For a top-level dictionary, the byte range of each of its values
        /// within the input. Empty for any other top-level value, and never
        /// includes keys of dictionaries nested deeper.
        let topLevelRanges: [String: Range<Int>]
    }

    static func decode(_ data: Data) throws -> Decoded {
        guard !data.isEmpty else { throw DecodeError.empty }
        guard data.count <= maxInputSize else { throw DecodeError.tooLarge }

        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        guard parser.index == parser.bytes.count else { throw DecodeError.trailingData }
        return Decoded(value: value, topLevelRanges: parser.topLevelRanges)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var topLevelRanges: [String: Range<Int>] = [:]

        private static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        mutating func parseValue(depth: Int) throws -> Value {
            guard depth <= Bencode.maxDepth else { throw DecodeError.tooDeep }
            guard index < bytes.count else { throw DecodeError.truncated }
            switch bytes[index] {
            case UInt8(ascii: "i"): return .integer(try parseInteger())
            case UInt8(ascii: "l"): return try parseList(depth: depth)
            case UInt8(ascii: "d"): return try parseDictionary(depth: depth)
            case let byte where Self.isDigit(byte): return .bytes(try parseString())
            default: throw DecodeError.malformed(offset: index)
            }
        }

        mutating func parseInteger() throws -> Int64 {
            index += 1 // "i"
            var negative = false
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
                negative = true
                index += 1
            }
            let digitsStart = index
            var value: Int64 = 0
            while index < bytes.count, Self.isDigit(bytes[index]) {
                let digit = Int64(bytes[index] - UInt8(ascii: "0"))
                let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: 10)
                let (next, addOverflow) = negative
                    ? scaled.subtractingReportingOverflow(digit)
                    : scaled.addingReportingOverflow(digit)
                if scaleOverflow || addOverflow { throw DecodeError.malformed(offset: digitsStart) }
                value = next
                index += 1
            }
            guard index > digitsStart else {
                if index >= bytes.count { throw DecodeError.truncated }
                throw DecodeError.malformed(offset: index)
            }
            guard index < bytes.count else { throw DecodeError.truncated }
            guard bytes[index] == UInt8(ascii: "e") else { throw DecodeError.malformed(offset: index) }
            index += 1
            return value
        }

        mutating func parseString() throws -> Data {
            let lengthStart = index
            var length = 0
            while index < bytes.count, Self.isDigit(bytes[index]) {
                let digit = Int(bytes[index] - UInt8(ascii: "0"))
                let (scaled, scaleOverflow) = length.multipliedReportingOverflow(by: 10)
                let (next, addOverflow) = scaled.addingReportingOverflow(digit)
                if scaleOverflow || addOverflow { throw DecodeError.malformed(offset: lengthStart) }
                length = next
                index += 1
            }
            guard index < bytes.count else { throw DecodeError.truncated }
            guard bytes[index] == UInt8(ascii: ":") else { throw DecodeError.malformed(offset: index) }
            index += 1
            // The length is a claim; what is actually left is the fact.
            guard length <= bytes.count - index else { throw DecodeError.truncated }
            let data = Data(bytes[index..<(index + length)])
            index += length
            return data
        }

        mutating func parseList(depth: Int) throws -> Value {
            index += 1 // "l"
            var items: [Value] = []
            while true {
                guard index < bytes.count else { throw DecodeError.truncated }
                if bytes[index] == UInt8(ascii: "e") {
                    index += 1
                    return .list(items)
                }
                items.append(try parseValue(depth: depth + 1))
            }
        }

        mutating func parseDictionary(depth: Int) throws -> Value {
            index += 1 // "d"
            var entries: [String: Value] = [:]
            while true {
                guard index < bytes.count else { throw DecodeError.truncated }
                if bytes[index] == UInt8(ascii: "e") {
                    index += 1
                    return .dictionary(entries)
                }
                guard Self.isDigit(bytes[index]) else { throw DecodeError.malformed(offset: index) }
                let key = String(decoding: try parseString(), as: UTF8.self)
                guard entries[key] == nil else { throw DecodeError.duplicateKey(key) }

                let valueStart = index
                let value = try parseValue(depth: depth + 1)
                if depth == 0 { topLevelRanges[key] = valueStart..<index }
                entries[key] = value
            }
        }
    }
}
