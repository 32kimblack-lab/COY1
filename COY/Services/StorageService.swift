import Foundation
import UIKit
import FirebaseStorage
import FirebaseAuth
import AVFoundation

enum StorageError: Error {
	case uploadFailed
	case invalidImage
	case unauthorized
}

@MainActor
final class StorageService {
	static let shared = StorageService()
	private init() {}
	
	private let storage = Storage.storage()
	
	// MARK: - Delete Functions
	
	/// Delete a file from Firebase Storage by its URL
	func deleteFile(from urlString: String) async throws {
		guard !urlString.isEmpty else {
			print("⚠️ StorageService: Empty URL string provided")
			throw StorageError.uploadFailed
		}
		
		print("🗑️ StorageService: Attempting to delete file from URL: \(urlString)")
		
		// Firebase Storage URLs look like: https://firebasestorage.googleapis.com/v0/b/PROJECT.appspot.com/o/PATH%2FTO%2FFILE?alt=media&token=...
		guard let url = URL(string: urlString) else {
			print("❌ StorageService: Could not parse URL: \(urlString)")
			throw StorageError.uploadFailed
		}
		
		// Check if it's a Firebase Storage URL
		guard url.host?.contains("firebasestorage.googleapis.com") == true else {
			print("❌ StorageService: Not a Firebase Storage URL: \(urlString)")
			print("   Host: \(url.host ?? "nil")")
			throw StorageError.uploadFailed
		}
		
		// Extract the path from the URL
		// Firebase Storage URLs format: https://firebasestorage.googleapis.com/v0/b/BUCKET/o/PATH%2FTO%2FFILE?alt=media&token=...
		// The path might be URL-encoded (e.g., "chat_media%2Fimage.jpg")
		let pathComponents = url.pathComponents
		print("📋 StorageService: URL path components: \(pathComponents)")
		
		// Find the index of "o" in path components
		guard let oIndex = pathComponents.firstIndex(of: "o"),
			  oIndex + 1 < pathComponents.count else {
			print("❌ StorageService: Could not find 'o' in path components")
			print("   Path components: \(pathComponents)")
			print("   Full URL: \(urlString)")
			throw StorageError.uploadFailed
		}
		
		// Reconstruct the full path by joining all components after "o"
		// This handles URL-encoded paths that were split into multiple components
		let pathParts = pathComponents[(oIndex + 1)...]
		let encodedPath = pathParts.joined(separator: "/")
		
		// Decode the path (it might be URL-encoded like "chat_media%2Fimage.jpg")
		let decodedPath = encodedPath.removingPercentEncoding ?? encodedPath
		
		print("📁 StorageService: Extracted path: \(decodedPath)")
		print("   Encoded: \(encodedPath)")
		print("   Decoded: \(decodedPath)")
		
		let storageRef = storage.reference()
		let fileRef = storageRef.child(decodedPath)
		
		// Attempt to delete the file directly
		// Note: Firebase Storage delete() will succeed even if file doesn't exist
		// So we don't need to check existence first
		do {
			try await fileRef.delete()
			print("✅ StorageService: File deleted successfully from Storage!")
			print("   Path: \(decodedPath)")
			print("   Full URL: \(urlString)")
		} catch let error as NSError {
			print("❌ StorageService: CRITICAL ERROR - Failed to delete file from Storage")
			print("   Error domain: \(error.domain)")
			print("   Error code: \(error.code)")
			print("   Error description: \(error.localizedDescription)")
			print("   User info: \(error.userInfo)")
			print("   File path: \(decodedPath)")
			print("   Full URL: \(urlString)")
			// Re-throw the error so caller knows deletion failed
			throw error
		}
	}
	
	// MARK: - Upload Functions
	
