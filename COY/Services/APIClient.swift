import Foundation
import UIKit
import FirebaseAuth

// MARK: - API Client for Backend Integration
@MainActor
final class APIClient {
	static let shared = APIClient()
	private init() {}
	
	// Vercel API URL - Update this if your deployment URL changes
	private let baseURL = "https://backend-delta-two-66.vercel.app"
	
	// MARK: - User Profile Endpoints
	
	/// Create or update user profile
	func createOrUpdateUser(
		userId: String,
		name: String,
		username: String,
		email: String,
		birthMonth: String,
		birthDay: String,
		birthYear: String,
		profileImage: UIImage?,
		backgroundImage: UIImage?
	) async throws -> UserResponse {
		var request = try await createRequest(endpoint: "/users/\(userId)", method: "PUT")
		
		// Create multipart form data
		var formData = [
			"name": name,
			"username": username,
			"email": email,
			"birthMonth": birthMonth,
			"birthDay": birthDay,
			"birthYear": birthYear
		]
		
		// Add images if provided
		var imageDataDict: [String: Data] = [:]
		if let profileImage = profileImage,
		   let profileData = profileImage.jpegData(compressionQuality: 0.8) {
			formData["profileImage"] = "profileImage"
			imageDataDict["profileImage"] = profileData
		}
		
		if let backgroundImage = backgroundImage,
		   let bgData = backgroundImage.jpegData(compressionQuality: 0.8) {
			formData["backgroundImage"] = "backgroundImage"
			imageDataDict["backgroundImage"] = bgData
		}
		
		request.httpBody = try createMultipartBody(formData: formData, media: imageDataDict)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(UserResponse.self, from: data)
	}
	
