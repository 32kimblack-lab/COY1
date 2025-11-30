import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import AVKit
import AVFoundation
import FirebaseAuth
import FirebaseFirestore
import Combine
import Photos
import GoogleMobileAds

struct CYPostDetailView: View {
	let initialPost: CollectionPost
	let collection: CollectionData?
	let allPosts: [CollectionPost]? // Optional: array of all posts for navigation
	let currentPostIndex: Int? // Optional: current post index in the array
	
	@State private var post: CollectionPost
	@State private var currentIndex: Int? // Track current index for navigation
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	@StateObject private var cyServiceManager = CYServiceManager.shared // Observe ServiceManager for real-time updates
	@StateObject private var adManager = AdManager.shared
	@State private var lastAdShownIndex: Int = -1
	@State private var nativeAds: [String: GADNativeAd] = [:] // Cache for native ads in post detail
	
	@State private var currentMediaIndex: Int = 0
	@State private var isStarred: Bool = false
	@State private var commentCount: Int = 0
	@State private var showComments: Bool = false
	@State private var showShare: Bool = false
	@State private var showStarredBy: Bool = false
	@State private var showTags: Bool = false
	@State private var showMenu: Bool = false
	@State private var showEditPost: Bool = false
	@State private var showReport: Bool = false
	@State private var showDeleteAlert: Bool = false
	@State private var showCommentsDisabledAlert: Bool = false
	@State private var showDownloadSuccessAlert: Bool = false
	@State private var showDownloadErrorAlert: Bool = false
	@State private var downloadErrorMessage: String = ""
	@State private var isDeleting: Bool = false
	@State private var isDownloading: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@State private var elapsedTimes: [Int: Double] = [:]
	@State private var timeObservers: [Int: AnyCancellable] = [:]
	@State private var userDownloadEnabled: Bool = false
	@State private var taggedUsers: [UserService.AppUser] = []
	@State private var collectionOwner: UserService.AppUser?
	@State private var postAuthor: UserService.AppUser?
	@State private var commentsListener: ListenerRegistration? // Real-time comment count listener
	@State private var showOwnerProfile: Bool = false
	@State private var showAuthorProfile: Bool = false
	@State private var loadedCollection: CollectionData? // Collection loaded if not provided initially
	@State private var maxMediaHeight: CGFloat = {
		// Initialize with 55% of screen height as default, will be recalculated based on content
		let screenHeight = UIScreen.main.bounds.height
		return screenHeight * 0.55
	}()
	
	// TabView-based navigation state (like Pinterest grid media swiping)
	@State private var currentPostTabIndex: Int = 0
	
	private let screenWidth: CGFloat = UIScreen.main.bounds.width
	private var backgroundColor: Color { colorScheme == .dark ? .black : .white }
	