	func uploadCollectionImage(_ image: UIImage, collectionId: String) async throws -> String {
		print("📤 StorageService: Starting collection image upload")
		print("   - Collection ID: \(collectionId)")
		
		// Verify user is authenticated
		guard Auth.auth().currentUser != nil else {
			print("❌ StorageService: User not authenticated")
			throw StorageError.uploadFailed
		}
		
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			print("❌ StorageService: Failed to convert image to JPEG data")
			throw StorageError.uploadFailed
		}
		
		let storageRef = storage.reference()
		let imageRef = storageRef.child("collection_images/\(collectionId).jpg")
		
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		// Upload to Firebase Storage
		let _ = try await imageRef.putDataAsync(imageData, metadata: metadata)
		
		// Get download URL
		let downloadURL = try await imageRef.downloadURL()
		print("✅ StorageService: Collection image uploaded successfully")
		print("   - Download URL: \(downloadURL.absoluteString)")
		return downloadURL.absoluteString
	}
	
	func uploadChatImage(_ image: UIImage, path: String) async throws -> String {
		guard Auth.auth().currentUser != nil else {
			throw StorageError.unauthorized
		}
		
		// Resize image to max 1920x1920 to reduce file size and upload time
		let resizedImage = resizeImageForChat(image, maxDimension: 1920)
		
		// Use lower compression quality for chat (0.7) to balance quality and file size
		guard let imageData = resizedImage.jpegData(compressionQuality: 0.7) else {
			throw StorageError.invalidImage
		}
		
		let storageRef = storage.reference()
		let imageRef = storageRef.child(path)
		
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		let _ = try await imageRef.putDataAsync(imageData, metadata: metadata)
		let downloadURL = try await imageRef.downloadURL()
		return downloadURL.absoluteString
	}
	
	// Helper function to resize images for chat
	private func resizeImageForChat(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
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
	
	func uploadChatVideo(_ videoURL: URL, path: String) async throws -> String {
		guard Auth.auth().currentUser != nil else {
			throw StorageError.unauthorized
		}
		
		// Check file size to decide if compression is needed
		let fileAttributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
		let fileSize = fileAttributes[.size] as? Int64 ?? 0
		let compressionThreshold: Int64 = 10 * 1024 * 1024 // 10MB - compress if larger
		
		let videoURLToUpload: URL
		let shouldCleanup: Bool
		
		if fileSize > compressionThreshold {
			// Compress large videos before upload
			videoURLToUpload = try await compressVideoForChat(videoURL: videoURL)
			shouldCleanup = true
		} else {
			// Small videos can be uploaded directly (faster)
			videoURLToUpload = videoURL
			shouldCleanup = false
		}
		
		// Use file upload instead of loading entire file into memory
		let storageRef = storage.reference()
		let videoRef = storageRef.child(path)
		
		let metadata = StorageMetadata()
		metadata.contentType = "video/mp4"
		
		// Upload from file URL directly (more memory efficient)
		let _ = try await videoRef.putFileAsync(from: videoURLToUpload, metadata: metadata)
		let downloadURL = try await videoRef.downloadURL()
		
		// Clean up temporary compressed video file if we created one
		if shouldCleanup {
			try? FileManager.default.removeItem(at: videoURLToUpload)
		}
		
		return downloadURL.absoluteString
	}
	
	// Helper function to compress videos for chat
	private func compressVideoForChat(videoURL: URL) async throws -> URL {
		let asset = AVAsset(url: videoURL)
		
		// Create export session with MediumQuality preset (good balance of quality and file size)
		guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
			throw StorageError.uploadFailed
		}
		
		// Create temporary output URL
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("mp4")
		
		exportSession.outputURL = outputURL
		exportSession.outputFileType = .mp4
		exportSession.shouldOptimizeForNetworkUse = true // Optimize for faster upload
		
		// Export video asynchronously
		await exportSession.export()
		
		guard exportSession.status == .completed else {
			if let error = exportSession.error {
				throw error
			}
			throw StorageError.uploadFailed
		}
		
		return outputURL
	}
}

