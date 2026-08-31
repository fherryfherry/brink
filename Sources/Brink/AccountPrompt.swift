import AppKit

/// Small native NSAlert-based prompts for the "Add account" / "Remove
/// account" menu flow — no need for a whole SwiftUI sheet/window for a
/// one-or-two-field form.
enum AccountPrompt {
    @MainActor
    static func text(title: String, message: String, placeholder: String = "") -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = placeholder
        return run(title: title, message: message, accessory: field, confirmTitle: L("Add")) {
            let value = field.stringValue.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    /// Two labeled fields stacked vertically — used for Claude/Codex, which
    /// need both a display name and a config-dir folder name.
    @MainActor
    static func twoFields(title: String, message: String,
                          label1: String, placeholder1: String,
                          label2: String, placeholder2: String) -> (String, String)? {
        let field1 = NSTextField(string: "")
        field1.placeholderString = placeholder1
        field1.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let field2 = NSTextField(string: "")
        field2.placeholderString = placeholder2
        field2.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let stack = NSStackView(views: [labeled(label1, field1), labeled(label2, field2)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        return run(title: title, message: message, accessory: stack, confirmTitle: L("Add"),
                   firstResponder: field1) {
            let v1 = field1.stringValue.trimmingCharacters(in: .whitespaces)
            let v2 = field2.stringValue.trimmingCharacters(in: .whitespaces)
            return v1.isEmpty ? nil : (v1, v2)
        }
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

    private static func labeled(_ text: String, _ field: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    @MainActor
    private static func run<T>(title: String, message: String, accessory: NSView, confirmTitle: String,
                               firstResponder: NSView? = nil, extract: () -> T?) -> T? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("Cancel"))
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = firstResponder ?? accessory
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return extract()
    }
}
