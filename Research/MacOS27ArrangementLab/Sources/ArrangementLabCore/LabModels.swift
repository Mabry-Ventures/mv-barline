import Foundation

public enum FixtureVariant: String, Codable, CaseIterable, Sendable {
    case uniqueLabels = "unique-labels"
    case duplicateLabels = "duplicate-labels"
    case absentLabels = "absent-labels"
    case dynamicTitles = "dynamic-titles"
    case reversedCreation = "reversed-creation"
}

public struct LabRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double {
        x + width / 2
    }

    public var centerY: Double {
        y + height / 2
    }

    public func approximatelyMatches(_ other: LabRect, tolerance: Double = 1) -> Bool {
        abs(x - other.x) <= tolerance &&
            abs(y - other.y) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }

    public func approximatelySharesCenter(with other: LabRect, tolerance: Double = 1) -> Bool {
        abs(centerX - other.centerX) <= tolerance &&
            abs(centerY - other.centerY) <= tolerance
    }
}

public enum CoordinateSpaceTransformer {
    public static func appKitToAccessibility(
        item: LabRect,
        appKitScreen: LabRect,
        accessibilityScreen: LabRect
    ) -> LabRect {
        LabRect(
            x: accessibilityScreen.x + item.x - appKitScreen.x,
            y: accessibilityScreen.y + appKitScreen.y + appKitScreen.height - item.y - item.height,
            width: item.width,
            height: item.height
        )
    }
}

public struct FixtureItemReceipt: Codable, Equatable, Sendable {
    public let token: String
    public let generation: Int
    public let autosaveName: String
    public let creationOrdinal: Int
    public let frame: LabRect?
    public let activations: Int

    public init(
        token: String,
        generation: Int,
        autosaveName: String,
        creationOrdinal: Int,
        frame: LabRect?,
        activations: Int
    ) {
        self.token = token
        self.generation = generation
        self.autosaveName = autosaveName
        self.creationOrdinal = creationOrdinal
        self.frame = frame
        self.activations = activations
    }
}

public struct FixtureReceipt: Codable, Equatable, Sendable {
    public let schema: Int
    public let session: String
    public let processIdentifier: Int32
    public let bundleIdentifier: String
    public let publisherKind: String
    public let variant: FixtureVariant
    public let sequence: Int
    public let items: [FixtureItemReceipt]

    public init(
        schema: Int = 1,
        session: String,
        processIdentifier: Int32,
        bundleIdentifier: String,
        publisherKind: String,
        variant: FixtureVariant,
        sequence: Int,
        items: [FixtureItemReceipt]
    ) {
        self.schema = schema
        self.session = session
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.publisherKind = publisherKind
        self.variant = variant
        self.sequence = sequence
        self.items = items
    }
}

public struct ObservedFixtureItem: Codable, Equatable, Sendable {
    public let token: String
    public let generation: Int
    public let frame: LabRect
    public let relativeIndex: Int
    public let hitTestMatched: Bool
    public let role: String?
    public let subrole: String?

    public init(
        token: String,
        generation: Int,
        frame: LabRect,
        relativeIndex: Int,
        hitTestMatched: Bool,
        role: String?,
        subrole: String?
    ) {
        self.token = token
        self.generation = generation
        self.frame = frame
        self.relativeIndex = relativeIndex
        self.hitTestMatched = hitTestMatched
        self.role = role
        self.subrole = subrole
    }
}

public struct ObservedCandidate: Codable, Equatable, Sendable {
    public let frame: LabRect?
    public let role: String?
    public let subrole: String?

    public init(frame: LabRect?, role: String?, subrole: String?) {
        self.frame = frame
        self.role = role
        self.subrole = subrole
    }
}

public struct FixtureObservation: Codable, Equatable, Sendable {
    public let schema: Int
    public let session: String
    public let processIdentifier: Int32
    public let receiptSequence: Int
    public let complete: Bool
    public let items: [ObservedFixtureItem]
    public let candidates: [ObservedCandidate]

