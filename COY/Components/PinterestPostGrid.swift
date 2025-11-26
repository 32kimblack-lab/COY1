import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import FirebaseAuth
import AVKit

// MARK: - Pinterest Style Post Grid
struct PinterestPostGrid: View {
	let posts: [CollectionPost]
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	var onPinPost: ((CollectionPost) -> Void)? = nil
	var onDeletePost: ((CollectionPost) -> Void)? = nil
	
	@State private var postHeights: [String: CGFloat] = [:]
	@StateObject private var videoPlayerManager = VideoPlayerManager.shared
	
	// Pinterest-style measurements
	private let columns = 2
	private let horizontalGutter: CGFloat = 16 // Spacing between columns (matches Pinterest)
	private let verticalSpacing: CGFloat = 20 // Spacing between rows (matches Pinterest) - this is now consistent because each card has bottom padding
	private let horizontalPadding: CGFloat = 16 // Padding from screen edges (matches Pinterest)
	private let cardBottomPadding: CGFloat = 12 // Consistent bottom padding for each card (ensures uniform spacing)
	
	// Computed properties for responsive sizing
	private var screenWidth: CGFloat {
		UIScreen.main.bounds.width
	}
	
	private var columnWidth: CGFloat {
		// Calculate column width: (screen width - (padding * 2) - gutter) / columns
		(screenWidth - (horizontalPadding * 2) - horizontalGutter) / CGFloat(columns)
	}
	
	var body: some View {
		ScrollView {
			LazyVStack(spacing: verticalSpacing) { // Consistent spacing between rows
				// Create two columns using HStack
				ForEach(0..<(posts.count + 1) / 2, id: \.self) { rowIndex in
					HStack(alignment: .top, spacing: horizontalGutter) {
						// Left column
						if rowIndex * 2 < posts.count {
							PinterestPostCard(
								post: posts[rowIndex * 2],
								collection: collection,
								isIndividualCollection: isIndividualCollection,
								currentUserId: currentUserId,
								width: columnWidth,
								videoPlayerManager: videoPlayerManager,
								onPinPost: onPinPost,
								onDeletePost: onDeletePost
							)
							.id("post_\(posts[rowIndex * 2].id)")
						} else {
							// Empty space to maintain alignment
							Spacer()
								.frame(width: columnWidth)
						}
						
						// Right column
						if rowIndex * 2 + 1 < posts.count {
							PinterestPostCard(
								post: posts[rowIndex * 2 + 1],
								collection: collection,
								isIndividualCollection: isIndividualCollection,
								currentUserId: currentUserId,
								width: columnWidth,
								videoPlayerManager: videoPlayerManager,
								onPinPost: onPinPost,
								onDeletePost: onDeletePost
							)
							.id("post_\(posts[rowIndex * 2 + 1].id)")
						} else {
							// Empty space to maintain alignment
							Spacer()
								.frame(width: columnWidth)
						}
					}
					.padding(.horizontal, horizontalPadding)
				}
			}
			.padding(.top, horizontalPadding) // Top padding
			.padding(.bottom, horizontalPadding) // Bottom padding
		}
		.coordinateSpace(name: "scroll")
	}
}

// MARK: - Pinterest Post Card
struct PinterestPostCard: View {
	let post: CollectionPost
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	let width: CGFloat
	@ObservedObject var videoPlayerManager: VideoPlayerManager
	var onPinPost: ((CollectionPost) -> Void)? = nil
	var onDeletePost: ((CollectionPost) -> Void)? = nil
	
	@State private var imageHeight: CGFloat = 200
	@State private var showStar: Bool = false
	@State private var isStarred: Bool = false
	@State private var showPostDetail: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@State private var isVisible: Bool = false
	@State private var currentVideoIndex: Int? = nil
	@State private var currentPageIndex: Int = 0 // Track current page in carousel
	@Environment(\.colorScheme) var colorScheme
	
	// Check if current user can pin this post
	private var canPin: Bool {
		guard let currentUserId = currentUserId, let collection = collection else { return false }
		// Individual collections: user can pin their own posts
		if isIndividualCollection {
			return post.authorId == currentUserId
		}
		// Multi-member collections: only owner/admin can pin
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		return isOwner || isAdmin
	}
	
