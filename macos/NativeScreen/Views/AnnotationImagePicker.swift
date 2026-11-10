import AppKit
import UniformTypeIdentifiers

/// The open panel for an image annotation.
@MainActor
enum AnnotationImagePicker {
    static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose an image to add")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a style name. Nil when cancelled or left empty.
    static func askStyleName() -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save style")
        alert.informativeText = String(localized: "Saved styles can be used in every project.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Style name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
