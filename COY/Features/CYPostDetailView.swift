import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import AVKit
import FirebaseAuth
import Combine

struct CYPostDetailView: View {
	let post: CollectionPost
	let collection: CollectionData?
	
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@State private var currentMediaIndex: Int = 0
	@State private var isStarred: Bool = false
	@State private var showFullCaption: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@State private var elapsedTimes: [Int: Double] = [:]
	@State private var timeObservers: [Int: AnyCancellable] = [:]
	
	private let screenWidth: CGFloat = UIScreen.main.bounds.width
	private let maxHeight: CGFloat = UIScreen.main.bounds.height * 0.6
	
	// Calculate individual heights for each media item
	private func calculateHeight(for mediaItem: MediaItem) -> CGFloat {
		if mediaItem.isVideo {
			// For videos, use a default aspect ratio (16:9) or from thumbnail
			if let thumbnailURL = mediaItem.thumbnailURL,
			   let aspectRatio = imageAspectRatios[thumbnailURL] {
				return screenWidth / aspectRatio
			} else {
				return screenWidth * (9.0 / 16.0) // Default 16:9
			}
		} else if let imageURL = mediaItem.imageURL,
				  let aspectRatio = imageAspectRatios[imageURL] {
			// Use calculated aspect ratio
			return screenWidth / aspectRatio
		} else {
			// Default aspect ratio for images (4:3)
			return screenWidth * (3.0 / 4.0)
		}
	}
	
	// Calculate the tallest height from all media items
	private var calculatedHeight: CGFloat {
		if post.mediaItems.isEmpty {
			return maxHeight // Default max height
		}
		
		// For multiple media items, find the tallest one
		var maxCalculatedHeight: CGFloat = 0
		
		for mediaItem in post.mediaItems {
			let height = calculateHeight(for: mediaItem)
			maxCalculatedHeight = max(maxCalculatedHeight, height)
		}
		
		// Cap at maxHeight to prevent overly tall images
		return min(maxCalculatedHeight, maxHeight)
	}
	
	// Check if media items have different heights
	private var hasDifferentHeights: Bool {
		// Single media item - no blur needed
		if post.mediaItems.count <= 1 {
			return false
		}
		
		// Calculate heights for all items
		var heights: [CGFloat] = []
		for mediaItem in post.mediaItems {
			heights.append(calculateHeight(for: mediaItem))
		}
		
		// Check if any heights are different (with small tolerance for floating point)
		let tolerance: CGFloat = 1.0
		for i in 0..<heights.count {
			for j in (i+1)..<heights.count {
				if abs(heights[i] - heights[j]) > tolerance {
					return true
				}
			}
		}
		
		return false
	}
	
	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					// Media Carousel with blur background (only if multiple items with different heights)
					if !post.mediaItems.isEmpty {
						ZStack {
							// Blur background - only show if multiple items with different heights
							if hasDifferentHeights {
								blurBackgroundView
									.frame(width: screenWidth, height: calculatedHeight)
									.clipped()
							}
							
							// Media carousel on top
							TabView(selection: $currentMediaIndex) {
								ForEach(0..<post.mediaItems.count, id: \.self) { index in
									mediaView(mediaItem: post.mediaItems[index], index: index)
										.tag(index)
								}
							}
							.tabViewStyle(.page)
							.frame(height: calculatedHeight)
							.onChange(of: currentMediaIndex) { oldValue, newValue in
								handleMediaIndexChange(from: oldValue, to: newValue)
							}
							.overlay(
								// Page indicator dots
								VStack {
									Spacer()
									if post.mediaItems.count > 1 {
										HStack(spacing: 6) {
											ForEach(0..<post.mediaItems.count, id: \.self) { index in
												Circle()
													.fill(index == currentMediaIndex ? Color.white : Color.white.opacity(0.4))
													.frame(width: 6, height: 6)
											}
										}
										.padding(.bottom, 12)
									}
								}
							)
						}
					}
					
