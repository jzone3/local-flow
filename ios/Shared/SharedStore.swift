import Foundation

/// What the app and the keyboard share: the App Group with the last transcript, and the URL that opens the app.
enum SharedStore {
    static let appGroup = "group.com.jzone3.LocalFlow"
    /// Opening this starts listening right away.
    static let dictateURL = URL(string: "localflow://dictate")!
    static let returnQueryItem = "return"

    static func dictateURL(returningTo bundleID: String?) -> URL {
        guard let bundleID, var components = URLComponents(url: dictateURL, resolvingAgainstBaseURL: false) else { return dictateURL }
        components.queryItems = [URLQueryItem(name: returnQueryItem, value: bundleID)]
        return components.url ?? dictateURL
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static var lastTranscript: String? {
        get { defaults?.string(forKey: "lastTranscript") }
        set { defaults?.set(newValue, forKey: "lastTranscript") }
    }
}
