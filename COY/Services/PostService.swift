import Foundation
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth
import UIKit
import AVFoundation

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
		allowReplies: Bool
	) async throws -> String {
		guard let userId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Get author name
		let authorName = try await getAuthorName(userId: userId)
		
		// Upload all media to Firebase Storage FIRST
		var mediaURLs: [MediaItem] = []
		for item in mediaItems {
			if let image = item.image {
				// Upload image to Firebase Storage
				let imageURL = try await uploadImage(image, path: "posts/\(UUID().uuidString).jpg")
				mediaURLs.append(MediaItem(
					imageURL: imageURL,
					thumbnailURL: nil,
					videoURL: nil,
					videoDuration: nil,
					isVideo: false
				))
			} else if let videoURL = item.videoURL {
				// Upload video to Firebase Storage
				let videoStorageURL = try await uploadVideo(videoURL, path: "posts/\(UUID().uuidString).mp4")
				// Generate thumbnail for video
				let thumbnailURL = try? await generateAndUploadThumbnail(videoURL: videoURL, path: "posts/thumbnails/\(UUID().uuidString).jpg")
				mediaURLs.append(MediaItem(
					imageURL: nil,
					thumbnailURL: thumbnailURL,
					videoURL: videoStorageURL,
					videoDuration: item.videoDuration,
					isVideo: true
				))
			}
		}
		
		guard !mediaURLs.isEmpty else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media items to post"])
		}
		
		// Save to Firebase Firestore FIRST (source of truth)
		let db = Firestore.firestore()
		let postData: [String: Any] = [
			"title": caption ?? "",
			"caption": caption ?? "",
			"collectionId": collectionId,
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
			"createdAt": Timestamp()
		]
		
		let docRef = try await db.collection("posts").addDocument(data: postData)
		let postId = docRef.documentID
		
		print("✅ Post saved to Firebase: \(postId)")
		
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
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image"])
		}
		
		let storage = Storage.storage()
		let imageRef = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		let _ = try await imageRef.putDataAsync(imageData, metadata: metadata)
		let downloadURL = try await imageRef.downloadURL()
		return downloadURL.absoluteString
	}
	
	private func uploadVideo(_ videoURL: URL, path: String) async throws -> String {
		let videoData = try Data(contentsOf: videoURL)
		let storage = Storage.storage()
		let videoRef = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "video/mp4"
		let _ = try await videoRef.putDataAsync(videoData, metadata: metadata)
		let downloadURL = try await videoRef.downloadURL()
		return downloadURL.absoluteString
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
	
	// Get comment count for a post
	func getCommentCount(postId: String) async throws -> Int {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("posts")
			.document(postId)
			.collection("comments")
			.getDocuments()
		
		return snapshot.documents.count
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

