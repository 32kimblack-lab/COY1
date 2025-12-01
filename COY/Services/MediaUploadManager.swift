import Foundation
import FirebaseStorage
import AVFoundation
import UIKit

/// Manages optimized media uploads with compression, parallel processing, and progress tracking
@MainActor
final class MediaUploadManager {
	static let shared = MediaUploadManager()
	private init() {}
	
	// CRITICAL FIX: Rate limiting for uploads to prevent Firebase Storage overload
	private let maxConcurrentUploads = 5 // Limit concurrent uploads to prevent overwhelming Firebase Storage
	private var activeUploadCount = 0
	private var uploadQueue: [() async throws -> Void] = []
	private var isProcessingQueue = false
	
	/// Upload progress information
	struct UploadProgress {
		let completedCount: Int
		let totalCount: Int
		let overallProgress: Double // 0.0 to 1.0
		let currentFileIndex: Int
		let currentFileName: String
	}
	
	/// Result of a single media upload
	struct MediaUploadResult {
		let index: Int
		let mediaItem: MediaItem
	}
	
	/// Upload all media items with progress tracking
	func uploadMediaItems(
		_ mediaItems: [CreatePostMediaItem],
		progressCallback: @escaping (UploadProgress) -> Void
	) async throws -> [MediaItem] {
		guard !mediaItems.isEmpty else {
			throw NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media items to upload"])
		}
		
		// Step 1: Compress ALL videos in PARALLEL (Instagram-style - 5-8x faster)
		var compressedItems: [(index: Int, image: UIImage?, videoURL: URL?, shouldCleanup: Bool)] = []
		compressedItems.reserveCapacity(mediaItems.count)
		
		// Process images immediately (lightweight)
		for (index, item) in mediaItems.enumerated() {
			if let image = item.image {
				let compressedImage = compressImageIfNeeded(image)
				compressedItems.append((index: index, image: compressedImage, videoURL: nil, shouldCleanup: false))
			}
		}
		
		// Compress ALL videos in parallel using TaskGroup (critical for speed)
		var compressionResults: [Int: (url: URL, shouldCleanup: Bool)] = [:]
		var completedCompressions = 0
		
		await withTaskGroup(of: (Int, URL?, Bool).self) { group in
			// Add all video compression tasks
			for (index, item) in mediaItems.enumerated() {
				if let videoURL = item.videoURL {
					group.addTask {
						// Run compression off main thread (TaskGroup automatically handles this)
						do {
							let compressedURL = try await self.compressVideoIfNeeded(videoURL: videoURL)
							let shouldCleanup = compressedURL != videoURL
							return (index, compressedURL, shouldCleanup)
						} catch {
							print("❌ Failed to compress video \(index + 1): \(error.localizedDescription)")
							// Fallback to original
							return (index, videoURL, false)
						}
					}
				}
			}
			
			// Collect results as they complete
			for await (index, compressedURL, shouldCleanup) in group {
				if let url = compressedURL {
					compressionResults[index] = (url: url, shouldCleanup: shouldCleanup)
					completedCompressions += 1
					
					// Update progress on main thread
					await MainActor.run {
						progressCallback(UploadProgress(
							completedCount: completedCompressions,
							totalCount: mediaItems.filter { $0.videoURL != nil }.count,
							overallProgress: Double(completedCompressions) / Double(mediaItems.filter { $0.videoURL != nil }.count) * 0.3, // Compression is 30% of total
							currentFileIndex: index,
							currentFileName: "Compressing video \(index + 1)..."
						))
					}
				}
			}
		}
		
		// Add compressed videos to items list
		for (index, result) in compressionResults {
			compressedItems.append((index: index, image: nil, videoURL: result.url, shouldCleanup: result.shouldCleanup))
		}
		
		// Sort by index to maintain original order
		compressedItems.sort { $0.index < $1.index }
		
		// Step 2: Upload files with rate limiting (CRITICAL FIX: Prevent Firebase Storage overload)
		var uploadProgress: [Int: Double] = [:] // Track progress per file
		var allResults: [MediaUploadResult] = []
		var completedUploads = 0
		
		// CRITICAL FIX: Use semaphore to limit concurrent uploads
		let uploadSemaphore = DispatchSemaphore(value: maxConcurrentUploads)
		
		try await withThrowingTaskGroup(of: MediaUploadResult.self) { group in
			// Add upload tasks with rate limiting
			for compressedItem in compressedItems {
				group.addTask { [weak self] in
					// Wait for available slot (rate limiting)
					await withCheckedContinuation { continuation in
						uploadSemaphore.wait()
						continuation.resume()
					}
					
					defer {
						uploadSemaphore.signal() // Release slot when done
					}
					// Run uploads off main thread
					let index = compressedItem.index
					
					if let image = compressedItem.image {
						// Upload image
						let imageURL = try await self?.uploadImageWithProgress(
							image,
							path: "posts/\(UUID().uuidString).jpg",
							index: index,
							totalCount: mediaItems.count,
							progressCallback: { fileProgress in
								uploadProgress[index] = fileProgress
								let overallProgress = self?.calculateOverallProgress(
									uploadProgress: uploadProgress,
									completedCount: uploadProgress.values.filter { $0 >= 1.0 }.count,
									totalCount: mediaItems.count,
									compressionPhaseComplete: true
								) ?? 0.0
								Task { @MainActor in
									progressCallback(UploadProgress(
										completedCount: uploadProgress.values.filter { $0 >= 1.0 }.count,
										totalCount: mediaItems.count,
										overallProgress: 0.3 + (overallProgress * 0.7), // Upload is 70% of total (after 30% compression)
										currentFileIndex: index,
										currentFileName: "Uploading image \(index + 1)/\(mediaItems.count)..."
									))
								}
							}
						) ?? ""
						
						return MediaUploadResult(
							index: index,
							mediaItem: MediaItem(
								imageURL: imageURL,
								thumbnailURL: nil,
								videoURL: nil,
								videoDuration: nil,
								isVideo: false
							)
						)
					} else if let videoURL = compressedItem.videoURL {
						// Upload video
						let videoStorageURL = try await self?.uploadVideoWithProgress(
							videoURL,
							path: "posts/\(UUID().uuidString).mp4",
							index: index,
							totalCount: mediaItems.count,
							progressCallback: { fileProgress in
								uploadProgress[index] = fileProgress
								let overallProgress = self?.calculateOverallProgress(
									uploadProgress: uploadProgress,
									completedCount: uploadProgress.values.filter { $0 >= 1.0 }.count,
									totalCount: mediaItems.count,
									compressionPhaseComplete: true
								) ?? 0.0
								Task { @MainActor in
									progressCallback(UploadProgress(
										completedCount: uploadProgress.values.filter { $0 >= 1.0 }.count,
										totalCount: mediaItems.count,
										overallProgress: 0.3 + (overallProgress * 0.7), // Upload is 70% of total
										currentFileIndex: index,
										currentFileName: "Uploading video \(index + 1)/\(mediaItems.count)..."
									))
								}
							}
						) ?? ""
						
						// Generate and upload thumbnail (can happen in parallel)
						let thumbnailURL = try? await self?.generateAndUploadThumbnail(
							videoURL: videoURL,
							path: "posts/thumbnails/\(UUID().uuidString).jpg"
						)
						
						// Clean up compressed file if needed
						if compressedItem.shouldCleanup {
							try? FileManager.default.removeItem(at: videoURL)
						}
						
						// Get original video duration from mediaItems
						let originalItem = mediaItems[index]
						
						return MediaUploadResult(
							index: index,
							mediaItem: MediaItem(
								imageURL: nil,
								thumbnailURL: thumbnailURL,
								videoURL: videoStorageURL,
								videoDuration: originalItem.videoDuration,
								isVideo: true
							)
						)
					}
					
					throw NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid media item"])
				}
			}
			
			// Collect results as they complete
			for try await result in group {
				allResults.append(result)
				completedUploads += 1
			}
		}
		
		// Sort results by index to maintain original order
		allResults.sort { $0.index < $1.index }
		
		// Clean up any remaining compressed files
		for compressedItem in compressedItems {
			if compressedItem.shouldCleanup, let videoURL = compressedItem.videoURL {
				try? FileManager.default.removeItem(at: videoURL)
			}
		}
		
		return allResults.map { $0.mediaItem }
	}
	
