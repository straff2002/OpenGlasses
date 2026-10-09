import Foundation

/// A strict JSON reader for team-learning bundles (Plan FP P3) — the structural half of treating a
/// bundle from another phone as untrusted input.
///
/// Platform decoders are lenient in exactly the ways an unsigned file must not be: a duplicated key
/// silently keeps its last value, so two readers of the same bytes can disagree about what they say;
/// `1.0` and `1e0` decode as the integer 1; and a truncated file and a malformed one fail with the
/// same opaque error. This reader refuses every one of those by name before `JSONDecoder` sees the
/// bytes, so the decoder only ever reads a document whose meaning is unambiguous:
///
/// - a key repeated inside one object is refused (`duplicateKey`);
/// - a number that is not a plain integer — a fraction, an exponent, a leading zero, `-0` — is
///   refused (`nonIntegerNumber`), and so is one outside ±(2^53 − 1);
/// - input that ends while a value, string, array or object is still open is `truncated`; anything
///   else that is not JSON is `malformed`; trailing bytes after the document are `malformed`.
///
/// It parses into a small tree (`Value`) the bundle's schema check walks. Depth is bounded so a
/// hostile file cannot recurse the parser off the stack.
enum LearningBundleJSON {

    /// One parsed value. Objects keep their keys in document order.
    indirect enum Value: Equatable {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case integer(Int64)
        case bool(Bool)
        case null

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.object(let a), .object(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            case (.array(let a), .array(let b)): return a == b
            case (.string(let a), .string(let b)): return a == b
            case (.integer(let a), .integer(let b)): return a == b
            case (.bool(let a), .bool(let b)): return a == b
            case (.null, .null): return true
            default: return false
            }
        }

        /// The value under `key` in an object, or nil.
        subscript(key: String) -> Value? {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }

        var keys: [String] {
            guard case .object(let pairs) = self else { return [] }
            return pairs.map(\.0)
        }
    }

    enum Failure: Error, Equatable {
        case truncated
        case malformed
        case duplicateKey(String)
        case nonIntegerNumber
        case tooDeep
    }

    /// The contract's ceiling on integers: positive and at most 2^53 − 1, the largest a double
    /// carries exactly, so a reader in any language sees the same number.
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let maximumDepth = 12

    static func parse(_ data: Data) -> Result<Value, Failure> {
        var parser = Parser(bytes: Array(data))
        do {
            let value = try parser.value(depth: 0)
            parser.whitespace()
            guard parser.index == parser.bytes.count else { return .failure(.malformed) }
            return .success(value)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.malformed)
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        /// The next byte, or `truncated` when the input has run out where more was required.
        mutating func peek() throws -> UInt8 {
            whitespace()
            guard index < bytes.count else { throw Failure.truncated }
            return bytes[index]
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth <= LearningBundleJSON.maximumDepth else { throw Failure.tooDeep }
            switch try peek() {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .integer(try integer())
            default: throw Failure.malformed
            }
        }

        mutating func literal(_ word: String) throws {
            for expected in word.utf8 {
                guard index < bytes.count else { throw Failure.truncated }
                guard bytes[index] == expected else { throw Failure.malformed }
                index += 1
            }
        }

        mutating func object(depth: Int) throws -> Value {
            index += 1 // {
            var pairs: [(String, Value)] = []
            var seen = Set<String>()
            if try peek() == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                guard try peek() == UInt8(ascii: "\"") else { throw Failure.malformed }
                let key = try string()
                guard seen.insert(key).inserted else { throw Failure.duplicateKey(key) }
                guard try peek() == UInt8(ascii: ":") else { throw Failure.malformed }
                index += 1
                pairs.append((key, try value(depth: depth + 1)))
                switch try peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"): index += 1; return .object(pairs)
                default: throw Failure.malformed
                }
            }
        }

        mutating func array(depth: Int) throws -> Value {
            index += 1 // [
            var items: [Value] = []
            if try peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try value(depth: depth + 1))
                switch try peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"): index += 1; return .array(items)
                default: throw Failure.malformed
                }
            }
        }

        /// A string token, unescaped by `JSONDecoder` so escapes mean exactly what they mean to the
        /// platform. Raw control bytes inside a string are malformed JSON.
        mutating func string() throws -> String {
            let start = index
            index += 1 // opening quote
            while true {
                guard index < bytes.count else { throw Failure.truncated }
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") { break }
                if byte < 0x20 { throw Failure.malformed }
                if byte == UInt8(ascii: "\\") {
                    guard index < bytes.count else { throw Failure.truncated }
                    index += 1
                }
            }
            guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                throw Failure.malformed
            }
            return text
        }

        /// A plain integer: an optional minus, then `0` or a digit run with no leading zero. A
        /// fraction or an exponent after it is refused by name, and so is `-0`.
        mutating func integer() throws -> Int64 {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digitStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > digitStart else {
                if index >= bytes.count { throw Failure.truncated }
                throw Failure.malformed
            }
            if index < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
                throw Failure.nonIntegerNumber
            }
            let digits = index - digitStart
            if bytes[digitStart] == UInt8(ascii: "0"), digits > 1 { throw Failure.nonIntegerNumber }
            guard let text = String(bytes: bytes[start..<index], encoding: .utf8),
                  let number = Int64(text), text != "-0",
                  number.magnitude <= UInt64(LearningBundleJSON.maximumSafeInteger) else { throw Failure.nonIntegerNumber }
            return number
        }
    }
}
