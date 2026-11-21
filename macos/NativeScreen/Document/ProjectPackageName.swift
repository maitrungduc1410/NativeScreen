import Foundation

/// Folder names for renamed projects (`spec/06` ADR-99). Same rules as `ProjectStore.PackageName` and
/// `ProjectStore.RenamedPackagePath` on Windows, so a package copied between the two keeps working.
enum ProjectPackageName {
    static let packageExtension = ".nativescreen"
    private static let maximumLength = 120
    private static let forbiddenCharacters: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// A project name as a folder name both systems accept: characters a file name cannot hold become "-", a trailing
    /// ".nativescreen" and trailing dots and spaces go, a reserved device name gets a "-". Nil when nothing is left.
    static func folderName(for name: String) -> String? {
        var text = name.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasSuffix(packageExtension) {
            text = String(text.dropLast(packageExtension.count))
        }
        text = String(text.map { character -> Character in
            let isControl = character.unicodeScalars.allSatisfy { $0.value < 32 }
            return isControl || forbiddenCharacters.contains(character) ? "-" : character
        })
        text = trimmingTrailingDotsAndSpaces(text).trimmingCharacters(in: .whitespaces)
        if text.count > maximumLength {
            text = trimmingTrailingDotsAndSpaces(String(text.prefix(maximumLength)))
        }
        let stem = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        if reservedNames.contains(stem.uppercased()) {
            text += "-"
        }
        return text.isEmpty ? nil : text
    }

    /// Where a package moves when its project is renamed: itself for the same name, the new name next to it, or
    /// "Name 2" when another package has the name. The package's own folder counts as free, so renaming "Name 2"
    /// to "Name" while "Name" exists leaves it where it is. Nil when the name gives no folder name.
    static func renamedPackageURL(for packageURL: URL, name: String) -> URL? {
        guard let folder = folderName(for: name) else { return nil }
        let current = packageURL.standardizedFileURL
        let directory = current.deletingLastPathComponent()
        let wanted = folder + packageExtension
        if current.lastPathComponent == wanted { return current }
        // Only the case changes: the same folder on a case-insensitive volume, so it is not taken.
        if current.lastPathComponent.lowercased() == wanted.lowercased() {
            return directory.appendingPathComponent(wanted, isDirectory: true)
        }
        var candidate = directory.appendingPathComponent(wanted, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path), !isSameFolder(candidate, current) {
            candidate = directory.appendingPathComponent("\(folder) \(index)\(packageExtension)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }

    private static func trimmingTrailingDotsAndSpaces(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last == "." || last == " " {
            result = result.dropLast()
        }
        return String(result)
    }
}