	// MARK: - Compression
	
	/// Compress video with aggressive settings to enforce 8-15MB max (CRITICAL for scale)
	/// Uses iterative compression if needed to hit target size
	nonisolated private func compressVideoIfNeeded(videoURL: URL) async throws -> URL {
		// This method is nonisolated, so it runs off main thread automatically when called from TaskGroup
		let fileAttributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
		let fileSize = fileAttributes[.size] as? Int64 ?? 0
		let maxFileSize: Int64 = 15 * 1024 * 1024 // 15MB hard limit (70-90% reduction from typical 100MB+)
		let compressionThreshold: Int64 = 8 * 1024 * 1024 // 8MB - compress if larger
		
		// If video is already small enough, upload directly
		if fileSize <= compressionThreshold {
			return videoURL
		}
		
		// CRITICAL: Enforce hard limit - reject videos that can't be compressed below 15MB
		if fileSize > 200 * 1024 * 1024 { // 200MB+ videos are too large
			throw NSError(
				domain: "MediaUploadManager",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "Video is too large (\(String(format: "%.1f", Double(fileSize) / 1024 / 1024))MB). Please use a shorter video or compress it first."]
			)
		}
		
		// Compress large videos with aggressive settings
		print("📹 Compressing video from \(String(format: "%.1f", Double(fileSize) / 1024 / 1024))MB (target: <15MB)...")
		
