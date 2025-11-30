import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

struct SearchView: View {
	@State private var searchText = ""
	@State private var selectedTab: Int = 0
	@State private var collections: [CollectionData] = []
	@State private var posts: [CollectionPost] = []
	@State private var postsCollectionMap: [String: CollectionData] = [:]
	@State private var users: [UserSearchResult] = []
	@State private var isLoadingCollections = false
	@State private var isLoadingPosts = false
	@State private var isLoadingUsers = false
	@State private var searchTask: Task<Void, Never>?
	// Request state is managed by CollectionRequestStateManager.shared
	@State private var selectedCollection: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedUserId: String?
	@State private var showingProfile = false
	@State private var hasLoadedOnce = false // Track if data has been loaded to prevent reloading
	@State private var followStatus: [String: Bool] = [:] // Track follow status for immediate UI updates
	@State private var membershipStatus: [String: Bool] = [:] // Track membership status for immediate UI updates
	
	// Cache for discover feed
	private class DiscoverCache {
		static let shared = DiscoverCache()
		private init() {}
		
		private var cachedCollections: [CollectionData] = []
		private var cachedPosts: [CollectionPost] = []
		private var cachedPostsCollectionMap: [String: CollectionData] = [:]
		private var cachedUsers: [UserSearchResult] = []
		private var hasData = false
		
		func getCachedData() -> (collections: [CollectionData], posts: [CollectionPost], postsMap: [String: CollectionData], users: [UserSearchResult]) {
			return (cachedCollections, cachedPosts, cachedPostsCollectionMap, cachedUsers)
		}
		
		func setCachedData(collections: [CollectionData], posts: [CollectionPost], postsMap: [String: CollectionData], users: [UserSearchResult]) {
			self.cachedCollections = collections
			self.cachedPosts = posts
			self.cachedPostsCollectionMap = postsMap
			self.cachedUsers = users
			self.hasData = true
		}
		
		func hasDataLoaded() -> Bool {
			return hasData
		}
		
