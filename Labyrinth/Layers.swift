import Foundation

struct CanvasLayer: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var isHidden: Bool

    init(id: UUID = UUID(), name: String, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isHidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isHidden = (try? container.decode(Bool.self, forKey: .isHidden)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isHidden, forKey: .isHidden)
    }
}

enum CanvasZItem: Hashable, Codable {
    case layer(UUID)
    case card(UUID)

    private enum Kind: String, Codable {
        case layer
        case card
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    var id: UUID {
        switch self {
        case .layer(let id), .card(let id):
            return id
        }
    }

    private var kind: Kind {
        switch self {
        case .layer:
            return .layer
        case .card:
            return .card
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let id = try container.decode(UUID.self, forKey: .id)
        switch kind {
        case .layer:
            self = .layer(id)
        case .card:
            self = .card(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
    }
}