	// Check if this is the current user's post
	private var isOwnPost: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return post.authorId == currentUserId
	}
	
	// Check if post author allows downloads (for showing button)
	private var canShowDownload: Bool {
		post.allowDownload
	}
	
	// Check if user can actually download (for enabling action)
	private var canDownload: Bool {
		post.allowDownload && userDownloadEnabled
	}
	
	init(post: CollectionPost, collection: CollectionData?, allPosts: [CollectionPost]? = nil, currentPostIndex: Int? = nil) {
		self.initialPost = post
		self.collection = collection
		self.allPosts = allPosts
		self.currentPostIndex = currentPostIndex
		_post = State(initialValue: post)
		_currentIndex = State(initialValue: currentPostIndex)
		// Initialize tab index - need to account for ads in the items array
		if let index = currentPostIndex, allPosts != nil {
			// Calculate the TabView index accounting for ads
			var tabIndex = index
			for i in 0..<index {
				if (i + 1) % 5 == 0 {
					tabIndex += 1 // Add 1 for each ad before this post
				}
			}
			_currentPostTabIndex = State(initialValue: tabIndex)
		} else if let index = currentPostIndex {
			_currentPostTabIndex = State(initialValue: index)
		}
	}
	
	var body: some View {
			ZStack {
			// Background color
				backgroundColor.ignoresSafeArea()
				
			// TabView-based navigation - like media carousel in Pinterest grid
			if let posts = allPosts, !posts.isEmpty {
				// Build items array with posts and ads (ad after every 5 posts)
				let items = buildItemsWithAds(posts: posts)
				
				TabView(selection: $currentPostTabIndex) {
					ForEach(0..<items.count, id: \.self) { index in
						switch items[index] {
						case .post(let postIndex):
							if postIndex < posts.count {
						PostDetailTabContentView(
									post: posts[postIndex],
							collection: collection ?? loadedCollection,
							authService: authService,
							onStarTapped: {
										let currentPost = posts[postIndex]
								if currentPost.authorId == authService.user?.uid {
									showStarredBy = true
								} else {
									Task {
										await toggleStar()
									}
								}
							},
							onCommentTapped: {
										let currentPost = posts[postIndex]
								if currentPost.allowReplies {
									showComments = true
								} else {
									showCommentsDisabledAlert = true
								}
							},
							onShareTapped: {
								showShare = true
							},
							isStarred: isStarred
						)
						.tag(index)
							}
						case .ad(let adKey):
							// Native ad view for post detail
							PostDetailAdView(adKey: adKey, nativeAds: $nativeAds, adManager: adManager)
								.tag(index)
						}
					}
				}
				.tabViewStyle(.page(indexDisplayMode: .never)) // Hide page indicators, use native swipe
				.onChange(of: currentPostTabIndex) { oldValue, newValue in
					// Pause ALL videos from previous post when swiping to new post
					if oldValue >= 0 && oldValue < items.count {
						switch items[oldValue] {
						case .post(let oldPostIndex):
							if oldPostIndex < posts.count {
								let previousPost = posts[oldPostIndex]
								for (index, mediaItem) in previousPost.mediaItems.enumerated() where mediaItem.isVideo {
									if let videoURL = mediaItem.videoURL {
										let playerId = "\(previousPost.id)_\(index)_\(videoURL)"
										VideoPlayerManager.shared.pauseVideo(playerId: playerId)
										if let player = VideoPlayerManager.shared.findPlayer(by: playerId) {
											player.isMuted = true
										}
									}
								}
							}
						default:
							break
						}
					}
					
					// Handle post changes (skip ads)
					if newValue < items.count {
						switch items[newValue] {
						case .post(let postIndex):
							if postIndex < posts.count {
								// Find old post index if it was a post
								var oldPostIndex: Int? = nil
								if oldValue < items.count {
									if case .post(let oldPostIdx) = items[oldValue] {
										oldPostIndex = oldPostIdx
									}
								}
								handlePostTabChange(
									from: oldPostIndex ?? (oldValue < posts.count ? oldValue : -1),
									to: postIndex,
									in: posts
								)
							}
						case .ad:
							// Preload next ad when viewing an ad
							if newValue + 1 < items.count {
								switch items[newValue + 1] {
								case .ad(let nextAdKey):
									loadAdIfNeeded(adKey: nextAdKey)
								default:
									break
								}
							}
						}
					}
				}
				.onAppear {
					// Preload interstitial ad when post detail view appears
					adManager.loadInterstitialAd()
					// Preload native ads when view appears
					for item in items {
						if case .ad(let adKey) = item {
							loadAdIfNeeded(adKey: adKey)
						}
					}
				}
				.zIndex(1) // Below header and bottom controls
			} else {
				// Fallback to single post view if no posts array
				mainContentView
					.zIndex(1)
			}
			
			// Header - always on top, updates based on current post
			VStack(spacing: 0) {
				Spacer()
					.frame(height: 0) // Push header down from top
					headerView
					.frame(maxWidth: .infinity)
					.allowsHitTesting(true)
					.contentShape(Rectangle())
					Spacer()
					.allowsHitTesting(false) // Don't block touches below
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			.padding(.top, 4) // Top padding for header - moved even higher
			.zIndex(1000)
			.allowsHitTesting(true) // Ensure header can receive touches
			.background(Color.clear) // Transparent background but still intercepts touches
			}
			.navigationBarBackButtonHidden(true)
			.navigationTitle("")
			.toolbar(.hidden, for: .tabBar)
			.ignoresSafeArea(.container, edges: .bottom)
			.sheet(isPresented: $showComments) {
				CommentsView(post: post)
					.environmentObject(authService)
					.presentationDetents([.medium])
					.presentationDragIndicator(.visible)
			}
			.sheet(isPresented: $showShare) {
				SharePostView(post: post)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showStarredBy) {
				StarredByView(postId: post.id)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showTags) {
				TagsView(taggedUsers: taggedUsers)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showReport) {
				ReportView(itemId: post.id, itemType: .post, itemName: post.title.isEmpty ? "Post" : post.title)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showEditPost) {
				EditPostView(post: post, collection: collection ?? loadedCollection)
					.environmentObject(authService)
			}
			.fullScreenCover(isPresented: $showOwnerProfile) {
				if let collection = collection ?? loadedCollection {
					NavigationStack {
						ViewerProfileView(userId: collection.ownerId)
							.environmentObject(authService)
					}
				}
			}
			.fullScreenCover(isPresented: $showAuthorProfile) {
				if let author = postAuthor {
					NavigationStack {
						ViewerProfileView(userId: author.userId)
							.environmentObject(authService)
					}
				}
			}
			.alert("Delete Post", isPresented: $showDeleteAlert) {
				Button("Cancel", role: .cancel) { }
				Button("Delete", role: .destructive) {
					Task {
						await deletePost()
					}
				}
			} message: {
				Text("Are you sure you want to delete this post? This action cannot be undone.")
			}
			.alert("Comments Disabled", isPresented: $showCommentsDisabledAlert) {
				Button("OK", role: .cancel) { }
			} message: {
				Text("User has comments off.")
			}
			.alert("Download Successful", isPresented: $showDownloadSuccessAlert) {
				Button("OK", role: .cancel) { }
			} message: {
				Text("Successfully downloaded to your camera roll.")
			}
			.alert("Download Failed", isPresented: $showDownloadErrorAlert) {
				Button("OK", role: .cancel) { }
			} message: {
				Text(downloadErrorMessage)
			}
		.onAppear {
			loadInitialData()
			setupListeners()
			// If collection is not provided, try to load it from post's collectionId
			if collection == nil && !post.collectionId.isEmpty {
				Task {
					await loadCollectionIfNeeded()
				}
			}
			// Preload interstitial ad for post swiping
			adManager.loadInterstitialAd()
		}
		.onDisappear {
			// Clean up listener when view disappears
			commentsListener?.remove()
			commentsListener = nil
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostUpdated"))) { notification in
			if let updatedPostId = notification.object as? String, updatedPostId == post.id {
				// Reload post data from Firestore when post is updated
				Task {
					await reloadPost()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostDeleted"))) { notification in
			if let deletedPostId = notification.object as? String, deletedPostId == post.id {
				// Dismiss view when post is deleted
				dismiss()
			}
		}
		.task {
			await calculateMaxMediaHeight()
		}
		.onDisappear {
			// Pause all videos when leaving the view
			pauseAllVideos()
			cleanupTimeObservers()
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
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
			// Immediately reload post detail when profile is updated to show new author username/name/images
			if let userId = notification.userInfo?["userId"] as? String,
			   userId == post.authorId {
				print("🔄 CYPostDetailView: Post author profile updated, reloading immediately to show new info")
				loadInitialData()
			}
		}
		.onChange(of: cyServiceManager.currentUser) { oldValue, newValue in
			// Real-time update when current user's profile changes via ServiceManager
			// If this post is by the current user, immediately reload to show updated info
			if newValue != nil, post.authorId == Auth.auth().currentUser?.uid {
				print("🔄 CYPostDetailView: Current user (post author) profile updated via ServiceManager, reloading immediately")
				loadInitialData()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentAdded"))) { notification in
			if (notification.object as? String) == post.id {
				// Real-time listener will update automatically, but we can also refresh here
				Task {
					do {
						commentCount = try await PostService.shared.getCommentCount(postId: post.id)
					} catch {
						print("Error updating comment count: \(error)")
					}
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentDeleted"))) { notification in
			if (notification.object as? String) == post.id {
				Task {
					do {
						commentCount = try await PostService.shared.getCommentCount(postId: post.id)
					} catch {
						print("Error updating comment count: \(error)")
					}
				}
			}
		}
	}
	
	// MARK: - Header View
	@ViewBuilder
	private var headerView: some View {
		// Get current post for header
		let currentPostForHeader: CollectionPost = {
			if let posts = allPosts, !posts.isEmpty, currentPostTabIndex >= 0 && currentPostTabIndex < posts.count {
				return posts[currentPostTabIndex]
			}
			return post
		}()
		
		HStack {
			Button(action: {
				dismiss()
			}) {
				Image(systemName: "chevron.backward")
					.font(.system(size: 20))
					.foregroundColor(colorScheme == .dark ? .white : .black)
					.frame(width: 46, height: 46)
			}
			.buttonStyle(.plain)
			.allowsHitTesting(true)
			.contentShape(Rectangle())
			
			Spacer()
			
			VStack(spacing: 3) {
				if let collection = collection ?? loadedCollection {
					Button(action: {
						Task {
							// Check if users are mutually blocked before navigating
							let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
							if !areMutuallyBlocked {
						showOwnerProfile = true
							}
						}
					}) {
						Text(collection.name)
							.font(.system(size: 18, weight: .semibold))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					.buttonStyle(.plain)
					.allowsHitTesting(true)
					.contentShape(Rectangle())
				}
				
				// Use current post's author info
				if let currentPostAuthor = postAuthor, currentPostAuthor.userId == currentPostForHeader.authorId, !currentPostAuthor.username.isEmpty {
					Button(action: {
						Task {
							// Check if users are mutually blocked before navigating
							let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: currentPostAuthor.userId)
							if !areMutuallyBlocked {
						showAuthorProfile = true
							}
						}
					}) {
						Text("@\(currentPostAuthor.username)")
							.font(.system(size: 14))
							.foregroundColor(.blue)
					}
					.buttonStyle(.plain)
					.allowsHitTesting(true)
					.contentShape(Rectangle())
				} else if !currentPostForHeader.authorName.isEmpty {
					Button(action: {
						Task {
							// Check if users are mutually blocked before navigating
							let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: currentPostForHeader.authorId)
							if !areMutuallyBlocked {
						showAuthorProfile = true
							}
						}
					}) {
						Text("@\(currentPostForHeader.authorName)")
							.font(.system(size: 14))
							.foregroundColor(.blue)
					}
					.buttonStyle(.plain)
					.allowsHitTesting(true)
					.contentShape(Rectangle())
				}
			}
			.allowsHitTesting(true)
			
			Spacer()
			
			Button(action: {
				showMenu.toggle()
			}) {
				Image(systemName: "ellipsis")
					.font(.system(size: 20))
					.foregroundColor(colorScheme == .dark ? .white : .black)
					.frame(width: 46, height: 46)
			}
			.buttonStyle(.plain)
			.allowsHitTesting(true)
			.contentShape(Rectangle())
			.confirmationDialog("", isPresented: $showMenu, titleVisibility: .hidden) {
				if canShowDownload {
					if isDownloading {
						Button("Downloading...") {
							// Disabled while downloading
						}
						.disabled(true)
					} else {
						Button("Download") {
							print("🔍 Download button tapped - allowDownload: \(post.allowDownload), userDownloadEnabled: \(userDownloadEnabled)")
							Task {
								await handleDownload()
							}
						}
					}
				}
				
				if isOwnPost {
					Button("Edit") {
						showEditPost = true
					}
					
					Button("Delete", role: .destructive) {
						showDeleteAlert = true
					}
				} else {
					Button("Report", role: .destructive) {
						showReport = true
					}
				}
			}
		}
		.padding(.horizontal)
		.padding(.top, 4) // Top padding for header content - moved even higher
		.padding(.bottom, 8)
		.frame(maxWidth: .infinity)
		.allowsHitTesting(true)
		.contentShape(Rectangle())
	}
	
	// MARK: - Main Content View
	@ViewBuilder
	private var mainContentView: some View {
					VStack(spacing: 0) {
			Color.clear.frame(height: 50)
			pagerView
		}
	}
	
	// MARK: - Post Detail Tab Content View (for TabView navigation)
	private struct PostDetailTabContentView: View {
		let post: CollectionPost
		let collection: CollectionData?
		let authService: AuthService
		
		@Environment(\.colorScheme) var colorScheme
		@State private var currentMediaIndex: Int = 0
		@State private var imageAspectRatios: [String: CGFloat] = [:]
		
		// Pass callbacks from parent for button actions
		var onStarTapped: (() -> Void)?
		var onCommentTapped: (() -> Void)?
		var onShareTapped: (() -> Void)?
		var isStarred: Bool = false
		
		private let screenWidth: CGFloat = UIScreen.main.bounds.width
		private let containerHeight: CGFloat = UIScreen.main.bounds.height * 0.55
		
		var body: some View {
						VStack(spacing: 0) {
				Color.clear.frame(height: 50)
				
				ScrollView {
					VStack(spacing: 0) {
						// Media content with blur effect
						if !post.mediaItems.isEmpty {
							// Calculate if we need fixed height (blur) or dynamic height (fits)
							let needsFixedHeight = calculateNeedsFixedHeight()
							let mediaHeight = needsFixedHeight ? containerHeight : calculateDynamicMediaHeight()
							
							ZStack(alignment: .center) {
								TabView(selection: $currentMediaIndex) {
									ForEach(0..<post.mediaItems.count, id: \.self) { index in
										PostMediaViewWithBlur(
											mediaItem: post.mediaItems[index],
											index: index,
											postId: post.id,
											post: post,
											currentMediaIndex: currentMediaIndex,
											imageAspectRatios: imageAspectRatios,
											colorScheme: colorScheme
										)
										.tag(index)
									}
							}
							.tabViewStyle(.page)
							.frame(maxWidth: .infinity)
							.frame(height: mediaHeight)
							// TabView handles swipes - buttons below will handle their own touches
							.allowsHitTesting(true)
							.onChange(of: currentMediaIndex) { oldValue, newValue in
								// Pause old video and play new video when swiping
								handleMediaIndexChangeInTabView(from: oldValue, to: newValue)
							}
								
								// Page indicator
								if post.mediaItems.count > 1 {
									VStack {
										HStack {
											Spacer()
											Text("\(currentMediaIndex + 1)/\(post.mediaItems.count)")
												.font(.caption)
												.fontWeight(.semibold)
												.padding(.horizontal, 8)
												.padding(.vertical, 4)
												.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
												.foregroundColor(.primary)
												.padding(.top, 12)
												.padding(.trailing, 12)
										}
										Spacer()
									}
									.allowsHitTesting(false)
								}
							}
						}
						
						// Bottom controls - with working buttons
						// No fixed padding when post fits - let it flow naturally
						PostBottomControlsViewWithActions(
							post: post,
							isStarred: isStarred,
							onStarTapped: onStarTapped,
							onCommentTapped: onCommentTapped,
							onShareTapped: onShareTapped
						)
						.padding(.top, 16)
						.padding(.bottom, 20)
						.allowsHitTesting(true)
						.contentShape(Rectangle())
						
						Spacer(minLength: 100)
					}
				}
			}
			.onAppear {
				calculateAspectRatios()
				// Auto-play first video if it's a video
				if !post.mediaItems.isEmpty && post.mediaItems[0].isVideo {
					playVideoInTabView(at: 0)
				}
			}
			.onDisappear {
				// Pause all videos when leaving this view
				pauseAllVideosInTabView()
			}
		}
		
		// Handle media index change in TabView (when swiping between videos)
		private func handleMediaIndexChangeInTabView(from oldIndex: Int, to newIndex: Int) {
			// Pause and mute old video
			if oldIndex >= 0 && oldIndex < post.mediaItems.count && post.mediaItems[oldIndex].isVideo,
			   let oldVideoURL = post.mediaItems[oldIndex].videoURL {
				let oldPlayerId = "\(post.id)_\(oldIndex)_\(oldVideoURL)"
				VideoPlayerManager.shared.pauseVideo(playerId: oldPlayerId)
				if let player = VideoPlayerManager.shared.findPlayer(by: oldPlayerId) {
					player.isMuted = true
				}
			}
			
			// Play new video if it's a video
			if newIndex >= 0 && newIndex < post.mediaItems.count && post.mediaItems[newIndex].isVideo {
				playVideoInTabView(at: newIndex)
			} else {
				// If new media is not a video, pause all videos
				pauseAllVideosInTabView()
			}
		}
		
		// Play video in TabView
		private func playVideoInTabView(at index: Int) {
			guard index >= 0 && index < post.mediaItems.count else { return }
			guard post.mediaItems[index].isVideo,
				  let videoURL = post.mediaItems[index].videoURL else { return }
			
			// Pause other videos in this post
			for i in 0..<post.mediaItems.count where i != index && post.mediaItems[i].isVideo {
				if let otherVideoURL = post.mediaItems[i].videoURL {
					let otherPlayerId = "\(post.id)_\(i)_\(otherVideoURL)"
					VideoPlayerManager.shared.pauseVideo(playerId: otherPlayerId)
					if let player = VideoPlayerManager.shared.findPlayer(by: otherPlayerId) {
						player.isMuted = true
					}
				}
			}
			
			// Play current video
			let playerId = "\(post.id)_\(index)_\(videoURL)"
			VideoPlayerManager.shared.playVideo(playerId: playerId)
			
			// Unmute the playing video
			if let player = VideoPlayerManager.shared.findPlayer(by: playerId) {
				player.isMuted = false
			}
		}
		
		// Pause all videos in TabView
		private func pauseAllVideosInTabView() {
			for (index, mediaItem) in post.mediaItems.enumerated() where mediaItem.isVideo {
				if let videoURL = mediaItem.videoURL {
					let playerId = "\(post.id)_\(index)_\(videoURL)"
					VideoPlayerManager.shared.pauseVideo(playerId: playerId)
					if let player = VideoPlayerManager.shared.findPlayer(by: playerId) {
						player.isMuted = true
					}
				}
			}
		}
				
		// Calculate if we need fixed container height (for blur) or dynamic height (fits naturally)
		private func calculateNeedsFixedHeight() -> Bool {
			guard !post.mediaItems.isEmpty else { return false }
			
			let isSinglePost = post.mediaItems.count == 1
			let allItemsSameHeight = checkIfAllItemsSameHeight()
			
			// Check if any item exceeds max height
			for mediaItem in post.mediaItems {
				let naturalHeight = calculateHeight(for: mediaItem)
				if naturalHeight > containerHeight {
					return true // Exceeds max, needs fixed height with blur
				}
			}
			
			// If single post fits, use dynamic height
			if isSinglePost {
				return false
			}
			
			// If multi-media with same heights that fit, use dynamic height
			if allItemsSameHeight {
				return false
			}
			
			// Different heights in multi-media - need fixed height
			return true
		}
		
		// Calculate dynamic height based on actual media height
		private func calculateDynamicMediaHeight() -> CGFloat {
			guard !post.mediaItems.isEmpty else { return containerHeight }
			
			// For single post, use its natural height
			if post.mediaItems.count == 1 {
				let height = calculateHeight(for: post.mediaItems[0])
				return min(height, containerHeight) // Cap at max
			}
			
			// For multi-media with same heights, use that height
			if checkIfAllItemsSameHeight() {
				let height = calculateHeight(for: post.mediaItems[0])
				return min(height, containerHeight) // Cap at max
			}
			
			// Different heights - use container height
			return containerHeight
		}
		
		// Calculate height for a media item
		private func calculateHeight(for mediaItem: MediaItem) -> CGFloat {
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty,
			   let cachedRatio = imageAspectRatios[imageURL] {
				return screenWidth / cachedRatio
			} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty,
					  let cachedRatio = imageAspectRatios[thumbnailURL] {
				return screenWidth / cachedRatio
			}
			return containerHeight
		}
		
		// Check if all media items have the same height
		private func checkIfAllItemsSameHeight() -> Bool {
			guard post.mediaItems.count > 1 else { return true } // Single item is considered "same"
			
			var heights: [CGFloat] = []
			for item in post.mediaItems {
				let height = calculateHeight(for: item)
				heights.append(height)
			}
			
			// Check if all heights are the same (with small tolerance for floating point)
			let tolerance: CGFloat = 1.0
			guard let firstHeight = heights.first else { return true }
			for height in heights {
				if abs(height - firstHeight) > tolerance {
					return false
				}
			}
			return true
		}
		
		private func calculateAspectRatios() {
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
	
	// MARK: - Post Media View With Blur
	private struct PostMediaViewWithBlur: View {
		let mediaItem: MediaItem
		let index: Int
		let postId: String
		let post: CollectionPost
		let currentMediaIndex: Int
		let imageAspectRatios: [String: CGFloat]
		let colorScheme: ColorScheme
		
		private let screenWidth: CGFloat = UIScreen.main.bounds.width
		private let containerHeight: CGFloat = UIScreen.main.bounds.height * 0.55
		
		var body: some View {
			if mediaItem.isVideo {
				videoViewWithBlur
			} else {
				imageViewWithBlur
			}
		}
		
		@ViewBuilder
		private var imageViewWithBlur: some View {
			// Calculate natural height - same logic as videos
			let imageNaturalHeight = calculateHeight(for: mediaItem)
			let maxAllowed = containerHeight
			let exceedsMax = imageNaturalHeight > maxAllowed
			let displayHeight = exceedsMax ? containerHeight : imageNaturalHeight
			
			// For single posts that fit: use natural height, no blur
			// For single posts that exceed: use containerHeight with blur
			// For multi-media: check if all items have same height
			let isSinglePost = post.mediaItems.count == 1
			let allItemsSameHeight = checkIfAllItemsSameHeight()
			
			let itemHeight: CGFloat = {
				if isSinglePost && !exceedsMax {
					// Single post that fits - use natural height, no blur
					return imageNaturalHeight
				} else if !isSinglePost && allItemsSameHeight && !exceedsMax {
					// Multi-media with same heights that fit - use natural height, no blur
					return imageNaturalHeight
				} else {
					// Exceeds max or different heights - use containerHeight with blur
					return containerHeight
				}
			}()
			
			// Calculate aspect ratio
			let aspectRatio: CGFloat = {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty,
				   let cachedRatio = imageAspectRatios[imageURL] {
					return cachedRatio
				}
				let naturalWidth = screenWidth
				return naturalWidth / imageNaturalHeight
			}()
			
			let isTall = aspectRatio < 1.0
			
			// Show blur only if:
			// 1. Exceeds max height (needs scaling)
			// 2. Multi-media with different heights (needs consistent container)
			// 3. Single/multi that doesn't fill container (has extra space)
			let needsBlur: Bool = {
				if isSinglePost && !exceedsMax {
					// Single post that fits - no blur
					return false
				} else if !isSinglePost && allItemsSameHeight && !exceedsMax {
					// Multi-media with same heights that fit - no blur
					return false
				} else {
					// Show blur for exceeds max, different heights, or extra space
					return exceedsMax || !allItemsSameHeight || imageNaturalHeight < itemHeight
				}
			}()
			
			let useFitContentMode = isTall || exceedsMax
			
			ZStack(alignment: .center) {
				// Blur background - only show when needed
				if needsBlur {
					blurBackgroundView(height: itemHeight)
						.frame(width: screenWidth, height: itemHeight)
						.clipped()
				}
				
				// Image - display like videos
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
					WebImage(url: url)
						.resizable()
						.indicator(.activity)
						.aspectRatio(contentMode: useFitContentMode ? .fit : .fill)
						.frame(width: screenWidth, height: displayHeight)
						.clipped()
				}
			}
			.frame(width: screenWidth, height: itemHeight)
			.clipped()
		}
		
		@ViewBuilder
		private var videoViewWithBlur: some View {
			// Calculate natural height
			let videoNaturalHeight = calculateHeight(for: mediaItem)
			let maxAllowed = containerHeight
			let exceedsMax = videoNaturalHeight > maxAllowed
			let displayHeight = exceedsMax ? containerHeight : videoNaturalHeight
			
			// For single posts that fit: use natural height, no blur
			// For single posts that exceed: use containerHeight with blur
			// For multi-media: check if all items have same height
			let isSinglePost = post.mediaItems.count == 1
			let allItemsSameHeight = checkIfAllItemsSameHeight()
			
			let itemHeight: CGFloat = {
				if isSinglePost && !exceedsMax {
					// Single post that fits - use natural height, no blur
					return videoNaturalHeight
				} else if !isSinglePost && allItemsSameHeight && !exceedsMax {
					// Multi-media with same heights that fit - use natural height, no blur
					return videoNaturalHeight
				} else {
					// Exceeds max or different heights - use containerHeight with blur
					return containerHeight
				}
			}()
			
			// Calculate aspect ratio
			let aspectRatio: CGFloat = {
				if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty,
				   let cachedRatio = imageAspectRatios[thumbnailURL] {
					return cachedRatio
				}
				let naturalWidth = screenWidth
				return naturalWidth / videoNaturalHeight
			}()
			
			let isTall = aspectRatio < 1.0
			
			// Show blur only if:
			// 1. Exceeds max height (needs scaling)
			// 2. Multi-media with different heights (needs consistent container)
			// 3. Single/multi that doesn't fill container (has extra space)
			let needsBlur: Bool = {
				if isSinglePost && !exceedsMax {
					// Single post that fits - no blur
					return false
				} else if !isSinglePost && allItemsSameHeight && !exceedsMax {
					// Multi-media with same heights that fit - no blur
					return false
				} else {
					// Show blur for exceeds max, different heights, or extra space
					return exceedsMax || !allItemsSameHeight || videoNaturalHeight < itemHeight
				}
			}()
			
			let useFitContentMode = isTall || exceedsMax
			
			ZStack(alignment: .center) {
				// Blur background - only show when needed
				if needsBlur {
					blurBackgroundView(height: itemHeight)
						.frame(width: screenWidth, height: itemHeight)
						.clipped()
				}
				
				// Video
				if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
					let playerId = "\(postId)_\(index)_\(videoURL)"
					let player = VideoPlayerManager.shared.player(for: videoURL, id: playerId)
					
					ZStack {
						// Show thumbnail while video loads
						if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
							WebImage(url: url)
								.resizable()
								.indicator(.activity)
								.aspectRatio(contentMode: useFitContentMode ? .fit : .fill)
								.frame(width: screenWidth, height: displayHeight)
								.clipped()
						}
						
						ScaledVideoPlayer(
							player: player,
							displayHeight: displayHeight,
							useFitContentMode: useFitContentMode,
							containerWidth: screenWidth,
							containerHeight: itemHeight
						)
						.frame(width: screenWidth, height: itemHeight)
						.clipped()
					}
					.onAppear {
						// Play if this is the current visible video
						if index == currentMediaIndex {
							VideoPlayerManager.shared.playVideo(playerId: playerId)
							if let player = VideoPlayerManager.shared.findPlayer(by: playerId) {
								player.isMuted = false
							}
						}
					}
					.onDisappear {
						VideoPlayerManager.shared.pauseVideo(playerId: playerId)
					}
				}
			}
			.frame(width: screenWidth, height: itemHeight)
			.clipped()
		}
		
		private func calculateHeight(for mediaItem: MediaItem) -> CGFloat {
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty,
			   let cachedRatio = imageAspectRatios[imageURL] {
				return screenWidth / cachedRatio
			} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty,
					  let cachedRatio = imageAspectRatios[thumbnailURL] {
				return screenWidth / cachedRatio
			}
			return containerHeight
		}
		
		// Check if all media items have the same height
		private func checkIfAllItemsSameHeight() -> Bool {
			guard post.mediaItems.count > 1 else { return true } // Single item is considered "same"
			
			var heights: [CGFloat] = []
			for item in post.mediaItems {
				let height = calculateHeight(for: item)
				heights.append(height)
			}
			
			// Check if all heights are the same (with small tolerance for floating point)
			let tolerance: CGFloat = 1.0
			guard let firstHeight = heights.first else { return true }
			for height in heights {
				if abs(height - firstHeight) > tolerance {
					return false
				}
			}
			return true
		}
		
		@ViewBuilder
		private func blurBackgroundView(height: CGFloat) -> some View {
			if index < post.mediaItems.count {
				let currentMedia = post.mediaItems[index]
				if let imageURL = currentMedia.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
					WebImage(url: url)
						.resizable()
						.indicator(.activity)
						.aspectRatio(contentMode: .fill)
						.frame(width: screenWidth, height: height)
						.blur(radius: 20)
						.opacity(0.6)
				} else if let thumbnailURL = currentMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
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
	}
	
	// MARK: - Post Bottom Controls View
	private struct PostBottomControlsView: View {
		let post: CollectionPost
		
		var body: some View {
			VStack(spacing: 12) {
				HStack {
					HStack(spacing: 12) {
						Image(systemName: "star")
							.font(.system(size: 18))
						Image(systemName: "bubble.right")
							.font(.system(size: 18))
						Image(systemName: "arrow.turn.up.right")
							.font(.system(size: 18))
					}
					Spacer()
				}
				.padding(.horizontal)
				
				if let caption = post.caption, !caption.isEmpty {
					Text(caption)
						.font(.system(size: 13))
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal)
				}
				
				Text(CYPostDetailView.formatPostDate(post.createdAt))
					.font(.system(size: 11))
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal)
			}
		}
	}
	
	// MARK: - Post Bottom Controls View With Actions (for TabView)
	private struct PostBottomControlsViewWithActions: View {
		let post: CollectionPost
		let isStarred: Bool
		let onStarTapped: (() -> Void)?
		let onCommentTapped: (() -> Void)?
		let onShareTapped: (() -> Void)?
		
		@Environment(\.colorScheme) var colorScheme
		
		var body: some View {
			VStack(spacing: 12) {
				HStack(alignment: .firstTextBaseline, spacing: 0) {
					HStack(spacing: 8) {
						Button(action: {
							onStarTapped?()
						}) {
							Image(systemName: isStarred ? "star.fill" : "star")
								.font(.system(size: 22))
								.foregroundColor(isStarred ? .yellow : (colorScheme == .dark ? .white : .black))
								.frame(width: 46, height: 46)
						}
						.buttonStyle(.plain)
						.allowsHitTesting(true)
						.contentShape(Rectangle())
						
						Button(action: {
							onCommentTapped?()
						}) {
							Image(systemName: "bubble.right")
								.font(.system(size: 22))
								.foregroundColor(colorScheme == .dark ? .white : .black)
								.frame(width: 46, height: 46)
						}
						.buttonStyle(.plain)
						.allowsHitTesting(true)
						.contentShape(Rectangle())
						
						Button(action: {
							onShareTapped?()
						}) {
							Image(systemName: "arrow.turn.up.right")
								.font(.system(size: 22))
								.foregroundColor(colorScheme == .dark ? .white : .black)
								.frame(width: 46, height: 46)
						}
						.buttonStyle(.plain)
						.allowsHitTesting(true)
						.contentShape(Rectangle())
					}
					.allowsHitTesting(true)
					Spacer()
				}
				.padding(.horizontal)
				.allowsHitTesting(true)
				.contentShape(Rectangle())
				
				if let caption = post.caption, !caption.isEmpty {
					Text(caption)
						.font(.system(size: 13))
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal)
				}
				
				HStack(alignment: .firstTextBaseline, spacing: 0) {
					Text(CYPostDetailView.formatPostDate(post.createdAt))
						.font(.system(size: 11))
					Spacer()
				}
				.padding(.horizontal)
			}
			.allowsHitTesting(true)
			.contentShape(Rectangle())
		}
	}
	
	// MARK: - Ad Integration
	
	enum TabItem {
		case post(Int) // Post index
		case ad(String) // Ad key
	}
	
	// Build items array with posts and ads (ad after every 5 posts)
	private func buildItemsWithAds(posts: [CollectionPost]) -> [TabItem] {
		var items: [TabItem] = []
		for (index, _) in posts.enumerated() {
			items.append(.post(index))
			// Insert ad after every 5 posts (after posts at index 4, 9, 14, etc.)
			if (index + 1) % 5 == 0 && index < posts.count - 1 {
				let adKey = "postdetail_ad_\(index)"
				items.append(.ad(adKey))
			}
		}
		return items
	}
	
	// Load ad if not already loaded
	private func loadAdIfNeeded(adKey: String) {
		guard nativeAds[adKey] == nil else { return }
		adManager.loadNativeAd(adKey: adKey, location: .postDetail) { ad in
			if let ad = ad {
				Task { @MainActor in
					nativeAds[adKey] = ad
					print("✅ CYPostDetailView: Native ad loaded for key: \(adKey)")
				}
			}
		}
	}
	
	// Handle TabView post change - like media carousel
	private func handlePostTabChange(from oldIndex: Int, to newIndex: Int, in posts: [CollectionPost]) {
		guard newIndex >= 0 && newIndex < posts.count else { return }
		
		// Pause and mute ALL videos from previous post
		if oldIndex >= 0 && oldIndex < posts.count {
			let previousPost = posts[oldIndex]
			for (index, mediaItem) in previousPost.mediaItems.enumerated() where mediaItem.isVideo {
				if let videoURL = mediaItem.videoURL {
					let playerId = "\(previousPost.id)_\(index)_\(videoURL)"
					VideoPlayerManager.shared.pauseVideo(playerId: playerId)
					// Ensure muted (pauseVideo should handle this, but double-check)
					if let player = VideoPlayerManager.shared.findPlayer(by: playerId) {
						player.isMuted = true
					}
				}
			}
		}
		
		// Update current post and index
		let newPost = posts[newIndex]
		post = newPost
		currentIndex = newIndex
		currentMediaIndex = 0
		
		// Load data for new post
		Task {
			// Try to load updated post from Firestore
			if let updatedPost = try? await CollectionService.shared.getPostById(postId: newPost.id) {
				await MainActor.run {
					self.post = updatedPost
					// Load post author for header
					Task {
						do {
							self.postAuthor = try await UserService.shared.getUser(userId: updatedPost.authorId)
						} catch {
							print("Error loading post author: \(error)")
						}
					}
					loadInitialData()
					// Auto-play video if first media item is a video
					if !updatedPost.mediaItems.isEmpty && updatedPost.mediaItems[0].isVideo {
						playVideo(at: 0)
					}
				}
			} else {
				// Fallback to post from array
				await MainActor.run {
					// Load post author for header
					Task {
						do {
							self.postAuthor = try await UserService.shared.getUser(userId: newPost.authorId)
						} catch {
							print("Error loading post author: \(error)")
						}
					}
					loadInitialData()
					// Auto-play video if first media item is a video
					if !newPost.mediaItems.isEmpty && newPost.mediaItems[0].isVideo {
						playVideo(at: 0)
				}
			}
		}
	}
	}
	
	// Navigate to a specific post in the array (kept for backward compatibility)
	private func navigateToPost(at index: Int, in posts: [CollectionPost]) {
		currentPostTabIndex = index
	}
	
	// MARK: - Pager View
	@ViewBuilder
	private var pagerView: some View {
		GeometryReader { geo in
			ZStack {
				ScrollView {
					VStack(spacing: 0) {
						VStack(spacing: 0) {
							mediaContentView
								.frame(maxWidth: geo.size.width)
								.frame(height: actualMediaHeight) // Use actual calculated height
								// Media carousel area - no post navigation gesture here
						}
						
						// Bottom controls area - buttons and caption
						postBottomControls
						
						Spacer(minLength: 100)
					}
				}
				
				// No gesture overlay needed - TabView handles all navigation
			}
		}
		.padding(.top)
	}
	
	
	// Calculate actual media height
	// ALL posts (single and multi-media) are capped at 55% of screen height
	private var actualMediaHeight: CGFloat {
		if post.mediaItems.isEmpty {
			let maxAllowed = UIScreen.main.bounds.height * 0.55
			return maxAllowed
		}
		
		// Calculate natural height for the tallest item
		var tallestHeight: CGFloat = 0
		for mediaItem in post.mediaItems {
			let height = calculateHeight(for: mediaItem)
			tallestHeight = max(tallestHeight, height)
		}
		
		// ALWAYS cap at 55% of screen height (for both single and multi-media posts)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		return min(tallestHeight, maxAllowed)
	}
	
	// Check if content needs to scale down (exceeds 55%)
	private var needsScaling: Bool {
		if post.mediaItems.isEmpty {
			return false
		}
		
		var tallestHeight: CGFloat = 0
		for mediaItem in post.mediaItems {
			let height = calculateHeight(for: mediaItem)
			tallestHeight = max(tallestHeight, height)
		}
		
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		return tallestHeight > maxAllowed
	}
	
	// MARK: - Media Content View
	@ViewBuilder
	private var mediaContentView: some View {
		// Calculate container height: tallest item's height, capped at 55%
		let tallestNaturalHeight: CGFloat = {
			if post.mediaItems.isEmpty {
				return UIScreen.main.bounds.height * 0.55
			}
			var tallest: CGFloat = 0
			for mediaItem in post.mediaItems {
				tallest = max(tallest, calculateHeight(for: mediaItem))
			}
			let maxAllowed = UIScreen.main.bounds.height * 0.55
			return min(tallest, maxAllowed)
		}()
		
		let containerHeight = tallestNaturalHeight
		
		ZStack(alignment: .center) {
			// Media carousel - each item displays at its natural height
			TabView(selection: $currentMediaIndex) {
				ForEach(0..<post.mediaItems.count, id: \.self) { index in
					mediaView(mediaItem: post.mediaItems[index], index: index, containerHeight: containerHeight)
						.tag(index)
				}
			}
			.tabViewStyle(.page)
			.frame(maxWidth: .infinity)
			.frame(height: containerHeight) // Container height (tallest item, capped at 55%)
			.onChange(of: currentMediaIndex) { oldValue, newValue in
				handleMediaIndexChange(from: oldValue, to: newValue)
			}
			
			// Page indicator (top right, like CYInsidepicture)
			if post.mediaItems.count > 1 {
				VStack {
					HStack {
						Spacer()
						Text("\(currentMediaIndex + 1)/\(post.mediaItems.count)")
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
			}
		}
		.frame(maxWidth: .infinity)
		.animation(.easeInOut(duration: 0.08), value: currentMediaIndex)
	}
	
	// MARK: - Blur Background
	@ViewBuilder
	private func blurBackgroundView(height: CGFloat) -> some View {
		if currentMediaIndex < post.mediaItems.count {
			let currentMedia = post.mediaItems[currentMediaIndex]
			if let imageURL = currentMedia.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: screenWidth, height: height)
					.blur(radius: 20)
					.opacity(0.6)
			} else if let thumbnailURL = currentMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
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
	
	// MARK: - Post Bottom Controls
	@ViewBuilder
	private var postBottomControls: some View {
		VStack(spacing: 12) {
			HStack(alignment: .firstTextBaseline, spacing: 0) {
				HStack(spacing: 8) {
					Button(action: {
						if isOwnPost {
							showStarredBy = true
						} else {
							Task {
								await toggleStar()
							}
						}
					}) {
						Image(systemName: isStarred ? "star.fill" : "star")
							.font(.system(size: 22))
							.foregroundColor(isStarred ? .yellow : (colorScheme == .dark ? .white : .black))
							.frame(width: 46, height: 46)
					}
					.buttonStyle(.plain)
					.allowsHitTesting(true)
					.contentShape(Rectangle())
					
					Button(action: {
						print("🔍 Comment button tapped - allowReplies: \(post.allowReplies)")
						if post.allowReplies {
							showComments = true
						} else {
							print("🚫 Comments disabled, showing alert")
							showCommentsDisabledAlert = true
						}
					}) {
						Image(systemName: "bubble.right")
							.font(.system(size: 22))
							.foregroundColor(colorScheme == .dark ? .white : .black)
							.frame(width: 46, height: 46)
					}
					.buttonStyle(.plain)
					.allowsHitTesting(true)
					.contentShape(Rectangle())
					
					Button(action: {
						showShare = true
					}) {
						Image(systemName: "arrow.turn.up.right")
							.font(.system(size: 22))
							.foregroundColor(colorScheme == .dark ? .white : .black)
							.frame(width: 46, height: 46)
					}
					.buttonStyle(.plain)
					.allowsHitTesting(true)
					.contentShape(Rectangle())
				}
				.allowsHitTesting(true)
				Spacer()
			}
			.padding(.horizontal)
			
			// Caption and Tags
			captionAndTagsView
			
			HStack(alignment: .firstTextBaseline, spacing: 0) {
				Text(CYPostDetailView.formatPostDate(post.createdAt))
				.font(.system(size: 11))
				.foregroundColor(colorScheme == .dark ? .gray : .black.opacity(0.7))
				Spacer()
			}
				.padding(.horizontal)
		}
		.padding(.top, 16)
		.padding(.bottom, 20)
		.allowsHitTesting(true) // Ensure bottom controls can receive touches
	}
	
	// MARK: - Bottom Actions Bar (kept for compatibility)
	private var bottomActionsBar: some View {
		HStack(spacing: 24) {
			// Star Button
			Button(action: {
				if isOwnPost {
					showStarredBy = true
				} else {
					Task {
						await toggleStar()
					}
				}
			}) {
				Image(systemName: isStarred ? "star.fill" : "star")
					.font(.system(size: 22))
					.foregroundColor(isStarred ? .yellow : (colorScheme == .dark ? .white : .black))
			}
			
			// Comment Button (with badge)
			Button(action: {
				print("🔍 Comment button tapped (bottomActionsBar) - allowReplies: \(post.allowReplies)")
				if post.allowReplies {
					showComments = true
				} else {
					print("🚫 Comments disabled, showing alert")
					showCommentsDisabledAlert = true
				}
			}) {
				ZStack(alignment: .topTrailing) {
					Image(systemName: "bubble.right")
						.font(.system(size: 22))
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					if commentCount > 0 {
						Circle()
							.fill(Color.blue)
							.frame(width: 8, height: 8)
							.offset(x: 4, y: -4)
					}
				}
			}
			
			// Share Button
			Button(action: {
				showShare = true
			}) {
				Image(systemName: "paperplane")
					.font(.system(size: 22))
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			
			Spacer()
			
			// Tags Button (only if there are tags)
			if !taggedUsers.isEmpty {
				Button(action: {
					showTags = true
				}) {
					Text("Tags")
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.background(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.9))
						.cornerRadius(8)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(colorScheme == .dark ? Color.black : Color.white)
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
		}
	}
	
	// MARK: - Caption Section
	private var captionAndTimerSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Caption and Tags
			captionAndTagsView
		}
		.padding(.bottom, 16)
	}
	
	// MARK: - Media Views
	@ViewBuilder
	private func mediaView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		if mediaItem.isVideo {
			videoView(mediaItem: mediaItem, index: index, containerHeight: containerHeight)
		} else {
			imageView(mediaItem: mediaItem, index: index, containerHeight: containerHeight)
		}
	}
	
	@ViewBuilder
	private func imageView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		// Calculate natural height for this image
		let imageNaturalHeight = calculateHeight(for: mediaItem)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		
		// Check if image exceeds 55% - if so, scale down to fit
		let exceedsMax = imageNaturalHeight > maxAllowed
		let displayHeight = exceedsMax ? containerHeight : imageNaturalHeight
		
		// For multi-media posts, use container height; for single posts, use calculated display height
		let itemHeight = post.mediaItems.count == 1 ? displayHeight : containerHeight
		
		// Calculate aspect ratio to determine if image is tall or wide
		let aspectRatio: CGFloat = {
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty,
			   let cachedRatio = imageAspectRatios[imageURL] {
				return cachedRatio
			}
			// Fallback: calculate from natural dimensions
			let naturalWidth = screenWidth
			return naturalWidth / imageNaturalHeight
		}()
		
		// Determine if image is tall (narrower than screen) or wide (wider than screen)
		let isTall = aspectRatio < 1.0 // Image is taller than it is wide
		let isWide = aspectRatio > 1.0 // Image is wider than it is tall
		
		// For multi-media posts:
		// - Wide images that are shorter than container: blur on top/bottom
		// - Tall images: blur on sides (when using .fit to show full image)
		// For single posts:
		// - When exceeds max: blur on sides (when using .fit)
		let needsBlurForMultiMedia = post.mediaItems.count > 1 && (
			(isWide && imageNaturalHeight < containerHeight) || // Wide image shorter than container
			(isTall) // Tall image will have side space when using .fit
		)
		let needsBlurForSingle = post.mediaItems.count == 1 && exceedsMax
		let showBlur = needsBlurForMultiMedia || needsBlurForSingle
		
		// For multi-media posts with tall images, use .fit to show full image (leaves side space for blur)
		// For wide images in multi-media, use .fill to fill width
		// For single posts that exceed max, use .fit to show full image
		let useFitContentMode = (post.mediaItems.count > 1 && isTall) || (post.mediaItems.count == 1 && exceedsMax)
		
		ZStack(alignment: .center) {
			// Blur background - fills empty space (sides for tall images, top/bottom for wide images)
			if showBlur {
				blurBackgroundView(height: itemHeight)
					.frame(width: screenWidth, height: itemHeight)
					.clipped()
			}
			
			// Image - use .fit for tall images or when scaling down, .fill for wide images
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.aspectRatio(contentMode: useFitContentMode ? .fit : .fill)
					.frame(maxWidth: useFitContentMode ? screenWidth : screenWidth)
					.frame(maxHeight: displayHeight)
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
	private func videoView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		// Calculate natural height for this video (just like images)
		let videoNaturalHeight = calculateHeight(for: mediaItem)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		
		// Check if video exceeds 55% - if so, scale down to fit
		let exceedsMax = videoNaturalHeight > maxAllowed
		let displayHeight = exceedsMax ? containerHeight : videoNaturalHeight
		
		// For multi-media posts, use container height; for single posts, use calculated display height
		let itemHeight = post.mediaItems.count == 1 ? displayHeight : containerHeight
		
		// Calculate aspect ratio to determine if video is tall or wide
		let aspectRatio: CGFloat = {
			if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty,
			   let cachedRatio = imageAspectRatios[thumbnailURL] {
				return cachedRatio
			}
			// Fallback: calculate from natural dimensions
			let naturalWidth = screenWidth
			return naturalWidth / videoNaturalHeight
		}()
		
		// Determine if video is tall (narrower than screen) or wide (wider than screen)
		let isTall = aspectRatio < 1.0 // Video is taller than it is wide
		let isWide = aspectRatio > 1.0 // Video is wider than it is tall
		
		// For multi-media posts:
		// - Wide videos that are shorter than container: blur on top/bottom
		// - Tall videos: blur on sides (when using .fit to show full video)
		// For single posts:
		// - When exceeds max: blur on sides (when using .fit)
		let needsBlurForMultiMedia = post.mediaItems.count > 1 && (
			(isWide && videoNaturalHeight < containerHeight) || // Wide video shorter than container
			(isTall) // Tall video will have side space when using .fit
		)
		let needsBlurForSingle = post.mediaItems.count == 1 && exceedsMax
		let showBlur = needsBlurForMultiMedia || needsBlurForSingle
		
		// For multi-media posts with tall videos, use .fit to show full video (leaves side space for blur)
		// For wide videos in multi-media, use .fill to fill width
		// For single posts that exceed max, use .fit to show full video
		let useFitContentMode = (post.mediaItems.count > 1 && isTall) || (post.mediaItems.count == 1 && exceedsMax)
		
		ZStack(alignment: .center) {
			// Blur background - fills empty space (sides for tall videos, top/bottom for wide videos)
			if showBlur {
				blurBackgroundView(height: itemHeight)
					.frame(width: screenWidth, height: itemHeight)
					.clipped()
			}
			
			// Video Player - use .fit for tall videos or when scaling down, .fill for wide videos
			// Match image behavior exactly
			if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
				let playerId = "\(post.id)_\(index)_\(videoURL)"
				let player = VideoPlayerManager.shared.player(for: videoURL, id: playerId)
				
				ZStack {
					// Show thumbnail while video loads
					if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
						WebImage(url: url)
							.resizable()
							.indicator(.activity)
							.aspectRatio(contentMode: useFitContentMode ? .fit : .fill)
							.frame(width: screenWidth, height: displayHeight)
							.clipped()
					}
					
					ScaledVideoPlayer(
						player: player,
						displayHeight: displayHeight,
						useFitContentMode: useFitContentMode,
						containerWidth: screenWidth,
						containerHeight: itemHeight
					)
					.frame(width: screenWidth, height: itemHeight)
					.clipped()
				}
				.ignoresSafeArea(.container, edges: .horizontal)
				.onAppear {
					// Play immediately if this is the current visible video
					if index == currentMediaIndex {
						playVideo(at: index)
					}
				}
				.onDisappear {
					// Pause and mute when video goes out of view
					VideoPlayerManager.shared.pauseVideo(playerId: playerId)
				}
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.2))
					.frame(width: screenWidth, height: displayHeight)
			}
		}
		.frame(width: screenWidth, height: itemHeight) // Container height for blur
		.clipped()
	}
	
	// MARK: - Unified Max Height Calculation
	private func calculateMaxMediaHeight() async {
		// Calculate 55% of screen height as the maximum
		let screenHeight = UIScreen.main.bounds.height
		let maxAllowedHeight = screenHeight * 0.55
		
		// If already calculated and not default, skip recalculation
		let defaultHeight = screenHeight * 0.55
		guard maxMediaHeight == defaultHeight || maxMediaHeight == 0 else { return }
		
		// If no media items, use default
		guard !post.mediaItems.isEmpty else {
			await MainActor.run {
				self.maxMediaHeight = min(400, maxAllowedHeight)
			}
			return
		}
		
		var calculatedHeight: CGFloat = 0
		let screenWidth = UIScreen.main.bounds.width
		
		for mediaItem in post.mediaItems {
			if mediaItem.isVideo {
				if let videoURL = mediaItem.videoURL, !videoURL.isEmpty, let url = URL(string: videoURL) {
					let asset = AVURLAsset(url: url)
					do {
						let tracks = try await asset.loadTracks(withMediaType: .video)
						if let track = tracks.first {
							let naturalSize = try await track.load(.naturalSize)
							let transform = try await track.load(.preferredTransform)
							let size = naturalSize.applying(transform)
							let width = abs(size.width)
							let height = abs(size.height)
							if width > 0 && height > 0 && !width.isNaN && !height.isNaN {
								let aspectRatio = width / height
								if aspectRatio.isFinite && aspectRatio > 0 {
									let fittedHeight = screenWidth / aspectRatio
									if fittedHeight.isFinite && !fittedHeight.isNaN {
										calculatedHeight = max(calculatedHeight, fittedHeight)
									}
								}
							}
						}
					} catch {
						// Use default if video loading fails
						calculatedHeight = max(calculatedHeight, 400)
					}
				}
			} else {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
					if let image = try? await loadImage(from: url) {
						let width = image.size.width
						let height = image.size.height
						if width > 0 && height > 0 && !width.isNaN && !height.isNaN {
							let aspectRatio = width / height
							if aspectRatio.isFinite && aspectRatio > 0 {
								let fittedHeight = screenWidth / aspectRatio
								if fittedHeight.isFinite && !fittedHeight.isNaN {
									calculatedHeight = max(calculatedHeight, fittedHeight)
								}
							}
						}
					}
				}
			}
		}
		
		// Use calculated height, but cap it at 60% of screen height
		// If no media loaded, use a default height
		let finalHeight = calculatedHeight > 0 ? min(calculatedHeight, maxAllowedHeight) : min(400, maxAllowedHeight)
		
		await MainActor.run {
			self.maxMediaHeight = finalHeight
		}
	}
	
	private func loadImage(from url: URL) async throws -> UIImage {
		let (data, _) = try await URLSession.shared.data(from: url)
		guard let image = UIImage(data: data) else {
			throw NSError(domain: "ImageLoadingError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
		}
		return image
	}
	
	// MARK: - Helper Functions
	private func setupListeners() {
		// Remove existing listener if any
		commentsListener?.remove()
		
		// Set up real-time comment count listener
		let db = Firestore.firestore()
		let commentsRef = db.collection("posts").document(post.id).collection("comments")
		
		commentsListener = commentsRef.addSnapshotListener { snapshot, error in
			if let error = error {
				print("Error listening to comments: \(error)")
				return
			}
			
			Task { @MainActor in
				self.commentCount = snapshot?.documents.count ?? 0
			}
		}
	}
	
	private func reloadPost() async {
		do {
			if let updatedPost = try await CollectionService.shared.getPostById(postId: post.id) {
				await MainActor.run {
					self.post = updatedPost
					print("✅ CYPostDetailView: Reloaded post - allowDownload: \(updatedPost.allowDownload), allowReplies: \(updatedPost.allowReplies)")
					// Reload other data that depends on the post (but don't reload the post again)
					Task {
						await reloadPostDependentData()
					}
				}
			}
		} catch {
			print("❌ Error reloading post: \(error)")
		}
	}
	
	private func reloadPostDependentData() async {
		// Load star status
		do {
			isStarred = try await PostService.shared.isPostStarred(postId: post.id)
		} catch {
			print("Error loading star status: \(error)")
		}
		
		// Load comment count
		do {
			commentCount = try await PostService.shared.getCommentCount(postId: post.id)
		} catch {
			print("Error loading comment count: \(error)")
		}
		
		// Load user download setting
		do {
			userDownloadEnabled = try await PostService.shared.getUserDownloadEnabled()
		} catch {
			print("Error loading download setting: \(error)")
		}
		
		// Load tagged users and filter out blocked users
		do {
			var loadedTaggedUsers = try await PostService.shared.getTaggedUsers(postId: post.id)
			// Filter out blocked users
			loadedTaggedUsers = await UserService.shared.filterUsersFromBlocked(loadedTaggedUsers)
			taggedUsers = loadedTaggedUsers
		} catch {
			print("Error loading tagged users: \(error)")
		}
		
		// Load post author
		do {
			postAuthor = try await UserService.shared.getUser(userId: post.authorId)
		} catch {
			print("Error loading post author: \(error)")
		}
		
		// Load collection owner if collection exists
		if let collection = collection ?? loadedCollection {
			do {
				collectionOwner = try await UserService.shared.getUser(userId: collection.ownerId)
			} catch {
				print("Error loading collection owner: \(error)")
			}
		}
	}
	
	private func loadInitialData() {
		Task {
			// First, reload the post from Firestore to get the latest data
			do {
				if let freshPost = try await CollectionService.shared.getPostById(postId: post.id) {
					await MainActor.run {
						self.post = freshPost
						print("✅ CYPostDetailView.loadInitialData: Reloaded post from Firestore - allowDownload: \(freshPost.allowDownload), allowReplies: \(freshPost.allowReplies)")
					}
				} else {
					print("⚠️ CYPostDetailView.loadInitialData: Could not reload post from Firestore, using initial post")
					print("🔍 CYPostDetailView: Post data - allowDownload: \(post.allowDownload), allowReplies: \(post.allowReplies)")
				}
			} catch {
				print("❌ CYPostDetailView.loadInitialData: Error reloading post: \(error)")
				print("🔍 CYPostDetailView: Using initial post data - allowDownload: \(post.allowDownload), allowReplies: \(post.allowReplies)")
			}
			
			// Load star status
			do {
				isStarred = try await PostService.shared.isPostStarred(postId: post.id)
			} catch {
				print("Error loading star status: \(error)")
			}
			
			// Load comment count
			do {
				commentCount = try await PostService.shared.getCommentCount(postId: post.id)
			} catch {
				print("Error loading comment count: \(error)")
			}
			
			// Load user download setting
			do {
				userDownloadEnabled = try await PostService.shared.getUserDownloadEnabled()
			} catch {
				print("Error loading download setting: \(error)")
			}
			
			// Load tagged users
			do {
				taggedUsers = try await PostService.shared.getTaggedUsers(postId: post.id)
			} catch {
				print("Error loading tagged users: \(error)")
			}
			
			// Load collection owner
		if let collection = collection ?? loadedCollection {
				do {
					collectionOwner = try await UserService.shared.getUser(userId: collection.ownerId)
				} catch {
					print("Error loading collection owner: \(error)")
				}
			}
			
			// Load post author
			do {
				postAuthor = try await UserService.shared.getUser(userId: post.authorId)
			} catch {
				print("Error loading post author: \(error)")
			}
			
			// Setup video players
			setupVideoPlayers()
			
			// Calculate aspect ratios for blur logic
			calculateImageAspectRatios()
			
			// Always play first video if it's a video (will loop automatically)
			// This ensures videos continue playing when navigating back to a post
			if !post.mediaItems.isEmpty && post.mediaItems[0].isVideo {
				// Small delay to ensure player is ready
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					self.playVideo(at: 0)
				}
			}
		}
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
	
	private func deletePost() async {
		guard isOwnPost else { return }
		isDeleting = true
		
		do {
			try await CollectionService.shared.deletePost(postId: post.id)
			print("✅ Post deleted successfully")
			
			// Post notification to refresh views
			await MainActor.run {
				NotificationCenter.default.post(
					name: NSNotification.Name("PostDeleted"),
					object: post.id,
					userInfo: ["postId": post.id, "collectionId": post.collectionId]
				)
				
				// Dismiss the view
				dismiss()
			}
		} catch {
			print("❌ Error deleting post: \(error)")
			await MainActor.run {
				isDeleting = false
			}
		}
	}
	
	private func toggleStar() async {
		let newStarredState = !isStarred
		do {
			try await PostService.shared.toggleStarPost(postId: post.id, isStarred: newStarredState)
			await MainActor.run {
				isStarred = newStarredState
				// Post notification to sync with Pinterest grid
				NotificationCenter.default.post(
					name: NSNotification.Name(newStarredState ? "PostStarred" : "PostUnstarred"),
					object: post.id
				)
			}
		} catch {
			print("Error toggling star: \(error)")
		}
	}
	
	private func handleDownload() async {
		await MainActor.run {
			isDownloading = true
		}
		
		do {
			// Request photo library permission
			let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
			guard status == .authorized || status == .limited else {
				await MainActor.run {
					isDownloading = false
					downloadErrorMessage = "Photo library access is required to download media. Please enable it in Settings."
					showDownloadErrorAlert = true
				}
				return
			}
			
			// Get media items with type information
			let mediaItems = try await PostService.shared.getPostMediaItems(postId: post.id)
			
			guard !mediaItems.isEmpty else {
				await MainActor.run {
					isDownloading = false
					downloadErrorMessage = "No media found to download."
					showDownloadErrorAlert = true
				}
				return
			}
			
			var savedCount = 0
			var errorCount = 0
			
			// Download and save each media item
			for mediaItem in mediaItems {
				do {
					if mediaItem.isVideo {
						// Download and save video
						let (data, _) = try await URLSession.shared.data(from: mediaItem.url)
						let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
						try data.write(to: tempURL)
						
						try await PHPhotoLibrary.shared().performChanges {
							PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
						}
						
						// Clean up temp file
						try? FileManager.default.removeItem(at: tempURL)
						savedCount += 1
					} else {
						// Download and save image
						let (data, _) = try await URLSession.shared.data(from: mediaItem.url)
						guard let image = UIImage(data: data) else {
							errorCount += 1
							continue
						}
						
						try await PHPhotoLibrary.shared().performChanges {
							PHAssetChangeRequest.creationRequestForAsset(from: image)
						}
						savedCount += 1
					}
				} catch {
					print("❌ Error saving media item: \(error)")
					errorCount += 1
				}
			}
			
			await MainActor.run {
				isDownloading = false
				if savedCount > 0 {
					if errorCount > 0 {
						downloadErrorMessage = "Downloaded \(savedCount) item(s), but \(errorCount) failed."
						showDownloadErrorAlert = true
					} else {
						showDownloadSuccessAlert = true
					}
				} else {
					downloadErrorMessage = "Failed to download media. Please try again."
					showDownloadErrorAlert = true
				}
			}
		} catch {
			await MainActor.run {
				isDownloading = false
				downloadErrorMessage = "Error downloading: \(error.localizedDescription)"
				showDownloadErrorAlert = true
			}
			print("❌ Error downloading post: \(error)")
		}
	}
	
	private func setupVideoPlayers() {
		for (index, mediaItem) in post.mediaItems.enumerated() {
			if mediaItem.isVideo, let videoURL = mediaItem.videoURL {
				_ = VideoPlayerManager.shared.getOrCreatePlayer(for: videoURL, postId: "\(post.id)_\(index)")
				setupElapsedTimeTracking(for: index, videoURL: videoURL)
			}
		}
	}
	
	private func setupElapsedTimeTracking(for index: Int, videoURL: String) {
		let playerId = "\(post.id)_\(index)_\(videoURL)"
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
		
		// Pause other videos in this post only (not videos from other posts)
		for i in 0..<post.mediaItems.count where i != index && post.mediaItems[i].isVideo {
			if let otherVideoURL = post.mediaItems[i].videoURL {
				let otherPlayerId = "\(post.id)_\(i)_\(otherVideoURL)"
				VideoPlayerManager.shared.pauseVideo(playerId: otherPlayerId)
				// Mute paused videos
				if let player = VideoPlayerManager.shared.findPlayer(by: otherPlayerId) {
					player.isMuted = true
				}
			}
		}
		
		// Play the current video (will loop automatically via VideoPlayerManager)
		let playerId = "\(post.id)_\(index)_\(videoURL)"
		VideoPlayerManager.shared.playVideo(playerId: playerId)
		
		// Unmute the playing video
		if let player = VideoPlayerManager.shared.findPlayer(by: playerId) {
			player.isMuted = false
		}
	}
	
	private func pauseAllVideos() {
		// Pause all videos from current post (including audio)
		// This ensures no audio plays when navigating away
		for (index, mediaItem) in post.mediaItems.enumerated() where mediaItem.isVideo {
			if let videoURL = mediaItem.videoURL {
				let playerId = "\(post.id)_\(index)_\(videoURL)"
				VideoPlayerManager.shared.pauseVideo(playerId: playerId)
				
				// Also mute the player to stop audio immediately
				if let player = VideoPlayerManager.shared.findPlayer(by: playerId) {
					player.isMuted = true
				}
			}
		}
	}
	
	private func handleMediaIndexChange(from oldIndex: Int, to newIndex: Int) {
		// Pause and mute the old video
		if oldIndex >= 0 && oldIndex < post.mediaItems.count && post.mediaItems[oldIndex].isVideo,
		   let oldVideoURL = post.mediaItems[oldIndex].videoURL {
			let oldPlayerId = "\(post.id)_\(oldIndex)_\(oldVideoURL)"
			VideoPlayerManager.shared.pauseVideo(playerId: oldPlayerId)
			// Ensure it's muted (pauseVideo should handle this, but double-check)
			if let player = VideoPlayerManager.shared.findPlayer(by: oldPlayerId) {
				player.isMuted = true
			}
		}
		
		// Play the new video if it's a video
		if newIndex >= 0 && newIndex < post.mediaItems.count && post.mediaItems[newIndex].isVideo {
			playVideo(at: newIndex)
		} else {
			// If new media is not a video, ensure all videos in this post are paused
			pauseAllVideos()
		}
	}
	
	private func cleanupTimeObservers() {
		for (_, cancellable) in timeObservers {
			cancellable.cancel()
		}
		timeObservers.removeAll()
	}
	
	// Load collection if not provided initially
	private func loadCollectionIfNeeded() async {
		guard collection == nil, !post.collectionId.isEmpty else { return }
		
		do {
			if let fetchedCollection = try await CollectionService.shared.getCollection(collectionId: post.collectionId) {
				await MainActor.run {
					self.loadedCollection = fetchedCollection
					// Also load collection owner
					Task {
						do {
							self.collectionOwner = try await UserService.shared.getUser(userId: fetchedCollection.ownerId)
						} catch {
							print("Error loading collection owner: \(error)")
						}
					}
				}
			}
		} catch {
			print("Error loading collection: \(error)")
		}
	}
	
	private func formatElapsedTime(_ seconds: Double) -> String {
		let minutes = Int(seconds) / 60
		let secs = Int(seconds) % 60
		return String(format: "%d:%02d", minutes, secs)
	}
	
	// MARK: - Post Date Formatting
	/// Formats post date: seconds -> minutes -> days -> full date after 7 days
	static func formatPostDate(_ date: Date) -> String {
		let now = Date()
		let timeInterval = now.timeIntervalSince(date)
		
		// Less than 60 seconds: show seconds
		if timeInterval < 60 {
			let seconds = Int(timeInterval)
			return seconds <= 1 ? "1 second ago" : "\(seconds) seconds ago"
		}
		
		// Less than 60 minutes: show minutes
		if timeInterval < 3600 {
			let minutes = Int(timeInterval / 60)
			return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
		}
		
		// Less than 24 hours: show hours
		if timeInterval < 86400 {
			let hours = Int(timeInterval / 3600)
			return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
		}
		
		// Less than 7 days: show days
		if timeInterval < 604800 { // 7 days = 604800 seconds
			let days = Int(timeInterval / 86400)
			return days == 1 ? "1 day ago" : "\(days) days ago"
		}
		
		// 7 days or more: show full date (e.g., "November 3rd, 2025")
		let formatter = DateFormatter()
		formatter.dateFormat = "MMMM d"
		
		// Get day with ordinal suffix (1st, 2nd, 3rd, 4th, etc.)
		let calendar = Calendar.current
		let day = calendar.component(.day, from: date)
		let daySuffix = getDaySuffix(day)
		
		let monthDay = formatter.string(from: date)
		let year = calendar.component(.year, from: date)
		
		return "\(monthDay)\(daySuffix), \(year)"
	}
	
	/// Returns the ordinal suffix for a day (st, nd, rd, th)
	static func getDaySuffix(_ day: Int) -> String {
		switch day {
		case 1, 21, 31:
			return "st"
		case 2, 22:
			return "nd"
		case 3, 23:
			return "rd"
		default:
			return "th"
		}
	}
	
	// MARK: - Height Calculation (matching Pinterest grid logic)
	// Calculate individual heights for each media item
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
}

