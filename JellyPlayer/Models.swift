import Foundation

struct AuthResponse: Decodable {
    let accessToken: String
    let user: JFUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

struct JFUser: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JFItemsResponse: Decodable {
    let items: [JFItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

/// A Jellyfin item (library, folder, album or song). Only the fields this app uses.
struct JFItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String?
    let isFolder: Bool?
    let collectionType: String?
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let artists: [String]?
    let runTimeTicks: Int64?
    let imageTags: [String: String]?
    let albumPrimaryImageTag: String?
    let parentId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case isFolder = "IsFolder"
        case collectionType = "CollectionType"
        case album = "Album"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case runTimeTicks = "RunTimeTicks"
        case imageTags = "ImageTags"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case parentId = "ParentId"
    }

    var artistLine: String {
        if let artists, !artists.isEmpty { return artists.joined(separator: ", ") }
        return albumArtist ?? "Unknown artist"
    }

    var subtitle: String {
        // Skip the album when it just repeats the song title (common for singles).
        if let album, !album.isEmpty, album.caseInsensitiveCompare(name) != .orderedSame {
            return "\(artistLine) · \(album)"
        }
        return artistLine
    }

    /// Jellyfin ticks are 100 ns.
    var duration: TimeInterval? {
        runTimeTicks.map { Double($0) / 10_000_000 }
    }

    static func == (lhs: JFItem, rhs: JFItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct FolderSelection: Codable, Equatable {
    let id: String
    let name: String
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
