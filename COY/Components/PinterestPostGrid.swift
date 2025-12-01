import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import FirebaseAuth
import AVKit
import GoogleMobileAds
import Combine

// MARK: - Real-time User Profile Display Components

/// Displays post author name with real-time updates when user edits their profile
struct PostAuthorNameView: View {
	let authorId: String
	let fallbackName: String
	
	@State private var displayName: String = ""
	
	var body: some View {
		Text("@\(displayName.isEmpty ? fallbackName : displayName)")
			.onAppear {
				displayName = fallbackName
				// Subscribe to real-time updates for this user
				if !authorId.isEmpty {
					UserService.shared.subscribeToUserProfile(userId: authorId)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserProfileUpdated"))) { notification in
				// Update display when user profile changes
				if let updatedUserId = notification.object as? String,
				   updatedUserId == authorId,
				   let userInfo = notification.userInfo,
				   let newUsername = userInfo["username"] as? String {
					displayName = newUsername
				}
			}
	}
}

/// Displays collection owner name with real-time updates when user edits their profile
struct CollectionOwnerNameView: View {
	let ownerId: String
	let fallbackName: String
	
	@State private var displayName: String = ""
	
	var body: some View {
		Text(displayName.isEmpty ? fallbackName : displayName)
			.onAppear {
				displayName = fallbackName
				// Subscribe to real-time updates for this user
				UserService.shared.subscribeToUserProfile(userId: ownerId)
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserProfileUpdated"))) { notification in
				// Update display when user profile changes
				if let updatedUserId = notification.object as? String,
				   updatedUserId == ownerId,
				   let userInfo = notification.userInfo,
				   let newName = userInfo["name"] as? String {
					displayName = newName
				}
			}
	}
}

// MARK: - Pinterest Style Post Grid
struct PinterestPostGrid: View {
	let posts: [CollectionPost]
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	var postsCollectionMap: [String: CollectionData]? = nil // Map of post IDs to collections
	var showAds: Bool = true // Whether to show ads (hide on own profile)
	var adLocation: AdManager.AdLocation = .home // Ad location for proper ad unit ID
	var roundedCorners: Bool = false // Whether to show rounded corners (true for inside collection, false for home/search)
	var onPinPost: ((CollectionPost) -> Void)? = nil
	var onDeletePost: ((CollectionPost) -> Void)? = nil
	
	@State private var postHeights: [String: CGFloat] = [:]
	@StateObject private var videoPlayerManager = VideoPlayerManager.shared
	@StateObject private var gridVideoManager = GridVideoPlaybackManager.shared
	@StateObject private var adManager = AdManager.shared
	@State private var nativeAds: [String: GADNativeAd] = [:]
	
	// Pinterest-style measurements
	private var columns: Int {
		// Use 3 columns on iPad (matching Pinterest), 2 columns on iPhone
		UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
	}
	private let horizontalGutter: CGFloat = 16 // Spacing between columns (increased for better breathing room)
	private let verticalSpacing: CGFloat = 28 // Vertical spacing between items (increased for better breathing room)
	private let horizontalPadding: CGFloat = 16 // Padding from screen edges (matches Pinterest)
	
	// Computed properties for responsive sizing
	private var screenWidth: CGFloat {
		// Exclude safe area insets for accurate width calculation
		let bounds = UIScreen.main.bounds
		if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
		   let window = windowScene.windows.first {
			let safeAreaInsets = window.safeAreaInsets
			return bounds.width - safeAreaInsets.left - safeAreaInsets.right
		}
		return bounds.width
	}
	
	private var columnWidth: CGFloat {
		// Calculate column width: (screen width - (padding * 2) - (gutter * (columns - 1))) / columns
		let totalGutterSpace = horizontalGutter * CGFloat(columns - 1)
		return (screenWidth - (horizontalPadding * 2) - totalGutterSpace) / CGFloat(columns)
	}
	
	// Grid item enum to handle both posts and ads
	enum GridItem: Identifiable {
		case post(post: CollectionPost, index: Int, itemIndex: Int)
		case ad(key: String, index: Int)
		