		func clearCache() {
			cachedCollections.removeAll()
			cachedPosts.removeAll()
			cachedPostsCollectionMap.removeAll()
			cachedUsers.removeAll()
			hasData = false
		}
	}
	// Request state is managed by CollectionRequestStateManager.shared
	@StateObject private var adManager = AdManager.shared
	@State private var nativeAds: [String: GADNativeAd] = [:] // For single ads
	@State private var carouselAdsCache: [String: [GADNativeAd]] = [:] // For carousel/multi-card ads
	@State private var collectionAdPositions: Set<Int> = []
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.scenePhase) private var scenePhase
	@EnvironmentObject var authService: AuthService

	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				VStack(spacing: 0) {
				header
				
					searchBar
						.padding(.horizontal)
						.padding(.top, 8)
						.padding(.bottom, 12)

				tabSwitcher
					.padding(.bottom, 8)

				content
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.navigationBarHidden(true)
			.navigationDestination(isPresented: $showingInsideCollection) {
				if let collection = selectedCollection {
					CYInsideCollectionView(collection: collection)
						.environmentObject(authService)
				}
			}
			.navigationDestination(isPresented: $showingProfile) {
				if let userId = selectedUserId {
					ViewerProfileView(userId: userId)
						.environmentObject(authService)
				}
			}
			.onAppear {
				// ALWAYS use cache first - no auto-refresh on tab switch or view appearance
				if DiscoverCache.shared.hasDataLoaded() && searchText.isEmpty {
					let cached = DiscoverCache.shared.getCachedData()
					// Use cached data immediately (no network call) for the current tab
					switch selectedTab {
					case 0:
						self.collections = cached.collections
					case 1:
						self.posts = cached.posts
						self.postsCollectionMap = cached.postsMap
					case 2:
						self.users = cached.users
					default:
						break
					}
					hasLoadedOnce = true
				} else if !hasLoadedOnce {
					// No cache exists, load fresh (only on first app launch)
					Task {
						await performSearch()
						hasLoadedOnce = true
					}
				}
				// Initialize shared request state manager
				Task {
					await CollectionRequestStateManager.shared.initializeState()
				}
			}
			.onChange(of: selectedTab) { oldValue, newValue in
				// When tab changes, just show cached data - NO refresh
				if DiscoverCache.shared.hasDataLoaded() && searchText.isEmpty {
					let cached = DiscoverCache.shared.getCachedData()
					switch newValue {
					case 0:
						self.collections = cached.collections
					case 1:
						self.posts = cached.posts
						self.postsCollectionMap = cached.postsMap
					case 2:
						self.users = cached.users
					default:
						break
					}
				} else if !hasLoadedOnce {
					// Only load if we haven't loaded this tab's data yet
					Task {
						await performSearch(forceRefresh: false)
					}
				}
			}
			.refreshable {
				// Pull-to-refresh: Check for new content, reorder if none found
				// Works for both discover mode (empty search) and active searches
				await refreshDiscoverFeed()
			}
			.onChange(of: scenePhase) { oldPhase, newPhase in
				// When app becomes active (from background or completely closed), refresh current tab
				if newPhase == .active {
					Task {
						await performSearch(forceRefresh: true)
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionHidden"))) { _ in
				// Refresh search when a collection is hidden
				Task {
					await performSearch(forceRefresh: true)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionUnhidden"))) { _ in
				// Refresh search when a collection is unhidden
				Task {
					await performSearch(forceRefresh: true)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { notification in
				// Immediately filter out blocked user from search results
				if let blockedUserId = notification.userInfo?["blockedUserId"] as? String {
				Task {
						await MainActor.run {
							// Remove blocked user from users list
							users.removeAll { $0.id == blockedUserId }
							// Remove collections owned by blocked user
							collections.removeAll { $0.ownerId == blockedUserId }
							// Remove posts from blocked user
							posts.removeAll { $0.authorId == blockedUserId }
							// Update postsCollectionMap
							postsCollectionMap = postsCollectionMap.filter { key, _ in
								!posts.contains(where: { $0.id == key })
							}
							// Clear cache
							DiscoverCache.shared.clearCache()
						}
						// Then refresh to ensure consistency
					await performSearch(forceRefresh: true)
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
				// Refresh search results when a user is unblocked
				Task {
					await performSearch(forceRefresh: true)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionJoined"))) { notification in
				// Update membership status when user joins a collection
				if let collectionId = notification.object as? String,
				   let userId = notification.userInfo?["userId"] as? String,
				   userId == Auth.auth().currentUser?.uid {
					membershipStatus[collectionId] = true
					// Remove from discover list since user is now a member
					collections.removeAll { $0.id == collectionId }
				}
			}
			.onChange(of: searchText) { oldValue, newValue in
				// When search text changes, clear cache and search fresh
				// This is a user-initiated search, so it's okay to refresh
				if oldValue != newValue {
					// Only clear cache if user is actually searching (not clearing search)
					if !newValue.isEmpty {
						// Don't clear cache on search - keep discover cache separate
						// Just perform the search
					}
					searchTask?.cancel()
					searchTask = Task {
						try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
						if !Task.isCancelled {
							await performSearch(forceRefresh: true)
						}
					}
				}
			}
		}
	}

	private var header: some View {
		HStack {
			Spacer()
			Text("Discover")
				.font(.headline)
				.fontWeight(.bold)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Spacer()
		}
		.padding(.vertical, 12)
	}
	
	private var searchBar: some View {
			HStack {
			HStack {
			Image(systemName: "magnifyingglass")
					.foregroundColor(.secondary)
					.padding(.leading, 12)
				
				TextField("Search collections, posts, users...", text: $searchText)
					.textFieldStyle(PlainTextFieldStyle())
		.padding(.vertical, 12)
					.padding(.trailing, 12)
			}
			.background(
				RoundedRectangle(cornerRadius: 12)
					.fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
			)
			
			if !searchText.isEmpty {
				Button(action: {
					searchText = ""
				}) {
					Image(systemName: "xmark.circle.fill")
						.foregroundColor(.secondary)
						.padding(.leading, 8)
				}
			}
		}
	}

	private var tabSwitcher: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				ForEach(0..<3) { index in
					Button(action: {
						withAnimation {
							selectedTab = index
						}
						// NO refresh on tab switch - just show cached data
						// Only load if we don't have cached data for this tab
						if !hasCachedDataForTab(index) {
							Task {
								await performSearch(forceRefresh: false)
							}
						}
					}) {
						VStack(spacing: 0) {
							Text(tabTitle(for: index))
								.font(.headline)
								.foregroundColor(selectedTab == index ? Color.primary : .gray)
								.padding(.bottom, 5)
							
							Rectangle()
								.frame(height: 2)
								.foregroundColor(selectedTab == index ? Color.primary : .clear)
						}
					}
					.frame(maxWidth: .infinity)
				}
			}
			.padding(.horizontal)
			.padding(.bottom, 8)
		}
	}
	
	// Check if we have cached data for a specific tab
	private func hasCachedDataForTab(_ tabIndex: Int) -> Bool {
		let cached = DiscoverCache.shared.getCachedData()
		switch tabIndex {
		case 0: return !cached.collections.isEmpty
		case 1: return !cached.posts.isEmpty
		case 2: return !cached.users.isEmpty
		default: return false
		}
	}

	private func tabTitle(for index: Int) -> String {
		switch index {
		case 0: return "Collections"
		case 1: return "Post"
		case 2: return "Usernames"
		default: return ""
		}
	}

	@ViewBuilder
	private var content: some View {
		switch selectedTab {
		case 0:
			collectionsContent
		case 1:
			postsContent
		default:
			usernamesContent
		}
	}
	
	private var collectionsContent: some View {
		Group {
			if isLoadingCollections {
				collectionsLoadingView
			} else if collections.isEmpty {
				collectionsEmptyView
			} else {
				collectionsListView
			}
		}
	}
	
	private var collectionsLoadingView: some View {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	private var collectionsEmptyView: some View {
				VStack(spacing: 12) {
					Image(systemName: "square.stack.3d.up")
						.font(.system(size: 48))
						.foregroundColor(.secondary)
					Text(searchText.isEmpty ? "Discover collections from other users" : "No collections found")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	private var collectionsListView: some View {
				ScrollView {
					LazyVStack(spacing: 16) {
				ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
					collectionRowWithAd(index: index, collection: collection)
				}
			}
			.padding(.vertical)
		}
	}
	
	@ViewBuilder
	private func collectionRowWithAd(index: Int, collection: CollectionData) -> some View {
		// Insert collection-style ad every 5 collections
		if index > 0 && index % 5 == 0 {
			collectionAdView(adKey: "collection_ad_\(index)")
		}
		
							CollectionRowDesign(
								collection: collection,
								isFollowing: followStatus[collection.id] ?? collection.followers.contains(Auth.auth().currentUser?.uid ?? ""),
								hasRequested: CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id),
								isMember: membershipStatus[collection.id] ?? {
									let currentUserId = Auth.auth().currentUser?.uid ?? ""
									return collection.members.contains(currentUserId) || collection.owners.contains(currentUserId)
								}(),
								isOwner: collection.ownerId == Auth.auth().currentUser?.uid,
								onFollowTapped: {
									Task {
										await handleFollowTapped(collection: collection)
									}
								},
								onActionTapped: {
									handleCollectionAction(collection: collection)
								},
								onProfileTapped: {
									Task {
										// Check if users are mutually blocked before navigating
										let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
										if !areMutuallyBlocked {
									selectedUserId = collection.ownerId
									showingProfile = true
										}
									}
								},
								onCollectionTapped: {
									Task {
										await handleCollectionTap(collection: collection)
									}
								}
							)
							.padding(.horizontal)
						}
	
	@ViewBuilder
	private func collectionAdView(adKey: String) -> some View {
		// Check if we have carousel ads for this key
		if let carouselAds = carouselAdsCache[adKey], let firstAd = carouselAds.first {
			// Use ONE primary ad, but show it in 4 slots so the whole row
			// is visually a single "sponsored collection" with 4 posts.
			let unifiedCarousel = Array(repeating: firstAd, count: 4)
			
			CollectionStyleAdCard(carouselAds: unifiedCarousel)
				.padding(.horizontal)
		} else {
			// Placeholder that already looks like a collection row design
			CollectionStyleAdPlaceholder()
				.padding(.horizontal)
				.onAppear {
					// Load carousel ads (4 ads) when placeholder appears - use collection ad unit
					adManager.loadCarouselAds(adKey: adKey, location: .collection) { ads in
						if !ads.isEmpty {
							Task { @MainActor in
								carouselAdsCache[adKey] = ads
							}
						}
				}
			}
		}
	}
	
	private var postsContent: some View {
		Group {
			if isLoadingPosts {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if posts.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "text.bubble")
						.font(.system(size: 48))
						.foregroundColor(.secondary)
					Text(searchText.isEmpty ? "Discover posts from other users' collections" : "No posts found")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				PinterestPostGrid(
					posts: posts,
					collection: nil,
					isIndividualCollection: false,
					currentUserId: Auth.auth().currentUser?.uid,
					postsCollectionMap: postsCollectionMap,
					showAds: true,
					adLocation: .discoverPost
				)
			}
		}
	}
	
	private var usernamesContent: some View {
		Group {
			if isLoadingUsers {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if users.isEmpty {
		VStack(spacing: 12) {
			Image(systemName: "person.crop.circle")
				.font(.system(size: 48))
				.foregroundColor(.secondary)
					Text(searchText.isEmpty ? "Discover users on the app" : "No users found")
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 12) {
						ForEach(users) { user in
							Button(action: {
								Task {
									// Check if users are mutually blocked before navigating
									let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: user.id)
									if !areMutuallyBlocked {
								selectedUserId = user.id
								showingProfile = true
									}
								}
							}) {
								UserSearchCard(user: user)
							}
							.buttonStyle(PlainButtonStyle())
							.padding(.horizontal)
						}
					}
					.padding(.vertical)
				}
			}
		}
	}
	
	// MARK: - Pull-to-Refresh with Reordering
	/// Refresh discover feed: Check for new content, reorder if none found
	@MainActor
	private func refreshDiscoverFeed() async {
		let query = searchText.isEmpty ? nil : searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			collections = []
			posts = []
			users = []
			return
		}
		
		// Load hidden collection IDs
		do {
			try await CYServiceManager.shared.loadCurrentUser()
		} catch {
			print("Error loading current user: \(error.localizedDescription)")
		}
		let hiddenCollectionIds = Set(CYServiceManager.shared.getHiddenCollectionIds())
		
		switch selectedTab {
		case 0:
			await refreshCollections(query: query, currentUserId: currentUserId, hiddenCollectionIds: hiddenCollectionIds)
		case 1:
			await refreshPosts(query: query, currentUserId: currentUserId, hiddenCollectionIds: hiddenCollectionIds)
		case 2:
			await refreshUsers(query: query)
		default:
			break
		}
	}
	
	@MainActor
	private func performSearch(forceRefresh: Bool = false) async {
		// If we already have data for current tab, not forcing refresh, and in discover mode (empty search), skip
		// This prevents unnecessary reloads when switching tabs
		if hasLoadedOnce && !forceRefresh && searchText.isEmpty {
			let hasDataForCurrentTab: Bool
			switch selectedTab {
			case 0: hasDataForCurrentTab = !collections.isEmpty
			case 1: hasDataForCurrentTab = !posts.isEmpty
			case 2: hasDataForCurrentTab = !users.isEmpty
			default: hasDataForCurrentTab = false
			}
			
			if hasDataForCurrentTab {
				print("⏭️ SearchView: Using cached data for tab \(selectedTab), skipping reload")
				return
			}
		}
		
		let query = searchText.isEmpty ? nil : searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			collections = []
			posts = []
			return
		}
		
		// Load hidden collection IDs
		do {
			try await CYServiceManager.shared.loadCurrentUser()
		} catch {
			print("Error loading current user: \(error.localizedDescription)")
		}
		let hiddenCollectionIds = Set(CYServiceManager.shared.getHiddenCollectionIds())
		
		switch selectedTab {
		case 0:
			await searchCollections(query: query, currentUserId: currentUserId, hiddenCollectionIds: hiddenCollectionIds)
			// Cache the results
			let cached = DiscoverCache.shared.getCachedData()
			DiscoverCache.shared.setCachedData(
				collections: collections,
				posts: cached.posts,
				postsMap: cached.postsMap,
				users: cached.users
			)
		case 1:
			await searchPosts(query: query, currentUserId: currentUserId, hiddenCollectionIds: hiddenCollectionIds)
			// Cache the results
			let cached = DiscoverCache.shared.getCachedData()
			DiscoverCache.shared.setCachedData(
				collections: cached.collections,
				posts: posts,
				postsMap: postsCollectionMap,
				users: cached.users
			)
		case 2:
			await searchUsernames(query: query)
			// Cache the results
			let cached = DiscoverCache.shared.getCachedData()
			DiscoverCache.shared.setCachedData(
				collections: cached.collections,
				posts: cached.posts,
				postsMap: cached.postsMap,
				users: users
			)
		default:
			break
		}
	}
	
	@MainActor
	private func searchCollections(query: String?, currentUserId: String, hiddenCollectionIds: Set<String>) async {
		isLoadingCollections = true
		defer { isLoadingCollections = false }
		
		do {
			let db = Firestore.firestore()
			let queryRef: Query = db.collection("collections")
			
			// Always load public collections, then filter in memory so search is
			// case-insensitive and works with emojis and partial matches.
			// Try query with index first, fallback to query without ordering if index is missing.
			var snapshot: QuerySnapshot
			var needsSorting = false
			do {
				snapshot = try await queryRef
					.whereField("isPublic", isEqualTo: true)
					.order(by: "createdAt", descending: true)
					.limit(to: 50)
					.getDocuments()
			} catch {
				if error.localizedDescription.contains("index") {
					print("⚠️ SearchView: Index missing, using fallback query (unsorted)")
					needsSorting = true
					snapshot = try await queryRef
						.whereField("isPublic", isEqualTo: true)
						.limit(to: 50)
						.getDocuments()
				} else {
					throw error
				}
			}
			
			var allCollections = snapshot.documents.compactMap { doc -> CollectionData? in
				let data = doc.data()
				let ownerId = data["ownerId"] as? String ?? ""
				let ownersArray = data["owners"] as? [String]
				let owners = ownersArray ?? [ownerId]
				let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
				
				return CollectionData(
					id: doc.documentID,
					name: data["name"] as? String ?? "",
					description: data["description"] as? String ?? "",
					type: data["type"] as? String ?? "Individual",
					isPublic: data["isPublic"] as? Bool ?? false,
					ownerId: ownerId,
					ownerName: data["ownerName"] as? String ?? "",
					owners: owners,
					imageURL: data["imageURL"] as? String,
					invitedUsers: data["invitedUsers"] as? [String] ?? [],
					members: data["members"] as? [String] ?? [],
					memberCount: data["memberCount"] as? Int ?? 0,
					followers: data["followers"] as? [String] ?? [],
					followerCount: data["followerCount"] as? Int ?? 0,
					allowedUsers: data["allowedUsers"] as? [String] ?? [],
					deniedUsers: data["deniedUsers"] as? [String] ?? [],
					createdAt: createdAt
				)
			}
			
			if needsSorting {
				allCollections.sort { $0.createdAt > $1.createdAt }
			}
			
			// Filter out owned/member/hidden/followed
			var filteredCollections = allCollections.filter { collection in
				if collection.ownerId == currentUserId { return false }
				if collection.members.contains(currentUserId) { return false }
				if hiddenCollectionIds.contains(collection.id) { return false }
				if collection.followers.contains(currentUserId) { return false }
				return true
			}
			
			// If user typed something, filter by collection name (case-insensitive, emojis ok)
			if let query = query, !query.isEmpty {
				let searchQuery = query.lowercased()
				filteredCollections = filteredCollections.filter { collection in
					collection.name.lowercased().contains(searchQuery)
				}
			}
			
			// Filter out collections from blocked users / access rules
			filteredCollections = await CollectionService.filterCollections(filteredCollections)
			
			// Additional check: filter out collections from mutually blocked users
			var finalFiltered: [CollectionData] = []
			for collection in filteredCollections {
				let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
				if !areMutuallyBlocked {
					finalFiltered.append(collection)
				}
			}
			filteredCollections = finalFiltered
			
			// Check if we have new collections compared to cached data
			if DiscoverCache.shared.hasDataLoaded() && query == nil {
				let cached = DiscoverCache.shared.getCachedData()
				let cachedCollectionIds = Set(cached.collections.map { $0.id })
				let newCollectionIds = Set(filteredCollections.map { $0.id })
				let hasNewCollections = !newCollectionIds.subtracting(cachedCollectionIds).isEmpty
				
				if hasNewCollections {
					// New collections found - use them
					collections = filteredCollections
					// Update cache
					DiscoverCache.shared.setCachedData(
						collections: filteredCollections,
						posts: cached.posts,
						postsMap: cached.postsMap,
						users: cached.users
					)
				} else {
					// No new collections - reorder/shuffle existing feed
					var reorderedCollections = cached.collections
					reorderedCollections.shuffle()
					collections = reorderedCollections
					// Update cache with reordered collections
					DiscoverCache.shared.setCachedData(
						collections: reorderedCollections,
						posts: cached.posts,
						postsMap: cached.postsMap,
						users: cached.users
					)
				}
			} else {
				// No cached data or search query exists - use new results
				collections = filteredCollections
				// Update cache
				let cached = DiscoverCache.shared.getCachedData()
				DiscoverCache.shared.setCachedData(
					collections: filteredCollections,
					posts: cached.posts,
					postsMap: cached.postsMap,
					users: cached.users
				)
			}
			
			// Initialize follow & membership status
			for collection in collections {
				followStatus[collection.id] = collection.followers.contains(currentUserId)
				membershipStatus[collection.id] = collection.members.contains(currentUserId) || collection.owners.contains(currentUserId)
			}
			
			await CollectionRequestStateManager.shared.initializeState()
		} catch {
			print("Error searching collections: \(error.localizedDescription)")
			collections = []
		}
	}
	
	@MainActor
	private func refreshCollections(query: String?, currentUserId: String, hiddenCollectionIds: Set<String>) async {
		// Store current collection IDs to check for new content
		let currentCollectionIds = Set(collections.map { $0.id })
		
		// Fetch fresh data
		await searchCollections(query: query, currentUserId: currentUserId, hiddenCollectionIds: hiddenCollectionIds)
		
		// Check if we have new collections
		let newCollectionIds = Set(collections.map { $0.id })
		let hasNewCollections = !newCollectionIds.subtracting(currentCollectionIds).isEmpty
		
		// If active search and no new collections, reorder existing results
		if query != nil && !hasNewCollections && !collections.isEmpty {
			var reorderedCollections = collections
			reorderedCollections.shuffle()
			collections = reorderedCollections
		}
	}
			
	@MainActor
	private func searchPosts(query: String?, currentUserId: String, hiddenCollectionIds: Set<String>) async {
		isLoadingPosts = true
		defer { isLoadingPosts = false }
		
		do {
			let db = Firestore.firestore()
			let queryRef: Query = db.collection("posts")
			
			// Always load recent posts, then filter in memory so search can use
			// collection name AND caption/title (case-insensitive, emojis ok).
			let snapshot = try await queryRef
				.order(by: "createdAt", descending: true)
				.limit(to: 80)
				.getDocuments()
			
			let allPosts = snapshot.documents.compactMap { doc -> CollectionPost? in
				let data = doc.data()
				
				var allMediaItems: [MediaItem] = []
				if let mediaItemsArray = data["mediaItems"] as? [[String: Any]] {
					allMediaItems = mediaItemsArray.compactMap { mediaData in
						MediaItem(
							imageURL: mediaData["imageURL"] as? String,
							thumbnailURL: mediaData["thumbnailURL"] as? String,
							videoURL: mediaData["videoURL"] as? String,
							videoDuration: mediaData["videoDuration"] as? Double,
							isVideo: mediaData["isVideo"] as? Bool ?? false
						)
					}
				}
				
				let firstMediaItem = allMediaItems.first
				
				return CollectionPost(
					id: doc.documentID,
					title: data["title"] as? String ?? data["caption"] as? String ?? "",
					collectionId: data["collectionId"] as? String ?? "",
					authorId: data["authorId"] as? String ?? "",
					authorName: data["authorName"] as? String ?? "",
					createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
					firstMediaItem: firstMediaItem,
					mediaItems: allMediaItems
				)
			}
			
			let postsNotByUser = allPosts.filter { $0.authorId != currentUserId }
			let collectionIds = Array(Set(postsNotByUser.map { $0.collectionId }.filter { !$0.isEmpty }))
			
			var userCollectionIds: Set<String> = []
			var followedCollectionIds: Set<String> = []
			let discoverCollectionIds: Set<String> = Set(collections.map { $0.id })
			var newPostsCollectionMap: [String: CollectionData] = [:]
			
			if !collectionIds.isEmpty {
				await withTaskGroup(of: (String, Bool, Bool, CollectionData?).self) { group in
					for collectionId in collectionIds {
						group.addTask {
							do {
								if let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) {
									let isUserCollection = collection.ownerId == currentUserId || collection.members.contains(currentUserId)
									let isFollowed = collection.followers.contains(currentUserId)
									return (collectionId, isUserCollection, isFollowed, collection)
								}
							} catch {
								print("Error fetching collection \(collectionId): \(error.localizedDescription)")
							}
							return (collectionId, false, false, nil)
						}
					}
					
					for await (collectionId, isUserCollection, isFollowed, collection) in group {
						if isUserCollection {
							userCollectionIds.insert(collectionId)
						}
						if isFollowed {
							followedCollectionIds.insert(collectionId)
						}
						if let collection = collection {
							for post in postsNotByUser where post.collectionId == collectionId {
								newPostsCollectionMap[post.id] = collection
							}
						}
					}
				}
			}
			
			let lowerQuery = query?.lowercased()
			
			var filteredPosts = postsNotByUser.filter { post in
				// Basic structural filters (same as before)
				if post.collectionId.isEmpty { return true }
				if userCollectionIds.contains(post.collectionId) { return false }
				if hiddenCollectionIds.contains(post.collectionId) { return false }
				if followedCollectionIds.contains(post.collectionId) { return false }
				// In discover mode (empty search), only show posts from collections
				// visible in the Discover Collections tab
				if lowerQuery == nil && !discoverCollectionIds.contains(post.collectionId) { return false }
				
				// If user typed a query, require that either the collection name
				// OR the post caption/title contains it (case-insensitive, emojis ok)
				if let q = lowerQuery {
					let collectionName = newPostsCollectionMap[post.id]?.name.lowercased() ?? ""
					let captionOrTitle = post.title.lowercased()
					if !collectionName.contains(q) && !captionOrTitle.contains(q) {
						return false
					}
				}
				
				return true
			}
			
			filteredPosts = await CollectionService.filterPosts(filteredPosts)
			
			// Additional check: filter out posts from mutually blocked users
			var finalFilteredPosts: [CollectionPost] = []
			for post in filteredPosts {
				let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: post.authorId)
				if !areMutuallyBlocked {
					finalFilteredPosts.append(post)
				}
			}
			filteredPosts = finalFilteredPosts
			
			let finalPostsMap = newPostsCollectionMap.filter { key, _ in
				filteredPosts.contains(where: { $0.id == key })
			}
			
			// Check if we have new posts compared to cached data
			if DiscoverCache.shared.hasDataLoaded() && query == nil {
				let cached = DiscoverCache.shared.getCachedData()
				let cachedPostIds = Set(cached.posts.map { $0.id })
				let newPostIds = Set(filteredPosts.map { $0.id })
				let hasNewPosts = !newPostIds.subtracting(cachedPostIds).isEmpty
				
				if hasNewPosts {
					// New posts found - use them
					posts = filteredPosts
					postsCollectionMap = finalPostsMap
					// Update cache
					DiscoverCache.shared.setCachedData(
						collections: cached.collections,
						posts: filteredPosts,
						postsMap: finalPostsMap,
						users: cached.users
					)
				} else {
					// No new posts - reorder/shuffle existing feed
					var reorderedPosts = cached.posts
					reorderedPosts.shuffle()
					posts = reorderedPosts
					postsCollectionMap = cached.postsMap
					// Update cache with reordered posts
					DiscoverCache.shared.setCachedData(
						collections: cached.collections,
						posts: reorderedPosts,
						postsMap: cached.postsMap,
						users: cached.users
					)
				}
			} else {
				// No cached data or search query exists - use new results
				posts = filteredPosts
				postsCollectionMap = finalPostsMap
				// Update cache
				let cached = DiscoverCache.shared.getCachedData()
				DiscoverCache.shared.setCachedData(
					collections: cached.collections,
					posts: filteredPosts,
					postsMap: finalPostsMap,
					users: cached.users
				)
			}
		} catch {
			print("Error searching posts: \(error.localizedDescription)")
			posts = []
		}
	}
	
	@MainActor
	private func refreshPosts(query: String?, currentUserId: String, hiddenCollectionIds: Set<String>) async {
		// Store current post IDs to check for new content
		let currentPostIds = Set(posts.map { $0.id })
		
		// Fetch fresh data
		await searchPosts(query: query, currentUserId: currentUserId, hiddenCollectionIds: hiddenCollectionIds)
		
		// Check if we have new posts
		let newPostIds = Set(posts.map { $0.id })
		let hasNewPosts = !newPostIds.subtracting(currentPostIds).isEmpty
		
		// If active search and no new posts, reorder existing results
		if query != nil && !hasNewPosts && !posts.isEmpty {
			var reorderedPosts = posts
			reorderedPosts.shuffle()
			posts = reorderedPosts
			// Also shuffle the postsCollectionMap to match
			var shuffledMap: [String: CollectionData] = [:]
			for post in reorderedPosts {
				if let collection = postsCollectionMap[post.id] {
					shuffledMap[post.id] = collection
				}
			}
			postsCollectionMap = shuffledMap
		}
	}
	
	@MainActor
	private func searchUsernames(query: String?) async {
		isLoadingUsers = true
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			users = []
			isLoadingUsers = false
			return
		}
		
		do {
			let db = Firestore.firestore()
			let friendService = FriendService.shared
			var foundUsers: [UserSearchResult] = []
			
			if let query = query, !query.isEmpty {
				let queryLower = query.lowercased()
				let snapshot = try await db.collection("users")
					.limit(to: 15)
					.getDocuments()
				
				for doc in snapshot.documents {
					let data = doc.data()
					let username = (data["username"] as? String ?? "").lowercased()
					let name = (data["name"] as? String ?? "").lowercased()
					
					if username.contains(queryLower) || name.contains(queryLower) {
						// Check mutual blocking
						let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: doc.documentID)
						
						if !areMutuallyBlocked && doc.documentID != currentUserId {
							foundUsers.append(UserSearchResult(
								id: doc.documentID,
								name: data["name"] as? String ?? "",
								username: data["username"] as? String ?? "",
								profileImageURL: data["profileImageURL"] as? String
							))
						}
					}
				}
			} else {
				let snapshot = try await db.collection("users")
					.limit(to: 100)
					.getDocuments()
				
				for doc in snapshot.documents {
					if doc.documentID == currentUserId { continue }
					let data = doc.data()
					// Check mutual blocking
					let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: doc.documentID)
					if !areMutuallyBlocked {
						foundUsers.append(UserSearchResult(
							id: doc.documentID,
							name: data["name"] as? String ?? "",
							username: data["username"] as? String ?? "",
							profileImageURL: data["profileImageURL"] as? String
						))
					}
				}
			}
			
			// Check if we have new users compared to cached data
			if DiscoverCache.shared.hasDataLoaded() && query == nil {
				let cached = DiscoverCache.shared.getCachedData()
				let cachedUserIds = Set(cached.users.map { $0.id })
				let newUserIds = Set(foundUsers.map { $0.id })
				let hasNewUsers = !newUserIds.subtracting(cachedUserIds).isEmpty
				
				if hasNewUsers {
					// New users found - use them
					users = foundUsers
					// Update cache
					DiscoverCache.shared.setCachedData(
						collections: cached.collections,
						posts: cached.posts,
						postsMap: cached.postsMap,
						users: foundUsers
					)
				} else {
					// No new users - reorder/shuffle existing feed
					var reorderedUsers = cached.users
					reorderedUsers.shuffle()
					users = reorderedUsers
					// Update cache with reordered users
					DiscoverCache.shared.setCachedData(
						collections: cached.collections,
						posts: cached.posts,
						postsMap: cached.postsMap,
						users: reorderedUsers
					)
				}
			} else {
				// No cached data or search query exists - use new results
				users = foundUsers
				// Update cache
				let cached = DiscoverCache.shared.getCachedData()
				DiscoverCache.shared.setCachedData(
					collections: cached.collections,
					posts: cached.posts,
					postsMap: cached.postsMap,
					users: foundUsers
				)
			}
		} catch {
			print("Error searching usernames: \(error)")
			users = []
		}
		
		isLoadingUsers = false
	}
	
	@MainActor
	private func refreshUsers(query: String?) async {
		// Store current user IDs to check for new content
		let currentUserIds = Set(users.map { $0.id })
		
		// Fetch fresh data
		await searchUsernames(query: query)
		
		// Check if we have new users
		let newUserIds = Set(users.map { $0.id })
		let hasNewUsers = !newUserIds.subtracting(currentUserIds).isEmpty
		
		// If active search and no new users, reorder existing results
		if query != nil && !hasNewUsers && !users.isEmpty {
			var reorderedUsers = users
			reorderedUsers.shuffle()
			users = reorderedUsers
		}
	}
	
	@MainActor
	private func handleFollowTapped(collection: CollectionData) async {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		let isCurrentlyFollowing = followStatus[collection.id] ?? collection.followers.contains(currentUserId)
		followStatus[collection.id] = !isCurrentlyFollowing
		
		do {
			if isCurrentlyFollowing {
				try await CollectionService.shared.unfollowCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
			} else {
				try await CollectionService.shared.followCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
				NotificationCenter.default.post(name: NSNotification.Name("CollectionFollowed"), object: nil, userInfo: ["collectionId": collection.id])
			}
			
			if !isCurrentlyFollowing {
				collections.removeAll { $0.id == collection.id }
			}
		} catch {
			print("❌ Error following/unfollowing collection: \(error.localizedDescription)")
			followStatus[collection.id] = isCurrentlyFollowing
		}
	}
	
	private func handleCollectionAction(collection: CollectionData) {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		let isMember = collection.members.contains(currentUserId)
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		if collection.type == "Request" && !isMember && !isOwner && !isAdmin {
			let hasRequested = CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id)
			
			if let currentUserId = Auth.auth().currentUser?.uid {
				if hasRequested {
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionRequestCancelled"),
						object: collection.id,
						userInfo: ["requesterId": currentUserId, "collectionId": collection.id]
					)
				} else {
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionRequestSent"),
						object: collection.id,
						userInfo: ["requesterId": currentUserId, "collectionId": collection.id]
					)
				}
			}
			
			Task {
				do {
					if hasRequested {
						try await CollectionService.shared.cancelCollectionRequest(collectionId: collection.id)
					} else {
					try await CollectionService.shared.sendCollectionRequest(collectionId: collection.id)
					}
				} catch {
					print("Error \(hasRequested ? "cancelling" : "sending") collection request: \(error.localizedDescription)")
					if let currentUserId = Auth.auth().currentUser?.uid {
						if hasRequested {
							NotificationCenter.default.post(
								name: NSNotification.Name("CollectionRequestSent"),
								object: collection.id,
								userInfo: ["requesterId": currentUserId, "collectionId": collection.id]
							)
						} else {
							NotificationCenter.default.post(
								name: NSNotification.Name("CollectionRequestCancelled"),
								object: collection.id,
								userInfo: ["requesterId": currentUserId, "collectionId": collection.id]
							)
						}
					}
				}
			}
		} else if collection.type == "Open" && !isMember && !isOwner && !isAdmin {
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionJoined"),
				object: collection.id,
				userInfo: ["userId": currentUserId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collection.id,
				userInfo: ["action": "memberAdded", "userId": currentUserId]
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("UserCollectionsUpdated"),
				object: currentUserId
			)
			
			membershipStatus[collection.id] = true
			
			Task {
				do {
					try await CollectionService.shared.joinCollection(collectionId: collection.id)
				} catch {
					print("Error joining collection: \(error.localizedDescription)")
					await MainActor.run {
						membershipStatus[collection.id] = false
					}
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionLeft"),
						object: collection.id,
						userInfo: ["userId": currentUserId]
					)
				}
			}
		} else if collection.type == "Open" && isMember && !isOwner {
			Task {
				do {
					try await CollectionService.shared.leaveCollection(collectionId: collection.id, userId: currentUserId)
				} catch {
					print("Error leaving collection: \(error.localizedDescription)")
				}
			}
		}
	}
	
	private func handleCollectionTap(collection: CollectionData) async {
		if !collection.isPublic {
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			let isMember = collection.members.contains(currentUserId)
			let isOwner = collection.ownerId == currentUserId
			let isAdmin = collection.owners.contains(currentUserId)
			
			if isOwner || isMember || isAdmin {
				let authManager = BiometricAuthManager()
				let success = await authManager.authenticateWithFallback(reason: "Access \(collection.name)")
				
				if success {
					await MainActor.run {
						selectedCollection = collection
						showingInsideCollection = true
					}
				}
				return
			}
		}
		
		await MainActor.run {
			selectedCollection = collection
			showingInsideCollection = true
		}
	}
	}
	
