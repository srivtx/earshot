// Recognises supported buds by their Bluetooth name and says how to reach their control channel.

public enum Brand: String, Sendable, CaseIterable {
    case realme, oppo, oneplus, samsung, sony, nothing, soundcore

    public var title: String {
        switch self {
        case .realme: "realme"
        case .oppo: "OPPO"
        case .oneplus: "OnePlus"
        case .samsung: "Samsung"
        case .sony: "Sony"
        case .nothing: "Nothing"
        case .soundcore: "soundcore"
        }
    }
}

/// How to find a brand's control service in the device's SDP records.
public enum ServiceMatch: Equatable, Sendable {
    /// A 128-bit service class UUID.
    case uuid([UInt8])
    /// Any service class UUID starting with these bytes (soundcore puts the model number at the end).
    case prefix([UInt8])
}

public struct Profile: Equatable, Sendable {
    public var brand: Brand
    /// Confirmed on real hardware. Everything else is built from published protocol work and
    /// marked experimental until an owner confirms it.
    public var tested: Bool
    /// Tried in order.
    public var services: [ServiceMatch]
    /// Used when the SDP record isn't cached yet.
    public var fallbackChannel: UInt8?
    fileprivate var make: @Sendable (String) -> any Driver

    public func driver(name: String) -> any Driver { make(name) }

    public static func == (a: Profile, b: Profile) -> Bool {
        a.brand == b.brand && a.tested == b.tested && a.services == b.services && a.fallbackChannel == b.fallbackChannel
    }
}

public enum Profiles {
    public static func match(name: String) -> Profile? {
        let n = name.lowercased().trimmingSpaces()
        if n.hasPrefix("realme buds") {
            // The Buds Air 7 call themselves "realme Buds Air7".
            return opo(.realme, app: "realme Link", tested: n.replacingSpaces() == "realmebudsair7")
        }
        if n.hasPrefix("oppo enco") { return opo(.oppo, app: "HeyMelody", tested: false) }
        if n.hasPrefix("oneplus buds") || n.hasPrefix("oneplus nord buds") || n.hasPrefix("nord buds") {
            return opo(.oneplus, app: "HeyMelody", tested: false)
        }
        if let model = galaxyModel(n) {
            return Profile(brand: .samsung, tested: false,
                           services: [.uuid(uuid("2e73a4ad-332d-41fc-90e2-16bef06523f2")),
                                      .uuid(uuid("00001101-0000-1000-8000-00805f9b34fb"))],
                           fallbackChannel: nil, make: { _ in GalaxyDriver(model: model) })
        }
        if ["wh-", "wf-", "wi-", "linkbuds", "ult wear"].contains(where: n.hasPrefix) {
            let headphones = n.hasPrefix("wh-") || n.hasPrefix("ult wear")
            return Profile(brand: .sony, tested: false,
                           services: [.uuid(uuid("956c7b26-d49a-4ba8-b03f-b17d393cb6e2")),
                                      .uuid(uuid("96cc203e-5068-46ad-b32d-e316f5e069ba"))],
                           fallbackChannel: nil, make: { _ in SonyDriver(headphones: headphones) })
        }
        if n.hasPrefix("nothing ear") || n.hasPrefix("ear (") || n.hasPrefix("cmf buds") {
            return Profile(brand: .nothing, tested: false,
                           services: [.uuid(uuid("aeac4a03-dff5-498f-843a-34487cf133eb"))],
                           fallbackChannel: nil, make: { NothingDriver(name: $0) })
        }
        // soundcore headphones and speakers use other layouts.
        if n.hasPrefix("soundcore"),
           !["space one", "space q", "q30", "q35", "q45", "life q", "life tune", "motion", "boom"].contains(where: n.contains) {
            return Profile(brand: .soundcore, tested: false,
                           services: [.prefix(Array(uuid("0cf12d31-fac3-4553-bd80-d6832e700000").prefix(15)))],
                           fallbackChannel: nil, make: { SoundcoreDriver(name: $0) })
        }
        return nil
    }

    public static let airSevenToggles: [Toggle] = [.spatial, .volumeBoost, .dynamicBass, .hiRes, .gameMode, .multipoint, .windNoise]

    private static func opo(_ brand: Brand, app: String, tested: Bool) -> Profile {
        // Channel 15 is where the Buds Air 7 puts the service.
        Profile(brand: brand, tested: tested, services: [.uuid(uuid("0000079a-d102-11e1-9b23-00025b00a5a5"))],
                fallbackChannel: brand == .realme ? 15 : nil,
                make: { _ in OPODriver(companionApp: app, knownToggles: tested ? airSevenToggles : []) })
    }

    /// Galaxy Buds are named "Galaxy Buds2 Pro (A1B2)" but can be renamed, so the model words are
    /// matched on their own as well. The original 2019 Galaxy Buds use an older framing and aren't covered.
    static func galaxyModel(_ n: String) -> GalaxyModel? {
        let base = n.hasPrefix("galaxy ") ? String(n.dropFirst(7)) : n
        let models: [(String, GalaxyModel)] = [
            ("buds4 pro", .buds4Pro), ("buds4", .buds4), ("buds3 pro", .buds3Pro), ("buds3 fe", .buds3FE),
            ("buds3", .buds3), ("buds2 pro", .buds2Pro), ("buds2", .buds2), ("buds fe", .budsFE),
            ("buds core", .budsCore), ("buds pro", .budsPro), ("buds live", .budsLive), ("buds+", .budsPlus),
        ]
        return models.first { base.hasPrefix($0.0) }?.1
    }

    /// Parses a UUID string into its 16 bytes.
    static func uuid(_ text: String) -> [UInt8] {
        let hex = Array(text.filter { $0 != "-" }.utf8)
        return stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(String(decoding: hex[i...(i + 1)], as: UTF8.self), radix: 16)!
        }
    }
}

private extension String {
    func replacingSpaces() -> String { filter { $0 != " " } }

    func trimmingSpaces() -> String {
        String(drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
    }
}