		var id: String {
			switch self {
			case .post(let post, _, _):
				return "post_\(post.id)"
			case .ad(let key, _):
				return "ad_\(key)"
			}
		}
	}
	
	// Masonry layout: distribute posts into columns based on shortest column
	// Includes ads every 4 posts
	// Optimized: Calculate once and cache to avoid expensive recalculation
	private var columnArrays: [[GridItem]] {
		var columnsArray = Array(repeating: [GridItem](), count: columns)
		var columnHeights = Array(repeating: CGFloat.zero, count: columns)
		var itemIndex = 0
		
		for (postIndex, post) in posts.enumerated() {
			// Insert ad every 4 posts (after posts at index 3, 7, 11, etc.) - only if showAds is true
			if showAds && postIndex > 0 && postIndex % 4 == 0 {
				// Find shortest column for ad
			if let shortestColumnIndex = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset {
					let adKey = "ad_\(postIndex)"
					columnsArray[shortestColumnIndex].append(.ad(key: adKey, index: itemIndex))
				
					// Estimate ad height based on actual content (matches GridNativeAdCard calculation)
					// Media height + padding + labels + spacing
					let mediaHeight = max(columnWidth * 1.2, 120)
					var estimatedAdHeight: CGFloat = 16 // Top and bottom padding
					estimatedAdHeight += mediaHeight // Media view
					estimatedAdHeight += 8 + 12 + 8 // Spacing + ad label + spacing
					estimatedAdHeight += 36 + 8 // Headline (2 lines) + spacing
					estimatedAdHeight += 32 + 8 // Body (2 lines) + spacing
					estimatedAdHeight += 16 // Advertiser
					columnHeights[shortestColumnIndex] += estimatedAdHeight + verticalSpacing
					itemIndex += 1
				}
			}
			
			// Find shortest column for post
			if let shortestColumnIndex = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset {
				columnsArray[shortestColumnIndex].append(.post(post: post, index: postIndex, itemIndex: itemIndex))
				
				// Estimate height for this post
				let estimatedHeight = estimatePostHeight(for: post)
				columnHeights[shortestColumnIndex] += estimatedHeight + verticalSpacing
				itemIndex += 1
			}
		}
		
		return columnsArray
	}
	
	// Estimate post height before actual calculation (for masonry distribution)
	private func estimatePostHeight(for post: CollectionPost) -> CGFloat {
		// Base height for media (estimate based on aspect ratios)
		var mediaHeight: CGFloat = 0
		
		if let firstMedia = post.mediaItems.first {
			if firstMedia.isVideo {
				// Default 16:9 for videos
				mediaHeight = columnWidth * (9.0 / 16.0)
			} else {
				// Default 4:3 for images
				mediaHeight = columnWidth * (3.0 / 4.0)
			}
		} else {
			mediaHeight = columnWidth * (3.0 / 4.0) // Default
		}
		
		// Add height for caption/info section (estimated)
		let infoHeight: CGFloat = 80 // Approximate height for profile image, name, username, caption
		
		return mediaHeight + infoHeight
	}
	
	var body: some View {
		ScrollView {
			HStack(alignment: .top, spacing: horizontalGutter) {
				ForEach(columnArrays.indices, id: \.self) { columnIndex in
					VStack(spacing: verticalSpacing) {
						ForEach(columnArrays[columnIndex]) { item in
							gridItemView(for: item)
						}
					}
					.frame(width: columnWidth)
				}
			}
			.padding(.horizontal, horizontalPadding)
			.padding(.top, horizontalPadding)
			.padding(.bottom, horizontalPadding)
		}
		.onPreferenceChange(VideoFramesPreferenceKey.self) { frames in
			// Forward every card's frame and visibility to the grid manager
			for info in frames {
				// Only forward if it looks like a real video (non-empty url)
				guard !info.videoURL.isEmpty else {
					gridVideoManager.removeVideo(playerId: info.playerId)
					continue
				}
				gridVideoManager.updateVideoVisibility(
					postId: info.postId,
					videoURL: info.videoURL,
					frame: info.frame,
					visibility: info.visibility
				)
			}
			// evaluatePlayback is now called automatically in updateVideoVisibility
		}
		.onAppear {
			// Preload only a few ads to reduce initial load
			adManager.preloadNativeAds(count: 3, location: adLocation)
			// Ads will load lazily when placeholders appear (no upfront loading)
		}
		.onDisappear {
			// Clear all video tracking when grid disappears
			gridVideoManager.clearAll()
		}
	}
	
