import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import AVKit
import FirebaseAuth
import Combine

// MARK: - Pinterest Style Post Grid
struct PinterestPostGrid: View {
	let posts: [CollectionPost]
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	
	@State private var postHeights: [String: CGFloat] = [:]
	@StateObject private var scrollPosition = ScrollPositionTracker()
	
	private let columns = 2
	private let spacing: CGFloat = 8
	private let padding: CGFloat = 12
	
	var body: some View {
		ScrollView {
			LazyVStack(spacing: spacing) {
				// Create two columns using HStack
				ForEach(0..<(posts.count + 1) / 2, id: \.self) { rowIndex in
					HStack(alignment: .top, spacing: spacing) {
						// Left column
						if rowIndex * 2 < posts.count {
							PinterestPostCard(
								post: posts[rowIndex * 2],
								collection: collection,
								isIndividualCollection: isIndividualCollection,
								currentUserId: currentUserId,
								width: (UIScreen.main.bounds.width - (padding * 2) - spacing) / CGFloat(columns),
								scrollPosition: scrollPosition
							)
						}
						
						// Right column
						if rowIndex * 2 + 1 < posts.count {
							PinterestPostCard(
								post: posts[rowIndex * 2 + 1],
								collection: collection,
								isIndividualCollection: isIndividualCollection,
								currentUserId: currentUserId,
								width: (UIScreen.main.bounds.width - (padding * 2) - spacing) / CGFloat(columns),
								scrollPosition: scrollPosition
							)
						} else {
							// Empty space to maintain alignment
							Spacer()
								.frame(width: (UIScreen.main.bounds.width - (padding * 2) - spacing) / CGFloat(columns))
						}
					}
					.padding(.horizontal, padding)
				}
			}
			.padding(.vertical, padding)
			.background(GeometryReader { geometry in
				Color.clear.preference(
					key: ScrollOffsetPreferenceKey.self,
					value: geometry.frame(in: .named("scroll")).minY
				)
			})
			.onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
				scrollPosition.scrollOffset = value
			}
		}
		.coordinateSpace(name: "scroll")
		.onDisappear {
			VideoPlayerManager.shared.pauseAll()
		}
	}
}

// MARK: - Scroll Position Tracker
@MainActor
class ScrollPositionTracker: ObservableObject {
	@Published var scrollOffset: CGFloat = 0
	@Published var visibleCards: Set<String> = []
}

// MARK: - Scroll Offset Preference Key
struct ScrollOffsetPreferenceKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}

// MARK: - Card Frame Preference Key
struct CardFramePreferenceKey: PreferenceKey {
	static var defaultValue: CGRect = .zero
	static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
		value = nextValue()
	}
}

// MARK: - Pinterest Post Card
struct PinterestPostCard: View {
	let post: CollectionPost
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	let width: CGFloat
	let scrollPosition: ScrollPositionTracker
	
	@State private var imageHeight: CGFloat = 200
	@State private var showStar: Bool = false
	@State private var showPostDetail: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@State private var cardFrame: CGRect = .zero
	@State private var isVisible: Bool = false
	@State private var elapsedTime: Double = 0.0
	@State private var timeObserver: AnyCancellable?
	@Environment(\.colorScheme) var colorScheme
	
	private var playerId: String {
		"\(post.id)_\(post.mediaItems.first?.videoURL ?? "")"
	}
	
	// Calculate individual heights for each media item
	private func calculateHeight(for mediaItem: MediaItem) -> CGFloat {
		if mediaItem.isVideo {
			// For videos, use a default aspect ratio (16:9)
			return width * (9.0 / 16.0)
		} else if let imageURL = mediaItem.imageURL,
				  let aspectRatio = imageAspectRatios[imageURL] {
			// Use calculated aspect ratio
			return width / aspectRatio
		} else {
			// Default aspect ratio for images (4:3)
			return width * (3.0 / 4.0)
		}
	}
	
