import AppKit
import ApplicationServices

/// Accessibility helpers: focused window titles, and the Firefox URL fallback.
enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt pointing at Privacy & Security → Accessibility.
    static func promptForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private static func copyAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let win = copyAttr(app, kAXFocusedWindowAttribute) else { return nil }
        return (win as! AXUIElement)
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard let win = focusedWindow(pid: pid) else { return nil }
        return copyAttr(win, kAXTitleAttribute) as? String
    }

    /// Focused window rect in global display coordinates (top-left origin —
    /// the same space as CGDisplayBounds, so it can be matched to a display
    /// without flipping). nil when the app exposes no focused window.
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard let win = focusedWindow(pid: pid),
              let posRef = copyAttr(win, kAXPositionAttribute),
              let sizeRef = copyAttr(win, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Firefox exposes no Apple Events for tabs; read the URL out of the focused
    /// window's accessibility tree instead (address-bar text field, or a web area's
    /// AXURL). Bounded breadth-first walk; returns nil when the toolbar is hidden
    /// or the tree shape changes — callers degrade to title-only.
    static func urlFromAXTree(pid: pid_t) -> String? {
        guard let win = focusedWindow(pid: pid) else { return nil }
        var queue: [AXUIElement] = [win]
        var visited = 0
        while !queue.isEmpty && visited < 400 {
            let el = queue.removeFirst()
            visited += 1
            let role = copyAttr(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" {
                if let url = copyAttr(el, kAXURLAttribute) as? URL { return url.absoluteString }
                if let s = copyAttr(el, kAXURLAttribute) as? String, !s.isEmpty { return s }
            }
            if role == "AXTextField" || role == "AXComboBox" {
                if let v = copyAttr(el, kAXValueAttribute) as? String, let url = normalizeURL(v) {
                    return url
                }
            }
            if let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: kids.prefix(24))
            }
        }
        return nil
    }

    /// Accepts "https://x.y/z" or bare "x.y/z" address-bar text; rejects everything else.
    static func normalizeURL(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains(" ") { return nil }
        if s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil {
            return s
        }
        if s.range(of: #"^[\w.-]+\.[a-zA-Z]{2,}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return "https://" + s
        }
        return nil
    }
}