	// Check if current user can delete this post
	private var canDelete: Bool {
		guard let currentUserId = currentUserId, let collection = collection else { return false }
		// User can always delete their own posts
		if post.authorId == currentUserId {
			return true
		}
		// Owner/admin can delete any post
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		return isOwner || isAdmin
	}
	
	// Calculate individual heights for each media item
	private func calculateHeight(for mediaItem: MediaItem) -> CGFloat {
		if mediaItem.isVideo {
			// For videos, use thumbnail aspect ratio if available, otherwise default 16:9
			if let thumbnailURL = mediaItem.thumbnailURL,
			   let aspectRatio = imageAspectRatios[thumbnailURL] {
				return width / aspectRatio
			} else {
				return width * (9.0 / 16.0) // Default 16:9
			}
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
		
		// For single media item, use natural height
		if post.mediaItems.count == 1 {
			return calculateHeight(for: post.mediaItems[0])
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
	
	// Check if a specific media item has a different height than other items
	private func hasDifferentHeight(mediaItem: MediaItem, atIndex: Int) -> Bool {
		// Single media item - no blur needed
		if post.mediaItems.count <= 1 {
			return false
		}
		
		// Calculate height for this specific item
		let thisHeight = calculateHeight(for: mediaItem)
		
		// Calculate heights for all other items
		let tolerance: CGFloat = 1.0
		for (index, otherItem) in post.mediaItems.enumerated() {
			if index != atIndex {
				let otherHeight = calculateHeight(for: otherItem)
				if abs(thisHeight - otherHeight) > tolerance {
					return true // This item has a different height
				}
			}
		}
		
		return false
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Media Content with blur background
			ZStack {
				// If all items have the same height, use natural height (like single post)
				// Otherwise, use calculated height (tallest)
				let contentHeight: CGFloat = {
					if post.mediaItems.count == 1 {
						return post.mediaItems.first.map { calculateHeight(for: $0) } ?? calculatedHeight
					} else if !hasDifferentHeights {
						// All items have same height - use natural height (like single post)
						return post.mediaItems.first.map { calculateHeight(for: $0) } ?? calculatedHeight
					} else {
						// Items have different heights - use tallest
						return calculatedHeight
					}
				}()
				
				// Blur background is now handled per-item in imageView and videoPlayerView
				// Each item that has a different height will show its own blur
				
				// Media content on top
				mediaContentView
					.frame(width: width)
					.frame(height: contentHeight)
					.clipped()
			}
			.cornerRadius(16) // Pinterest uses slightly larger corner radius
			.onTapGesture {
				showPostDetail = true
			}
			.contextMenu {
				contextMenuContent
			}
			.background(
				GeometryReader { geometry in
					Color.clear
						.preference(key: ViewOffsetKey.self, value: geometry.frame(in: .named("scroll")))
				}
			)
			.onPreferenceChange(ViewOffsetKey.self) { frame in
				checkVisibility(frame: frame)
			}
			
			// Post Info - under the media (matches Pinterest spacing)
			VStack(alignment: .leading, spacing: 6) {
				// Username and Star in same row
				HStack(alignment: .center, spacing: 8) {
					// Username - only show for Invite, Request, or Open collections
					if shouldShowUsername {
						if !post.authorName.isEmpty {
							Text("@\(post.authorName)")
								.font(.caption)
								.fontWeight(.medium)
								.foregroundColor(.primary)
								.lineLimit(1)
						}
					}
					
					Spacer()
					
					// Star Icon - ALWAYS show (filled when starred, outline when not)
					if shouldShowStar {
						Button(action: {
							Task {
								await toggleStar()
							}
						}) {
							Image(systemName: isStarred ? "star.fill" : "star")
							.font(.system(size: 16, weight: .medium))
								.foregroundColor(isStarred ? .yellow : .secondary)
						}
					}
				}
				
				// Caption - use post.caption if available, otherwise post.title
				let captionText = post.caption ?? post.title
				if !captionText.isEmpty {
					Text(captionText)
						.font(.caption)
						.foregroundColor(.secondary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}
			}
			.padding(.horizontal, 4) // Small padding for text content (matches Pinterest)
			.padding(.top, 8) // Consistent top spacing after media
			.padding(.bottom, 8) // Consistent bottom spacing after caption (ensures uniform spacing between posts)
		}
		.onAppear {
			checkStarVisibility()
			loadStarStatus()
			calculateImageAspectRatios()
			isVisible = true
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostStarred"))) { notification in
			if (notification.object as? String) == post.id {
				isStarred = true
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostUnstarred"))) { notification in
			if (notification.object as? String) == post.id {
				isStarred = false
			}
		}
		.onDisappear {
			isVisible = false
			// Pause video when card disappears
			if let videoIndex = currentVideoIndex,
			   videoIndex < post.mediaItems.count,
			   post.mediaItems[videoIndex].isVideo,
			   let videoURL = post.mediaItems[videoIndex].videoURL {
				let playerId = "\(post.id)_\(videoURL)"
				videoPlayerManager.pauseVideo(playerId: playerId)
			}
		}
		.fullScreenCover(isPresented: $showPostDetail) {
			CYPostDetailView(post: post, collection: collection)
		}
	}
	
	// MARK: - Context Menu
	@ViewBuilder
	private var contextMenuContent: some View {
		if canPin {
			Button(action: {
				onPinPost?(post)
			}) {
				Label(post.isPinned ? "Unpin" : "Pin", systemImage: post.isPinned ? "pin.slash" : "pin")
			}
		}
		
		if canDelete {
			Button(role: .destructive, action: {
				onDeletePost?(post)
			}) {
				Label("Delete", systemImage: "trash")
			}
		}
	}
	
	// Visibility check for video autoplay
	private func checkVisibility(frame: CGRect) {
		let screenHeight = UIScreen.main.bounds.height
		let cardTop = frame.minY
		let cardBottom = frame.maxY
		let cardHeight = frame.height
		
		// Check if card is 70% visible (30% or less out of frame)
		let visibleTop = max(0, cardTop)
		let visibleBottom = min(screenHeight, cardBottom)
		let visibleHeight = max(0, visibleBottom - visibleTop)
		let visibilityRatio = cardHeight > 0 ? visibleHeight / cardHeight : 0
		
		// Find first video in post
		if let videoIndex = post.mediaItems.firstIndex(where: { $0.isVideo }),
		   let videoURL = post.mediaItems[videoIndex].videoURL {
			let playerId = "\(post.id)_\(videoURL)"
			
			// If card is at least 70% visible and no other video is playing, play this one
			if visibilityRatio >= 0.7 {
				// Check if another video is currently playing
				if let activePlayerId = videoPlayerManager.activePlayerId, activePlayerId != playerId {
					// Another video is playing, don't start this one
					return
				}
				
				// Play this video
				currentVideoIndex = videoIndex
				videoPlayerManager.playVideo(playerId: playerId)
			} else {
				// Card is less than 70% visible, pause video
				if currentVideoIndex == videoIndex {
					videoPlayerManager.pauseVideo(playerId: playerId)
					currentVideoIndex = nil
				}
			}
		}
	}
	
	// MARK: - Blur Background View
	@ViewBuilder
	private var blurBackgroundView: some View {
		// For carousel, show blur that matches the current page
		if post.mediaItems.count > 1 {
			// Show blur for the currently visible page - use that item's image/video
			if currentPageIndex < post.mediaItems.count {
				blurBackgroundForItem(post.mediaItems[currentPageIndex], fillHeight: calculatedHeight)
			}
		} else if let firstMedia = post.firstMediaItem ?? post.mediaItems.first {
			// Single media item - show blur for that specific item
			blurBackgroundForItem(firstMedia, fillHeight: calculatedHeight)
		}
	}
	
	@ViewBuilder
	private func blurBackgroundForItem(_ mediaItem: MediaItem, fillHeight: CGFloat) -> some View {
		// Use the specific image/video from this media item for the blur
		// But fill the entire calculatedHeight area
		if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.aspectRatio(contentMode: .fill)
				.frame(width: width, height: fillHeight)
				.blur(radius: 20)
				.opacity(0.6)
		} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.aspectRatio(contentMode: .fill)
				.frame(width: width, height: fillHeight)
				.blur(radius: 20)
				.opacity(0.6)
		} else {
			// Fallback gradient - adapts to color scheme
			LinearGradient(
				colors: colorScheme == .dark 
					? [Color.white.opacity(0.1), Color.white.opacity(0.05)]
					: [Color.black.opacity(0.1), Color.black.opacity(0.05)],
				startPoint: .top,
				endPoint: .bottom
			)
			.frame(width: width, height: fillHeight)
		}
	}
	
	// MARK: - Media Content View
	@ViewBuilder
	private var mediaContentView: some View {
		if post.mediaItems.count > 1 {
			// Multiple media items - show swipeable carousel
			// If all items have same height, use natural height (like single post)
			// Otherwise, use calculated height (tallest)
			let containerHeight: CGFloat = {
				if !hasDifferentHeights {
					// All items have same height - use natural height (like single post)
					return post.mediaItems.first.map { calculateHeight(for: $0) } ?? calculatedHeight
				} else {
					// Items have different heights - use tallest
					return calculatedHeight
				}
			}()
			
			TabView(selection: $currentPageIndex) {
				ForEach(0..<post.mediaItems.count, id: \.self) { index in
					Group {
						if post.mediaItems[index].isVideo {
							videoPlayerView(mediaItem: post.mediaItems[index], index: index)
						} else {
							imageView(mediaItem: post.mediaItems[index], index: index)
						}
					}
					.tag(index)
				}
			}
			.tabViewStyle(.page)
			.frame(height: containerHeight)
		} else if let mediaItem = post.firstMediaItem ?? post.mediaItems.first {
			// Single media item OR all items have same height - use natural height
			if mediaItem.isVideo {
				// Video Player - use natural height
				videoPlayerView(mediaItem: mediaItem, index: 0)
			} else {
				// Image or Live Photo - use natural height
				imageView(mediaItem: mediaItem, index: 0)
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
	private func imageView(mediaItem: MediaItem, index: Int) -> some View {
		let imageNaturalHeight = calculateHeight(for: mediaItem)
		// If all items have same height, use natural height (like single post)
		// Otherwise, use calculated height (tallest)
		let itemHeight: CGFloat = {
			if post.mediaItems.count == 1 {
				return imageNaturalHeight
			} else if !hasDifferentHeights {
				// All items have same height - use natural height (like single post)
				return imageNaturalHeight
			} else {
				// Items have different heights - use tallest
				return calculatedHeight
			}
		}()
		let showBlur = post.mediaItems.count > 1 && hasDifferentHeights && hasDifferentHeight(mediaItem: mediaItem, atIndex: index)
		
		ZStack {
			// Blur background - show if this specific item has different height
			if showBlur {
				blurBackgroundForItem(mediaItem, fillHeight: itemHeight)
					.frame(width: width, height: itemHeight)
					.clipped()
			}
			
			// Image on top - use natural height, fill to avoid gaps
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.aspectRatio(contentMode: .fill) // Fill to avoid gaps like videos
					.frame(width: width, height: imageNaturalHeight) // Use natural height
					.clipped()
			} else {
				Rectangle()
					.fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
					.frame(width: width, height: imageNaturalHeight)
					.overlay(
						Image(systemName: "photo")
							.foregroundColor(colorScheme == .dark ? .white.opacity(0.3) : .black.opacity(0.3))
					)
			}
		}
		.frame(width: width, height: itemHeight) // Container height for blur
		.clipped()
	}
	
	// MARK: - Video Player View with Autoplay
	@ViewBuilder
	private func videoPlayerView(mediaItem: MediaItem, index: Int) -> some View {
		// Calculate natural height for this video (just like images)
		let videoNaturalHeight = calculateHeight(for: mediaItem)
		// If all items have same height, use natural height (like single post)
		// Otherwise, use calculated height (tallest)
		let itemHeight: CGFloat = {
			if post.mediaItems.count == 1 {
				return videoNaturalHeight
			} else if !hasDifferentHeights {
				// All items have same height - use natural height (like single post)
				return videoNaturalHeight
			} else {
				// Items have different heights - use tallest
				return calculatedHeight
			}
		}()
		let showBlur = post.mediaItems.count > 1 && hasDifferentHeights && hasDifferentHeight(mediaItem: mediaItem, atIndex: index)
		
		ZStack {
			// Blur background - show if this specific item has different height (fills empty space)
			// For single posts, also show blur if video is shorter than container (shouldn't happen, but just in case)
			if showBlur || (post.mediaItems.count == 1 && videoNaturalHeight < itemHeight) {
				blurBackgroundForItem(mediaItem, fillHeight: itemHeight)
					.frame(width: width, height: itemHeight)
					.clipped()
			}
			
			// Video Player (autoplay, no controls) - exactly like images: use natural height
			if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
				let playerId = "\(post.id)_\(videoURL)"
				let player = videoPlayerManager.getOrCreatePlayer(for: videoURL, postId: post.id)
				
				VideoPlayer(player: player)
					.allowsHitTesting(false) // Prevent taps from reaching video player (taps go to parent)
					.aspectRatio(contentMode: .fill) // Fill the frame to avoid black bars
					.frame(width: width, height: videoNaturalHeight) // Use natural height
					.clipped()
					.onAppear {
						// Autoplay when visible
						if index == 0 {
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
								if isVisible && currentVideoIndex == nil {
									if videoPlayerManager.activePlayerId == nil {
										currentVideoIndex = index
										videoPlayerManager.playVideo(playerId: playerId)
									}
								}
							}
						}
					}
					.onDisappear {
						videoPlayerManager.pauseVideo(playerId: playerId)
						if currentVideoIndex == index {
							currentVideoIndex = nil
						}
					}
			}
			
			// Duration Badge - at the top right
			if let duration = mediaItem.videoDuration {
				VStack {
					HStack {
						Spacer()
						Text(formatDuration(duration))
							.font(.caption2)
							.fontWeight(.semibold)
							.foregroundColor(.white)
							.padding(.horizontal, 6)
							.padding(.vertical, 3)
							.background(Color.black.opacity(0.7))
							.cornerRadius(4)
							.padding(8)
					}
					Spacer()
				}
			}
		}
		.frame(width: width, height: itemHeight) // Container height (for blur)
		.clipped()
		.contentShape(Rectangle())
		.onTapGesture {
			showPostDetail = true
		}
	}
	
	// MARK: - Helper Methods
	private var shouldShowUsername: Bool {
		// Only show username for Invite, Request, or Open collections (not Individual)
		guard let collection = collection else { return false }
		return collection.type != "Individual"
	}
	
	private var shouldShowStar: Bool {
		// Always show star for ALL posts (both individual and member collections)
		return currentUserId != nil
	}
	
	private func checkStarVisibility() {
		showStar = shouldShowStar
	}
	
	private func loadStarStatus() {
		guard currentUserId != nil else { return }
		Task {
			do {
				isStarred = try await PostService.shared.isPostStarred(postId: post.id)
			} catch {
				print("Error loading star status: \(error)")
			}
		}
	}
	
	private func toggleStar() async {
		guard currentUserId != nil else { return }
		let newStarredState = !isStarred
		do {
			try await PostService.shared.toggleStarPost(postId: post.id, isStarred: newStarredState)
			await MainActor.run {
				isStarred = newStarredState
				// Post notification to sync with post detail and other views
				NotificationCenter.default.post(
					name: NSNotification.Name(newStarredState ? "PostStarred" : "PostUnstarred"),
					object: post.id
				)
			}
		} catch {
			print("Error toggling star: \(error)")
		}
	}
	
	private func formatDuration(_ seconds: Double) -> String {
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
							) { image, data, error, cacheType, finished, loadedImageURL in
								if let image = image, finished, let loadedImageURL = loadedImageURL {
									let aspectRatio = image.size.width / image.size.height
									DispatchQueue.main.async {
										imageAspectRatios[loadedImageURL.absoluteString] = aspectRatio
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

// MARK: - View Offset Key for Scroll Detection
struct ViewOffsetKey: PreferenceKey {
	static var defaultValue: CGRect = .zero
	static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
		value = nextValue()
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