	// Calculate the tallest height from all media items
	private var calculatedHeight: CGFloat {
		if post.mediaItems.isEmpty {
			return 200 // Default height
		}
		
		// For multiple media items, find the tallest one
		var maxHeight: CGFloat = 200
		
		for mediaItem in post.mediaItems {
			let height = calculateHeight(for: mediaItem)
			maxHeight = max(maxHeight, height)
		}
		
		return maxHeight
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
		VStack(alignment: .leading, spacing: 8) {
			// Media Content with blur background (only if multiple items with different heights)
			ZStack {
				// Blur background - only show if multiple items with different heights
				if hasDifferentHeights {
					blurBackgroundView
						.frame(width: width, height: calculatedHeight)
						.clipped()
				}
				
				// Media content on top
				mediaContentView
					.frame(width: width, height: calculatedHeight)
					.clipped()
			}
			.cornerRadius(12)
			.background(GeometryReader { geometry in
				Color.clear.preference(
					key: CardFramePreferenceKey.self,
					value: geometry.frame(in: .named("scroll"))
				)
			})
			.onPreferenceChange(CardFramePreferenceKey.self) { frame in
				cardFrame = frame
				checkVisibility()
			}
			.onTapGesture {
				showPostDetail = true
			}
			
			// Post Info - under the media
			VStack(alignment: .leading, spacing: 4) {
				// Username and Star in same row
				HStack(alignment: .center, spacing: 6) {
					// Username
					if !post.authorName.isEmpty {
						Text("@\(post.authorName)")
							.font(.caption)
							.fontWeight(.medium)
							.foregroundColor(.primary)
							.lineLimit(1)
					}
					
					Spacer()
					
					// Star Icon (only for members if individual collection)
					if shouldShowStar {
						Image(systemName: "star.fill")
							.font(.caption2)
							.foregroundColor(.yellow)
					}
				}
				
				// Caption
				if !post.title.isEmpty {
					Text(post.title)
						.font(.caption)
						.foregroundColor(.secondary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}
			}
			.padding(.horizontal, 0)
		}
		.onAppear {
			checkStarVisibility()
			calculateImageAspectRatios()
			setupVideoPlayer()
		}
		.onChange(of: isVisible) { oldValue, newValue in
			handleVisibilityChange(newValue)
		}
		.onDisappear {
			// Clean up video player when card disappears
			if post.mediaItems.contains(where: { $0.isVideo }) {
				VideoPlayerManager.shared.pauseVideo(playerId: playerId)
			}
			timeObserver?.cancel()
		}
		.fullScreenCover(isPresented: $showPostDetail) {
			CYPostDetailView(post: post, collection: collection)
		}
	}
	
	// MARK: - Visibility Detection
	private func checkVisibility() {
		guard cardFrame.height > 0 else { return }
		
		let screenHeight = UIScreen.main.bounds.height
		let cardTop = cardFrame.minY
		let cardBottom = cardFrame.maxY
		let cardHeight = cardFrame.height
		
		// Calculate visible portion
		let visibleTop = max(0, -cardTop)
		let visibleBottom = max(0, cardBottom - screenHeight)
		let visibleHeight = max(0, cardHeight - visibleTop - visibleBottom)
		let visiblePercentage = cardHeight > 0 ? visibleHeight / cardHeight : 0
		
		// Video is considered visible if 70% or more is in view
		let wasVisible = isVisible
		isVisible = visiblePercentage >= 0.7 && cardTop < screenHeight && cardBottom > 0
		
		// Only trigger change if visibility actually changed
		if wasVisible != isVisible {
			handleVisibilityChange(isVisible)
		}
	}
	
	private func handleVisibilityChange(_ visible: Bool) {
		guard post.mediaItems.contains(where: { $0.isVideo }) else { return }
		
		if visible {
			// Play video when it becomes visible
			VideoPlayerManager.shared.playVideo(playerId: playerId)
		} else {
			// Pause video when it goes out of view
			VideoPlayerManager.shared.pauseVideo(playerId: playerId)
		}
	}
	
	private func setupVideoPlayer() {
		guard let videoItem = post.mediaItems.first(where: { $0.isVideo }),
			  let videoURL = videoItem.videoURL else {
			return
		}
		
		// Create player
		_ = VideoPlayerManager.shared.getOrCreatePlayer(for: videoURL, postId: post.id)
		
		// Subscribe to elapsed time updates
		timeObserver = VideoPlayerManager.shared.observeElapsedTime(for: playerId) { time in
			Task { @MainActor in
				elapsedTime = time
			}
		}
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
					.frame(width: width, height: calculatedHeight)
					.blur(radius: 20)
					.opacity(0.6)
			} else if let thumbnailURL = firstMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: width, height: calculatedHeight)
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
	