	// Extract view building to separate function to avoid SwiftUI warnings
	@ViewBuilder
	private func gridItemView(for item: GridItem) -> some View {
		switch item {
		case .post(let post, let postIndex, _):
			// Get collection for this post
			let postCollection = collection ?? postsCollectionMap?[post.id]
							PinterestPostCard(
				post: post,
								collection: postCollection,
								isIndividualCollection: isIndividualCollection,
								currentUserId: currentUserId,
								width: columnWidth,
								videoPlayerManager: videoPlayerManager,
								gridVideoManager: gridVideoManager,
								allPosts: posts,
				currentPostIndex: postIndex,
								roundedCorners: roundedCorners,
								onPinPost: onPinPost,
								onDeletePost: onDeletePost
							)
			.id("post_\(post.id)")
			
		case .ad(let adKey, _):
			if let nativeAd = nativeAds[adKey] {
				GridNativeAdCard(nativeAd: nativeAd, width: columnWidth)
					.id("ad_\(adKey)")
			} else {
				// Placeholder while ad loads
				RoundedRectangle(cornerRadius: 12)
					.fill(Color.gray.opacity(0.1))
					.frame(width: columnWidth, height: columnWidth * 1.5)
					.id("ad_placeholder_\(adKey)")
					.onAppear {
						// Load ad when placeholder appears
						adManager.loadNativeAd(adKey: adKey, location: adLocation) { ad in
							if let ad = ad {
								Task { @MainActor in
									nativeAds[adKey] = ad
								}
							}
						}
					}
			}
		}
	}
	
	// MARK: - Visibility and Height Tracking
}

// MARK: - Pinterest Post Card
struct PinterestPostCard: View {
	let post: CollectionPost
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	let width: CGFloat
	@ObservedObject var videoPlayerManager: VideoPlayerManager
	@ObservedObject var gridVideoManager: GridVideoPlaybackManager
	let allPosts: [CollectionPost]? // Optional: array of all posts for navigation
	let currentPostIndex: Int? // Optional: current post index in the array
	var roundedCorners: Bool = false // Whether to show rounded corners
	var onPinPost: ((CollectionPost) -> Void)? = nil
	var onDeletePost: ((CollectionPost) -> Void)? = nil
	
	@State private var imageHeight: CGFloat = 200
	@State private var showStar: Bool = false
	@State private var isStarred: Bool = false
	@State private var showPostDetail: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@State private var isVisible: Bool = false
	@State private var currentPageIndex: Int = 0 // Track current page in carousel
	@State private var ownerProfileImageURL: String? // Store owner's profile image URL for fallback
	@State private var imageLoadingStates: [String: Bool] = [:] // Track loading state for each image
	@State private var videoLoadingStates: [String: Bool] = [:] // Track loading state for each video
	@State private var videoReadyStates: [String: Bool] = [:] // Track if video is ready to play
	@State private var videoErrorStates: [String: Bool] = [:] // Track if video has error
	@State private var elapsedTime: Double = 0.0 // Track elapsed time for current video
	@State private var elapsedTimeCancellable: AnyCancellable? // Cancellable for elapsed time subscription
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
		VStack(alignment: .leading, spacing: 0) {
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
				
				// Loading placeholder for entire media container (while calculating dimensions)
				if calculatedHeight == 0 || contentHeight == 0 {
					Rectangle()
						.fill(colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.15))
						.frame(width: width, height: 200) // Default height while loading
				}
				
				// Blur background is now handled per-item in imageView and videoPlayerView
				// Each item that has a different height will show its own blur
				
				// Media content on top
				mediaContentView
					.frame(width: width)
					.frame(height: contentHeight)
					.clipped()
				
