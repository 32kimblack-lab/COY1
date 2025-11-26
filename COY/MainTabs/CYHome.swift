import SwiftUI
import FirebaseAuth
import SDWebImageSwiftUI
import SDWebImage
import AVKit

// MARK: - Static Cache for CYHome
class HomeViewCache {
	static let shared = HomeViewCache()
	private init() {}
	
	private var hasLoadedDataOnce = false
	private var cachedFollowedCollections: [CollectionData] = []
	private var cachedPostsWithCollections: [(post: CollectionPost, collection: CollectionData)] = []
	private var cachedFollowedCollectionIds: Set<String> = []
	
	func hasDataLoaded() -> Bool {
		return hasLoadedDataOnce
	}
	
	func getCachedData() -> (collections: [CollectionData], postsWithCollections: [(post: CollectionPost, collection: CollectionData)], followedIds: Set<String>) {
		return (cachedFollowedCollections, cachedPostsWithCollections, cachedFollowedCollectionIds)
	}
	
	func setCachedData(collections: [CollectionData], postsWithCollections: [(post: CollectionPost, collection: CollectionData)], followedIds: Set<String>) {
		self.cachedFollowedCollections = collections
		self.cachedPostsWithCollections = postsWithCollections
		self.cachedFollowedCollectionIds = followedIds
		self.hasLoadedDataOnce = true
	}
	
	func clearCache() {
		hasLoadedDataOnce = false
		cachedFollowedCollections.removeAll()
		cachedPostsWithCollections.removeAll()
		cachedFollowedCollectionIds.removeAll()
	}
	
	func matchesCurrentFollowedIds(_ currentIds: Set<String>) -> Bool {
		return cachedFollowedCollectionIds == currentIds
	}
}

struct CYHome: View {
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var isMenuOpen = false
	@State private var followedCollections: [CollectionData] = []
	@State private var postsWithCollections: [(post: CollectionPost, collection: CollectionData)] = []
	@State private var isLoading = false
	@State private var selectedPost: CollectionPost?
	@State private var selectedCollection: CollectionData?
	@State private var isLoadingMore = false
	@State private var hasMoreData = true
	@State private var lastPostTimestamp: Date?
	@State private var showNotifications = false
	@State private var unreadNotificationCount = 0
	@State private var currentPostIndex = 0
	
