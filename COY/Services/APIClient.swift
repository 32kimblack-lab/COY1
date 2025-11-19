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
		try validateResponse(response, data: data)
		return try JSONDecoder().decode(UserResponse.self, from: data)
	}
	
	/// Get user profile
	func getUser(userId: String) async throws -> UserResponse {
		let request = try await createRequest(endpoint: "/users/\(userId)", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
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
		try validateResponse(response, data: data)
		return try JSONDecoder().decode(CollectionResponse.self, from: data)
	}
	
	/// Get user's collections
	func getUserCollections(userId: String) async throws -> [CollectionResponse] {
		let request = try await createRequest(endpoint: "/users/\(userId)/collections", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
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
		try validateResponse(response, data: data)
		return try JSONDecoder().decode(PostResponse.self, from: data)
	}
	
	/// Create a post with Firebase Storage URLs (no file upload needed)
	func createPostWithURLs(
		collectionId: String,
		caption: String?,
		mediaURLs: [MediaItem],
		taggedUsers: [String]?,
		allowDownload: Bool,
		allowReplies: Bool
	) async throws -> PostResponse {
		var request = try await createRequest(endpoint: "/collections/\(collectionId)/posts/urls", method: "POST")
		
		var body: [String: Any] = [
			"allowDownload": allowDownload,
			"allowReplies": allowReplies
		]
		
		if let caption = caption, !caption.isEmpty {
			body["caption"] = caption
		}
		
		if let taggedUsers = taggedUsers, !taggedUsers.isEmpty {
			body["taggedUsers"] = taggedUsers
		}
		
		// Convert MediaItem array to the format backend expects
		body["mediaItems"] = mediaURLs.map { item in
			var mediaDict: [String: Any] = [
				"isVideo": item.isVideo
			]
			if let imageURL = item.imageURL {
				mediaDict["imageURL"] = imageURL
			}
			if let thumbnailURL = item.thumbnailURL {
				mediaDict["thumbnailURL"] = thumbnailURL
			}
			if let videoURL = item.videoURL {
				mediaDict["videoURL"] = videoURL
			}
			if let duration = item.videoDuration {
				mediaDict["videoDuration"] = duration
			}
			return mediaDict
		}
		
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		return try JSONDecoder().decode(PostResponse.self, from: data)
	}
	
	/// Get posts for a collection
	func getCollectionPosts(collectionId: String) async throws -> [CollectionPost] {
		print("📡 Fetching posts for collection: \(collectionId)")
		let request = try await createRequest(endpoint: "/collections/\(collectionId)/posts", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		
		// Log response for debugging
		if let httpResponse = response as? HTTPURLResponse {
			print("📡 Get collection posts response: \(httpResponse.statusCode) for collection: \(collectionId)")
			if httpResponse.statusCode != 200 {
				if let errorData = String(data: data, encoding: .utf8) {
					print("❌ Error response: \(errorData)")
				}
			}
		}
		
		try validateResponse(response, data: data)
		
		let postsResponse = try JSONDecoder().decode(PostsResponse.self, from: data)
		print("✅ Decoded \(postsResponse.posts.count) posts for collection: \(collectionId)")
		
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
				mediaItems: allMediaItems,
				isPinned: postData.isPinned ?? false,
				caption: postData.caption
			)
		}
	}
	
	/// Get visible collections (for home/search feeds)
	func getVisibleCollections() async throws -> [CollectionResponse] {
		let request = try await createRequest(endpoint: "/collections/visible", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
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
		
		try validateResponse(response, data: data)
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
		
		try validateResponse(response, data: data)
		
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
		try validateResponse(response, data: data)
		return try JSONDecoder().decode(CollectionResponse.self, from: data)
	}
	
	/// Update a collection
	func updateCollection(
		collectionId: String,
		name: String? = nil,
		description: String? = nil,
		image: Data? = nil,
		imageURL: String? = nil,
		isPublic: Bool? = nil,
		allowedUsers: [String]? = nil,
		deniedUsers: [String]? = nil
	) async throws -> CollectionResponse {
		var files: [(data: Data, fieldName: String, fileName: String, mimeType: String)] = []
		if let image = image {
			files.append((image, "image", "collection.jpg", "image/jpeg"))
		}
		
		var body: [String: Any] = [:]
		
		// CRITICAL FIX: Only include non-empty strings, convert empty strings to nil
		if let nameValue = name, !nameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			body["name"] = nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		if let descriptionValue = description, !descriptionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			body["description"] = descriptionValue.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		// Include imageURL if provided (from Firebase Storage)
		if let imageURL = imageURL, !imageURL.isEmpty {
			body["imageURL"] = imageURL
			print("🔧 APIClient.updateCollection: Including imageURL from Firebase Storage")
		}
		
		// CRITICAL: Always include isPublic if it's provided (even if false)
		if let isPublicValue = isPublic {
			body["isPublic"] = isPublicValue  // Send as Bool directly
			print("🔧 APIClient.updateCollection: Including isPublic=\(isPublicValue) (Bool)")
		} else {
			print("🔧 APIClient.updateCollection: isPublic is nil - not updating visibility")
		}
		
		// CRITICAL FIX: Always send arrays if they're provided (even if empty)
		// Backend expects arrays, not nil
		if let allowedUsers = allowedUsers {
			body["allowedUsers"] = allowedUsers  // Send even if empty array
		}
		
		if let deniedUsers = deniedUsers {
			body["deniedUsers"] = deniedUsers  // Send even if empty array
		}
		
		print("🔧 APIClient.updateCollection: Full request body: \(body)")
		
		// CRITICAL: Ensure body is not empty or backend might reject
		if body.isEmpty {
			print("⚠️ APIClient.updateCollection: Body is empty - this might cause 400 error")
			// Don't send empty body - return error or send a minimal update
			throw NSError(domain: "APIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "No fields to update"])
		}
		
		var request = try await createRequest(endpoint: "/collections/\(collectionId)", method: "PUT")
		
		if !files.isEmpty {
			// Use multipart form data if we have files
			var formData: [String: String] = [:]
			for (key, value) in body {
				if let stringValue = value as? String {
					formData[key] = stringValue
				} else if let boolValue = value as? Bool {
					formData[key] = String(boolValue)
				} else if let arrayValue = value as? [String] {
					formData[key] = arrayValue.joined(separator: ",")
				}
			}
			
			var imageDataDict: [String: Data] = [:]
			for file in files {
				formData[file.fieldName] = file.fieldName
				imageDataDict[file.fieldName] = file.data
			}
			
			request.httpBody = try createMultipartBody(formData: formData, media: imageDataDict)
			request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		} else {
			// Use JSON if no files
			request.httpBody = try JSONSerialization.data(withJSONObject: body)
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		return try JSONDecoder().decode(CollectionResponse.self, from: data)
	}
	
	/// Update user preferences
	func updateUser(
		userId: String,
		collectionSortPreference: String? = nil,
		customCollectionOrder: [String]? = nil
	) async throws -> UserResponse {
		// Use PUT method as specified in backend requirements
		var request = try await createRequest(endpoint: "/users/\(userId)", method: "PUT")
		
		var body: [String: Any] = [:]
		if let sortPreference = collectionSortPreference {
			body["collectionSortPreference"] = sortPreference
		}
		if let customOrder = customCollectionOrder {
			body["customCollectionOrder"] = customOrder
		}
		
		// Ensure body is not empty
		guard !body.isEmpty else {
			throw APIError.httpError(statusCode: 400, message: "No data to update")
		}
		
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		
		print("📤 PUT /api/users/\(userId) with body: \(body)")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		if let httpResponse = response as? HTTPURLResponse {
			print("📥 Response status: \(httpResponse.statusCode)")
			if httpResponse.statusCode == 404 {
				throw APIError.httpError(statusCode: 404, message: "User not found in backend. User may need to be created first.")
			}
		}
		
		try validateResponse(response, data: data)
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
		} else {
			print("⚠️ No Firebase token available - request will fail authentication")
		}
		
		return request
	}
	
	/// Get Firebase Auth ID token for backend authentication
	private func getFirebaseAuthToken() async throws -> String? {
		guard let user = Auth.auth().currentUser else {
			print("⚠️ No authenticated user found")
			return nil
		}
		
		let token = try await user.getIDToken()
		return token
	}
	
	private func validateResponse(_ response: URLResponse, data: Data? = nil) throws {
		guard let httpResponse = response as? HTTPURLResponse else {
			throw APIError.invalidResponse
		}
		
		guard (200...299).contains(httpResponse.statusCode) else {
			var errorMessage = "Request failed"
			if let data = data, let errorString = String(data: data, encoding: .utf8) {
				errorMessage = errorString
				print("❌ Backend API Error (\(httpResponse.statusCode)): \(errorString)")
			} else {
				print("❌ Backend API Error (\(httpResponse.statusCode)): No error details available")
			}
			throw APIError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
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
	
	// MARK: - Post Management Endpoints
	
	/// Delete a post
	func deletePost(postId: String) async throws {
		let request = try await createRequest(endpoint: "/posts/\(postId)", method: "DELETE")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
	}
	
	/// Toggle post pin status
	func togglePostPin(postId: String, isPinned: Bool) async throws -> PostResponse {
		var request = try await createRequest(endpoint: "/posts/\(postId)/pin", method: "PATCH")
		
		let body: [String: Any] = ["isPinned": isPinned]
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		return try JSONDecoder().decode(PostResponse.self, from: data)
	}
	
	/// Get notifications
	func getNotifications() async throws -> [NotificationData] {
		let request = try await createRequest(endpoint: "/notifications", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		return try JSONDecoder().decode([NotificationData].self, from: data)
	}
	
	// MARK: - Collection Member Management
	
	/// Promote a member to admin (only Owner can do this)
	func promoteMemberToAdmin(collectionId: String, memberId: String) async throws {
		print("👤 APIClient: Promoting member \(memberId) to admin in collection \(collectionId)")
		let request = try await createRequest(endpoint: "/collections/\(collectionId)/members/\(memberId)/promote", method: "POST")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		print("✅ APIClient: Member promoted successfully")
	}
	
	/// Remove a member from collection (Owner and Admins can do this)
	func removeMemberFromCollection(collectionId: String, memberId: String) async throws {
		print("🗑️ APIClient: Removing member \(memberId) from collection \(collectionId)")
		let request = try await createRequest(endpoint: "/collections/\(collectionId)/members/\(memberId)", method: "DELETE")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		print("✅ APIClient: Member removed successfully")
	}
	
	/// Delete a collection (soft delete - only owner can do this)
	func deleteCollection(collectionId: String) async throws {
		print("🗑️ APIClient: Deleting collection \(collectionId)")
		let request = try await createRequest(endpoint: "/collections/\(collectionId)", method: "DELETE")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		print("✅ APIClient: Collection deleted successfully")
	}
	
	/// Leave a collection (member/admin can leave, but not owner)
	func leaveCollection(collectionId: String) async throws {
		print("👋 APIClient: Leaving collection \(collectionId)")
		let request = try await createRequest(endpoint: "/collections/\(collectionId)/leave", method: "POST")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response, data: data)
		print("✅ APIClient: Left collection successfully")
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
	let allowedUsers: [String]?
	let deniedUsers: [String]?
	let owners: [String]?
	let admins: [String]? // Admins promoted by Owner
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
	let isPinned: Bool?
}

struct PostMediaItem: Codable {
	let imageURL: String?
	let thumbnailURL: String?
	let videoURL: String?
	let videoDuration: Double?
	let isVideo: Bool?
}

// MARK: - Notification Models

struct NotificationData: Codable {
	let id: String
	let type: NotificationType
	let fromUserId: String
	let toUserId: String
	let collectionId: String?
	let postId: String?
	let message: String?
	let createdAt: String
	let isRead: Bool
}

enum NotificationType: String, Codable {
	case collectionInvite = "collectionInvite"
	case follow = "follow"
	case postLike = "postLike"
	case postComment = "postComment"
	case collectionRequest = "collectionRequest"
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