				// Pin icon badge overlay (top left corner) - only show in CYInsideCollectionView (when roundedCorners is true)
				if post.isPinned && roundedCorners {
					VStack {
						HStack {
							Image(systemName: "pin.fill")
								.font(.caption2)
								.fontWeight(.semibold)
								.foregroundColor(.white)
								.padding(.horizontal, 6)
								.padding(.vertical, 3)
								.background(Color.blue.opacity(0.8))
								.cornerRadius(4)
								.padding(8)
							Spacer()
						}
						Spacer()
					}
				}
			}
			.cornerRadius(roundedCorners ? 16 : 0) // Rounded corners for inside collection, sharp for home/search
			.onTapGesture {
				showPostDetail = true
			}
			.contextMenu {
				contextMenuContent
			}
			// Use new visibility system for single-video posts only
			.background(
				Group {
					// Only track visibility for single-video posts (not carousels)
					if post.mediaItems.count == 1,
					   let mediaItem = post.mediaItems.first,
					   mediaItem.isVideo,
					   let videoURL = mediaItem.videoURL {
						GeometryReader { geometry in
							Color.clear
								.preference(
									key: VideoFramesPreferenceKey.self,
									value: [VideoFrameInfo(
										playerId: "\(post.id)_\(videoURL)",
										postId: post.id,
										videoURL: videoURL,
										frame: geometry.frame(in: .global),
										visibility: calculateVisibilityPercentage(frame: geometry.frame(in: .global))
									)]
								)
						}
					} else {
						Color.clear
					}
				}
			)
			