// MARK: - Collection Style Ad Placeholder (matches CollectionRowDesign layout)
private struct CollectionStyleAdPlaceholder: View {
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	
	private var isIPad: Bool {
		horizontalSizeClass == .regular
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: isIPad ? 16 : 12) {
			HStack(spacing: isIPad ? 16 : 12) {
				let imageSize: CGFloat = isIPad ? 56 : 44
				ZStack {
					Circle()
						.fill(Color.blue.opacity(0.08))
						.frame(width: imageSize, height: imageSize)
					
					Image(systemName: "megaphone.fill")
						.font(.system(size: isIPad ? 28 : 22))
						.foregroundColor(.blue)
				}
				
				VStack(alignment: .leading, spacing: isIPad ? 6 : 4) {
					RoundedRectangle(cornerRadius: 4)
						.fill(Color.gray.opacity(colorScheme == .dark ? 0.4 : 0.2))
						.frame(width: isIPad ? 140 : 110, height: isIPad ? 18 : 14)
					
					Text("Sponsored")
						.font(isIPad ? .subheadline : .caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
			}
			.padding(.horizontal, isIPad ? 20 : 16)
			
			let thumbnailWidth: CGFloat = isIPad ? 180 : 90
			let thumbnailHeight: CGFloat = isIPad ? 260 : 130
			let spacing: CGFloat = isIPad ? 18 : 8
			
			HStack(spacing: spacing) {
				ForEach(0..<4, id: \.self) { _ in
					RoundedRectangle(cornerRadius: 2)
						.fill(Color.gray.opacity(colorScheme == .dark ? 0.5 : 0.25))
						.frame(width: thumbnailWidth, height: thumbnailHeight)
				}
			}
			.padding(.horizontal, isIPad ? 20 : 16)
			.padding(.bottom, isIPad ? 24 : 20)
		}
	}
}

// MARK: - User Search Result
struct UserSearchResult: Identifiable {
	let id: String
	let name: String
	let username: String
	let profileImageURL: String?
}

// MARK: - User Search Card
struct UserSearchCard: View {
	let user: UserSearchResult
	
	var body: some View {
		HStack(spacing: 12) {
			if let imageURL = user.profileImageURL, !imageURL.isEmpty {
				CachedProfileImageView(url: imageURL, size: 50)
					.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 50)
			}
			
			VStack(alignment: .leading, spacing: 4) {
				Text(user.name)
					.font(.system(size: 16, weight: .semibold))
					.foregroundColor(.primary)
					.lineLimit(1)
				
				Text("@\(user.username)")
					.font(.system(size: 14))
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			
			Spacer()
		}
		.padding(.vertical, 8)
	}
}
