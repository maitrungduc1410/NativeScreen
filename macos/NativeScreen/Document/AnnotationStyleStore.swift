import Foundation
import Observation

/// Annotation styles the user saved, shared by every project on this Mac.
@Observable
public final class AnnotationStyleStore {
    public static let shared = AnnotationStyleStore()

    public private(set) var saved: [AnnotationStyle] = []
    private let defaultsKey = "NativeScreen.AnnotationStyles"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let styles = try? JSONDecoder().decode([AnnotationStyle].self, from: data) {
            saved = styles
        }
    }

    public var all: [AnnotationStyle] { AnnotationStyle.builtIn + saved }

    public func save(_ style: AnnotationStyle) {
        saved.removeAll { $0.name.caseInsensitiveCompare(style.name) == .orderedSame }
        saved.append(style)
        persist()
    }

    public func delete(id: String) {
        saved.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