			// Post Info - under the media (matches Pinterest spacing)
			VStack(alignment: .leading, spacing: 6) {
				// Collection profile image, collection name, username, and star
				HStack(alignment: .center, spacing: 8) {
					// Left side: Profile image with collection name and username on the same row
					// For inside collection view with members: Show ONLY username (no collection profile/name)
					// For home/search feeds: Show collection profile + name + username
					// Detect if we're inside a collection view (not home feed) by checking if collection is provided
					// Inside collection view: collection is set, roundedCorners is true
					// Home/search feeds: collection is nil or from postsCollectionMap, roundedCorners is false
					let isInsideCollectionView = collection != nil && roundedCorners
					let isInsideCollectionWithMembers = isInsideCollectionView && 
						collection?.type != "Individual" && 
						(collection?.memberCount ?? 0) > 0
					
					if !isIndividualCollection && !isInsideCollectionWithMembers {
						// Collection profile image - use same logic as CollectionRowDesign
						Group {
							if let collection = collection {
								if let imageURL = collection.imageURL, !imageURL.isEmpty {
									// Use collection's profile image if available
									CachedProfileImageView(url: imageURL, size: 26)
										.clipShape(Circle())
								} else {
									// Use owner's profile image as fallback
									if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty {
										CachedProfileImageView(url: ownerImageURL, size: 26)
											.clipShape(Circle())
									} else {
										// Fallback to default icon if owner has no profile image
										DefaultProfileImageView(size: 26)
									}
								}
							} else {
								DefaultProfileImageView(size: 26)
							}
						}
						.frame(width: 26, height: 26)
						
						// Collection name and username - on the same row as profile image
						VStack(alignment: .leading, spacing: 1) {
							// Collection name
							if let collection = collection {
								Text(collection.name)
									.font(.caption2)
									.fontWeight(.medium)
									.foregroundColor(.primary)
									.lineLimit(1)
							}
							
							// Username - below collection name (real-time from UserService)
							PostAuthorNameView(authorId: post.authorId, fallbackName: post.authorName)
									.font(.caption2)
									.fontWeight(.medium)
									.foregroundColor(.secondary)
									.lineLimit(1)
						}
					} else if isInsideCollectionWithMembers {
						// Inside collection with members: Show ONLY username (no collection profile/name)
						PostAuthorNameView(authorId: post.authorId, fallbackName: post.authorName)
							.font(.caption2)
							.fontWeight(.medium)
							.foregroundColor(.secondary)
							.lineLimit(1)
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
						.padding(.leading, 8) // Add extra spacing before star icon
					}
				}
				
				// Caption - use post.caption if available, otherwise post.title
				let captionText = post.caption ?? post.title
				if !captionText.isEmpty {
					Text(captionText)
						.font(.caption2)
						.foregroundColor(.secondary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}
			}
			.padding(.horizontal, 10) // Increased padding for text content for better spacing
			.padding(.top, 8) // Add top padding to separate from media
			.padding(.bottom, 4) // Bottom padding for better separation between posts
		}
		.onAppear {
			isVisible = true
			// Defer heavy operations to avoid blocking initial render
			Task { @MainActor in
			checkStarVisibility()
			loadStarStatus()
			// Load owner's profile image if collection has no imageURL (same as CollectionRowDesign)
			if let collection = collection, collection.imageURL?.isEmpty != false {
				loadOwnerProfileImage()
			}
			}
			// Defer aspect ratio calculation to background (non-blocking)
			Task.detached(priority: .utility) {
				await calculateImageAspectRatios()
			}
			// Initialize loading states for all media items (lightweight)
			for mediaItem in post.mediaItems {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty {
					imageLoadingStates[imageURL] = true // Start as loading
				}
				if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
					videoLoadingStates[videoURL] = true // Start as loading
				}
			}
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
			// Remove video from grid manager when card disappears
			// Use stable playerId format: "\(postId)_\(videoURL)"
			if post.mediaItems.count == 1,
			   let mediaItem = post.mediaItems.first,
			   mediaItem.isVideo,
			   let videoURL = mediaItem.videoURL {
				let playerId = "\(post.id)_\(videoURL)"
				gridVideoManager.removeVideo(playerId: playerId)
			}
			// Cancel elapsed time subscription
			elapsedTimeCancellable?.cancel()
			elapsedTimeCancellable = nil
			elapsedTime = 0.0
		}
		.fullScreenCover(isPresented: $showPostDetail) {
			CYPostDetailView(
				post: post,
				collection: collection,
				allPosts: allPosts,
				currentPostIndex: currentPostIndex
			)
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
			WebImage(url: url, options: [.lowPriority, .retryFailed, .scaleDownLargeImages])
				.resizable()
				.indicator(.activity)
				.aspectRatio(contentMode: .fill)
				.frame(width: width, height: fillHeight)
				.blur(radius: 20)
				.opacity(0.6)
		} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
			WebImage(url: url, options: [.lowPriority, .retryFailed, .scaleDownLargeImages])
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
			
			// Image on top - force fill to match Pinterest (no gaps)
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				ZStack {
					// Loading placeholder - color scheme aware
					if imageLoadingStates[imageURL] != false {
						Rectangle()
							.fill(colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.15))
							.frame(width: width, height: imageNaturalHeight)
					}
					
					WebImage(url: url, options: [.lowPriority, .retryFailed, .scaleDownLargeImages, .progressiveLoad])
						.onSuccess { image, data, cacheType in
							// Image loaded successfully
							Task { @MainActor in
							imageLoadingStates[imageURL] = false
							}
						}
						.onFailure { error in
							// Image failed to load - keep placeholder visible
							Task { @MainActor in
							imageLoadingStates[imageURL] = false
							}
						}
						.resizable()
						.indicator(.activity)
						.transition(.fade(duration: 0.2))
						.scaledToFill()
						.frame(width: width, height: imageNaturalHeight)
						.clipped()
				}
			} else {
				Rectangle()
					.fill(colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.15))
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
				let player = videoPlayerManager.player(for: videoURL, id: playerId)
				let isVideoReady = videoReadyStates[playerId] ?? false
				let hasVideoError = videoErrorStates[playerId] ?? false
				
				ZStack {
					// Thumbnail placeholder while video loads or if video fails
					if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
						WebImage(url: url, options: [.lowPriority, .retryFailed, .scaleDownLargeImages, .progressiveLoad])
							.resizable()
							.indicator(.activity)
							.aspectRatio(contentMode: .fill)
							.frame(width: width, height: videoNaturalHeight)
							.clipped()
							.opacity(isVideoReady && !hasVideoError ? 0 : 1) // Hide when video is playing
					} else {
						// Fallback placeholder
						Rectangle()
							.fill(colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.15))
							.frame(width: width, height: videoNaturalHeight)
							.opacity(isVideoReady && !hasVideoError ? 0 : 1) // Hide when video is playing
					}
					
					// Show VideoPlayer when ready and no error, OR if player is actually playing
					// This ensures the video shows even if state tracking is slightly off
					let shouldShowVideo = (isVideoReady && !hasVideoError) || (player.rate > 0 && player.currentItem?.status == .readyToPlay)
					if shouldShowVideo, let playerItem = player.currentItem, playerItem.status == .readyToPlay {
						VideoPlayer(player: player)
							.allowsHitTesting(false)
							.aspectRatio(contentMode: .fill)
							.frame(width: width, height: videoNaturalHeight)
							.clipped()
							.onAppear {
								// Ensure video is playing when view appears
								if player.rate == 0 && gridVideoManager.activeVideoIDs.contains(playerId) {
									player.isMuted = true
									player.play()
								}
							}
					}
				}
				.onAppear {
					// Check player item status
					if let playerItem = player.currentItem {
						// Update state based on current status
						switch playerItem.status {
						case .readyToPlay:
							videoReadyStates[playerId] = true
							videoErrorStates[playerId] = false
						case .failed:
							videoErrorStates[playerId] = true
							videoReadyStates[playerId] = false
						case .unknown:
							// Observe status changes
							let observer = playerItem.observe(\.status, options: [.new]) { item, _ in
								Task { @MainActor in
									switch item.status {
									case .readyToPlay:
										videoReadyStates[playerId] = true
										videoErrorStates[playerId] = false
									case .failed:
										videoErrorStates[playerId] = true
										videoReadyStates[playerId] = false
									default:
										break
									}
								}
							}
							// Store observer (will be cleaned up on disappear)
							_ = observer
						@unknown default:
							break
						}
					}
							// For single-video posts, ensure player is ready
							if post.mediaItems.count == 1 && mediaItem.isVideo {
								// Get the player from manager to ensure it's the same instance
								let actualPlayer = videoPlayerManager.player(for: videoURL, id: playerId)
								actualPlayer.isMuted = true
								
								// Set up looping
								if actualPlayer.currentItem != nil {
									actualPlayer.actionAtItemEnd = .none
									NotificationCenter.default.addObserver(
										forName: .AVPlayerItemDidPlayToEndTime,
										object: actualPlayer.currentItem,
										queue: .main
									) { _ in
										actualPlayer.seek(to: .zero) { _ in
											actualPlayer.play()
										}
									}
								}
								
								// Grid manager will handle playback based on visibility
								// Just ensure player is ready
								videoPlayerManager.playVideo(playerId: playerId)
							}
							
							// Subscribe to elapsed time updates for this video (for timer display)
							// Cancel any existing subscription first
							elapsedTimeCancellable?.cancel()
							
							// Get or create elapsed time publisher and subscribe
							if let publisher = videoPlayerManager.getElapsedTimePublisher(for: playerId) {
								// Get current elapsed time
								elapsedTime = videoPlayerManager.getElapsedTime(for: playerId)
								
								// Subscribe to updates (already on main actor)
								elapsedTimeCancellable = publisher
									.sink { time in
										elapsedTime = time
									}
							}
						}
						.onDisappear {
							// Pause when video disappears
							if post.mediaItems.count == 1 && mediaItem.isVideo {
								let actualPlayer = videoPlayerManager.findPlayer(by: playerId)
								actualPlayer?.pause()
								videoPlayerManager.pauseVideo(playerId: playerId)
							}
							// Cancel elapsed time subscription when video disappears
							elapsedTimeCancellable?.cancel()
							elapsedTimeCancellable = nil
							elapsedTime = 0.0
						}
				}
			
			// Duration Badge - at the top right (shows remaining time countdown)
			// Only show for the currently visible video in carousel, or for single videos
			if let duration = mediaItem.videoDuration,
			   (post.mediaItems.count == 1 || currentPageIndex == index) {
				VStack {
					HStack {
						Spacer()
						Text(formatRemainingTime(elapsed: elapsedTime, total: duration))
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
	
	private func formatRemainingTime(elapsed: Double, total: Double) -> String {
		// Show remaining time (countdown from total)
		// e.g., if total is 55 seconds and elapsed is 5 seconds, show 50 seconds remaining
		let remaining = max(0, total - elapsed)
		return formatDuration(remaining)
	}
	
	// MARK: - Load Owner Profile Image (same as CollectionRowDesign)
	private func loadOwnerProfileImage() {
		// Skip if already loaded
		if ownerProfileImageURL != nil {
			return
		}
		
		guard let collection = collection else { return }
		
		Task {
			do {
				let owner = try await UserService.shared.getUser(userId: collection.ownerId)
				await MainActor.run {
					ownerProfileImageURL = owner?.profileImageURL
				}
			} catch {
				print("Error loading owner profile image: \(error.localizedDescription)")
			}
		}
	}
	
	// MARK: - Calculate Visibility Percentage
	private func calculateVisibilityPercentage(frame: CGRect) -> Double {
		let screenHeight = UIScreen.main.bounds.height
		let safeAreaTop = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap { $0.windows }
			.first { $0.isKeyWindow }?
			.safeAreaInsets.top ?? 0
		
		let safeAreaBottom = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap { $0.windows }
			.first { $0.isKeyWindow }?
			.safeAreaInsets.bottom ?? 0
		
		let viewportTop = safeAreaTop
		let viewportBottom = screenHeight - safeAreaBottom
		
		let viewTop = frame.minY
		let viewBottom = frame.maxY
		let cardHeight = frame.height
		
		let visibleTop = max(viewportTop, viewTop)
		let visibleBottom = min(viewportBottom, viewBottom)
		let visibleHeight = max(0, visibleBottom - visibleTop)
		
		return cardHeight > 0 ? Double(visibleHeight / cardHeight) : 0.0
	}
	
	// MARK: - Calculate Image Aspect Ratios (Optimized - Non-blocking, Deferred)
	private func calculateImageAspectRatios() {
		// Defer aspect ratio calculation to avoid blocking initial render
		// Only calculate for visible items to avoid unnecessary work
		// Use background priority to not interfere with UI rendering
		Task.detached(priority: .utility) {
			// Capture post.mediaItems for use in detached task
			let mediaItems = await MainActor.run {
				post.mediaItems
			}
			
			for mediaItem in mediaItems {
				// Skip if already calculated (check on main actor)
				let imageURL = mediaItem.isVideo ? mediaItem.thumbnailURL : mediaItem.imageURL
				if let urlString = imageURL, !urlString.isEmpty {
					let alreadyCalculated = await MainActor.run {
						imageAspectRatios[urlString] != nil
					}
					if alreadyCalculated {
						continue
					}
					
					// Load image to get dimensions (low priority, non-blocking)
					if let url = URL(string: urlString) {
						// Use SDWebImage with low priority and scale down options for faster loading
						SDWebImageManager.shared.loadImage(
							with: url,
							options: [.lowPriority, .retryFailed, .scaleDownLargeImages],
							progress: nil
						) { image, data, error, cacheType, finished, loadedImageURL in
							if let image = image, finished {
								let aspectRatio = image.size.width / image.size.height
								let finalURL = loadedImageURL?.absoluteString ?? urlString
								Task { @MainActor in
									imageAspectRatios[finalURL] = aspectRatio
								}
							}
						}
					}
				}
			}
		}
	}
}

// MARK: - Video Frame Info for Aggregated Visibility Tracking
// A small struct to carry the identifying info + frame + visibility for each card
struct VideoFrameInfo: Equatable {
	let playerId: String   // "\(post.id)_\(videoURL)"
	let postId: String
	let videoURL: String
	let frame: CGRect
	let visibility: Double // 0.0 to 1.0 (percentage visible)
}

// PreferenceKey that aggregates frames from all cards
struct VideoFramesPreferenceKey: PreferenceKey {
	static var defaultValue: [VideoFrameInfo] { [] }
	
	static func reduce(value: inout [VideoFrameInfo], nextValue: () -> [VideoFrameInfo]) {
		// append new values (each card will send a single-element array)
		value.append(contentsOf: nextValue())
	}
}

