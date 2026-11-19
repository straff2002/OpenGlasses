import Foundation

/// Reads a format 1 van stock log and brings it to format 2 (Plan ML §2). Pure.
///
/// Format 1 kept every figure in whole units of the line's unit: a movement's `quantity`, a line's
/// `minimum` and `standard`, and the minimum and standard an `edited` movement noted as text
/// ("4", "4:base"). Format 2 keeps them all in thousandths. One scale for every unit, so the
/// migration multiplies by 1,000 and never looks at a line's unit: a line whose unit was edited
/// from `each` to `l` keeps its figures, as the edit always did. Kinds with no quantity (`edited`,
/// `reversed`) keep their zero.
///
/// The old shape is decoded here with its own integers, so a format 1 figure is never read as
/// thousandths by `StockQuantity`'s decoding. The store checks the version before it calls this,
/// so a log cannot be migrated twice.
enum VanStockLogMigration {

    /// What a format 1 file's `log` held.
    struct Format1Log: Decodable {
        let items: [Format1Item]
        let movements: [Format1Movement]
    }

    /// A format 1 line: everything as format 2 has it, except that `minimum` and `standard` are
    /// whole units.
    struct Format1Item: Decodable {
        /// The line with its figures cleared, ready to take them at the new scale.
        fileprivate let line: VanStockItem
        let minimum: Int?
        let standard: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: VanStockItem.CodingKeys.self)
            minimum = try Self.units(container, .minimum)
            standard = try Self.units(container, .standard)
            line = VanStockItem(
                id: try container.decode(String.self, forKey: .id),
                number: try container.decodeIfPresent(String.self, forKey: .number),
                description: try container.decode(String.self, forKey: .description),
                unit: try container.decode(VanStockUnit.self, forKey: .unit),
                standardSetBy: try container.decodeIfPresent(VanStockItem.StandardOrigin.self, forKey: .standardSetBy),
                bin: try container.decodeIfPresent(String.self, forKey: .bin),
                codes: try container.decode([String].self, forKey: .codes),
                verified: try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false,
                verification: try container.decodeIfPresent(VanStockVerification.self, forKey: .verification),
                createdBatch: try container.decode(String.self, forKey: .createdBatch))
        }

        private static func units(_ container: KeyedDecodingContainer<VanStockItem.CodingKeys>,
                                  _ key: VanStockItem.CodingKeys) throws -> Int? {
            guard let value = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
            return try VanStockLogMigration.checkedUnits(value, key: key, in: container)
        }
    }

    /// A format 1 movement: everything as format 2 has it, except that `quantity` is whole units.
    struct Format1Movement: Decodable {
        /// The movement with its quantity at zero, ready to take it at the new scale.
        fileprivate let movement: VanStockMovement
        let quantity: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: VanStockMovement.CodingKeys.self)
            let raw = try container.decode(Int.self, forKey: .quantity)
            quantity = try VanStockLogMigration.checkedUnits(raw, key: .quantity, in: container)
            movement = VanStockMovement(
                id: try container.decode(String.self, forKey: .id),
                itemID: try container.decode(String.self, forKey: .itemID),
                kind: try container.decode(VanStockMovement.Kind.self, forKey: .kind),
                at: try container.decode(Date.self, forKey: .at),
                batch: try container.decode(String.self, forKey: .batch),
                source: try container.decode(VanStockMovement.Source.self, forKey: .source),
                jobSessionID: try container.decodeIfPresent(String.self, forKey: .jobSessionID),
                jobReference: try container.decodeIfPresent(String.self, forKey: .jobReference),
                reason: try container.decodeIfPresent(VanStockMovement.RemovalReason.self, forKey: .reason),
                requestID: try container.decodeIfPresent(String.self, forKey: .requestID),
                reverses: try container.decodeIfPresent(String.self, forKey: .reverses),
                attribute: try container.decodeIfPresent(VanStockMovement.Attribute.self, forKey: .attribute),
                oldValue: try container.decodeIfPresent(String.self, forKey: .oldValue),
                newValue: try container.decodeIfPresent(String.self, forKey: .newValue),
                openingCounted: try container.decodeIfPresent(Bool.self, forKey: .openingCounted),
                openingUnreliable: try container.decodeIfPresent(Bool.self, forKey: .openingUnreliable))
        }
    }

    /// The same log in format 2: every figure, and every minimum and standard an edit noted,
    /// times 1,000. Opening figures and open orders are movements, so they scale with the rest.
    static func fromFormat1(_ old: Format1Log) -> VanStockLog {
        let items = old.items.map { entry -> VanStockItem in
            var item = entry.line
            item.minimum = entry.minimum.map(StockQuantity.init(whole:))
            item.standard = entry.standard.map(StockQuantity.init(whole:))
            return item
        }
        let movements = old.movements.map { entry -> VanStockMovement in
            let m = entry.movement
            var oldValue = m.oldValue
            var newValue = m.newValue
            if m.kind == .edited {
                switch m.attribute {
                case .minimum?:
                    oldValue = oldValue.map(scaledMinimum)
                    newValue = newValue.map(scaledMinimum)
                case .standard?:
                    oldValue = oldValue.map(scaledStandard)
                    newValue = newValue.map(scaledStandard)
                default:
                    break
                }
            }
            return VanStockMovement(
                id: m.id, itemID: m.itemID, kind: m.kind, quantity: StockQuantity(whole: entry.quantity),
                at: m.at, batch: m.batch, source: m.source, jobSessionID: m.jobSessionID,
                jobReference: m.jobReference, reason: m.reason, requestID: m.requestID,
                reverses: m.reverses, attribute: m.attribute, oldValue: oldValue, newValue: newValue,
                openingCounted: m.openingCounted, openingUnreliable: m.openingUnreliable)
        }
        return VanStockLog(items: items, movements: movements)
    }

    /// A format 1 minimum, "4", as format 2 writes it, "4000". Text that is not a figure in range
    /// is left as it was: undo reads it as no minimum, as format 1 did.
    static func scaledMinimum(_ raw: String) -> String {
        guard let units = Int(raw), (0...StockQuantity.maximumUnits).contains(units) else { return raw }
        return VanStockLog.encodeQuantity(StockQuantity(whole: units))
    }

    /// A format 1 standard, "4:base" or "4", as format 2 writes it, "4000:base" or "4000".
    static func scaledStandard(_ raw: String) -> String {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return raw }
        let figure = scaledMinimum(String(first))
        return parts.count > 1 ? "\(figure):\(parts[1])" : figure
    }

    /// A format 1 figure is whole units within 0 … a million; anything else makes the file
    /// unreadable rather than a figure format 2 could not hold.
    fileprivate static func checkedUnits<Key: CodingKey>(_ value: Int, key: Key,
                                                         in container: KeyedDecodingContainer<Key>) throws -> Int {
        guard (0...StockQuantity.maximumUnits).contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "A format 1 stock figure must be 0…\(StockQuantity.maximumUnits) units")
        }
        return value
    }
}
