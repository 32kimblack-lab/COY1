import Foundation
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth
import UIKit
import AVFoundation
import Network

@MainActor
final class PostService {
	static let shared = PostService()
	private init() {}
	
	/// Create a post - saves to Firebase (source of truth)
	func createPost(
		collectionId: String,
		caption: String?,
		mediaItems: [CreatePostMediaItem],
		taggedUsers: [String]?,
		allowDownload: Bool,
		allowReplies: Bool,
		progressCallback: ((MediaUploadManager.UploadProgress) -> Void)? = nil
	) async throws -> String {
		guard let userId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get author name
		let authorName = try await getAuthorName(userId: userId)
		
		// Check connection before uploading
		guard ConnectionStateManager.shared.isConnected else {
			throw NSError(
				domain: "PostService",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "No internet connection. Please check your network and try again."]
			)
		}
		
		// OPTIMIZED: Use MediaUploadManager for parallel uploads with progress tracking
		// This provides: compression, parallel uploads, progress tracking, and concurrency control
		let mediaURLs = try await MediaUploadManager.shared.uploadMediaItems(mediaItems) { progress in
			// Progress callback - can be used for UI updates if needed
			print("📊 Upload progress: \(Int(progress.overallProgress * 100))% - \(progress.completedCount)/\(progress.totalCount) - \(progress.currentFileName)")
			// Forward to provided callback if available
			progressCallback?(progress)
		}
		
