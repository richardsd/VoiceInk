import Foundation

enum HaloSessionDeliveryOverride: String, Equatable, Sendable {
    case forceDirect
    case forceReview
}

enum HaloEnhancementOutcome: Equatable, Sendable {
    case succeeded
    case rawFallback
}

enum HaloDeliveryDestinationState: Equatable, Sendable {
    /// The route is being selected before the asynchronous focus validation.
    case unresolved
    case valid
    case changed
}

enum HaloDeliveryRoute: Equatable, Sendable {
    case review
    case direct
}

struct HaloDeliveryDecisionContext: Equatable, Sendable {
    let policy: HaloDeliveryPolicy
    let enhancementOutcome: HaloEnhancementOutcome
    let sessionOverride: HaloSessionDeliveryOverride?
    let destinationState: HaloDeliveryDestinationState
}

enum HaloDeliveryDecisionResolver {
    static func route(for context: HaloDeliveryDecisionContext) -> HaloDeliveryRoute {
        if context.destinationState == .changed {
            return .review
        }

        switch context.sessionOverride {
        case .forceDirect:
            return .direct
        case .forceReview:
            return .review
        case nil:
            break
        }

        switch (context.policy, context.enhancementOutcome) {
        case (.alwaysReview, _):
            return .review
        case (.reviewWhenNeeded, .succeeded):
            return .direct
        case (.reviewWhenNeeded, .rawFallback):
            return .review
        case (.pasteImmediately, _):
            return .direct
        }
    }
}
