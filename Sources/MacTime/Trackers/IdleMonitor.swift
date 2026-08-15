import CoreGraphics
import Foundation

enum IdleMonitor {
    /// Seconds since the last user input event, session-wide.
    /// CGEventType has no public "any" case, so take the min across the input types.
    static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}
