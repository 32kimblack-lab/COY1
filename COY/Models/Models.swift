import Foundation

struct CollectionData: Identifiable, Codable {
	var id: String
	var name: String
	var description: String
	var type: String
	var isPublic: Bool
	var ownerId: String
	var ownerName: String
	var owners: [String]
	var imageURL: String?
	var invitedUsers: [String]
	var members: [String]
	var memberCount: Int
	var followers: [String]
	var followerCount: Int
	var allowedUsers: [String]
	var deniedUsers: [String]
	var createdAt: Date
	
	// Computed property for backward compatibility
	var title: String {
		return name
	}
}

struct CollectionPost: Identifiable {
	var id: String
	var title: String
	var collectionId: String
	var authorId: String
	var authorName: String
	var createdAt: Date
	var firstMediaItem: MediaItem?
}

struct MediaItem {
	var imageURL: String?
	var thumbnailURL: String?
	var videoURL: String?
	var videoDuration: Double?
	var isVideo: Bool
}