// MARK: - Tags View
struct TagsView: View {
	let taggedUsers: [UserService.AppUser]
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				List {
					ForEach(taggedUsers) { user in
						NavigationLink(destination: ViewerProfileView(userId: user.userId).environmentObject(authService)) {
							// NavigationLink will be disabled if user is blocked - ViewerProfileView handles it
							HStack(spacing: 12) {
								if let profileImageURL = user.profileImageURL, !profileImageURL.isEmpty, let url = URL(string: profileImageURL) {
									WebImage(url: url)
										.resizable()
										.scaledToFill()
										.frame(width: 50, height: 50)
										.clipShape(Circle())
								} else {
									DefaultProfileImageView(size: 50)
								}
								
								VStack(alignment: .leading, spacing: 4) {
									Text(user.username)
										.font(.system(size: 15, weight: .semibold))
										.foregroundColor(.primary)
									if !user.name.isEmpty {
										Text(user.name)
											.font(.system(size: 14))
											.foregroundColor(.secondary)
									}
								}
							}
							.padding(.vertical, 4)
						}
					}
				}
				.listStyle(PlainListStyle())
			}
			.navigationTitle("Tagged Users")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
		}
	}
}

// MARK: - Scaled Video Player
struct ScaledVideoPlayer: UIViewControllerRepresentable {
	let player: AVPlayer
	let displayHeight: CGFloat
	let useFitContentMode: Bool
	let containerWidth: CGFloat
	let containerHeight: CGFloat
	