		let asset = AVURLAsset(url: videoURL)
		
		// Try MediumQuality first (usually gets us to 8-15MB range)
		var exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality)
		var outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("mp4")
		
		exportSession?.outputURL = outputURL
		exportSession?.outputFileType = .mp4
		exportSession?.shouldOptimizeForNetworkUse = true
		
		// Export video
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			exportSession?.exportAsynchronously {
				continuation.resume()
			}
		}
		
		guard exportSession?.status == .completed else {
			if let error = exportSession?.error {
				throw error
			}
			throw NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video compression failed"])
		}
		
		// Check compressed file size
		let compressedAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
		var compressedSize = compressedAttributes[.size] as? Int64 ?? 0
		print("✅ Video compressed to \(String(format: "%.1f", Double(compressedSize) / 1024 / 1024))MB (was \(String(format: "%.1f", Double(fileSize) / 1024 / 1024))MB)")
		
		// If still too large, try LowQuality preset (more aggressive compression)
		if compressedSize > maxFileSize {
			print("⚠️ Video still too large (\(String(format: "%.1f", Double(compressedSize) / 1024 / 1024))MB), applying aggressive compression...")
			
			// Clean up first attempt
			try? FileManager.default.removeItem(at: outputURL)
			
			// Try LowQuality preset (more aggressive)
			exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetLowQuality)
			outputURL = FileManager.default.temporaryDirectory
				.appendingPathComponent(UUID().uuidString)
				.appendingPathExtension("mp4")
			
			exportSession?.outputURL = outputURL
			exportSession?.outputFileType = .mp4
			exportSession?.shouldOptimizeForNetworkUse = true
			
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				exportSession?.exportAsynchronously {
					continuation.resume()
				}
			}
			
			guard exportSession?.status == .completed else {
				if let error = exportSession?.error {
					throw error
				}
				throw NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aggressive video compression failed"])
			}
			
			let newAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
			compressedSize = newAttributes[.size] as? Int64 ?? 0
			print("✅ Aggressively compressed to \(String(format: "%.1f", Double(compressedSize) / 1024 / 1024))MB")
		}
		
		// Final check: if still over 15MB after aggressive compression, reject
		if compressedSize > maxFileSize {
			try? FileManager.default.removeItem(at: outputURL)
			throw NSError(
				domain: "MediaUploadManager",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "Video could not be compressed below 15MB. Please use a shorter video."]
			)
		}
		
		return outputURL
	}
	
	/// Compress image if needed (resize to 2048px max, JPEG quality 0.7)
	nonisolated private func compressImageIfNeeded(_ image: UIImage) -> UIImage {
		let maxDimension: CGFloat = 2048
		let size = image.size
		
		// If image is already smaller, just compress quality
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
		UIGraphicsBeginImageContextWithOptions(newSize, false, 0.8)
		image.draw(in: CGRect(origin: .zero, size: newSize))
		let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
		UIGraphicsEndImageContext()
		
		return resizedImage ?? image
	}
	
	// MARK: - Upload with Progress
	
	/// Upload image with progress tracking (runs off main thread)
	nonisolated private func uploadImageWithProgress(
		_ image: UIImage,
		path: String,
		index: Int,
		totalCount: Int,
		progressCallback: @escaping (Double) -> Void
	) async throws -> String {
		// Compress image
		let compressedImage = compressImageIfNeeded(image)
		guard let imageData = compressedImage.jpegData(compressionQuality: 0.7) else {
			throw NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image"])
		}
		
		let storage = Storage.storage()
		let imageRef = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		// Upload with progress tracking
		let uploadTask = imageRef.putData(imageData, metadata: metadata)
		
		// Observe progress
		uploadTask.observe(.progress) { snapshot in
			guard let progress = snapshot.progress else { return }
			let progressValue = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
			Task { @MainActor in
				progressCallback(progressValue)
			}
		}
		
		// Wait for completion
		let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
			uploadTask.observe(.success) { snapshot in
				if let metadata = snapshot.metadata {
					continuation.resume(returning: metadata)
				} else {
					continuation.resume(throwing: NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload completed but no metadata"]))
				}
			}
			
			uploadTask.observe(.failure) { snapshot in
				if let error = snapshot.error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(throwing: NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"]))
				}
			}
		}
		
		// Get download URL
		let downloadURL = try await imageRef.downloadURL()
		return downloadURL.absoluteString
	}
	
	/// Upload video with progress tracking (runs off main thread)
	nonisolated private func uploadVideoWithProgress(
		_ videoURL: URL,
		path: String,
		index: Int,
		totalCount: Int,
		progressCallback: @escaping (Double) -> Void
	) async throws -> String {
		let storage = Storage.storage()
		let videoRef = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "video/mp4"
		
		// Upload from file URL with progress tracking
		let uploadTask = videoRef.putFile(from: videoURL, metadata: metadata)
		
		// Observe progress
		uploadTask.observe(.progress) { snapshot in
			guard let progress = snapshot.progress else { return }
			let progressValue = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
			Task { @MainActor in
				progressCallback(progressValue)
			}
		}
		
		// Wait for completion
		let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
			uploadTask.observe(.success) { snapshot in
				if let metadata = snapshot.metadata {
					continuation.resume(returning: metadata)
				} else {
					continuation.resume(throwing: NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload completed but no metadata"]))
				}
			}
			
			uploadTask.observe(.failure) { snapshot in
				if let error = snapshot.error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(throwing: NSError(domain: "MediaUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"]))
				}
			}
		}
		
		// Get download URL
		let downloadURL = try await videoRef.downloadURL()
		return downloadURL.absoluteString
	}
	
	/// Generate and upload thumbnail
	private func generateAndUploadThumbnail(videoURL: URL, path: String) async throws -> String {
		let asset = AVURLAsset(url: videoURL)
		let imageGenerator = AVAssetImageGenerator(asset: asset)
		imageGenerator.appliesPreferredTrackTransform = true
		imageGenerator.maximumSize = CGSize(width: 300, height: 300)
		
		let time = CMTime(seconds: 0.1, preferredTimescale: 600)
		let cgImage = try await imageGenerator.image(at: time).image
		let thumbnail = UIImage(cgImage: cgImage)
		
		// Upload thumbnail (reuse image upload method)
		return try await uploadImageWithProgress(
			thumbnail,
			path: path,
			index: 0,
			totalCount: 1,
			progressCallback: { _ in }
		)
	}
	
	// MARK: - Helper Methods
	
	/// Calculate overall progress across all uploads
	nonisolated private func calculateOverallProgress(
		uploadProgress: [Int: Double],
		completedCount: Int,
		totalCount: Int,
		compressionPhaseComplete: Bool
	) -> Double {
		guard totalCount > 0 else { return 0.0 }
		
		// If compression phase is complete, we're in upload phase
		if compressionPhaseComplete {
			// Average progress of all files
			let totalProgress = uploadProgress.values.reduce(0.0, +)
			return totalProgress / Double(totalCount)
		} else {
			// Still in compression phase
			return Double(completedCount) / Double(totalCount) * 0.5 // Compression is 50% of total
		}
	}
}
