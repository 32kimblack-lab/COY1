import Foundation
import AVFoundation

/// Manages video disk caching to prevent repeated downloads
/// This is CRITICAL for reducing bandwidth - 67.6GB downloaded for 18.18MB stored indicates videos are being re-downloaded
class VideoCacheManager {
	static let shared = VideoCacheManager()
	
	private let cacheDirectory: URL
	private let maxCacheSize: Int64 = 500 * 1024 * 1024 // 500MB max cache
	private let cacheExpirationDays: Int = 7 // Keep videos for 7 days
	
	// Track active downloads to prevent duplicate downloads (must be accessed on MainActor)
	@MainActor private var activeDownloads: [String: Task<URL?, Never>] = [:]
	
	// Limit concurrent downloads to prevent network overload (accessible from nonisolated context)
	static let maxConcurrentDownloads = 3
	
	private init() {
		// Create cache directory in app's caches folder
		let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
		cacheDirectory = cachesDir.appendingPathComponent("VideoCache", isDirectory: true)
		
		// Create directory if it doesn't exist
		try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
		
		// Clean up old cached files on init (non-blocking)
		Task.detached(priority: .utility) {
			await self.cleanupOldCache()
		}
	}
	
	/// Get cache directory (for synchronous access)
	nonisolated func getCacheDirectory() -> URL {
		return cacheDirectory
	}
	
	/// Generate cache key synchronously (for immediate use)
	nonisolated func generateCacheKeySync(from urlString: String) -> String {
		// Use hash value of URL string for cache key (ensures uniqueness)
		let hash = urlString.hashValue
		let positiveHash = abs(hash)
		
		// Get file extension from URL
		let url = URL(string: urlString)
		let ext = url?.pathExtension ?? "mp4"
		
		// Also include a portion of the URL path for better organization
		let pathComponent = url?.lastPathComponent ?? ""
		let safePath = pathComponent.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "?", with: "_")
			.replacingOccurrences(of: "&", with: "_")
		
