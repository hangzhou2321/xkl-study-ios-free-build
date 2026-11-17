import ActivityKit
import Foundation

struct StudyPaceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let completed: Int
        let target: Int
        let away: Bool
    }
    let start: Date
    let end: Date
    let subject: String

    var returnURL: URL {
        var components = URLComponents()
        components.scheme = "xklstudy"
        components.host = "hourly"
        components.path = "/\(Int(start.timeIntervalSince1970))"
        return components.url!
    }
}
