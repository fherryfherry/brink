import AppKit

/// Small native NSAlert-based prompts for the "Add account" / "Remove
/// account" menu flow — no need for a whole SwiftUI sheet/window for a
/// one-or-two-field form.
enum AccountPrompt {
    @MainActor
    static func text(title: String, message: String, placeholder: String = "") -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: 22))
        field.placeholderString = placeholder
        return run(title: title, message: message, accessory: field, confirmTitle: L("Add")) {
            let value = field.stringValue.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? .failure(Invalid(L("This can't be blank."))) : .success(value)
        }
    }

    /// Display name + config folder for Claude/Codex; the folder comes back normalized relative to ~ (nil if left blank and optional).
    @MainActor
    static func nameAndFolder(title: String, message: String,
                              label1: String, placeholder1: String,
                              label2: String, placeholder2: String,
                              folderRequired: Bool) -> (String, String?)? {
        let field1 = NSTextField(string: "")
        field1.placeholderString = placeholder1
        let field2 = NSTextField(string: "")
        field2.placeholderString = placeholder2
        field1.nextKeyView = field2
        let form = labeledFields([(label1, field1), (label2, field2)])

        return run(title: title, message: message, accessory: form, confirmTitle: L("Add"),
                   firstResponder: field1) {
            let name = field1.stringValue.trimmingCharacters(in: .whitespaces)
            let rawDir = field2.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .failure(Invalid(L("%@ can't be blank.", label1))) }
            if rawDir.isEmpty {
                return folderRequired ? .failure(Invalid(L("%@ can't be blank.", label2))) : .success((name, nil))
            }
            guard let dir = homeRelativeFolder(rawDir) else {
                return .failure(Invalid(L("%@ must be a folder inside your home directory.", rawDir)))
            }
            var isDir: ObjCBool = false
            let full = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(dir).path
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
                return .failure(Invalid(L("Folder ~/%@ doesn't exist.", dir)))
            }
            return .success((name, dir))
        }
    }

    /// Accepts ".claude-work", "~/.claude-work" or "/Users/me/.claude-work" and returns ".claude-work"; nil if outside ~.
    static func homeRelativeFolder(_ input: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let expanded = (input as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (home as NSString).appendingPathComponent(expanded)
        let path = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return nil }
        let relative = String(path.dropFirst(home.count + 1))
        return relative.isEmpty ? nil : relative
    }

    @MainActor
    static func confirmRemove(displayName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Remove %@?", displayName)
        alert.informativeText = L("This just removes it from Brink — it doesn't sign you out or revoke anything.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static let fieldWidth: CGFloat = 220

    /// Frame-based on purpose: NSAlert's accessoryView needs a real frame, an Auto Layout stack gets misplaced over the message text.
    private static func labeledFields(_ rows: [(String, NSTextField)]) -> NSView {
        let labelH: CGFloat = 16, fieldH: CGFloat = 22, gap: CGFloat = 2, rowGap: CGFloat = 10
        let rowH = labelH + gap + fieldH
        let totalH = CGFloat(rows.count) * rowH + CGFloat(rows.count - 1) * rowGap
        let container = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: totalH))
        for (i, (text, field)) in rows.enumerated() {
            let top = totalH - CGFloat(i) * (rowH + rowGap)
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: top - labelH, width: fieldWidth, height: labelH)
            field.frame = NSRect(x: 0, y: top - labelH - gap - fieldH, width: fieldWidth, height: fieldH)
            container.addSubview(label)
            container.addSubview(field)
        }
        return container
    }

    struct Invalid: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Loops on an invalid confirm (e.g. a required field left blank) instead
    /// of silently doing nothing — the field contents are preserved (same
    /// NSAlert instance re-run) so the user isn't retyping everything.
    @MainActor
    private static func run<T>(title: String, message: String, accessory: NSView, confirmTitle: String,
                               firstResponder: NSView? = nil,
                               extract: () -> Result<T, Invalid>) -> T? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("Cancel"))
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = firstResponder ?? accessory
        NSApp.activate(ignoringOtherApps: true)
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let invalid: Invalid
            switch extract() {
            case .success(let value): return value
            case .failure(let error): invalid = error
            }
            let err = NSAlert()
            err.messageText = invalid.message
            err.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            err.runModal()
        }
    }
}