	private let pageSize = 20
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				ZStack {
				// Main Content
				VStack(spacing: 0) {
					// Custom Header
					HStack {
						HStack {
							Image(systemName: "line.3.horizontal")
								.resizable()
								.frame(width: 25, height: 25)
								.foregroundColor(colorScheme == .dark ? .white : .black)
								.onTapGesture {
									withAnimation(.easeInOut(duration: 0.3)) {
										isMenuOpen.toggle()
									}
								}
							
							Text("COY")
								.font(.system(size: 28, weight: .bold))
								.foregroundColor(colorScheme == .dark ? .white : .black)
							
							if let uiImage = UIImage(named: "Icon") {
								Image(uiImage: uiImage)
									.resizable()
									.scaledToFit()
									.frame(width: 40, height: 40)
									.padding(.leading, -15)
							} else {
								EmptyView()
							}
						}
						
						Spacer()
						
						HStack(spacing: 15) {
							NavigationLink(destination: AddFriendsScreen()) {
								Image(systemName: "person.badge.plus")
									.resizable()
									.frame(width: 25, height: 25)
									.foregroundColor(colorScheme == .dark ? .white : .black)
							}
							
							Button(action: {
								showNotifications = true
							}) {
								ZStack(alignment: .topTrailing) {
									Image(systemName: "bell.fill")
										.resizable()
										.frame(width: 25, height: 25)
										.foregroundColor(colorScheme == .dark ? .white : .black)
									
									if unreadNotificationCount > 0 {
										Text("\(unreadNotificationCount)")
											.font(.caption2)
											.fontWeight(.bold)
											.foregroundColor(.white)
											.padding(4)
											.background(Color.red)
											.clipShape(Circle())
											.offset(x: 8, y: -8)
									}
								}
							}
							.fullScreenCover(isPresented: $showNotifications) {
								NotificationsView(isPresented: $showNotifications)
							}
						}
					}
					.padding(.horizontal)
					.padding(.top, 8)
					.background(colorScheme == .dark ? Color.black : Color.white)
					
					// Posts content - Instagram-like feed
					if isLoading {
						ProgressView("Loading posts...")
							.frame(maxWidth: .infinity, maxHeight: .infinity)
					} else if postsWithCollections.isEmpty {
						emptyStateView
					} else {
						postsView
					}
				}
				.scaleEffect(isMenuOpen ? 0.95 : 1.0)
				.animation(.easeInOut(duration: 0.3), value: isMenuOpen)
				
				// Side Menu Overlay (invisible - for tap to close)
				if isMenuOpen {
					Color.clear
						.ignoresSafeArea()
						.onTapGesture {
							withAnimation(.easeInOut(duration: 0.3)) {
								isMenuOpen = false
							}
						}
				}
				
				// Side Menu
				HStack {
					sideMenuView
						.frame(width: 320)
						.background(colorScheme == .dark ? Color.black : Color.white)
						.offset(x: isMenuOpen ? 0 : -320)
						.animation(.easeInOut(duration: 0.3), value: isMenuOpen)
					
					Spacer()
				}
			}
		}
		.refreshable {
			// Force refresh on pull-to-refresh
			loadFollowedCollectionsAndPosts(forceRefresh: true)
		}
		.onAppear {
			// Use cache if available, otherwise load
			if HomeViewCache.shared.hasDataLoaded() {
				let cached = HomeViewCache.shared.getCachedData()
				// Use cached data immediately
				self.followedCollections = cached.collections
				self.postsWithCollections = cached.postsWithCollections
				print("✅ CYHome: Using cached data")
				
				// Check if followed collection IDs have changed in background
				Task {
					guard let currentUserId = authService.user?.uid else { return }
					let currentFollowed = try? await CollectionService.shared.getFollowedCollections(userId: currentUserId)
					let currentFollowedIds = Set(currentFollowed?.map { $0.id } ?? [])
					
					if !HomeViewCache.shared.matchesCurrentFollowedIds(currentFollowedIds) {
						// Followed collections changed, reload
						await MainActor.run {
							loadFollowedCollectionsAndPosts(forceRefresh: true)
						}
					}
				}
			} else {
				// No cache, load fresh
			loadFollowedCollectionsAndPosts()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionFollowed"))) { notification in
			// Reload when user follows a collection
			if let userId = notification.userInfo?["userId"] as? String,
			   userId == authService.user?.uid {
				loadFollowedCollectionsAndPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnfollowed"))) { notification in
			// Reload when user unfollows a collection
			if let userId = notification.userInfo?["userId"] as? String,
			   userId == authService.user?.uid {
				loadFollowedCollectionsAndPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostCreated"))) { notification in
			// Reload when a new post is created in a followed collection
			if let collectionId = notification.object as? String,
			   followedCollections.contains(where: { $0.id == collectionId }) {
				loadFollowedCollectionsAndPosts(forceRefresh: true)
			}
		}
		.sheet(item: $selectedPost) { post in
			if let collection = selectedCollection {
				CYInsideCollectionView(collection: collection)
			}
		}
			}
		}
	
	private var emptyStateView: some View {
		VStack(spacing: 12) {
			Image(systemName: "tray")
				.font(.system(size: 42))
				.foregroundColor(.secondary)
			Text("No posts yet")
				.font(.headline)
				.foregroundColor(.secondary)
			Text("Follow collections to see their posts here")
				.font(.subheadline)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	private var postsView: some View {
		ScrollView {
			LazyVStack(spacing: 0) {
				ForEach(postsWithCollections.indices, id: \.self) { index in
					let item = postsWithCollections[index]
					PostDetailCard(post: item.post, collection: item.collection)
						.onTapGesture {
							selectedPost = item.post
							selectedCollection = item.collection
						}
						.onAppear {
							if index == postsWithCollections.count - 3 {
								loadMoreIfNeeded()
							}
						}
				}
				
				if isLoadingMore {
					HStack {
						Spacer()
						ProgressView()
						Spacer()
					}
					.padding()
				} else if !hasMoreData && !postsWithCollections.isEmpty {
					HStack {
						Spacer()
						Text("No more posts")
							.font(.footnote)
							.foregroundColor(.secondary)
						Spacer()
					}
					.padding()
				}
			}
		}
	}
	
	private var sideMenuView: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Header
			HStack {
				Text("Following")
					.font(.title2)
					.fontWeight(.semibold)
				Spacer()
				Button(action: { 
					withAnimation(.easeInOut(duration: 0.3)) { 
						isMenuOpen = false 
					}
				}) {
					Image(systemName: "xmark")
						.font(.system(size: 16, weight: .semibold))
						.foregroundColor(.primary)
				}
			}
			.padding()
			
			Divider()
			
			// Followed Collections List
			if followedCollections.isEmpty {
				VStack(spacing: 12) {
					Spacer()
					Image(systemName: "heart.slash")
						.font(.system(size: 40))
						.foregroundColor(.secondary)
					Text("Not following any collections")
						.font(.headline)
						.foregroundColor(.secondary)
					Text("Follow collections to see them here")
						.font(.subheadline)
						.foregroundColor(.secondary)
					Spacer()
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 12) {
						ForEach(followedCollections) { collection in
							FollowedCollectionRow(collection: collection) {
								// Unfollow action
								Task {
									await unfollowCollection(collection: collection)
								}
							}
							.padding(.horizontal, 16)
						}
					}
					.padding(.vertical, 8)
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
	
	private func loadFollowedCollectionsAndPosts(forceRefresh: Bool = false) {
		guard let currentUserId = authService.user?.uid else { return }
		
		// If we have cached data and not forcing refresh, skip loading
		if HomeViewCache.shared.hasDataLoaded() && !forceRefresh {
			print("⏭️ CYHome: Using cached data, skipping reload")
			return
		}
		
		isLoading = true
		Task {
			do {
				// Load followed collections
				let followed = try await CollectionService.shared.getFollowedCollections(userId: currentUserId)
				
				// Load posts from all followed collections
				var allPosts: [(post: CollectionPost, collection: CollectionData)] = []
				
				await withTaskGroup(of: [(post: CollectionPost, collection: CollectionData)].self) { group in
					for collection in followed {
						group.addTask {
							do {
								let posts = try await CollectionService.shared.getCollectionPostsFromFirebase(collectionId: collection.id)
								// Filter posts
								let filteredPosts = await CollectionService.filterPosts(posts)
								return filteredPosts.map { (post: $0, collection: collection) }
							} catch {
								print("Error loading posts for collection \(collection.id): \(error)")
								return []
							}
						}
					}
					
					for await collectionPosts in group {
						allPosts.append(contentsOf: collectionPosts)
					}
				}
				
				// Sort by creation date (newest first)
				allPosts.sort { $0.post.createdAt > $1.post.createdAt }
				
				// Cache the data
				let followedIds = Set(followed.map { $0.id })
				HomeViewCache.shared.setCachedData(
					collections: followed,
					postsWithCollections: allPosts,
					followedIds: followedIds
				)
				
				await MainActor.run {
					self.followedCollections = followed
					self.postsWithCollections = allPosts
					self.isLoading = false
				}
			} catch {
				print("❌ Error loading followed collections: \(error)")
				await MainActor.run {
					self.isLoading = false
				}
			}
		}
	}
	
	private func unfollowCollection(collection: CollectionData) async {
		guard let currentUserId = authService.user?.uid else { return }
		
		do {
			try await CollectionService.shared.unfollowCollection(
				collectionId: collection.id,
				userId: currentUserId
			)
			// Reload to update the list
			loadFollowedCollectionsAndPosts(forceRefresh: true)
		} catch {
			print("❌ Error unfollowing collection: \(error.localizedDescription)")
		}
	}
	
	private func loadMoreIfNeeded() {
		guard !isLoadingMore, hasMoreData else { return }
		// For now, we load all posts at once
		// Can implement pagination later if needed
		isLoadingMore = false
		hasMoreData = false
	}
}

// MARK: - Post Detail Card (Matching CYPostDetailView design)
struct PostDetailCard: View {
	let post: CollectionPost
	let collection: CollectionData
	@Environment(\.colorScheme) var colorScheme
	@State private var ownerProfileImageURL: String?
	@State private var ownerUsername: String?
	@StateObject private var videoPlayerManager = VideoPlayerManager.shared
	@State private var currentMediaIndex = 0
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@State private var taggedUsers: [UserService.AppUser] = []
	
	private let screenWidth: CGFloat = UIScreen.main.bounds.width
	
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Header: Collection info
			HStack(spacing: 12) {
				// Collection profile image
				if let imageURL = collection.imageURL, !imageURL.isEmpty {
					CachedProfileImageView(url: imageURL, size: 40)
						.clipShape(Circle())
				} else {
					CachedProfileImageView(url: ownerProfileImageURL ?? "", size: 40)
						.clipShape(Circle())
						.onAppear {
							loadOwnerInfo()
						}
				}
				
				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 4) {
						Text(collection.name)
							.font(.headline)
							.foregroundColor(.primary)
						
						if let username = ownerUsername {
							Text("•")
								.foregroundColor(.secondary)
							
							Text("@\(username)")
								.font(.subheadline)
								.foregroundColor(.secondary)
						}
					}
					
					Text(collection.type == "Individual" ? "Individual" : "\(collection.memberCount) members")
						.font(.caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
			}
			.padding(.horizontal)
			.padding(.vertical, 12)
			
			// Media - Using same design as CYPostDetailView
			mediaContentView
			
			// Bottom controls (matching CYPostDetailView)
			postBottomControls
			
			// Caption and Tags
			captionAndTagsView
			
			// Date
			Text(post.createdAt, style: .date)
				.font(.system(size: 11))
				.foregroundColor(colorScheme == .dark ? .gray : .black.opacity(0.7))
				.padding(.horizontal)
				.padding(.top, 4)
				.padding(.bottom, 12)
			
			Divider()
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.onAppear {
			loadOwnerInfo()
			calculateImageAspectRatios()
			loadTaggedUsers()
		}
	}
	
	// Calculate actual media height (same logic as CYPostDetailView)
	// ALL posts (single and multi-media) are capped at 55% of screen height
	private var actualMediaHeight: CGFloat {
		let mediaItems = post.mediaItems.isEmpty ? (post.firstMediaItem.map { [$0] } ?? []) : post.mediaItems
		
		if mediaItems.isEmpty {
			let maxAllowed = UIScreen.main.bounds.height * 0.55
			return maxAllowed
		}
		
		// Calculate natural height for the tallest item
		var tallestHeight: CGFloat = 0
		for mediaItem in mediaItems {
			let height = calculateHeight(for: mediaItem)
			tallestHeight = max(tallestHeight, height)
		}
		
		// ALWAYS cap at 55% of screen height (for both single and multi-media posts)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		return min(tallestHeight, maxAllowed)
	}
	
	// Check if content needs to scale down (exceeds 55%)
	private var needsScaling: Bool {
		let mediaItems = post.mediaItems.isEmpty ? (post.firstMediaItem.map { [$0] } ?? []) : post.mediaItems
		
		if mediaItems.isEmpty {
			return false
		}
		
		var tallestHeight: CGFloat = 0
		for mediaItem in mediaItems {
			let height = calculateHeight(for: mediaItem)
			tallestHeight = max(tallestHeight, height)
		}
		
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		return tallestHeight > maxAllowed
	}
	
	@ViewBuilder
	private var mediaContentView: some View {
		let mediaItems = post.mediaItems.isEmpty ? (post.firstMediaItem.map { [$0] } ?? []) : post.mediaItems
		
		// Calculate container height: tallest item's height, capped at 55% (matching CYPostDetailView)
		let tallestNaturalHeight: CGFloat = {
			if mediaItems.isEmpty {
				return UIScreen.main.bounds.height * 0.55
			}
			var tallest: CGFloat = 0
			for mediaItem in mediaItems {
				tallest = max(tallest, calculateHeight(for: mediaItem))
			}
			let maxAllowed = UIScreen.main.bounds.height * 0.55
			return min(tallest, maxAllowed)
		}()
		
		let containerHeight = tallestNaturalHeight
		
		ZStack(alignment: .center) {
			// Media carousel - each item displays at its natural height
			if mediaItems.count > 1 {
				TabView(selection: $currentMediaIndex) {
					ForEach(0..<mediaItems.count, id: \.self) { index in
						mediaItemView(mediaItems[index], index: index, containerHeight: containerHeight)
							.tag(index)
					}
				}
				.tabViewStyle(.page)
				.frame(maxWidth: .infinity)
				.frame(height: containerHeight) // Container height (tallest item, capped at 55%)
				
				// Page indicator (top right)
				VStack {
					HStack {
						Spacer()
						Text("\(currentMediaIndex + 1)/\(mediaItems.count)")
							.font(.caption)
							.fontWeight(.semibold)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
							.foregroundColor(.primary)
							.padding(.top, 12)
							.padding(.trailing, 12)
							.animation(.easeInOut(duration: 0.2), value: currentMediaIndex)
					}
					Spacer()
				}
				.allowsHitTesting(false)
			} else if let mediaItem = mediaItems.first {
				// Single media item - capped at 55%
				mediaItemView(mediaItem, index: 0, containerHeight: containerHeight)
					.frame(maxWidth: .infinity)
			}
		}
		.frame(maxWidth: .infinity)
		.animation(.easeInOut(duration: 0.08), value: currentMediaIndex)
	}
	
	@ViewBuilder
	private func mediaItemView(_ mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		let mediaItems = post.mediaItems.isEmpty ? (post.firstMediaItem.map { [$0] } ?? []) : post.mediaItems
		
		if mediaItem.isVideo, let videoURL = mediaItem.videoURL {
			// Video view - matching CYPostDetailView exactly
			videoItemView(mediaItem: mediaItem, index: index, containerHeight: containerHeight, videoURL: videoURL)
		} else {
			// Image view - matching CYPostDetailView exactly
			imageItemView(mediaItem: mediaItem, index: index, containerHeight: containerHeight)
		}
	}
	
	@ViewBuilder
	private func imageItemView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		let mediaItems = post.mediaItems.isEmpty ? (post.firstMediaItem.map { [$0] } ?? []) : post.mediaItems
		
		// Calculate natural height for this image
		let imageNaturalHeight = calculateHeight(for: mediaItem)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		
		// Check if image exceeds 55% - if so, scale down to fit
		let exceedsMax = imageNaturalHeight > maxAllowed
		let displayHeight = exceedsMax ? containerHeight : imageNaturalHeight
		
		// For multi-media posts, use container height; for single posts, use calculated display height
		let itemHeight = mediaItems.count == 1 ? displayHeight : containerHeight
		
		// Show blur if:
		// 1. Multi-media post and item is shorter than container, OR
		// 2. Single post exceeds max and needs to scale down (will have side space)
		let showBlur = (mediaItems.count > 1 && imageNaturalHeight < containerHeight) || 
					   (mediaItems.count == 1 && exceedsMax)
		
		ZStack(alignment: .center) {
			// Blur background - fills empty space (sides when scaled down, or bottom when shorter)
			if showBlur {
				blurBackgroundView(height: itemHeight, mediaItem: mediaItem)
					.frame(width: screenWidth, height: itemHeight)
					.clipped()
			}
			
			// Image - use .fit when scaling down to show full image, .fill otherwise
			if let imageURL = mediaItem.imageURL ?? mediaItem.thumbnailURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.aspectRatio(contentMode: exceedsMax ? .fit : .fill) // Use .fit when scaling down, .fill otherwise
					.frame(maxWidth: exceedsMax ? screenWidth : screenWidth) // Allow width to scale when using .fit
					.frame(maxHeight: displayHeight) // Cap at container height when scaling down
					.clipped()
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.2))
					.frame(width: screenWidth, height: displayHeight)
			}
		}
		.frame(width: screenWidth, height: itemHeight) // Container height for blur
		.clipped()
	}
	
	@ViewBuilder
	private func videoItemView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat, videoURL: String) -> some View {
		let mediaItems = post.mediaItems.isEmpty ? (post.firstMediaItem.map { [$0] } ?? []) : post.mediaItems
		
		// Calculate natural height for this video (just like images)
		let videoNaturalHeight = calculateHeight(for: mediaItem)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		
		// Check if video exceeds 55% - if so, scale down to fit
		let exceedsMax = videoNaturalHeight > maxAllowed
		let displayHeight = exceedsMax ? containerHeight : videoNaturalHeight
		
		// For multi-media posts, use container height; for single posts, use calculated display height
		let itemHeight = mediaItems.count == 1 ? displayHeight : containerHeight
		
		// Show blur if:
		// 1. Multi-media post and item is shorter than container, OR
		// 2. Single post exceeds max and needs to scale down (will have side space)
		let showBlur = (mediaItems.count > 1 && videoNaturalHeight < containerHeight) || 
					   (mediaItems.count == 1 && exceedsMax)
		
		ZStack(alignment: .center) {
			// Blur background - fills empty space (sides when scaled down, or bottom when shorter)
			if showBlur {
				blurBackgroundView(height: itemHeight, mediaItem: mediaItem)
					.frame(width: screenWidth, height: itemHeight)
					.clipped()
			}
			
			// Gray placeholder - shows while video loads
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(maxWidth: exceedsMax ? screenWidth : screenWidth)
				.frame(maxHeight: displayHeight)
			
			// Video Player - use .fit when scaling down to show full video, .fill otherwise
			if !videoURL.isEmpty {
				let player = videoPlayerManager.getOrCreatePlayer(for: videoURL, postId: "\(post.id)_\(index)")
				VideoPlayer(player: player)
					.aspectRatio(contentMode: exceedsMax ? .fit : .fill) // Use .fit when scaling down, .fill otherwise
					.frame(maxWidth: exceedsMax ? screenWidth : screenWidth) // Allow width to scale when using .fit
					.frame(maxHeight: displayHeight) // Cap at container height when scaling down
					.clipped()
					.ignoresSafeArea(.container, edges: .horizontal)
					.onAppear {
						if index == currentMediaIndex {
							videoPlayerManager.playVideo(playerId: "\(post.id)_\(videoURL)")
						}
					}
					.onDisappear {
						videoPlayerManager.pauseVideo(playerId: "\(post.id)_\(videoURL)")
					}
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.3))
					.frame(maxWidth: exceedsMax ? screenWidth : screenWidth)
					.frame(maxHeight: displayHeight)
			}
		}
		.frame(width: screenWidth, height: itemHeight) // Container height for blur
		.clipped()
	}
	
	// MARK: - Post Bottom Controls (matching CYPostDetailView)
	@ViewBuilder
	private var postBottomControls: some View {
		VStack(spacing: 12) {
			HStack {
				HStack(spacing: 12) {
					// Star button (placeholder - can add functionality later)
					Button(action: {}) {
						Image(systemName: "star")
							.font(.system(size: 18))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					
					// Comment button (placeholder)
					Button(action: {}) {
						Image(systemName: "bubble.right")
							.font(.system(size: 18))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					
					// Share button (placeholder)
					Button(action: {}) {
						Image(systemName: "arrow.turn.up.right")
							.font(.system(size: 18))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
				}
				Spacer()
			}
			.padding(.horizontal)
		}
		.padding(.top, 16)
		.padding(.bottom, 8)
	}
	
	// MARK: - Blur Background
	@ViewBuilder
	private func blurBackgroundView(height: CGFloat, mediaItem: MediaItem) -> some View {
		if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.aspectRatio(contentMode: .fill)
				.frame(width: screenWidth, height: height)
				.blur(radius: 20)
				.opacity(0.6)
		} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.aspectRatio(contentMode: .fill)
				.frame(width: screenWidth, height: height)
				.blur(radius: 20)
				.opacity(0.6)
		} else {
			LinearGradient(
				colors: colorScheme == .dark ? 
					[Color.white.opacity(0.3), Color.white.opacity(0.1)] :
					[Color.black.opacity(0.3), Color.black.opacity(0.1)],
				startPoint: .top,
				endPoint: .bottom
			)
			.frame(height: height)
		}
	}
	
	// MARK: - Height Calculation (matching CYPostDetailView)
	private func calculateHeight(for mediaItem: MediaItem) -> CGFloat {
		if mediaItem.isVideo {
			// For videos, use thumbnail aspect ratio if available, otherwise default 16:9
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
	
	// MARK: - Calculate Image Aspect Ratios
	private func calculateImageAspectRatios() {
		let mediaItems = post.mediaItems.isEmpty ? (post.firstMediaItem.map { [$0] } ?? []) : post.mediaItems
		
		for mediaItem in mediaItems {
			if !mediaItem.isVideo {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty {
					Task {
						if let url = URL(string: imageURL) {
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
	
	private func loadOwnerInfo() {
		Task {
			if let owner = try? await UserService.shared.getUser(userId: collection.ownerId) {
				await MainActor.run {
					ownerProfileImageURL = owner.profileImageURL
					ownerUsername = owner.username
				}
			}
		}
	}
	
	// MARK: - Caption and Tags View
	@ViewBuilder
	private var captionAndTagsView: some View {
		let hasCaption = post.caption != nil && !post.caption!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasTags = !taggedUsers.isEmpty
		
		if hasCaption || hasTags {
			VStack(alignment: .leading, spacing: 4) {
				// Caption first (if exists)
				if hasCaption {
					Text(post.caption!)
						.font(.system(size: 13))
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.frame(maxWidth: .infinity, alignment: .leading)
						.fixedSize(horizontal: false, vertical: true)
				}
				
				// Tags with @ symbol (if exists)
				if hasTags {
					// Create a single text with all tags
					let tagsText = taggedUsers.map { "@\($0.username)" }.joined(separator: " ")
					Text(tagsText)
						.font(.system(size: 13))
						.foregroundColor(.blue)
						.frame(maxWidth: .infinity, alignment: .leading)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(.horizontal)
			.padding(.top, 8)
		}
	}
	
	private func loadTaggedUsers() {
		Task {
			do {
				taggedUsers = try await PostService.shared.getTaggedUsers(postId: post.id)
			} catch {
				print("Error loading tagged users: \(error)")
			}
		}
	}
}

// MARK: - Video Player View
struct VideoPlayerView: View {
	let videoURL: String
	let thumbnailURL: String?
	@ObservedObject var videoPlayerManager: VideoPlayerManager
	@State private var isPlaying = false
	@State private var showControls = true
	
	var body: some View {
		ZStack {
			// Thumbnail
			if let thumbnailURL = thumbnailURL, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(maxWidth: .infinity)
					.opacity(isPlaying ? 0 : 1)
			} else {
				Color.black
			}
			
			// Video player (when playing)
			if isPlaying {
				if URL(string: videoURL) != nil {
					VideoPlayerViewController(player: videoPlayerManager.getOrCreatePlayer(for: videoURL, postId: ""))
						.frame(maxWidth: .infinity)
				}
			}
			
			// Play button overlay
			if !isPlaying {
				Button(action: {
					let playerId = "\(videoURL)"
					videoPlayerManager.playVideo(playerId: playerId)
					isPlaying = true
				}) {
					Image(systemName: "play.circle.fill")
						.font(.system(size: 60))
						.foregroundColor(.white.opacity(0.9))
				}
			}
		}
		.onAppear {
			_ = videoPlayerManager.getOrCreatePlayer(for: videoURL, postId: "")
		}
		.onDisappear {
			let playerId = "\(videoURL)"
			videoPlayerManager.pauseVideo(playerId: playerId)
		}
	}
}

// MARK: - Video Player View Controller Wrapper
struct VideoPlayerViewController: UIViewControllerRepresentable {
	let player: AVPlayer
	
	func makeUIViewController(context: Context) -> AVPlayerViewController {
		let controller = AVPlayerViewController()
		controller.player = player
		controller.showsPlaybackControls = false
		return controller
	}
	
	func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
		uiViewController.player = player
	}
}

// MARK: - Followed Collection Row (Side Menu) - Matching NotificationRow Design
struct FollowedCollectionRow: View {
	let collection: CollectionData
	let onUnfollow: () -> Void
	@State private var ownerProfileImageURL: String?
	@State private var ownerUsername: String?
	
	var body: some View {
		HStack(spacing: 12) {
			// Collection profile image (matching NotificationRow size: 50)
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				CachedProfileImageView(url: imageURL, size: 50)
					.clipShape(Circle())
			} else {
				if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty {
					CachedProfileImageView(url: ownerImageURL, size: 50)
						.clipShape(Circle())
				} else {
					DefaultProfileImageView(size: 50)
				}
			}
			
			// Collection info (matching NotificationRow text styling)
			VStack(alignment: .leading, spacing: 4) {
				// Collection name (matching NotificationRow message font: .subheadline)
				Text(collection.name)
					.font(.subheadline)
					.foregroundColor(.primary)
				
				// Username • Type (matching NotificationRow time font: .caption)
				HStack(spacing: 4) {
					if let username = ownerUsername {
						Text("@\(username)")
							.font(.caption)
							.foregroundColor(.secondary)
						
						Text("•")
							.font(.caption)
							.foregroundColor(.secondary)
					}
					
					Text(collection.type == "Individual" ? "Individual" : "\(collection.memberCount) members")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
			
			Spacer()
			
			// Unfollow button (matching Accept/Deny button sizing)
			Button(action: onUnfollow) {
				Text("Unfollow")
					.font(.system(size: 12, weight: .semibold))
					.foregroundColor(.white)
					.frame(minWidth: 60, maxWidth: 60)
					.padding(.vertical, 6)
					.background(Color.red)
					.cornerRadius(8)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(Color(.systemBackground))
		.cornerRadius(12)
		.shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
		.task {
			await loadOwnerInfo()
		}
	}
	
	private func loadOwnerInfo() async {
		if let owner = try? await UserService.shared.getUser(userId: collection.ownerId) {
			await MainActor.run {
				ownerProfileImageURL = owner.profileImageURL
				ownerUsername = owner.username
			}
		}
	}
}