	/// Get user profile
	func getUser(userId: String) async throws -> UserResponse {
		let request = try await createRequest(endpoint: "/users/\(userId)", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(UserResponse.self, from: data)
	}
	
	// MARK: - Collection Endpoints
	
	/// Create a new collection
	func createCollection(
		name: String,
		description: String,
		type: String,
		isPublic: Bool,
		ownerId: String,
		ownerName: String,
		image: UIImage?,
		invitedUsers: [String]
	) async throws -> CollectionResponse {
		var request = try await createRequest(endpoint: "/collections", method: "POST")
		
		var formData: [String: String] = [
			"name": name,
			"description": description,
			"type": type,
			"isPublic": String(isPublic),
			"ownerId": ownerId,
			"ownerName": ownerName,
			"invitedUsers": invitedUsers.joined(separator: ",")
		]
		
		var imageDataDict: [String: Data] = [:]
		if let image = image,
		   let imgData = image.jpegData(compressionQuality: 0.8) {
			formData["image"] = "image"
			imageDataDict["image"] = imgData
		}
		
		request.httpBody = try createMultipartBody(formData: formData, media: imageDataDict)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(CollectionResponse.self, from: data)
	}
	
	/// Get user's collections
	func getUserCollections(userId: String) async throws -> [CollectionResponse] {
		let request = try await createRequest(endpoint: "/users/\(userId)/collections", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode([CollectionResponse].self, from: data)
	}
	
	/// Create a post in a collection
	func createPost(
		collectionId: String,
		caption: String?,
		mediaItems: [CreatePostMediaItem],
		taggedUsers: [String]?,
		allowDownload: Bool,
		allowReplies: Bool
	) async throws -> PostResponse {
		var request = try await createRequest(endpoint: "/collections/\(collectionId)/posts", method: "POST")
		
		var formData: [String: String] = [
			"allowDownload": String(allowDownload),
			"allowReplies": String(allowReplies)
		]
		
		if let caption = caption, !caption.isEmpty {
			formData["caption"] = caption
		}
		
		if let taggedUsers = taggedUsers, !taggedUsers.isEmpty {
			formData["taggedUsers"] = taggedUsers.joined(separator: ",")
		}
		
		// Add media files (images and videos)
		var mediaDataDict: [String: Data] = [:]
		var videoKeys: Set<String> = [] // Track which keys are videos
		for (index, item) in mediaItems.enumerated() {
			let key = "media\(index)"
			if let image = item.image,
			   let imageData = image.jpegData(compressionQuality: 0.8) {
				// Don't add key to formData - it's only in mediaDataDict
				mediaDataDict[key] = imageData
				print("📸 Added image \(key), size: \(imageData.count) bytes")
			} else if let videoURL = item.videoURL,
					  let videoData = try? Data(contentsOf: videoURL) {
				// Don't add key to formData - it's only in mediaDataDict
				mediaDataDict[key] = videoData
				videoKeys.insert(key) // Mark as video
				// Add video duration if available
				if let duration = item.videoDuration {
					formData["\(key)_duration"] = String(duration)
				}
				print("🎥 Added video \(key), size: \(videoData.count) bytes, duration: \(item.videoDuration ?? 0)")
			}
		}
		
		print("📊 Total media items to upload: \(mediaDataDict.count)")
		
		// Validate we have at least one media item
		guard !mediaDataDict.isEmpty else {
			throw NSError(domain: "APIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media items to upload"])
		}
		
		request.httpBody = try createMultipartBody(formData: formData, media: mediaDataDict, videoKeys: videoKeys)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		
		print("📦 Request body size: \(request.httpBody?.count ?? 0) bytes")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(PostResponse.self, from: data)
	}
	
	/// Get posts for a collection
	func getCollectionPosts(collectionId: String) async throws -> [CollectionPost] {
		let request = try await createRequest(endpoint: "/collections/\(collectionId)/posts", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		
		let postsResponse = try JSONDecoder().decode(PostsResponse.self, from: data)
		
		// Convert PostData to CollectionPost
		return postsResponse.posts.map { postData in
			// Parse createdAt date
			let dateFormatter = ISO8601DateFormatter()
			dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			let createdAt = dateFormatter.date(from: postData.createdAt) ?? Date()
			
			// Convert PostMediaItem to MediaItem
			var mediaItem: MediaItem?
			var allMediaItems: [MediaItem] = []
			
			if let postMedia = postData.firstMediaItem {
				mediaItem = MediaItem(
					imageURL: postMedia.imageURL,
					thumbnailURL: postMedia.thumbnailURL,
					videoURL: postMedia.videoURL,
					videoDuration: postMedia.videoDuration,
					isVideo: postMedia.isVideo ?? false
				)
				if let item = mediaItem {
					allMediaItems = [item]
				}
			}
			
			// If backend provides mediaItems array, use it
			// Otherwise fall back to firstMediaItem
			
			return CollectionPost(
				id: postData.id,
				title: postData.title,
				collectionId: postData.collectionId,
				authorId: postData.authorId,
				authorName: postData.authorName,
				createdAt: createdAt,
				firstMediaItem: mediaItem,
				mediaItems: allMediaItems
			)
		}
	}
	
	/// Get visible collections (for home/search feeds)
	func getVisibleCollections() async throws -> [CollectionResponse] {
		let request = try await createRequest(endpoint: "/collections/visible", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode([CollectionResponse].self, from: data)
	}
	
	/// Search collections - returns all public collections and collections user has access to
	func searchCollections(query: String? = nil) async throws -> [CollectionResponse] {
		var endpoint = "/collections/discover/collections"
		if let query = query, !query.isEmpty {
			let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
			endpoint += "?query=\(encodedQuery)"
		}
		print("🔍 Searching collections at: \(baseURL)/api\(endpoint)")
		let request = try await createRequest(endpoint: endpoint, method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		
		// Log response for debugging
		if let httpResponse = response as? HTTPURLResponse {
			print("📡 Collections search response: \(httpResponse.statusCode)")
			if httpResponse.statusCode != 200 {
				if let errorData = String(data: data, encoding: .utf8) {
					print("❌ Error response: \(errorData)")
				}
			}
		}
		
		try validateResponse(response)
		return try JSONDecoder().decode([CollectionResponse].self, from: data)
	}
	
	/// Search posts - returns posts from all accessible collections
	func searchPosts(query: String? = nil) async throws -> [CollectionPost] {
		var endpoint = "/collections/discover/posts"
		if let query = query, !query.isEmpty {
			let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
			endpoint += "?query=\(encodedQuery)"
		}
		print("🔍 Searching posts at: \(baseURL)/api\(endpoint)")
		let request = try await createRequest(endpoint: endpoint, method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		
		// Log response for debugging
		if let httpResponse = response as? HTTPURLResponse {
			print("📡 Posts search response: \(httpResponse.statusCode)")
			if httpResponse.statusCode != 200 {
				if let errorData = String(data: data, encoding: .utf8) {
					print("❌ Error response: \(errorData)")
				}
			}
		}
		
		try validateResponse(response)
		
		let postsResponse = try JSONDecoder().decode(PostsResponse.self, from: data)
		
		// Convert PostData to CollectionPost
		return postsResponse.posts.map { postData in
			// Parse createdAt date
			let dateFormatter = ISO8601DateFormatter()
			dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			let createdAt = dateFormatter.date(from: postData.createdAt) ?? Date()
			
			// Convert PostMediaItem to MediaItem
			var mediaItem: MediaItem?
			var allMediaItems: [MediaItem] = []
			
			// Use mediaItems array if available, otherwise fall back to firstMediaItem
			if let mediaItemsArray = postData.mediaItems, !mediaItemsArray.isEmpty {
				allMediaItems = mediaItemsArray.map { postMedia in
					MediaItem(
						imageURL: postMedia.imageURL,
						thumbnailURL: postMedia.thumbnailURL,
						videoURL: postMedia.videoURL,
						videoDuration: postMedia.videoDuration,
						isVideo: postMedia.isVideo ?? false
					)
				}
				mediaItem = allMediaItems.first
			} else if let postMedia = postData.firstMediaItem {
				mediaItem = MediaItem(
					imageURL: postMedia.imageURL,
					thumbnailURL: postMedia.thumbnailURL,
					videoURL: postMedia.videoURL,
					videoDuration: postMedia.videoDuration,
					isVideo: postMedia.isVideo ?? false
				)
				if let item = mediaItem {
					allMediaItems = [item]
				}
			}
			
			return CollectionPost(
				id: postData.id,
				title: postData.title,
				collectionId: postData.collectionId,
				authorId: postData.authorId,
				authorName: postData.authorName,
				createdAt: createdAt,
				firstMediaItem: mediaItem,
				mediaItems: allMediaItems
			)
		}
	}
	
	/// Get a specific collection
	func getCollection(collectionId: String) async throws -> CollectionResponse {
		let request = try await createRequest(endpoint: "/collections/\(collectionId)", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(CollectionResponse.self, from: data)
	}
	
	/// Update user preferences
	func updateUser(
		userId: String,
		collectionSortPreference: String? = nil,
		customCollectionOrder: [String]? = nil
	) async throws -> UserResponse {
		var request = try await createRequest(endpoint: "/users/\(userId)", method: "PATCH")
		
		var body: [String: Any] = [:]
		if let sortPreference = collectionSortPreference {
			body["collectionSortPreference"] = sortPreference
		}
		if let customOrder = customCollectionOrder {
			body["customCollectionOrder"] = customOrder
		}
		
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(UserResponse.self, from: data)
	}
	
	// MARK: - Helper Methods
	
	private func createRequest(endpoint: String, method: String) async throws -> URLRequest {
		guard let url = URL(string: "\(baseURL)/api\(endpoint)") else {
			throw APIError.invalidURL
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = method
		
		// Add Firebase Auth token for authentication
		if let idToken = try await getFirebaseAuthToken() {
			request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
		}
		
		return request
	}
	
	/// Get Firebase Auth ID token for backend authentication
	private func getFirebaseAuthToken() async throws -> String? {
		guard let user = Auth.auth().currentUser else {
			return nil
		}
		return try await user.getIDToken()
	}
	
	private func validateResponse(_ response: URLResponse) throws {
		guard let httpResponse = response as? HTTPURLResponse else {
			throw APIError.invalidResponse
		}
		
		guard (200...299).contains(httpResponse.statusCode) else {
			throw APIError.httpError(statusCode: httpResponse.statusCode, message: "Request failed")
		}
	}
	
	private let boundary = "Boundary-\(UUID().uuidString)"
	
	private func createMultipartBody(formData: [String: String], media: [String: Data], videoKeys: Set<String> = []) throws -> Data {
		var body = Data()
		
		// Add form fields
		for (key, value) in formData {
			// Skip media keys - they're added separately
			if media.keys.contains(key) {
				continue
			}
			body.append("--\(boundary)\r\n".data(using: .utf8)!)
			body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
			body.append("\(value)\r\n".data(using: .utf8)!)
		}
		
		// Add media files (images and videos)
		for (key, data) in media {
			let isVideo = videoKeys.contains(key)
			// Determine MIME type based on file extension or video detection
			let contentType: String
			let fileExtension: String
			
			if isVideo {
				// Try to detect video format from data or default to mp4
				// Check first few bytes for video signatures
				if data.count >= 4 {
					let header = data.prefix(4)
					// QuickTime/MOV files start with specific bytes
					if header[0] == 0x00 && header[1] == 0x00 && header[2] == 0x00 {
						contentType = "video/quicktime"
						fileExtension = "mov"
					} else {
						contentType = "video/mp4"
						fileExtension = "mp4"
					}
				} else {
					contentType = "video/mp4"
					fileExtension = "mp4"
				}
			} else {
				contentType = "image/jpeg"
				fileExtension = "jpg"
			}
			
			body.append("--\(boundary)\r\n".data(using: .utf8)!)
			body.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(key).\(fileExtension)\"\r\n".data(using: .utf8)!)
			body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
			body.append(data)
			body.append("\r\n".data(using: .utf8)!)
		}
		
		body.append("--\(boundary)--\r\n".data(using: .utf8)!)
		return body
	}
}

// MARK: - Response Models

struct UserResponse: Codable {
	let userId: String
	let name: String
	let username: String
	let email: String
	let profileImageURL: String?
	let backgroundImageURL: String?
	let birthMonth: String?
	let birthDay: String?
	let birthYear: String?
	let blockedUsers: [String]?
	let blockedCollectionIds: [String]?
	let hiddenPostIds: [String]?
	let starredPostIds: [String]?
	let collectionSortPreference: String?
	let customCollectionOrder: [String]?
	
	// Handle backend response - map uid (Firebase user ID) to userId
	enum CodingKeys: String, CodingKey {
		case userId = "uid"  // Backend uses "uid" for Firebase user ID
		case name
		case username
		case email
		case profileImageURL
		case backgroundImageURL
		case birthMonth
		case birthDay
		case birthYear
		case blockedUsers
		case blockedCollectionIds
		case hiddenPostIds
		case starredPostIds
		case collectionSortPreference
		case customCollectionOrder
	}
}

struct CollectionResponse: Codable {
	let id: String
	let name: String
	let description: String
	let type: String
	let isPublic: Bool
	let ownerId: String
	let ownerName: String
	let imageURL: String?
	let members: [String]
	let memberCount: Int
	let createdAt: String
}

struct PostResponse: Codable {
	let postId: String
	let collectionId: String
	let mediaURLs: [String]
}

// Response model for getting collection posts
struct PostsResponse: Codable {
	let posts: [PostData]
}

struct PostData: Codable {
	let id: String
	let title: String
	let collectionId: String
	let authorId: String
	let authorName: String
	let createdAt: String
	let firstMediaItem: PostMediaItem?
	let mediaItems: [PostMediaItem]?
	let caption: String?
	let allowDownload: Bool?
	let allowReplies: Bool?
	let taggedUsers: [String]?
}

struct PostMediaItem: Codable {
	let imageURL: String?
	let thumbnailURL: String?
	let videoURL: String?
	let videoDuration: Double?
	let isVideo: Bool?
}

// MARK: - API Errors

enum APIError: Error, LocalizedError {
	case invalidURL
	case invalidResponse
	case httpError(statusCode: Int, message: String)
	case encodingError
	case decodingError(Error)
	
	var errorDescription: String? {
		switch self {
		case .invalidURL:
			return "Invalid API URL"
		case .invalidResponse:
			return "Invalid response from server"
		case .httpError(let code, let message):
			return "HTTP \(code): \(message)"
		case .encodingError:
			return "Failed to encode request"
		case .decodingError(let error):
			return "Failed to decode response: \(error.localizedDescription)"
		}
	}
}

