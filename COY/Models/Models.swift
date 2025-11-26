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
	var firstMediaItem: MediaItem? // For backward compatibility
	var mediaItems: [MediaItem] // All media items for swipeable carousel
	var isPinned: Bool = false
	var pinnedAt: Date? // Timestamp when post was pinned (for sorting)
	var caption: String?
	var allowReplies: Bool = true // Default to true
	var allowDownload: Bool = false // Whether post author allows downloads
	var taggedUsers: [String] = [] // Array of user IDs who are tagged in this post
}

struct MediaItem {
	var imageURL: String?
	var thumbnailURL: String?
	var videoURL: String?
	var videoDuration: Double?
	var isVideo: Bool
}

struct Comment: Identifiable {
	var id: String
	var postId: String
	var userId: String
	var username: String
	var name: String
	var profileImageURL: String?
	var text: String
	var createdAt: Date
	var parentCommentId: String?
	var replyCount: Int = 0
}

// MARK: - Chat Models
// Note: ChatRoomModel, MessageModel, and FriendRequestModel are defined in separate files:
// - ChatRoomModel.swift
// - MessageModel.swift
// - FriendRequestModel.swift

