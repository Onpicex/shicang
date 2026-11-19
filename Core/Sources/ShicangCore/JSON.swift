import Foundation

/// 宽松 JSON（第三方接口字段常变，避免为每个字段写 Codable 结构）
public enum JSON: Decodable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }

    public subscript(_ k: String) -> JSON { if case .object(let o) = self { return o[k] ?? .null }; return .null }
    public subscript(_ i: Int) -> JSON { if case .array(let a) = self, i >= 0, i < a.count { return a[i] }; return .null }

    public var string: String? {
        switch self { case .string(let s): return s; case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n); default: return nil }
    }
    public var int: Int? { if case .number(let n) = self { return Int(n) }; if case .string(let s) = self { return Int(s) }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
}