		guard !mediaURLs.isEmpty else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media items to post"])
		}
		
		// Save to Firebase Firestore FIRST (source of truth)
		let db = Firestore.firestore()
		
		// Get collection owner ID for permission checks (allows owner to delete posts)
		var collectionOwnerId = userId // Default to current user (for individual collections)
		if let collection = try? await CollectionService.shared.getCollection(collectionId: collectionId) {
			collectionOwnerId = collection.ownerId
		}
		
		let postData: [String: Any] = [
			"title": caption ?? "",
			"caption": caption ?? "",
			"collectionId": collectionId,
			"collectionOwnerId": collectionOwnerId, // CRITICAL: Allows collection owner to delete posts (required by Firestore rules)
			"authorId": userId,
			"authorName": authorName,
			"firstMediaItem": [
				"imageURL": (mediaURLs[0].imageURL ?? "") as Any,
				"thumbnailURL": (mediaURLs[0].thumbnailURL ?? "") as Any,
				"videoURL": (mediaURLs[0].videoURL ?? "") as Any,
				"videoDuration": (mediaURLs[0].videoDuration ?? 0) as Any,
				"isVideo": mediaURLs[0].isVideo
			],
			"mediaItems": mediaURLs.map { item in
				[
					"imageURL": (item.imageURL ?? "") as Any,
					"thumbnailURL": (item.thumbnailURL ?? "") as Any,
					"videoURL": (item.videoURL ?? "") as Any,
					"videoDuration": (item.videoDuration ?? 0) as Any,
					"isVideo": item.isVideo
				]
			},
			"allowDownload": allowDownload,
			"allowReplies": allowReplies,
			"taggedUsers": taggedUsers ?? [],
			"isPinned": false,
			"commentCount": 0, // OPTIMIZATION: Initialize comment count for efficient counting
			"createdAt": Timestamp()
		]
		
		print("🔍 createPost: Saving postData with allowDownload=\(allowDownload), allowReplies=\(allowReplies)")
		print("🔍 createPost: Full postData keys: \(postData.keys.sorted())")
		
		// Save to Firestore with retry logic
		let docRef = try await FirebaseRetryManager.shared.executeWithRetry(
			operation: {
				// CRITICAL FIX: Track Firestore writes for usage monitoring
				FirebaseUsageMonitor.shared.trackWrite(count: 1)
				return try await db.collection("posts").addDocument(data: postData)
			},
			operationName: "Save post to Firestore"
		)
		let postId = docRef.documentID
		
		print("✅ Post saved to Firebase: \(postId) with allowDownload=\(allowDownload), allowReplies=\(allowReplies)")
		
		// Send notification for real-time updates (replaces expensive listeners)
		await MainActor.run {
			NotificationCenter.default.post(
				name: Notification.Name("PostCreated"),
				object: postId,
				userInfo: ["collectionId": collectionId]
			)
			// Also notify collection-specific update
			NotificationCenter.default.post(
				name: Notification.Name("CollectionPostsUpdated"),
				object: collectionId
			)
		}
		
		// Verify the values were saved correctly
		do {
			let savedDoc = try await db.collection("posts").document(postId).getDocument()
			if let savedData = savedDoc.data() {
				let savedAllowDownload = savedData["allowDownload"] as? Bool
				let savedAllowReplies = savedData["allowReplies"] as? Bool
				print("🔍 Verification: Saved post \(postId) has:")
				print("   - allowDownload in Firestore: \(savedAllowDownload?.description ?? "nil")")
				print("   - allowReplies in Firestore: \(savedAllowReplies?.description ?? "nil")")
				if savedAllowDownload != allowDownload || savedAllowReplies != allowReplies {
					print("❌ ERROR: Values mismatch! Expected allowDownload=\(allowDownload), allowReplies=\(allowReplies)")
				}
			}
		} catch {
			print("⚠️ Could not verify saved post: \(error)")
		}
		
		return postId
	}
	
	private func getAuthorName(userId: String) async throws -> String {
		// Try to get from UserService first
		if let user = try? await UserService.shared.getUser(userId: userId) {
			return user.name
		}
		
		// Fallback to Firestore
		let db = Firestore.firestore()
		let doc = try await db.collection("users").document(userId).getDocument()
		if let data = doc.data(), let name = data["name"] as? String, !name.isEmpty {
			return name
		}
		
		return "Unknown"
	}
	
	private func uploadImage(_ image: UIImage, path: String) async throws -> String {
		// OPTIMIZATION: Resize large images before compression (faster upload, smaller files)
		let maxDimension: CGFloat = 2048 // Resize to max 2048px (good quality, reasonable size)
		let resizedImage = resizeImageIfNeeded(image, maxDimension: maxDimension)
		
		// OPTIMIZATION: Use more aggressive compression (0.7 instead of 0.8) for faster uploads
		guard let imageData = resizedImage.jpegData(compressionQuality: 0.7) else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image"])
		}
		
		// Check image size (10MB limit for images)
		let maxImageSize: Int = 10 * 1024 * 1024 // 10MB
		if imageData.count > maxImageSize {
			// Compress further if too large
			guard let compressedData = resizedImage.jpegData(compressionQuality: 0.5) else {
				throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image is too large and compression failed"])
			}
			if compressedData.count > maxImageSize {
				throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image file is too large. Maximum size is 10MB"])
			}
		}
		
		let storage = Storage.storage()
		let imageRef = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		let _ = try await imageRef.putDataAsync(imageData, metadata: metadata)
		let downloadURL = try await imageRef.downloadURL()
		return downloadURL.absoluteString
	}
	
	// CRITICAL FIX: Compress videos before upload (59MB → 10-20MB = 3-5x faster upload)
	private func compressVideoIfNeeded(videoURL: URL) async throws -> URL {
		let fileAttributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
		let fileSize = fileAttributes[.size] as? Int64 ?? 0
		let compressionThreshold: Int64 = 15 * 1024 * 1024 // 15MB - compress if larger
		let maxFileSize: Int64 = 100 * 1024 * 1024 // 100MB hard limit
		
		// Check hard limit first
		if fileSize > maxFileSize {
			throw NSError(
				domain: "PostService",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "Video file is too large. Maximum size is 100MB. Your file is \(String(format: "%.1f", Double(fileSize) / 1024 / 1024))MB"]
			)
		}
		
		// If video is small enough, upload directly (faster)
		if fileSize <= compressionThreshold {
			return videoURL
		}
		
		// Compress large videos (59MB → ~15-20MB = much faster upload)
		print("📹 PostService: Compressing video from \(String(format: "%.1f", Double(fileSize) / 1024 / 1024))MB...")
		
		let asset = AVAsset(url: videoURL)
		guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create video export session"])
		}
		
		// Create temporary output URL
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("mp4")
		
		exportSession.outputURL = outputURL
		exportSession.outputFileType = .mp4
		exportSession.shouldOptimizeForNetworkUse = true // Optimize for faster upload
		
		// Export video (this compresses it)
		await exportSession.export()
		
		guard exportSession.status == .completed else {
			if let error = exportSession.error {
				throw error
			}
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video compression failed"])
		}
		
		// Check compressed file size
		let compressedAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
		let compressedSize = compressedAttributes[.size] as? Int64 ?? 0
		print("✅ PostService: Video compressed to \(String(format: "%.1f", Double(compressedSize) / 1024 / 1024))MB (was \(String(format: "%.1f", Double(fileSize) / 1024 / 1024))MB)")
		
		return outputURL
	}
	
	private func uploadVideo(_ videoURL: URL, path: String) async throws -> String {
		// Use file upload instead of loading entire video into memory (CRITICAL for scalability)
		// This prevents memory crashes with large videos and concurrent uploads
		let storage = Storage.storage()
		let videoRef = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "video/mp4"
		
		// Upload from file URL directly - much more memory efficient
		let _ = try await videoRef.putFileAsync(from: videoURL, metadata: metadata)
		let downloadURL = try await videoRef.downloadURL()
		return downloadURL.absoluteString
	}
	
	// Helper function to resize images before upload (faster, smaller files)
	private func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
		let size = image.size
		
		// If image is already smaller than max dimension, return original
		if size.width <= maxDimension && size.height <= maxDimension {
			return image
		}
		
		// Calculate new size maintaining aspect ratio
		let aspectRatio = size.width / size.height
		var newSize: CGSize
		
		if size.width > size.height {
			newSize = CGSize(width: maxDimension, height: maxDimension / aspectRatio)
		} else {
			newSize = CGSize(width: maxDimension * aspectRatio, height: maxDimension)
		}
		
		// Resize image
		UIGraphicsBeginImageContextWithOptions(newSize, false, 0.8) // Use 0.8 scale for better performance
		image.draw(in: CGRect(origin: .zero, size: newSize))
		let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
		UIGraphicsEndImageContext()
		
		return resizedImage ?? image
	}
	
	private func generateAndUploadThumbnail(videoURL: URL, path: String) async throws -> String {
		let asset = AVURLAsset(url: videoURL)
		let imageGenerator = AVAssetImageGenerator(asset: asset)
		imageGenerator.appliesPreferredTrackTransform = true
		imageGenerator.maximumSize = CGSize(width: 300, height: 300)
		
		let time = CMTime(seconds: 0.1, preferredTimescale: 600)
		let cgImage = try await imageGenerator.image(at: time).image
		let thumbnail = UIImage(cgImage: cgImage)
		
		return try await uploadImage(thumbnail, path: path)
	}
	
	// MARK: - Star/Unstar Post
	func toggleStarPost(postId: String, isStarred: Bool) async throws {
		guard let userId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		let db = Firestore.firestore()
		let starsRef = db.collection("posts").document(postId).collection("stars").document(userId)
		
		if isStarred {
			// Star the post
			try await starsRef.setData([
				"userId": userId,
				"starredAt": Timestamp()
			])
			
			// Add to user's starredPostIds
			let userRef = db.collection("users").document(userId)
			try await userRef.updateData([
				"starredPostIds": FieldValue.arrayUnion([postId])
			])
			
			// Send star notification
			Task {
				do {
					// Get post data to find owner and collection info
					let postDoc = try await db.collection("posts").document(postId).getDocument()
					guard let postData = postDoc.data(),
						  let postOwnerId = postData["authorId"] as? String,
						  let collectionId = postData["collectionId"] as? String else {
						return
					}
					
					// Get collection name
					var collectionName = "Me"
					if !collectionId.isEmpty {
						if let collectionDoc = try? await db.collection("collections").document(collectionId).getDocument(),
						   let collectionData = collectionDoc.data(),
						   let name = collectionData["name"] as? String {
							collectionName = name
						}
					}
					
					// Get post thumbnail/image - prioritize imageURL for images, thumbnailURL for videos
					let mediaItems = postData["mediaItems"] as? [[String: Any]] ?? []
					let firstMedia = mediaItems.first
					
					// For images: use imageURL directly (like videos use thumbnailURL)
					// For videos: use thumbnailURL if available, fallback to imageURL
					let isVideo = firstMedia?["isVideo"] as? Bool ?? false
					let thumbnailURL: String?
					if isVideo {
						// Video: prefer thumbnailURL, fallback to imageURL
						thumbnailURL = firstMedia?["thumbnailURL"] as? String ?? firstMedia?["imageURL"] as? String
					} else {
						// Image: use imageURL directly (images don't have thumbnailURL, they use imageURL)
						thumbnailURL = firstMedia?["imageURL"] as? String
					}
					
					// Get user info who starred
					guard let starUser = try? await UserService.shared.getUser(userId: userId) else {
						return
					}
					
					// Send notification
					try await NotificationService.shared.sendCollectionStarNotification(
						postId: postId,
						collectionId: collectionId,
						collectionName: collectionName,
						starUserId: userId,
						starUsername: starUser.username,
						starProfileImageURL: starUser.profileImageURL,
						postThumbnailURL: thumbnailURL,
						postOwnerId: postOwnerId
					)
				} catch {
					print("❌ Error sending star notification: \(error)")
				}
			}
		} else {
			// Unstar the post
			try await starsRef.delete()
			
			// Remove from user's starredPostIds
			let userRef = db.collection("users").document(userId)
			try await userRef.updateData([
				"starredPostIds": FieldValue.arrayRemove([postId])
			])
		}
		
		// Post notification to update UI
		Task { @MainActor in
			NotificationCenter.default.post(
				name: NSNotification.Name(isStarred ? "PostStarred" : "PostUnstarred"),
				object: postId,
				userInfo: ["userId": userId]
			)
		}
	}
	
	// Check if current user has starred a post
	func isPostStarred(postId: String) async throws -> Bool {
		guard let userId = Auth.auth().currentUser?.uid else { return false }
		
		let db = Firestore.firestore()
		let starDoc = try await db.collection("posts")
			.document(postId)
			.collection("stars")
			.document(userId)
			.getDocument()
		
		return starDoc.exists
	}
	
	// MARK: - Paginated Post Loading
	/// Get posts for a collection with pagination
	/// - Parameters:
	///   - collectionId: The collection ID
	///   - limit: Number of posts to fetch
	///   - lastDocument: Last document from previous page (nil for first page)
	///   - sortBy: Sort option ("Newest to Oldest", "Oldest to Newest", "Pinned First")
	/// - Returns: Tuple of (posts, lastDocument, hasMore)
	func getCollectionPostsPaginated(
		collectionId: String,
		limit: Int = 20,
		lastDocument: DocumentSnapshot? = nil,
		sortBy: String = "Newest to Oldest"
	) async throws -> (posts: [CollectionPost], lastDocument: DocumentSnapshot?, hasMore: Bool) {
		let db = Firestore.firestore()
		
		// Build base query
		var query: Query = db.collection("posts")
			.whereField("collectionId", isEqualTo: collectionId)
		
		// Add ordering based on sort option
		switch sortBy {
		case "Pinned First":
			// For pinned first, we need to sort by isPinned (descending) then createdAt
			// Note: This requires a composite index
			query = query
				.order(by: "isPinned", descending: true)
				.order(by: "createdAt", descending: true)
		case "Oldest to Newest":
			query = query.order(by: "createdAt", descending: false)
		default: // "Newest to Oldest"
			query = query.order(by: "createdAt", descending: true)
		}
		
		// Add pagination
		if let lastDoc = lastDocument {
			query = query.start(afterDocument: lastDoc)
		}
		query = query.limit(to: limit)
		
		let snapshot = try await query.getDocuments()
		
		// CRITICAL FIX: Track Firestore reads for usage monitoring
		// Each document read counts as 1 read operation
		FirebaseUsageMonitor.shared.trackRead(count: snapshot.documents.count)
		
		var posts: [CollectionPost] = []
		for doc in snapshot.documents {
			if let post = try? parsePost(from: doc) {
				posts.append(post)
			}
		}
		
		let lastDoc = snapshot.documents.last
		let hasMore = snapshot.documents.count == limit
		
		return (posts, lastDoc, hasMore)
	}
	
	/// Parse a post from Firestore document
	func parsePost(from doc: QueryDocumentSnapshot) throws -> CollectionPost {
		let data = doc.data()
		
		// Parse all mediaItems
		var allMediaItems: [MediaItem] = []
		if let mediaItemsArray = data["mediaItems"] as? [[String: Any]] {
			allMediaItems = mediaItemsArray.compactMap { mediaData in
				MediaItem(
					imageURL: mediaData["imageURL"] as? String,
					thumbnailURL: mediaData["thumbnailURL"] as? String,
					videoURL: mediaData["videoURL"] as? String,
					videoDuration: mediaData["videoDuration"] as? Double,
					isVideo: mediaData["isVideo"] as? Bool ?? false
				)
			}
		}
		
		// Fallback to firstMediaItem if mediaItems array is empty
		if allMediaItems.isEmpty, let firstMediaData = data["firstMediaItem"] as? [String: Any] {
			let firstItem = MediaItem(
				imageURL: firstMediaData["imageURL"] as? String,
				thumbnailURL: firstMediaData["thumbnailURL"] as? String,
				videoURL: firstMediaData["videoURL"] as? String,
				videoDuration: firstMediaData["videoDuration"] as? Double,
				isVideo: firstMediaData["isVideo"] as? Bool ?? false
			)
			allMediaItems = [firstItem]
		}
		
		let firstMediaItem = allMediaItems.first
		let isPinned = data["isPinned"] as? Bool ?? false
		let caption = data["caption"] as? String
		
		let titleValue: String = {
			if let title = data["title"] as? String, !title.isEmpty {
				return title
			}
			return caption ?? ""
		}()
		
		return CollectionPost(
			id: doc.documentID,
			title: titleValue,
			collectionId: data["collectionId"] as? String ?? "",
			authorId: data["authorId"] as? String ?? "",
			authorName: data["authorName"] as? String ?? "",
			createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
			firstMediaItem: firstMediaItem,
			mediaItems: allMediaItems,
			isPinned: isPinned,
			pinnedAt: (data["pinnedAt"] as? Timestamp)?.dateValue(),
			caption: caption,
			allowReplies: data["allowReplies"] as? Bool ?? true,
			allowDownload: data["allowDownload"] as? Bool ?? false,
			taggedUsers: data["taggedUsers"] as? [String] ?? []
		)
	}
	
	// Get comment count for a post
	// OPTIMIZED: Check if post document has commentCount field first (maintained by Cloud Function or on comment create/delete)
	// If not available, use a lightweight approach instead of fetching all comments
	func getCommentCount(postId: String) async throws -> Int {
		let db = Firestore.firestore()
		
		// First, try to get count from post document (if maintained)
		// This is the most efficient approach - O(1) read instead of O(n)
		let postDoc = try await db.collection("posts").document(postId).getDocument()
		if let data = postDoc.data(),
		   let commentCount = data["commentCount"] as? Int {
			return commentCount
		}
		
		// Fallback: If commentCount field doesn't exist, we need to count
		// CRITICAL FIX: Don't fetch all comments! Use a paginated count approach
		// For now, return 0 if count field doesn't exist
		// NOTE: In production, you should maintain commentCount in post document via Cloud Function
		// This prevents the expensive operation of counting all comments
		return 0
	}
	
	// Download post media (returns URL for download)
	func downloadPostMedia(postId: String) async throws -> [URL] {
		let db = Firestore.firestore()
		let postDoc = try await db.collection("posts").document(postId).getDocument()
		
		guard let data = postDoc.data(),
			  let mediaItems = data["mediaItems"] as? [[String: Any]] else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Post not found or has no media"])
		}
		
		var downloadURLs: [URL] = []
		for mediaItem in mediaItems {
			if let imageURL = mediaItem["imageURL"] as? String, !imageURL.isEmpty,
			   let url = URL(string: imageURL) {
				downloadURLs.append(url)
			} else if let videoURL = mediaItem["videoURL"] as? String, !videoURL.isEmpty,
					  let url = URL(string: videoURL) {
				downloadURLs.append(url)
			}
		}
		
		return downloadURLs
	}
	
	// Get post media items with type information
	func getPostMediaItems(postId: String) async throws -> [(url: URL, isVideo: Bool)] {
		let db = Firestore.firestore()
		let postDoc = try await db.collection("posts").document(postId).getDocument()
		
		guard let data = postDoc.data(),
			  let mediaItems = data["mediaItems"] as? [[String: Any]] else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Post not found or has no media"])
		}
		
		var mediaInfo: [(url: URL, isVideo: Bool)] = []
		for mediaItem in mediaItems {
			if let imageURL = mediaItem["imageURL"] as? String, !imageURL.isEmpty,
			   let url = URL(string: imageURL) {
				mediaInfo.append((url: url, isVideo: false))
			} else if let videoURL = mediaItem["videoURL"] as? String, !videoURL.isEmpty,
					  let url = URL(string: videoURL) {
				mediaInfo.append((url: url, isVideo: true))
			}
		}
		
		return mediaInfo
	}
	
	// Get tagged users for a post
	func getTaggedUsers(postId: String) async throws -> [UserService.AppUser] {
		let db = Firestore.firestore()
		let postDoc = try await db.collection("posts").document(postId).getDocument()
		
		guard let data = postDoc.data(),
			  let taggedUserIds = data["taggedUsers"] as? [String] else {
			return []
		}
		
		var taggedUsers: [UserService.AppUser] = []
		for userId in taggedUserIds {
			if let user = try? await UserService.shared.getUser(userId: userId) {
				taggedUsers.append(user)
			}
		}
		
		return taggedUsers
	}
	
	// Check if user allows downloads (from user settings)
	func getUserDownloadEnabled() async throws -> Bool {
		guard let userId = Auth.auth().currentUser?.uid else { return false }
		
		let db = Firestore.firestore()
		let userDoc = try await db.collection("users").document(userId).getDocument()
		
		if let data = userDoc.data() {
			return data["allowDownload"] as? Bool ?? false
		}
		
		return false
	}
}