		return "\(positiveHash)_\(safePath).\(ext)"
	}
	
	/// Get cached video URL or download and cache it
	/// Returns local file URL if cached, or downloads and caches it
	/// Runs off main thread to avoid blocking
	nonisolated func getCachedVideoURL(for remoteURL: String) async -> URL? {
		guard let url = URL(string: remoteURL) else { return nil }
		
		// Generate cache key from URL
		let cacheKey = generateCacheKeySync(from: remoteURL)
		let cachedFileURL = cacheDirectory.appendingPathComponent(cacheKey)
		
		// Check if file exists in cache and is not expired
		if FileManager.default.fileExists(atPath: cachedFileURL.path) {
			// Check if file is expired
			if let attributes = try? FileManager.default.attributesOfItem(atPath: cachedFileURL.path),
			   let modificationDate = attributes[.modificationDate] as? Date {
				let daysSinceModification = Calendar.current.dateComponents([.day], from: modificationDate, to: Date()).day ?? 0
				if daysSinceModification < cacheExpirationDays {
					// File is cached and not expired - return it
					return cachedFileURL
				} else {
					// File expired - delete it
					try? FileManager.default.removeItem(at: cachedFileURL)
				}
			} else {
				// File exists, return it (can't determine age, but better than re-downloading)
				return cachedFileURL
			}
		}
		
		// File not cached or expired - download it
		return await downloadAndCacheVideo(from: url, to: cachedFileURL, cacheKey: cacheKey)
	}
	
	/// Download video and save to cache with retry logic
	nonisolated private func downloadAndCacheVideo(from remoteURL: URL, to localURL: URL, cacheKey: String) async -> URL? {
		// Check if download is already in progress (thread-safe access)
		let (existingTask, canStart) = await MainActor.run {
			let existing = activeDownloads[cacheKey]
			let currentCount = activeDownloads.count
			let canStartNew = currentCount < VideoCacheManager.maxConcurrentDownloads
			return (existing, canStartNew)
		}
		
		if let task = existingTask {
			// Wait for existing download to complete
			// Task.value waits for the task to complete
			let result = await task.value
			if let cachedURL = result {
				return cachedURL
			}
			// Check if file now exists (might have been created by the task)
			if FileManager.default.fileExists(atPath: localURL.path) {
				return localURL
			}
		}
		
		// Wait if too many concurrent downloads
		if !canStart {
			// Wait a bit and check again
			try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
			// Retry after waiting
			return await downloadAndCacheVideo(from: remoteURL, to: localURL, cacheKey: cacheKey)
		}
		
		// Create download task with retry logic - stream directly to disk to avoid memory issues
		let downloadTask = Task<URL?, Never> {
			var resumeData: Data? = nil
			let maxRetries = 3
			
			// Configure session with longer timeouts for large videos
			let config = URLSessionConfiguration.default
			config.timeoutIntervalForRequest = 30.0
			config.timeoutIntervalForResource = 300.0 // 5 minutes for large videos
			config.waitsForConnectivity = true // Wait for network to be available
			let session = URLSession(configuration: config)
			
			for attempt in 0..<maxRetries {
				do {
					let tempURL: URL
					
					if let resume = resumeData {
						// Resume previous download using async continuation
						tempURL = try await withCheckedThrowingContinuation { continuation in
							let resumeTask = session.downloadTask(withResumeData: resume) { url, response, error in
								if let error = error {
									continuation.resume(throwing: error)
								} else if let url = url {
									continuation.resume(returning: url)
								} else {
									continuation.resume(throwing: NSError(domain: "VideoCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed"]))
								}
							}
							resumeTask.resume()
						}
					} else {
						// Fresh download
						(tempURL, _) = try await session.download(from: remoteURL)
					}
					
					// Move from temp location to cache location
					// Remove existing file if it exists
					if FileManager.default.fileExists(atPath: localURL.path) {
						try? FileManager.default.removeItem(at: localURL)
					}
					try FileManager.default.moveItem(at: tempURL, to: localURL)
					
					// Clean up if cache is too large
					await manageCacheSize()
					
					return localURL
				} catch let error as NSError {
					// Check if we can resume
					if let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
						resumeData = resume
						// Wait before retry (exponential backoff)
						let delay = min(Double(attempt + 1) * 2.0, 10.0) // Max 10 seconds
						try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
						continue
					}
					
					// Network error - retry with exponential backoff
					if error.code == NSURLErrorNetworkConnectionLost || 
					   error.code == NSURLErrorTimedOut ||
					   error.code == NSURLErrorNotConnectedToInternet {
						
						if attempt < maxRetries - 1 {
							// Wait before retry (exponential backoff)
							let delay = min(Double(attempt + 1) * 2.0, 10.0) // Max 10 seconds
							try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
							continue
						}
					}
					
					// Final attempt failed or non-retryable error
					if attempt == maxRetries - 1 {
						// Download failed after all retries - return nil to fall back to remote URL
						return nil
					}
				}
			}
			
			return nil
		}
		
		// Store task to prevent duplicate downloads (thread-safe)
		await MainActor.run {
			activeDownloads[cacheKey] = downloadTask
		}
		
		// Wait for download
		let result = await downloadTask.value
		
		// Remove from active downloads (thread-safe)
		_ = await MainActor.run {
			activeDownloads.removeValue(forKey: cacheKey)
		}
		
		return result
	}
	
	/// Clean up old cache files
	nonisolated private func cleanupOldCache() async {
		guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
			return
		}
		
		let now = Date()
		for file in files {
			if let modificationDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
				let daysSinceModification = Calendar.current.dateComponents([.day], from: modificationDate, to: now).day ?? 0
				if daysSinceModification >= cacheExpirationDays {
					try? FileManager.default.removeItem(at: file)
				}
			}
		}
	}
	
	/// Manage cache size - remove oldest files if cache exceeds limit
	nonisolated private func manageCacheSize() async {
		guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
			return
		}
		
		// Calculate total cache size
		var totalSize: Int64 = 0
		var fileInfos: [(url: URL, size: Int64, date: Date)] = []
		
		for file in files {
			if let resourceValues = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
			   let size = resourceValues.fileSize,
			   let date = resourceValues.contentModificationDate {
				totalSize += Int64(size)
				fileInfos.append((url: file, size: Int64(size), date: date))
			}
		}
		
		// If cache exceeds limit, remove oldest files
		if totalSize > maxCacheSize {
			// Sort by modification date (oldest first)
			fileInfos.sort { $0.date < $1.date }
			
			// Remove oldest files until under limit
			var currentSize = totalSize
			for fileInfo in fileInfos {
				if currentSize <= maxCacheSize {
					break
				}
				try? FileManager.default.removeItem(at: fileInfo.url)
				currentSize -= fileInfo.size
			}
		}
	}
	
	/// Clear all cached videos
	nonisolated func clearCache() {
		try? FileManager.default.removeItem(at: cacheDirectory)
		try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
	}
	
	/// Get current cache size
	nonisolated func getCacheSize() -> Int64 {
		guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
			return 0
		}
		
		var totalSize: Int64 = 0
		for file in files {
			if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
				totalSize += Int64(size)
			}
		}
		return totalSize
	}
}
