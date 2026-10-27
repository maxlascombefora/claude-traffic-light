import AppKit

/// Opens a Session in the Claude desktop app through its `claude://` URL scheme. The app gives
/// each Session a link `claude://claude.ai/epitaxy/<local id>` that opens that Session in the app.
///
/// Best-effort, like `GhosttyFocus`: a bad id or an app that ignores the link does nothing.
enum DesktopFocus {
    static func focus(hostSessionId: String) {
        guard hostSessionId.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil,
              let url = URL(string: "claude://claude.ai/epitaxy/\(hostSessionId)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
