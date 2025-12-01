import SwiftUI
import FirebaseFirestore
import FirebaseAuth

/// Main home feed view - displays posts from followed collections
/// Optimized for production with server-side feed generation and proper caching
struct CYHome: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@Environment(\.scenePhase) private var scenePhase
	@EnvironmentObject var authService: AuthService
	
	@StateObject private var cyServiceManager = CYServiceManager.shared // Observe ServiceManager for real-time updates
	@State private var isMenuOpen = false
	@State private var followedCollections: [CollectionData] = []
	@State private var postsWithCollections: [(post: CollectionPost, collection: CollectionData)] = []
	@State private var isLoading = false
	@State private var isLoadingMore = false
	@State private var hasMoreData = true
	@State private var lastPostTimestamp: Date?
	@State private var showNotifications = false
	@State private var unreadNotificationCount = 0
	@State private var friendRequestCount = 0
	@State private var sideMenuSearchText = "" // Search text for side menu
	
	// Check if device is iPad
	private var isIPad: Bool {
		horizontalSizeClass == .regular
	}
	
	private var notificationBadgeCount: Int? {
		unreadNotificationCount > 0 ? unreadNotificationCount : nil
	}
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				mainContentView
			}
		}
		.refreshable {
			// Pull-to-refresh: Check for new posts, reorder if none found
			await refreshFeed()
		}
		.onChange(of: scenePhase) { oldPhase, newPhase in
			// When app becomes active (from background or completely closed), refresh feed
			if newPhase == .active {
				Task {
					await refreshFeed()
				}
			}
		}
		.onAppear {
			// Start ServiceManager listener for real-time user updates
			Task {
				try? await CYServiceManager.shared.loadCurrentUser()
			}
			
			// Load unread notification count
			loadUnreadNotificationCount()
			
			// Load friend request count
			loadFriendRequestCount()
			
			// ALWAYS use cache first - no auto-refresh on tab switch or view appearance
			// This ensures fast loading and no unnecessary network calls
			// NO background checks - only refresh on pull-to-refresh or explicit notifications
			if HomeViewCache.shared.hasDataLoaded() {
				let cached = HomeViewCache.shared.getCachedData()
				// Filter cached data to remove posts from hidden collections and blocked users
				Task {
					let hiddenCollectionIds = await MainActor.run { () -> Set<String> in
						Set(cyServiceManager.getHiddenCollectionIds())
					}
					let blockedUserIds = await MainActor.run { () -> Set<String> in
						Set(cyServiceManager.getBlockedUsers())
					}
					await MainActor.run {
						// Filter collections (remove hidden collections and collections from blocked users)
						self.followedCollections = cached.collections.filter { collection in
							!hiddenCollectionIds.contains(collection.id) &&
							!blockedUserIds.contains(collection.ownerId)
						}
						// Filter posts (remove posts from hidden collections and blocked users)
						self.postsWithCollections = cached.postsWithCollections.filter { postWithCollection in
							!hiddenCollectionIds.contains(postWithCollection.post.collectionId) &&
							!blockedUserIds.contains(postWithCollection.post.authorId)
						}
					}
				}
			} else {
				// No cache exists, load fresh (only on first app launch)
				loadFollowedCollectionsAndPosts(forceRefresh: false)
			}
		}
		.onDisappear {
			// CRITICAL: Clean up all Firestore listeners when view disappears
			// This prevents memory leaks and battery drain
			FirestoreListenerManager.shared.removeAllListeners(for: "CYHome")
			#if DEBUG
			let remainingCount = FirestoreListenerManager.shared.getActiveListenerCount()
			print("✅ CYHome: Cleaned up listeners (remaining: \(remainingCount))")
			#endif
		}
		// Consolidated notification handler for feed updates
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionFollowed"))) { notification in
			handleFeedUpdateNotification(notification, action: "CollectionFollowed")
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnfollowed"))) { notification in
			handleFeedUpdateNotification(notification, action: "CollectionUnfollowed")
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostCreated"))) { notification in
			if let collectionId = notification.object as? String,
			   followedCollections.contains(where: { $0.id == collectionId }) {
				loadFollowedCollectionsAndPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { _ in
			print("🔄 CYHome: Profile updated, reloading to show new user info")
			loadFollowedCollectionsAndPosts(forceRefresh: true)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestCountChanged"))) { notification in
			if let userInfo = notification.userInfo,
			   let count = userInfo["count"] as? Int {
				friendRequestCount = count
			}
		}
		.onChange(of: cyServiceManager.currentUser) { oldValue, newValue in
			// Real-time update when current user's profile changes via ServiceManager
			guard let old = oldValue, let new = newValue else {
				// Initial load - filter existing posts from hidden collections and blocked users
				if let new = newValue {
					Task {
						let hiddenCollectionIds = Set(new.blockedCollectionIds)
						let blockedUserIds = Set(new.blockedUsers)
						await MainActor.run {
							// Remove posts from hidden collections and blocked users
							postsWithCollections.removeAll { postWithCollection in
								hiddenCollectionIds.contains(postWithCollection.post.collectionId) ||
								blockedUserIds.contains(postWithCollection.post.authorId)
							}
							// Remove collections that are hidden or owned by blocked users
							followedCollections.removeAll { collection in
								hiddenCollectionIds.contains(collection.id) ||
								blockedUserIds.contains(collection.ownerId)
							}
						}
					}
				}
				return
			}
			
			// Check if hidden collections changed
			let oldHiddenIds = Set(old.blockedCollectionIds)
			let newHiddenIds = Set(new.blockedCollectionIds)
			let hiddenCollectionsChanged = oldHiddenIds != newHiddenIds
			
			// Check if blocked users changed
			let oldBlockedUserIds = Set(old.blockedUsers)
			let newBlockedUserIds = Set(new.blockedUsers)
			let blockedUsersChanged = oldBlockedUserIds != newBlockedUserIds
			
			if hiddenCollectionsChanged {
				print("🔄 CYHome: Hidden collections changed, filtering posts")
				Task {
					let hiddenCollectionIds = newHiddenIds
					await MainActor.run {
						let beforeCount = postsWithCollections.count
						postsWithCollections.removeAll { hiddenCollectionIds.contains($0.post.collectionId) }
						followedCollections.removeAll { hiddenCollectionIds.contains($0.id) }
						if postsWithCollections.count < beforeCount {
							print("🚫 CYHome: Removed \(beforeCount - postsWithCollections.count) posts from hidden collections")
						}
					}
				}
			}
			
			if blockedUsersChanged {
				print("🔄 CYHome: Blocked users changed, filtering posts")
				Task {
					let blockedUserIds = newBlockedUserIds
					await MainActor.run {
						let beforeCount = postsWithCollections.count
						// Remove posts from blocked users
						postsWithCollections.removeAll { blockedUserIds.contains($0.post.authorId) }
						// Remove collections owned by blocked users
						followedCollections.removeAll { blockedUserIds.contains($0.ownerId) }
						// Clear cache
						HomeViewCache.shared.clearCache()
						if postsWithCollections.count < beforeCount {
							print("🚫 CYHome: Removed \(beforeCount - postsWithCollections.count) posts from blocked users")
						}
					}
				}
			}
			
			// Only reload if profile-relevant fields changed (not just starredPostIds, hiddenPostIds, etc.)
			let profileChanged = old.profileImageURL != new.profileImageURL ||
				old.backgroundImageURL != new.backgroundImageURL ||
				old.name != new.name ||
				old.username != new.username
			
			if profileChanged {
				print("🔄 CYHome: Current user profile updated via ServiceManager, reloading immediately")
				loadFollowedCollectionsAndPosts(forceRefresh: true)
			}
		}
		// Consolidated notification count updates
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UnreadNotificationCountChanged"))) { notification in
			if let userInfo = notification.userInfo,
			   let count = userInfo["count"] as? Int {
				unreadNotificationCount = count
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestSent"))) { _ in
			loadUnreadNotificationCount()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteSent"))) { _ in
			loadUnreadNotificationCount()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionMembersJoined"))) { _ in
			loadUnreadNotificationCount()
		}
		// Consolidated blocking/hiding handlers
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionHidden"))) { notification in
			handleCollectionHidden(notification)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnhidden"))) { notification in
			if let unhiddenCollectionId = notification.object as? String {
				print("✅ CYHome: Collection '\(unhiddenCollectionId)' was unhidden, reloading feed")
				loadFollowedCollectionsAndPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { notification in
			handleUserBlocked(notification)
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { notification in
			if let unblockedUserId = notification.userInfo?["unblockedUserId"] as? String {
				print("✅ CYHome: User '\(unblockedUserId)' was unblocked, reloading feed")
				loadFollowedCollectionsAndPosts(forceRefresh: true)
			}
		}
	}
	
	private var mainContentView: some View {
		ScrollViewReader { proxy in
			ZStack {
				// Main Content
				VStack(spacing: 0) {
					// Top anchor for scroll-to-top
					Color.clear
						.frame(height: 0)
						.id("topAnchor")
					
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
							
							Image("SplashIcon")
								.resizable()
								.scaledToFit()
								.frame(width: 40, height: 40)
						}
						
						Spacer()
						
						HStack(spacing: 15) {
							NavigationLink(destination: AddFriendsScreen()) {
								ZStack(alignment: .topTrailing) {
								Image(systemName: "person.badge.plus")
									.resizable()
									.frame(width: 25, height: 25)
									.foregroundColor(colorScheme == .dark ? .white : .black)
									
									if friendRequestCount > 0 {
										Text("\(friendRequestCount)")
											.font(.caption2)
											.fontWeight(.bold)
											.foregroundColor(.white)
											.padding(4)
											.background(Color.blue)
											.clipShape(Circle())
											.offset(x: 8, y: -8)
									}
								}
							}
							
							Button(action: {
								showNotifications = true
							}) {
								ZStack(alignment: .topTrailing) {
									Image(systemName: "bell.fill")
										.resizable()
										.frame(width: 25, height: 25)
										.foregroundColor(colorScheme == .dark ? .white : .black)
									
									if notificationBadgeCount != nil {
										Circle()
											.fill(Color.blue)
											.frame(width: 10, height: 10)
											.offset(x: 8, y: -8)
									}
								}
							}
							.fullScreenCover(isPresented: $showNotifications) {
								NotificationsView(isPresented: $showNotifications)
							}
							.onChange(of: showNotifications) { oldValue, newValue in
								// When notifications view is dismissed, refresh the count
								if oldValue == true && newValue == false {
									// View was dismissed, reload count (should be 0 after marking as read)
									loadUnreadNotificationCount()
								}
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
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToTopHome"))) { _ in
			withAnimation {
				proxy.scrollTo("topAnchor", anchor: .top)
			}
		}
		}
	}
	
	// MARK: - View Components
	private var emptyStateView: some View {
		ScrollView {
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
			.frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height * 0.7)
			.padding(.top, 100)
		}
		.refreshable {
			await refreshFeed()
		}
	}
	
	private var postsView: some View {
		// Extract posts from postsWithCollections for Pinterest grid
		// Remove duplicates by post ID (keep first occurrence)
		var seenPostIds = Set<String>()
		let uniquePostsWithCollections = postsWithCollections.filter { item in
			if seenPostIds.contains(item.post.id) {
				return false
			}
			seenPostIds.insert(item.post.id)
			return true
		}
		
		let posts = uniquePostsWithCollections.map { $0.post }
		
		// Create a map of post IDs to collections (now guaranteed to have unique keys)
		let postsCollectionMap = Dictionary(uniqueKeysWithValues: uniquePostsWithCollections.map { ($0.post.id, $0.collection) })
		
		return VStack(spacing: 0) {
			PinterestPostGrid(
			posts: posts,
			collection: nil, // Not an individual collection view
			isIndividualCollection: false,
			currentUserId: authService.user?.uid,
				postsCollectionMap: postsCollectionMap,
				showAds: true, // Show ads on home feed
				adLocation: .home // Use home ad unit
			)
			
			// Loading indicator at bottom when loading more
			if isLoadingMore {
				HStack {
					Spacer()
					ProgressView()
						.padding()
					Spacer()
				}
			}
			
			// Load more trigger when scrolling near bottom
			Color.clear
				.frame(height: 1)
				.onAppear {
					if hasMoreData && !isLoadingMore {
						loadMoreIfNeeded()
					}
				}
		}
	}
	
	// Filtered collections based on search
	private var filteredFollowedCollections: [CollectionData] {
		if sideMenuSearchText.isEmpty {
			return followedCollections
		}
		return followedCollections.filter { collection in
			collection.name.localizedCaseInsensitiveContains(sideMenuSearchText)
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
			
			// Search Bar
			HStack {
				Image(systemName: "magnifyingglass")
					.foregroundColor(.secondary)
				TextField("Search collections...", text: $sideMenuSearchText)
					.textFieldStyle(.plain)
			}
			.padding(12)
			.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
			.cornerRadius(10)
			.padding(.horizontal)
			.padding(.bottom, 8)
			
			Divider()
			
			// Followed Collections List
			if filteredFollowedCollections.isEmpty {
				VStack(spacing: 12) {
					Spacer()
					if sideMenuSearchText.isEmpty {
					Image(systemName: "heart.slash")
						.font(.system(size: 40))
						.foregroundColor(.secondary)
					Text("Not following any collections")
						.font(.headline)
						.foregroundColor(.secondary)
					Text("Follow collections to see them here")
						.font(.subheadline)
						.foregroundColor(.secondary)
					} else {
						Image(systemName: "magnifyingglass")
							.font(.system(size: 40))
							.foregroundColor(.secondary)
						Text("No collections found")
							.font(.headline)
							.foregroundColor(.secondary)
						Text("Try searching with a different term")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					Spacer()
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 12) {
						ForEach(filteredFollowedCollections) { collection in
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
	
	// MARK: - Feed Loading (Consolidated)
	/// Unified feed loading method - handles both initial load and refresh
	/// Uses server-side feed generation when available, falls back to client-side
	private func loadFeed(forceRefresh: Bool = false, isRefresh: Bool = false) async {
		guard let currentUserId = authService.user?.uid else { return }
		
		// Skip if we have cached data and not forcing refresh
		if HomeViewCache.shared.hasDataLoaded() && !forceRefresh && !isRefresh {
			return
		}
		
		await MainActor.run {
			isLoading = true
			hasMoreData = true
			lastPostTimestamp = nil
		}
		
		// Clear caches if refreshing
		if isRefresh {
			await MainActor.run {
				HomeViewCache.shared.clearCache()
				CollectionPostsCache.shared.clearAllCache()
				UserService.shared.clearUserCache(userId: currentUserId)
			}
			
			// Reload current user data
			do {
				CYServiceManager.shared.stopListening()
				try await CYServiceManager.shared.loadCurrentUser()
			} catch {
				print("⚠️ CYHome: Error reloading current user: \(error)")
			}
		}
		
		do {
			// Load followed collections
			let followed = try await CollectionService.shared.getFollowedCollections(userId: currentUserId)
			
			// Use server-side feed generation (10x faster, 10x fewer reads)
			let initialLimit = isIPad ? 30 : 24
			var allPosts: [(post: CollectionPost, collection: CollectionData)] = []
			
			do {
				// Try server-side feed first
				let (serverPosts, hasMore, _) = try await FeedService.shared.loadHomeFeed(
					pageSize: initialLimit,
					lastPostId: nil
				)
				
				// Map server posts to posts with collections
				for post in serverPosts {
					if let collection = followed.first(where: { $0.id == post.collectionId }) {
						allPosts.append((post: post, collection: collection))
					} else if let collection = try? await CollectionService.shared.getCollection(collectionId: post.collectionId) {
						allPosts.append((post: post, collection: collection))
					}
				}
				
				await MainActor.run {
					hasMoreData = hasMore
					lastPostTimestamp = allPosts.last?.post.createdAt
				}
				
				print("✅ CYHome: Loaded \(allPosts.count) posts from server-side feed")
			} catch {
				// Fallback to client-side loading
				print("⚠️ CYHome: Server-side feed failed, using client-side fallback: \(error.localizedDescription)")
				
				let clientPosts = try await FeedService.shared.loadHomeFeedClientSide(
					followedCollections: followed,
					limit: initialLimit
				)
				
				for post in clientPosts {
					if let collection = followed.first(where: { $0.id == post.collectionId }) {
						allPosts.append((post: post, collection: collection))
					}
				}
				
				// Apply client-side mixing as fallback
				allPosts = mixPosts(allPosts, isRefresh: isRefresh)
				await MainActor.run {
					hasMoreData = allPosts.count >= initialLimit
					lastPostTimestamp = allPosts.last?.post.createdAt
				}
			}
			
			// Filter out hidden collections and blocked users (single pass)
			let hiddenCollectionIds = await MainActor.run { () -> Set<String> in
				Set(cyServiceManager.getHiddenCollectionIds())
			}
			let blockedUserIds = await MainActor.run { () -> Set<String> in
				Set(cyServiceManager.getBlockedUsers())
			}
			
			allPosts = allPosts.filter { postWithCollection in
				!hiddenCollectionIds.contains(postWithCollection.post.collectionId) &&
				!blockedUserIds.contains(postWithCollection.post.authorId) &&
				!blockedUserIds.contains(postWithCollection.collection.ownerId)
			}
			
			// Take only initial limit
			let limitedPosts = Array(allPosts.prefix(initialLimit))
			
			// Cache the data
			let followedIds = Set(followed.map { $0.id })
			HomeViewCache.shared.setCachedData(
				collections: followed,
				postsWithCollections: limitedPosts,
				followedIds: followedIds
			)
			
			await MainActor.run {
				self.followedCollections = followed
				self.postsWithCollections = limitedPosts
				self.isLoading = false
			}
		} catch {
			print("❌ Error loading feed: \(error)")
			await MainActor.run {
				self.isLoading = false
				self.hasMoreData = false
			}
		}
	}
	
	// MARK: - Post Mixing Algorithm
	/// Mixes posts with recency score, shuffle factor, and creator distribution
	/// Ensures no single creator appears in long blocks
	@MainActor
	private func mixPosts(_ posts: [(post: CollectionPost, collection: CollectionData)], isRefresh: Bool = false) -> [(post: CollectionPost, collection: CollectionData)] {
		guard !posts.isEmpty else { return posts }
		
		let now = Date()
		let maxBlockSize = 2 // Maximum consecutive posts from same creator
		
		// Step 1: Calculate combined recency + engagement scores
		var scoredPosts = posts.map { postWithCollection -> (item: (post: CollectionPost, collection: CollectionData), score: Double, creatorId: String) in
			let post = postWithCollection.post
			let timeSinceCreation = now.timeIntervalSince(post.createdAt)
			let hoursSinceCreation = timeSinceCreation / 3600.0
			
			// Recency score: exponentially decays with time
			// Posts from last hour get score ~100, posts from 24h ago get ~50, posts from 7 days get ~10
			let recencyScore = 100.0 * exp(-hoursSinceCreation / 48.0) // Half-life of ~48 hours
			
			// Engagement score: use the pre-calculated engagement score from the post
			// Scale it to match recency score range (multiply by 2 to give it significant weight)
			let engagementScore = post.engagementScore * 2.0
			
			// Combine recency (60%) and engagement (40%) for balanced ranking
			// This ensures recent posts are prioritized, but highly engaging posts also rise
			let combinedScore = (recencyScore * 0.6) + (engagementScore * 0.4)
			
			// Add random shuffle factor (0-20 points) - lighter on refresh
			let shuffleFactor = isRefresh ? Double.random(in: 0...10) : Double.random(in: 0...20)
			
			let finalScore = combinedScore + shuffleFactor
			let creatorId = post.authorId
			
			return (item: postWithCollection, score: finalScore, creatorId: creatorId)
		}
		
		// Step 2: Sort by score (highest first)
		scoredPosts.sort { $0.score > $1.score }
		
		// Step 3: Distribute posts to avoid long blocks from same creator
		var mixedPosts: [(post: CollectionPost, collection: CollectionData)] = []
		var remainingPosts = scoredPosts
		var recentCreators: [String] = [] // Track recent creators in order (last maxBlockSize creators)
		
		while !remainingPosts.isEmpty {
			var found = false
			
			// Try to find a post from a creator that hasn't appeared in recent block
			for i in 0..<remainingPosts.count {
				let post = remainingPosts[i]
				let creatorId = post.creatorId
				
				// Count how many times this creator appears in recent block
				let recentCount = recentCreators.filter { $0 == creatorId }.count
				
				// If this creator hasn't exceeded max block size, use this post
				if recentCount < maxBlockSize {
					mixedPosts.append(post.item)
					remainingPosts.remove(at: i)
					
					// Update recent creators list (keep only last maxBlockSize)
					recentCreators.append(creatorId)
					if recentCreators.count > maxBlockSize {
						recentCreators.removeFirst()
					}
					
					found = true
					break
				}
			}
			
			// If all remaining creators have reached max block size, reset and take highest scored
			if !found {
				// Reset recent creators and take the highest scored remaining post
				recentCreators.removeAll()
				if let nextPost = remainingPosts.first {
					mixedPosts.append(nextPost.item)
					recentCreators.append(nextPost.creatorId)
					remainingPosts.removeFirst()
				}
			}
		}
		
		// Step 4: Light reshuffle on refresh (swap adjacent pairs randomly)
		if isRefresh {
			var reshuffled = mixedPosts
			let swapCount = min(reshuffled.count / 4, 10) // Swap up to 25% of posts, max 10 swaps
			
			for _ in 0..<swapCount {
				let index1 = Int.random(in: 0..<(reshuffled.count - 1))
				let index2 = index1 + 1
				if index2 < reshuffled.count {
					reshuffled.swapAt(index1, index2)
				}
			}
			return reshuffled
		}
		
		return mixedPosts
	}
	
	// MARK: - Pull-to-Refresh with Complete Fresh Reload
	/// Complete refresh: Clear all caches, reload current user, reload everything from scratch
	/// Equivalent to exiting and re-entering the app
	private func refreshFeed() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		print("🔄 CYHome: Starting COMPLETE refresh (equivalent to app restart)")
		
		// Step 1: Clear ALL caches first (including user profile caches)
		await MainActor.run {
			HomeViewCache.shared.clearCache()
			CollectionPostsCache.shared.clearAllCache()
			// Clear user profile caches to force fresh profile image/name loads
			UserService.shared.clearUserCache(userId: currentUserId)
			print("✅ CYHome: Cleared all caches (including user profile caches)")
		}
		
		// Step 2: Reload current user data (blocked users, hidden collections, etc.) - FORCE FRESH
		do {
			// Stop existing listener and reload fresh
			CYServiceManager.shared.stopListening()
			try await CYServiceManager.shared.loadCurrentUser()
			print("✅ CYHome: Reloaded current user data (fresh from Firestore)")
		} catch {
			print("⚠️ CYHome: Error reloading current user: \(error)")
		}
		
		// Step 3: Reload everything from scratch (no cache usage)
		do {
			// Load followed collections from scratch
			let followed = try await CollectionService.shared.getFollowedCollections(userId: currentUserId)
			print("✅ CYHome: Loaded \(followed.count) followed collections")
			
			// Load FIRST PAGE of posts from all followed collections (paginated)
			var allPosts: [(post: CollectionPost, collection: CollectionData)] = []
			let initialLimit = isIPad ? 30 : 24 // More for grid view
			
			await withTaskGroup(of: [(post: CollectionPost, collection: CollectionData)].self) { group in
				for collection in followed {
					group.addTask {
						// Skip hidden collections entirely - don't even load posts
						let isHidden = await MainActor.run { () -> Bool in
							CYServiceManager.shared.isCollectionHidden(collectionId: collection.id)
						}
						if isHidden {
							print("🚫 CYHome: Skipping hidden collection '\(collection.name)' (ID: \(collection.id))")
							return []
						}
						
						// Check if collection owner is mutually blocked
						let isOwnerBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
						if isOwnerBlocked {
							print("🚫 CYHome: Skipping collection from blocked owner '\(collection.ownerId)'")
							return []
						}
						
						do {
							// Load limited posts per collection to reduce initial load time
							let (posts, _, _) = try await PostService.shared.getCollectionPostsPaginated(
								collectionId: collection.id,
								limit: 25, // Reduced from 100 to improve performance
								lastDocument: nil,
								sortBy: "Newest to Oldest"
							)
							
							// Filter posts (includes hidden collections, blocked users, deleted posts check)
							let filteredPosts = await CollectionService.filterPosts(posts)
							
							// Additional filter: Remove posts from blocked authors (mutual blocking)
							var finalPosts: [CollectionPost] = []
							for post in filteredPosts {
								let isAuthorBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: post.authorId)
								if !isAuthorBlocked {
									finalPosts.append(post)
								}
							}
							
							return finalPosts.map { (post: $0, collection: collection) }
						} catch {
							print("⚠️ CYHome: Error loading posts for collection \(collection.id): \(error)")
							return []
						}
					}
				}
				
				for await collectionPosts in group {
					allPosts.append(contentsOf: collectionPosts)
				}
			}
			
			// Apply sorted + mixed feed algorithm with recency score, shuffle factor, and creator distribution
			let mixedPosts = mixPosts(allPosts, isRefresh: true)
			print("🔄 CYHome: Mixed posts with recency score and creator distribution on refresh")
			
			// Take only initial limit
			let limitedPosts = Array(mixedPosts.prefix(initialLimit))
			
			await MainActor.run {
				// Always use fresh data - no cache comparison
						self.postsWithCollections = limitedPosts
						self.lastPostTimestamp = limitedPosts.last?.post.createdAt
						self.hasMoreData = allPosts.count > initialLimit
				self.followedCollections = followed
						
				// Update cache with fresh data
						let followedIds = Set(followed.map { $0.id })
						HomeViewCache.shared.setCachedData(
							collections: followed,
							postsWithCollections: limitedPosts,
							followedIds: followedIds
						)
				
				print("✅ CYHome: Complete refresh finished - \(limitedPosts.count) posts loaded, \(followed.count) collections")
			}
		} catch {
			print("❌ CYHome: Error during complete refresh: \(error)")
		}
	}
	
	private func loadFollowedCollectionsAndPosts(forceRefresh: Bool = false) {
		guard let currentUserId = authService.user?.uid else { return }
		
		// If we have cached data and not forcing refresh, skip loading
		if HomeViewCache.shared.hasDataLoaded() && !forceRefresh {
			return
		}
		
		isLoading = true
		hasMoreData = true
		lastPostTimestamp = nil
		
		Task {
			do {
				// Load followed collections
				let followed = try await CollectionService.shared.getFollowedCollections(userId: currentUserId)
				
				// CRITICAL: Use server-side feed generation (10x faster, 10x fewer reads)
				// Falls back to client-side if Cloud Function fails
				let initialLimit = isIPad ? 30 : 24
				var allPosts: [(post: CollectionPost, collection: CollectionData)] = []
				
				do {
					// Try server-side feed first
					let (serverPosts, hasMore, lastId) = try await FeedService.shared.loadHomeFeed(
						pageSize: initialLimit,
						lastPostId: nil
					)
					
					// Map server posts to posts with collections
					for post in serverPosts {
						// Find collection for this post
						if let collection = followed.first(where: { $0.id == post.collectionId }) {
							allPosts.append((post: post, collection: collection))
						} else {
							// Fallback: Load collection if not in followed list
							if let collection = try? await CollectionService.shared.getCollection(collectionId: post.collectionId) {
								allPosts.append((post: post, collection: collection))
							}
						}
					}
					
					hasMoreData = hasMore
					lastPostTimestamp = allPosts.last?.post.createdAt
					
					print("✅ CYHome: Loaded \(allPosts.count) posts from server-side feed")
							} catch {
					// Fallback to client-side loading if Cloud Function fails
					print("⚠️ CYHome: Server-side feed failed, using client-side fallback: \(error.localizedDescription)")
					
					let clientPosts = try await FeedService.shared.loadHomeFeedClientSide(
						followedCollections: followed,
						limit: initialLimit
					)
					
					// Map to posts with collections
					for post in clientPosts {
						if let collection = followed.first(where: { $0.id == post.collectionId }) {
							allPosts.append((post: post, collection: collection))
					}
				}
				
					// Apply client-side mixing as fallback
					allPosts = mixPosts(allPosts, isRefresh: false)
					hasMoreData = allPosts.count >= initialLimit
					lastPostTimestamp = allPosts.last?.post.createdAt
				}
				
				// Filter out hidden collections and blocked users
				let hiddenCollectionIds = await MainActor.run { () -> Set<String> in
					Set(cyServiceManager.getHiddenCollectionIds())
				}
				let blockedUserIds = await MainActor.run { () -> Set<String> in
					Set(cyServiceManager.getBlockedUsers())
				}
				
				allPosts = allPosts.filter { postWithCollection in
					!hiddenCollectionIds.contains(postWithCollection.post.collectionId) &&
					!blockedUserIds.contains(postWithCollection.post.authorId) &&
					!blockedUserIds.contains(postWithCollection.collection.ownerId)
				}
				
				// Take only initial limit
				let limitedPosts = Array(allPosts.prefix(initialLimit))
				
				// Cache the data
				let followedIds = Set(followed.map { $0.id })
				HomeViewCache.shared.setCachedData(
					collections: followed,
					postsWithCollections: limitedPosts,
					followedIds: followedIds
				)
				
				await MainActor.run {
					self.followedCollections = followed
					self.postsWithCollections = limitedPosts
					self.isLoading = false
				}
			} catch {
				print("❌ Error loading feed: \(error)")
				await MainActor.run {
					self.isLoading = false
					self.hasMoreData = false
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
	
	// Load more posts (pagination)
	private func loadMoreIfNeeded() {
		guard !isLoadingMore && !isLoading && hasMoreData else { return }
		guard !postsWithCollections.isEmpty else { return }
		
		isLoadingMore = true
		
		Task {
			do {
				guard let currentUserId = authService.user?.uid else { return }
				
				// Load followed collections (in case they changed)
				let followed = try await CollectionService.shared.getFollowedCollections(userId: currentUserId)
				
				// Load more posts from all followed collections
				var newPosts: [(post: CollectionPost, collection: CollectionData)] = []
				let pageSize = isIPad ? 18 : 15
				
				// Get posts created before the last post timestamp
				let cutoffDate = lastPostTimestamp ?? Date()
				
				await withTaskGroup(of: [(post: CollectionPost, collection: CollectionData)].self) { group in
					for collection in followed {
						group.addTask {
							// Skip hidden collections entirely - don't even load posts
							let isHidden = await MainActor.run { () -> Bool in
								CYServiceManager.shared.isCollectionHidden(collectionId: collection.id)
							}
							if isHidden {
								print("🚫 CYHome: Skipping hidden collection '\(collection.name)' (ID: \(collection.id))")
								return []
							}
							
							do {
								// Load more posts from this collection
								// We'll need to track last document per collection for proper pagination
								// For now, use a simple approach: get posts older than cutoff
								let db = Firestore.firestore()
								let query = db.collection("posts")
									.whereField("collectionId", isEqualTo: collection.id)
									.whereField("createdAt", isLessThan: Timestamp(date: cutoffDate))
									.order(by: "createdAt", descending: true)
									.limit(to: 3) // 3 posts per collection per page
								
								let snapshot = try await query.getDocuments()
								var posts: [CollectionPost] = []
								
								for doc in snapshot.documents {
									// Documents from getDocuments() are already QueryDocumentSnapshot
									// PostService is @MainActor, access it from MainActor
									let postResult = await MainActor.run {
										Result { try PostService.shared.parsePost(from: doc) }
									}
									
									switch postResult {
									case .success(let post):
										posts.append(post)
									case .failure(let error):
										print("⚠️ Error parsing post \(doc.documentID): \(error)")
										// Continue with other documents
									}
								}
								
								// Filter posts (includes hidden collections check)
								let filteredPosts = await CollectionService.filterPosts(posts)
								return filteredPosts.map { (post: $0, collection: collection) }
							} catch {
								print("Error loading more posts for collection \(collection.id): \(error)")
								return []
							}
						}
					}
					
					for await collectionPosts in group {
						newPosts.append(contentsOf: collectionPosts)
					}
				}
				
				// Sort by creation date (newest first)
				newPosts.sort { $0.post.createdAt > $1.post.createdAt }
				
				// Take only pageSize
				let limitedNewPosts = Array(newPosts.prefix(pageSize))
				
				if !limitedNewPosts.isEmpty {
					lastPostTimestamp = limitedNewPosts.last?.post.createdAt
					hasMoreData = newPosts.count >= pageSize
					
					await MainActor.run {
						// Filter out any posts from hidden collections and blocked users before appending
						let hiddenCollectionIds = Set(cyServiceManager.getHiddenCollectionIds())
						let blockedUserIds = Set(cyServiceManager.getBlockedUsers())
						let filteredNewPosts = limitedNewPosts.filter { postWithCollection in
							!hiddenCollectionIds.contains(postWithCollection.post.collectionId) &&
							!blockedUserIds.contains(postWithCollection.post.authorId)
						}
						
						postsWithCollections.append(contentsOf: filteredNewPosts)
						// Re-sort all posts
						postsWithCollections.sort { $0.post.createdAt > $1.post.createdAt }
						isLoadingMore = false
					}
				} else {
					await MainActor.run {
						hasMoreData = false
						isLoadingMore = false
					}
				}
			} catch {
				print("❌ Error loading more posts: \(error)")
				await MainActor.run {
		isLoadingMore = false
		hasMoreData = false
				}
			}
		}
	}
	
	private func loadUnreadNotificationCount() {
		guard let currentUserId = authService.user?.uid else { return }
		
		Task {
			do {
				let notifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
				// Count ALL unread notifications (same as messages badge)
				let unreadCount = notifications.filter { !$0.isRead }.count
				await MainActor.run {
					self.unreadNotificationCount = unreadCount
				}
			} catch {
				print("❌ Error loading unread notification count: \(error)")
			}
		}
	}
	
	private func loadFriendRequestCount() {
		Task {
			do {
				// Use total pending count (not just unseen) - count should persist until accepted/denied
				let count = try await FriendService.shared.getTotalPendingFriendRequestCount()
				await MainActor.run {
					self.friendRequestCount = count
				}
			} catch {
				print("❌ Error loading friend request count: \(error)")
			}
		}
	}
	
	// MARK: - Notification Handlers (Consolidated)
	/// Handle feed update notifications (follow/unfollow)
	private func handleFeedUpdateNotification(_ notification: Notification, action: String) {
		if let userId = notification.userInfo?["userId"] as? String,
		   userId == authService.user?.uid {
			loadFollowedCollectionsAndPosts(forceRefresh: true)
		}
	}
	
	/// Handle collection hidden notification
	private func handleCollectionHidden(_ notification: Notification) {
		if let hiddenCollectionId = notification.object as? String {
			print("🚫 CYHome: Collection '\(hiddenCollectionId)' was hidden, removing posts from feed")
			Task {
				await MainActor.run {
					let hiddenCollectionIds = Set([hiddenCollectionId])
					let beforeCount = postsWithCollections.count
					postsWithCollections.removeAll { hiddenCollectionIds.contains($0.post.collectionId) }
					followedCollections.removeAll { $0.id == hiddenCollectionId }
					HomeViewCache.shared.clearCache()
					if postsWithCollections.count < beforeCount {
						print("🚫 CYHome: Removed \(beforeCount - postsWithCollections.count) posts from hidden collection")
					}
				}
			}
		}
	}
	
	/// Handle user blocked notification
	private func handleUserBlocked(_ notification: Notification) {
		if let blockedUserId = notification.userInfo?["blockedUserId"] as? String {
			print("🚫 CYHome: User '\(blockedUserId)' was blocked, removing their posts from feed")
			Task {
				await MainActor.run {
					let beforeCount = postsWithCollections.count
					postsWithCollections.removeAll { $0.post.authorId == blockedUserId }
					followedCollections.removeAll { $0.ownerId == blockedUserId }
					HomeViewCache.shared.clearCache()
					if postsWithCollections.count < beforeCount {
						print("🚫 CYHome: Removed \(beforeCount - postsWithCollections.count) posts from blocked user")
					}
				}
			}
		}
	}
}
