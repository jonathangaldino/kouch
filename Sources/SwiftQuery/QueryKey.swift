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

/// Identity of a query: an ordered list of JSON-like values.
///
/// ```swift
/// let key: QueryKey = ["user", 123]
/// let filtered: QueryKey = ["todos", ["status": "done"]]
/// ```
public struct QueryKey: Hashable, Sendable, ExpressibleByArrayLiteral, CustomStringConvertible {
    public var elements: [QueryKeyValue]

    public init(_ elements: [QueryKeyValue]) { self.elements = elements }
    public init(arrayLiteral elements: QueryKeyValue...) { self.elements = elements }

    public var description: String { QueryKeyValue.array(elements).description }

    /// Whether `self` matches a filter key: same leading elements, objects compared by subset.
    public func matches(_ filter: QueryKey, exact: Bool = false) -> Bool {
        exact ? self == filter : QueryKeyValue.array(elements).partiallyMatches(.array(filter.elements))
    }
}