	func makeUIViewController(context: Context) -> ScaledVideoPlayerController {
		let controller = ScaledVideoPlayerController()
		controller.player = player
		controller.displayHeight = displayHeight
		controller.useFitContentMode = useFitContentMode
		controller.containerWidth = containerWidth
		controller.containerHeight = containerHeight
		return controller
	}
	
	func updateUIViewController(_ uiViewController: ScaledVideoPlayerController, context: Context) {
		uiViewController.player = player
		uiViewController.displayHeight = displayHeight
		uiViewController.useFitContentMode = useFitContentMode
		uiViewController.containerWidth = containerWidth
		uiViewController.containerHeight = containerHeight
		uiViewController.updateLayout()
	}
}

class ScaledVideoPlayerController: UIViewController {
	var player: AVPlayer? {
		didSet {
			playerViewController?.player = player
		}
	}
	var displayHeight: CGFloat = 0 {
		didSet {
			updateLayout()
		}
	}
	var useFitContentMode: Bool = false {
		didSet {
			updateLayout()
		}
	}
	var containerWidth: CGFloat = 0 {
		didSet {
			updateLayout()
		}
	}
	var containerHeight: CGFloat = 0 {
		didSet {
			updateLayout()
		}
	}
	
	private var playerViewController: AVPlayerViewController?
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		// Make the container view transparent so blur shows through
		view.backgroundColor = .clear
		