					// Post Info Section
					VStack(alignment: .leading, spacing: 12) {
						// Username and Star Row
						HStack(alignment: .center, spacing: 12) {
							// Username
							if !post.authorName.isEmpty {
								Text("@\(post.authorName)")
									.font(.headline)
									.fontWeight(.semibold)
									.foregroundColor(.primary)
							}
							
							Spacer()
							
							// Star Button
							Button(action: {
								toggleStar()
							}) {
								Image(systemName: isStarred ? "star.fill" : "star")
									.font(.title3)
									.foregroundColor(isStarred ? .yellow : .gray)
							}
						}
						.padding(.horizontal, 16)
						.padding(.top, 12)
						
						// Caption
						if !post.title.isEmpty {
							VStack(alignment: .leading, spacing: 4) {
								Text(post.title)
									.font(.body)
									.foregroundColor(.primary)
									.lineLimit(showFullCaption ? nil : 3)
									.multilineTextAlignment(.leading)
								
								if post.title.count > 100 {
									Button(action: {
										showFullCaption.toggle()
									}) {
										Text(showFullCaption ? "Show less" : "Show more")
											.font(.caption)
											.foregroundColor(.blue)
									}
								}
							}
							.padding(.horizontal, 16)
						}
						
						// Post Metadata
						HStack {
							Text(timeAgoString(from: post.createdAt))
								.font(.caption)
								.foregroundColor(.secondary)
							
							Spacer()
						}
						.padding(.horizontal, 16)
						.padding(.top, 4)
					}
					.padding(.bottom, 20)
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(action: {
						dismiss()
					}) {
						Image(systemName: "xmark")
							.foregroundColor(.primary)
					}
				}
			}
		}
		.onAppear {
			loadStarStatus()
			calculateImageAspectRatios()
			setupVideoPlayers()
			// Play the first video if it's a video
			if !post.mediaItems.isEmpty && post.mediaItems[0].isVideo {
				playVideo(at: 0)
			}
		}
		.onDisappear {
			// Pause all videos when view disappears
			pauseAllVideos()
			cleanupTimeObservers()
		}
	}
	
	// MARK: - Video Player Management
	private func setupVideoPlayers() {
		for (index, mediaItem) in post.mediaItems.enumerated() {
			if mediaItem.isVideo, let videoURL = mediaItem.videoURL {
				// Create player for this video
				_ = VideoPlayerManager.shared.getOrCreatePlayer(for: videoURL, postId: "\(post.id)_\(index)")
				
				// Set up elapsed time tracking
				setupElapsedTimeTracking(for: index, videoURL: videoURL)
			}
		}
	}
	
	private func getPlayerId(for index: Int, videoURL: String) -> String {
		// VideoPlayerManager creates playerId as "\(postId)_\(videoURL)"
		// We pass postId as "\(post.id)_\(index)", so the final playerId is "\(post.id)_\(index)_\(videoURL)"
		return "\(post.id)_\(index)_\(videoURL)"
	}
	
	private func setupElapsedTimeTracking(for index: Int, videoURL: String) {
		let playerId = getPlayerId(for: index, videoURL: videoURL)
		if let publisher = VideoPlayerManager.shared.getElapsedTimePublisher(for: playerId) {
			let cancellable = publisher.sink { time in
				Task { @MainActor in
					elapsedTimes[index] = time
				}
			}
			timeObservers[index] = cancellable
		}
	}
	
	private func playVideo(at index: Int) {
		guard index >= 0 && index < post.mediaItems.count else { return }
		guard post.mediaItems[index].isVideo,
			  let videoURL = post.mediaItems[index].videoURL else { return }
		
		// Pause all other videos
		for i in 0..<post.mediaItems.count where i != index && post.mediaItems[i].isVideo {
			if let otherVideoURL = post.mediaItems[i].videoURL {
				let otherPlayerId = getPlayerId(for: i, videoURL: otherVideoURL)
				VideoPlayerManager.shared.pauseVideo(playerId: otherPlayerId)
			}
		}
		
		// Play the current video
		let playerId = getPlayerId(for: index, videoURL: videoURL)
		VideoPlayerManager.shared.playVideo(playerId: playerId)
	}
	
	private func pauseAllVideos() {
		for (index, mediaItem) in post.mediaItems.enumerated() where mediaItem.isVideo {
			if let videoURL = mediaItem.videoURL {
				let playerId = getPlayerId(for: index, videoURL: videoURL)
				VideoPlayerManager.shared.pauseVideo(playerId: playerId)
			}
		}
	}
	
	private func handleMediaIndexChange(from oldIndex: Int, to newIndex: Int) {
		// Pause the old video
		if oldIndex >= 0 && oldIndex < post.mediaItems.count && post.mediaItems[oldIndex].isVideo,
		   let oldVideoURL = post.mediaItems[oldIndex].videoURL {
			let oldPlayerId = getPlayerId(for: oldIndex, videoURL: oldVideoURL)
			VideoPlayerManager.shared.pauseVideo(playerId: oldPlayerId)
		}
		
		// Play the new video if it's a video
		if newIndex >= 0 && newIndex < post.mediaItems.count && post.mediaItems[newIndex].isVideo {
			playVideo(at: newIndex)
		}
	}
	
	private func cleanupTimeObservers() {
		for (_, cancellable) in timeObservers {
			cancellable.cancel()
		}
		timeObservers.removeAll()
	}
	
	// MARK: - Blur Background View
	@ViewBuilder
	private var blurBackgroundView: some View {
		// Use the first media item for blur background
		if let firstMedia = post.firstMediaItem ?? post.mediaItems.first {
			if let imageURL = firstMedia.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: screenWidth, height: calculatedHeight)
					.blur(radius: 20)
					.opacity(0.6)
			} else if let thumbnailURL = firstMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: screenWidth, height: calculatedHeight)
					.blur(radius: 20)
					.opacity(0.6)
			} else {
				// Fallback gradient
				LinearGradient(
					colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
					startPoint: .top,
					endPoint: .bottom
				)
			}
		} else {
			// Fallback gradient
			LinearGradient(
				colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
				startPoint: .top,
				endPoint: .bottom
			)
		}
	}
	
	// MARK: - Media View
	@ViewBuilder
	private func mediaView(mediaItem: MediaItem, index: Int) -> some View {
		if mediaItem.isVideo {
			videoView(mediaItem: mediaItem, index: index)
		} else {
			imageView(mediaItem: mediaItem)
		}
	}
	
	@ViewBuilder
	private func imageView(mediaItem: MediaItem) -> some View {
		if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.transition(.fade(duration: 0.2))
				.aspectRatio(contentMode: .fit)
				.frame(width: screenWidth, height: calculatedHeight)
				.clipped()
		} else {
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: calculatedHeight)
				.overlay(
					Image(systemName: "photo")
						.foregroundColor(.gray)
						.font(.largeTitle)
				)
		}
	}
	
	@ViewBuilder
	private func videoView(mediaItem: MediaItem, index: Int) -> some View {
		ZStack {
			// Video Player
			if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
				let player = VideoPlayerManager.shared.getOrCreatePlayer(for: videoURL, postId: "\(post.id)_\(index)")
				VideoPlayer(player: player)
					.frame(width: screenWidth, height: calculatedHeight)
					.clipped()
					.disabled(true) // Disable controls
					.onAppear {
						// Auto-play if this is the current index
						if index == currentMediaIndex {
							playVideo(at: index)
						}
					}
			} else {
				// Fallback thumbnail
				if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
					WebImage(url: url)
						.resizable()
						.indicator(.activity)
						.transition(.fade(duration: 0.2))
						.aspectRatio(contentMode: .fit)
						.frame(width: screenWidth, height: calculatedHeight)
						.clipped()
				} else {
					Rectangle()
						.fill(Color.black)
						.frame(height: calculatedHeight)
				}
			}
			
			// Elapsed Time Badge (count up)
			VStack {
				Spacer()
				HStack {
					Spacer()
					Text(formatElapsedTime(elapsedTimes[index] ?? 0.0))
						.font(.caption)
						.fontWeight(.semibold)
						.foregroundColor(.white)
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.background(Color.black.opacity(0.6))
						.cornerRadius(4)
						.padding(.trailing, 12)
						.padding(.bottom, 12)
				}
			}
		}
	}
	
	// MARK: - Helper Functions
	private func toggleStar() {
		// TODO: Implement star/unstar functionality
		isStarred.toggle()
	}
	
	private func loadStarStatus() {
		// TODO: Load star status from Firebase
		// Check if current user has starred this post
		// For now, default to false
		isStarred = false
	}
	
	private func timeAgoString(from date: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return formatter.localizedString(for: date, relativeTo: Date())
	}
	
	private func formatElapsedTime(_ seconds: Double) -> String {
		let minutes = Int(seconds) / 60
		let secs = Int(seconds) % 60
		return String(format: "%d:%02d", minutes, secs)
	}
	
	// MARK: - Calculate Image Aspect Ratios
	private func calculateImageAspectRatios() {
		// Pre-calculate aspect ratios for all media items using SDWebImage
		for mediaItem in post.mediaItems {
			if !mediaItem.isVideo {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty {
					// Load image to get dimensions
					Task {
						if let url = URL(string: imageURL) {
							// Use SDWebImage to load and get dimensions
							SDWebImageManager.shared.loadImage(
								with: url,
								options: [],
								progress: nil
							) { image, data, error, cacheType, finished, imageURL in
								if let image = image, finished, let imageURL = imageURL {
									let aspectRatio = image.size.width / image.size.height
									DispatchQueue.main.async {
										imageAspectRatios[imageURL.absoluteString] = aspectRatio
									}
								}
							}
						}
					}
				}
			} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty {
				// For videos, load thumbnail to get aspect ratio
				Task {
					if let url = URL(string: thumbnailURL) {
						SDWebImageManager.shared.loadImage(
							with: url,
							options: [],
							progress: nil
						) { image, data, error, cacheType, finished, _ in
							if let image = image, finished {
								let aspectRatio = image.size.width / image.size.height
								DispatchQueue.main.async {
									imageAspectRatios[thumbnailURL] = aspectRatio
								}
							}
						}
					}
				}
			}
		}
	}
}