    public init(
        schema: Int = 1,
        session: String,
        processIdentifier: Int32,
        receiptSequence: Int,
        complete: Bool,
        items: [ObservedFixtureItem],
        candidates: [ObservedCandidate]
    ) {
        self.schema = schema
        self.session = session
        self.processIdentifier = processIdentifier
        self.receiptSequence = receiptSequence
        self.complete = complete
        self.items = items
        self.candidates = candidates
    }
}

public enum SyntheticMoveStage: String, Codable, CaseIterable, Sendable {
    case idle
    case preflighting
    case sourceValidated
    case mouseDownPosted
    case dragging
    case mouseUpPosted
    case observing
    case verified
    case rejected
    case indeterminate
}

public enum SyntheticMoveDisposition: Codable, Equatable, Sendable {
    case preflightRejected(reason: String)
    case moveVerified
    case moveNotObserved
    case interferenceDetected
    case cleanupIndeterminate
    case restorationVerified
    case restorationFailed
}

public enum SyntheticMovePlacement: String, Codable, CaseIterable, Sendable {
    case before
    case after
}

public struct SyntheticMoveReport: Codable, Equatable, Sendable {
    public let schema: Int
    public let sourceToken: String
    public let destinationToken: String
    public let placement: SyntheticMovePlacement
    public let stages: [SyntheticMoveStage]
    public let disposition: String
    public let reason: String?
    public let beforeOrder: [String]
    public let afterOrder: [String]
    public let mouseDownConstructed: Bool
    public let mouseDownPosted: Bool
    public let mouseUpConstructed: Bool
    public let mouseUpPosted: Bool
    public let buttonCleanupVerified: Bool
    public let unrelatedOrderPreserved: Bool
    public let activationDelta: Int?

    public init(
        schema: Int = 1,
        sourceToken: String,
        destinationToken: String,
        placement: SyntheticMovePlacement,
        stages: [SyntheticMoveStage],
        disposition: String,
        reason: String? = nil,
        beforeOrder: [String],
        afterOrder: [String],
        mouseDownConstructed: Bool,
        mouseDownPosted: Bool,
        mouseUpConstructed: Bool,
        mouseUpPosted: Bool,
        buttonCleanupVerified: Bool,
        unrelatedOrderPreserved: Bool,
        activationDelta: Int?
    ) {
        self.schema = schema
        self.sourceToken = sourceToken
        self.destinationToken = destinationToken
        self.placement = placement
        self.stages = stages
        self.disposition = disposition
        self.reason = reason
        self.beforeOrder = beforeOrder
        self.afterOrder = afterOrder
        self.mouseDownConstructed = mouseDownConstructed
        self.mouseDownPosted = mouseDownPosted
        self.mouseUpConstructed = mouseUpConstructed
        self.mouseUpPosted = mouseUpPosted
        self.buttonCleanupVerified = buttonCleanupVerified
        self.unrelatedOrderPreserved = unrelatedOrderPreserved
        self.activationDelta = activationDelta
    }
}

public enum FixtureOrderVerifier {
    public static func tokensByScreenPosition(_ items: [ObservedFixtureItem]) -> [String] {
        items.sorted {
            if $0.frame.y != $1.frame.y {
                return $0.frame.y < $1.frame.y
            }
            return $0.frame.x < $1.frame.x
        }.map(\.token)
    }

    public static func preservesRelativeOrder(
        before: [String],
        after: [String],
        excluding movedToken: String
    ) -> Bool {
        before.filter { $0 != movedToken } == after.filter { $0 != movedToken }
    }

    public static func satisfiesPlacement(
        order: [String],
        source: String,
        destination: String,
        placement: SyntheticMovePlacement
    ) -> Bool {
        guard let sourceIndex = order.firstIndex(of: source),
              let destinationIndex = order.firstIndex(of: destination)
        else { return false }
        switch placement {
        case .before: return sourceIndex + 1 == destinationIndex
        case .after: return destinationIndex + 1 == sourceIndex
        }
    }
}