		let avPlayerVC = AVPlayerViewController()
		avPlayerVC.player = player
		avPlayerVC.showsPlaybackControls = true
		
		
		addChild(avPlayerVC)
		view.addSubview(avPlayerVC.view)
		avPlayerVC.view.backgroundColor = .clear
		avPlayerVC.didMove(toParent: self)
		
		playerViewController = avPlayerVC
		
		// Wait a bit for the controls to be rendered, then update layout
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			self.updateLayout()
		}
	}
	
	func updateLayout() {
		guard let playerVC = playerViewController else { return }
		
		// Always use full size (1.0) for controls regardless of video size
		// This ensures all controls (bars, buttons, skip buttons) are the same size
		let scaleFactor: CGFloat = 1.0
		
		// Update player view frame - always fill the container
		// The videoGravity will determine how the video content is displayed
		playerVC.view.frame = CGRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
		playerVC.view.autoresizingMask = []
		
		// Set the videoGravity based on content mode
		// This is done by accessing the AVPlayerViewController's contentOverlayView
		// and setting the playerLayer's videoGravity
		DispatchQueue.main.async {
			// Find the AVPlayerLayer in the view hierarchy
			self.setVideoGravity(for: playerVC.view, gravity: self.useFitContentMode ? .resizeAspect : .resizeAspectFill)
			
			// Scale controls - always full size
			self.scaleControls(in: playerVC.view, scale: scaleFactor)
		}
	}
	
	private func setVideoGravity(for view: UIView, gravity: AVLayerVideoGravity) {
		// Recursively find AVPlayerLayer and set videoGravity
		if let playerLayer = view.layer as? AVPlayerLayer {
			playerLayer.videoGravity = gravity
		}
		for subview in view.subviews {
			setVideoGravity(for: subview, gravity: gravity)
		}
		// Also check sublayers
		if let sublayers = view.layer.sublayers {
			for layer in sublayers {
				if let playerLayer = layer as? AVPlayerLayer {
					playerLayer.videoGravity = gravity
				}
			}
		}
	}
	
	private func scaleControls(in view: UIView, scale: CGFloat) {
		// Recursively find control bar views and scale them
		for subview in view.subviews {
			// Look for AVPlayerViewController's control bar
			let className = String(describing: type(of: subview))
			if className.contains("Controls") || className.contains("Overlay") || className.contains("Transport") {
				subview.transform = CGAffineTransform(scaleX: scale, y: scale)
			}
			
			// Also check for specific control elements
			if subview is UIButton || subview is UISlider || subview is UILabel {
				subview.transform = CGAffineTransform(scaleX: scale, y: scale)
			}
			
			// Recursively check subviews
			scaleControls(in: subview, scale: scale)
		}
	}
	
	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		updateLayout()
	}
}