	// MARK: - Media Content View
	@ViewBuilder
	private var mediaContentView: some View {
		if post.mediaItems.count > 1 {
			// Multiple media items - show swipeable carousel
			TabView {
				ForEach(0..<post.mediaItems.count, id: \.self) { index in
					Group {
						if post.mediaItems[index].isVideo {
							videoPlayerView(mediaItem: post.mediaItems[index])
						} else {
							imageView(mediaItem: post.mediaItems[index])
						}
					}
				}
			}
			.tabViewStyle(.page)
			.frame(height: calculatedHeight)
		} else if let mediaItem = post.firstMediaItem ?? post.mediaItems.first {
			// Single media item
			if mediaItem.isVideo {
				// Video Player
				videoPlayerView(mediaItem: mediaItem)
			} else {
				// Image or Live Photo
				imageView(mediaItem: mediaItem)
			}
		} else {
			// Placeholder
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: calculatedHeight)
				.overlay(
					Image(systemName: "photo")
						.foregroundColor(.gray)
				)
		}
	}
	
	// MARK: - Image View
	@ViewBuilder
	private func imageView(mediaItem: MediaItem) -> some View {
		if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.transition(.fade(duration: 0.2))
				.aspectRatio(contentMode: .fit)
				.frame(width: width, height: calculatedHeight)
				.clipped()
		} else {
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: calculatedHeight)
				.overlay(
					Image(systemName: "photo")
						.foregroundColor(.gray)
				)
		}
	}
	
	// MARK: - Video Player View
	@ViewBuilder
	private func videoPlayerView(mediaItem: MediaItem) -> some View {
		ZStack {
			// Video Player
			if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
				let player = VideoPlayerManager.shared.getOrCreatePlayer(for: videoURL, postId: post.id)
				VideoPlayer(player: player)
					.frame(width: width, height: calculatedHeight)
					.clipped()
					.disabled(true) // Disable controls
					.onAppear {
						// Auto-play if visible
						if isVisible {
							VideoPlayerManager.shared.playVideo(playerId: playerId)
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
					.frame(width: width, height: calculatedHeight)
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
					Text(formatElapsedTime(elapsedTime))
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundColor(.white)
						.padding(.horizontal, 6)
						.padding(.vertical, 3)
						.background(Color.black.opacity(0.7))
						.cornerRadius(4)
						.padding(8)
				}
			}
		}
		.frame(height: calculatedHeight)
		.onTapGesture {
			showPostDetail = true
		}
	}
	
	// MARK: - Helper Methods
	private var shouldShowStar: Bool {
		if isIndividualCollection {
			// Only show star if user is a member
			guard let currentUserId = currentUserId,
				  let collection = collection else {
				return false
			}
			return collection.members.contains(currentUserId) || collection.ownerId == currentUserId
		} else {
			// Show star for all posts in non-individual collections
			return true
		}
	}
	
	private func checkStarVisibility() {
		showStar = shouldShowStar
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
						) { image, data, error, cacheType, finished, imageURL in
							if let image = image, finished, let imageURL = imageURL {
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

// MARK: - Preview
#Preview {
	PinterestPostGrid(
		posts: [
			CollectionPost(
				id: "1",
				title: "Beautiful sunset at the beach",
				collectionId: "col1",
				authorId: "user1",
				authorName: "john_doe",
				createdAt: Date(),
				firstMediaItem: MediaItem(
					imageURL: "https://example.com/image1.jpg",
					thumbnailURL: nil,
					videoURL: nil,
					videoDuration: nil,
					isVideo: false
				),
				mediaItems: [
					MediaItem(
						imageURL: "https://example.com/image1.jpg",
						thumbnailURL: nil,
						videoURL: nil,
						videoDuration: nil,
						isVideo: false
					)
				]
			),
			CollectionPost(
				id: "2",
				title: "Amazing city lights",
				collectionId: "col1",
				authorId: "user2",
				authorName: "jane_smith",
				createdAt: Date(),
				firstMediaItem: MediaItem(
					imageURL: "https://example.com/image2.jpg",
					thumbnailURL: nil,
					videoURL: nil,
					videoDuration: nil,
					isVideo: false
				),
				mediaItems: [
					MediaItem(
						imageURL: "https://example.com/image2.jpg",
						thumbnailURL: nil,
						videoURL: nil,
						videoDuration: nil,
						isVideo: false
					)
				]
			)
		],
		collection: nil,
		isIndividualCollection: false,
		currentUserId: "user1"
	)
}

