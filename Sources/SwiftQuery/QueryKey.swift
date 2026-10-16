/// One JSON-like element of a ``QueryKey``.
///
/// Object elements hash independently of key order, so `["page": 1, "status": "done"]` and
/// `["status": "done", "page": 1]` identify the same query.
public enum QueryKeyValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([QueryKeyValue])
    case object([String: QueryKeyValue])
}

extension QueryKeyValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: QueryKeyValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, QueryKeyValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension QueryKeyValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let s): "\"\(s)\""
        case .int(let i): "\(i)"
        case .double(let d): "\(d)"
        case .bool(let b): "\(b)"
        case .null: "null"
        case .array(let a): "[\(a.map(\.description).joined(separator: ","))]"
        case .object(let o): "{\(o.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ","))}"
        }
    }

    /// TanStack `partialMatchKey`: arrays match by prefix, objects by subset, scalars by equality.
    func partiallyMatches(_ filter: QueryKeyValue) -> Bool {
        switch (self, filter) {
        case (.array(let a), .array(let b)):
            return b.count <= a.count && zip(a, b).allSatisfy { $0.partiallyMatches($1) }
        case (.object(let a), .object(let b)):
            return b.allSatisfy { key, value in a[key].map { $0.partiallyMatches(value) } ?? false }
        default:
            return self == filter
        }
    }
}

/// Keys are JSON values, so they encode as JSON.
extension QueryKeyValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([QueryKeyValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: QueryKeyValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Identity of a query: an ordered list of JSON-like values.
///
/// ```swift
/// let key: QueryKey = ["user", 123]
/// let filtered: QueryKey = ["todos", ["status": "done"]]
/// ```
public struct QueryKey: Hashable, Sendable, ExpressibleByArrayLiteral, CustomStringConvertible, Codable {
    public var elements: [QueryKeyValue]

    public init(_ elements: [QueryKeyValue]) { self.elements = elements }
    public init(from decoder: any Decoder) throws { elements = try [QueryKeyValue](from: decoder) }
    public func encode(to encoder: any Encoder) throws { try elements.encode(to: encoder) }
    public init(arrayLiteral elements: QueryKeyValue...) { self.elements = elements }

    public var description: String { QueryKeyValue.array(elements).description }

    /// Whether `self` matches a filter key: same leading elements, objects compared by subset.
    public func matches(_ filter: QueryKey, exact: Bool = false) -> Bool {
        exact ? self == filter : QueryKeyValue.array(elements).partiallyMatches(.array(filter.elements))
    }
}
