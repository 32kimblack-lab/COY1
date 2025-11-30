import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI
import LocalAuthentication

// MARK: - Search Screen (Full-screen search with recent searches)
struct SearchScreen: View {
	@State private var searchText = ""
	@State private var selectedTab: Int = 0
	@State private var recentSearches: [String] = []
	@State private var collections: [CollectionData] = []
	@State private var posts: [CollectionPost] = []
	@State private var users: [UserSearchResult] = []
	@State private var postsCollectionMap: [String: CollectionData] = [:]
	@State private var isLoadingCollections = false
	@State private var isLoadingPosts = false
	@State private var isLoadingUsers = false
	@State private var searchTask: Task<Void, Never>?
	@State private var selectedCollectionForNavigation: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedUserId: String?
	@State private var collectionFollowStatus: [String: Bool] = [:] // Track follow status for each collection
	
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var scenePhase
	@EnvironmentObject var authService: AuthService
	
	private let apiClient = APIClient.shared
	private let collectionService = CollectionService.shared
	private let userService = UserService.shared
	
	// UserDefaults key for recent searches
	private let recentSearchesKey = "recentSearches"
	
	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				// Search Bar
				searchBar
					.padding(.horizontal)
					.padding(.top, 8)
				
				// Show recent searches if search text is empty
				if searchText.isEmpty {
					recentSearchesView
				} else {
					// Tab Switcher
					tabSwitcher
						.padding(.top, 16)
						.padding(.bottom, 8)
					
					// Content
					content
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.background(colorScheme == .dark ? Color.black : Color.white)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Cancel") {
						dismiss()
					}
				}
			}
			.onAppear {
				loadRecentSearches()
			}
			.onChange(of: scenePhase) { oldPhase, newPhase in
				// When app becomes active (from background or completely closed), refresh if we have an active search
				if newPhase == .active {
					if !searchText.isEmpty {
						Task {
							await performSearch()
						}
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionFollowed"))) { notification in
				if let collectionId = notification.object as? String {
					collectionFollowStatus[collectionId] = true
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnfollowed"))) { notification in
				if let collectionId = notification.object as? String {
					collectionFollowStatus[collectionId] = false
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostHidden"))) { notification in
				// Refresh posts when a post is hidden
				Task {
					await performSearch()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostDeleted"))) { notification in
				// Refresh posts when a post is deleted
				Task {
					await performSearch()
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
						}
						// Then refresh to ensure consistency
						await performSearch()
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
				// Refresh search results when a user is unblocked
				Task {
					await performSearch()
				}
			}
			.navigationDestination(isPresented: $showingInsideCollection) {
				if let collection = selectedCollectionForNavigation {
					CYInsideCollectionView(collection: collection)
						.environmentObject(authService)
				}
			}
			.navigationDestination(isPresented: Binding(
				get: { selectedUserId != nil },
				set: { if !$0 { selectedUserId = nil } }
			)) {
				if let userId = selectedUserId {
					ViewerProfileView(userId: userId)
						.environmentObject(authService)
				}
			}
		}
	}
	
	// MARK: - Search Bar
	private var searchBar: some View {
		HStack {
			// Only show the magnifying glass icon, no text field
			Image(systemName: "magnifyingglass")
				.foregroundColor(.secondary)
				.font(.system(size: 18))
			
			Spacer()
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
	}
	
	// MARK: - Recent Searches View
	private var recentSearchesView: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				if !recentSearches.isEmpty {
					Text("Recent Searches")
						.font(.system(size: 18, weight: .semibold))
						.padding(.horizontal)
					
					ForEach(recentSearches, id: \.self) { search in
						Button(action: {
							searchText = search
							Task {
								await performSearch()
							}
						}) {
							HStack {
								Image(systemName: "clock")
									.foregroundColor(.secondary)
								Text(search)
									.foregroundColor(.primary)
								Spacer()
								Button(action: {
									removeRecentSearch(search)
								}) {
									Image(systemName: "xmark")
										.font(.caption)
										.foregroundColor(.secondary)
								}
							}
							.padding(.horizontal)
							.padding(.vertical, 8)
						}
						.buttonStyle(.plain)
					}
					
					if !recentSearches.isEmpty {
						Button(action: {
							clearRecentSearches()
						}) {
							Text("Clear Recent Searches")
								.font(.system(size: 14))
								.foregroundColor(.red)
								.frame(maxWidth: .infinity)
								.padding(.vertical, 8)
						}
						.padding(.horizontal)
					}
				} else {
					VStack(spacing: 12) {
						Image(systemName: "magnifyingglass")
							.font(.system(size: 48))
							.foregroundColor(.secondary)
						Text("Start searching to see results")
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.padding(.top, 100)
				}
			}
			.padding(.vertical)
		}
	}
	
	// MARK: - Tab Switcher
	private var tabSwitcher: some View {
		VStack(spacing: 10) {
			HStack(spacing: 0) {
				Spacer()
				tabButton(title: "Collections", index: 0)
				Spacer()
				tabButton(title: "Post", index: 1)
				Spacer()
				tabButton(title: "Usernames", index: 2)
				Spacer()
			}
			.padding(.horizontal, 16)
			
			// Moving underline - fixed width to match tab spacing
			GeometryReader { proxy in
				let totalWidth = proxy.size.width
				let tabWidth = totalWidth / 3
				let underlineWidth = tabWidth * 0.85 // 85% of tab width for better fit
				ZStack(alignment: .leading) {
					Rectangle()
						.fill(Color.clear)
						.frame(height: 2)
					
					Rectangle()
						.fill(Color.blue)
						.frame(width: underlineWidth, height: 2)
						.offset(x: CGFloat(selectedTab) * tabWidth + (tabWidth - underlineWidth) / 2)
				}
			}
			.frame(height: 2)
		}
	}
	
	private func tabButton(title: String, index: Int) -> some View {
		Button(action: {
			withAnimation {
				selectedTab = index
			}
		}) {
			Text(title)
				.font(.system(size: 16, weight: selectedTab == index ? .semibold : .regular))
				.foregroundColor(selectedTab == index ? .blue : .secondary)
		}
	}
	
	// MARK: - Content
	private var content: some View {
		Group {
			switch selectedTab {
			case 0:
				collectionsContent
			case 1:
				postsContent
			case 2:
				usernamesContent
			default:
				EmptyView()
			}
		}
	}
	
	// MARK: - Collections Content
	private var collectionsContent: some View {
		Group {
			if isLoadingCollections {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if collections.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "square.stack.3d.up")
						.font(.system(size: 48))
						.foregroundColor(.secondary)
					Text("No collections found")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 16) {
						ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
								CollectionRowDesign(
									collection: collection,
									isFollowing: collectionFollowStatus[collection.id] ?? false,
									hasRequested: false,
									isMember: collection.members.contains(Auth.auth().currentUser?.uid ?? ""),
									isOwner: collection.ownerId == Auth.auth().currentUser?.uid,
									onFollowTapped: {
										Task {
											await handleFollowTapped(collection: collection)
										}
									},
								onActionTapped: {
									Task {
										await handleCollectionAction(collection: collection)
									}
								},
									onProfileTapped: {
										selectedUserId = collection.ownerId
									},
									onCollectionTapped: {
									Task {
										await handleCollectionTap(collection: collection)
							}
								}
							)
							.padding(.horizontal)
							
							// Meta collection ad removed - component not available
						}
					}
					.padding(.vertical)
				}
				.refreshable {
					await refreshCollections()
				}
			}
		}
	}
	
	// MARK: - Posts Content
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
					Text("No posts found")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				// Use PinterestPostGrid instead
				PinterestPostGrid(
					posts: posts,
					collection: nil,
					isIndividualCollection: false,
					currentUserId: authService.user?.uid,
					postsCollectionMap: postsCollectionMap
				)
				.refreshable {
					await refreshPosts()
				}
			}
		}
	}
	
	// MARK: - Usernames Content
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
					Text("No users found")
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
				.refreshable {
					await refreshUsernames()
				}
			}
		}
	}
	
	// MARK: - Search Logic
	@MainActor
	private func performSearch() async {
		guard !searchText.isEmpty else { return }
		
		let query = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if query.isEmpty { return }
		
		// Save to recent searches
		saveToRecentSearches(searchText)
		
		switch selectedTab {
		case 0:
			await searchCollections(query: query)
		case 1:
			await searchPosts(query: query)
		case 2:
			await searchUsernames(query: query)
		default:
			break
		}
	}
	
	// Search Collections
	private func searchCollections(query: String) async {
		isLoadingCollections = true
		
		do {
			// CRITICAL FIX: Rate limiting handled by APIRateLimiter in APIClient
			let responses = try await apiClient.searchCollections(query: query)
			let currentUserId = Auth.auth().currentUser?.uid ?? ""
			
			// CRITICAL FIX: Limit results to prevent loading too much data
			let limitedResponses = Array(responses.prefix(100))
			
			let allCollections = limitedResponses.map { response in
				let dateFormatter = ISO8601DateFormatter()
				dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
				let createdAt = dateFormatter.date(from: response.createdAt) ?? Date()
				
				return CollectionData(
					id: response.id,
					name: response.name,
					description: response.description,
					type: response.type,
					isPublic: response.isPublic,
					ownerId: response.ownerId,
					ownerName: response.ownerName,
					owners: response.owners ?? [response.ownerId],
					imageURL: response.imageURL,
					invitedUsers: [],
					members: response.members,
					memberCount: response.memberCount,
					followers: [],
					followerCount: 0,
					allowedUsers: response.allowedUsers ?? [],
					deniedUsers: response.deniedUsers ?? [],
					createdAt: createdAt
				)
			}
			
			// Filter by access control and search query
			var filteredCollections: [CollectionData] = []
			let friendService = FriendService.shared
			
			for collection in allCollections {
				// Check access
				let canView = CollectionService.canUserViewCollection(collection, userId: currentUserId)
				
				// Filter by search query (case-insensitive)
				let nameMatches = collection.name.lowercased().contains(query)
				let descriptionMatches = collection.description.lowercased().contains(query)
				
				// Check if collection owner is blocked (mutual block check)
				// Check mutual blocking for collection owner
				let isOwnerMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
				
				// Only include if accessible, matches query, and owner is not mutually blocked
				if canView && (nameMatches || descriptionMatches) && !isOwnerMutuallyBlocked {
					filteredCollections.append(collection)
				}
			}
			
			// Filter out hidden collections and collections from blocked users (mutual blocking, blocked users, etc.)
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
			
			collections = filteredCollections
			
			// Load follow status for all collections
			await loadFollowStatusForCollections()
		} catch {
			print("Error searching collections: \(error)")
			collections = []
		}
		
		isLoadingCollections = false
	}
	
	// MARK: - Follow/Unfollow Functions
	private func handleFollowTapped(collection: CollectionData) async {
		guard let currentUserId = authService.user?.uid else {
			print("⚠️ SearchScreen: No current user ID")
			return
		}
		
		let isCurrentlyFollowing = collectionFollowStatus[collection.id] ?? false
		
		do {
			if isCurrentlyFollowing {
				// Unfollow
				try await CollectionService.shared.unfollowCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
				await MainActor.run {
					collectionFollowStatus[collection.id] = false
				}
			} else {
				// Follow
				try await CollectionService.shared.followCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
				await MainActor.run {
					collectionFollowStatus[collection.id] = true
				}
			}
		} catch {
			print("❌ Error following/unfollowing collection: \(error.localizedDescription)")
		}
	}
	
	private func loadFollowStatusForCollections() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		// Update follow status for all collections based on their followers array
				await MainActor.run {
			for collection in collections {
				collectionFollowStatus[collection.id] = collection.followers.contains(currentUserId)
			}
		}
	}
	
	// Search Posts
	private func searchPosts(query: String) async {
		isLoadingPosts = true
		
		do {
			// CRITICAL FIX: Limit collections fetched to prevent loading too much data
			// First, get accessible collections with limit (backend should handle this, but add safety)
			let responses = try await apiClient.searchCollections(query: nil) // Get all collections
			let currentUserId = Auth.auth().currentUser?.uid ?? ""
			
			// CRITICAL FIX: Limit to first 100 collections to prevent memory issues
			let limitedResponses = Array(responses.prefix(100))
			
			let allCollections = limitedResponses.map { response in
				let dateFormatter = ISO8601DateFormatter()
				dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
				let createdAt = dateFormatter.date(from: response.createdAt) ?? Date()
				
				return CollectionData(
					id: response.id,
					name: response.name,
					description: response.description,
					type: response.type,
					isPublic: response.isPublic,
					ownerId: response.ownerId,
					ownerName: response.ownerName,
					owners: response.owners ?? [response.ownerId],
					imageURL: response.imageURL,
					invitedUsers: [],
					members: response.members,
					memberCount: response.memberCount,
					followers: [],
					followerCount: 0,
					allowedUsers: response.allowedUsers ?? [],
					deniedUsers: response.deniedUsers ?? [],
					createdAt: createdAt
				)
			}
			
			// Filter accessible collections
			let accessibleCollections = allCollections.filter { collection in
				let isOwner = collection.ownerId == currentUserId
				let isMember = collection.members.contains(currentUserId)
				if isOwner || isMember { return false }
				return CollectionService.canUserViewCollection(collection, userId: currentUserId)
			}
			
			// Fetch posts from accessible collections
			var allPosts: [CollectionPost] = []
			var newPostsCollectionMap: [String: CollectionData] = [:]
			
			await withTaskGroup(of: (String, [CollectionPost]).self) { group in
				for collection in accessibleCollections {
					group.addTask {
						do {
							let posts = try await self.fetchPostsFromFirebaseForCollection(collectionId: collection.id)
							return (collection.id, posts)
						} catch {
							return (collection.id, [])
						}
					}
				}
				
				for await (collectionId, collectionPosts) in group {
					// Only add posts from collections the user has access to
					if accessibleCollections.contains(where: { $0.id == collectionId }) {
					allPosts.append(contentsOf: collectionPosts)
					}
					if let collection = accessibleCollections.first(where: { $0.id == collectionId }) {
						for post in collectionPosts {
							newPostsCollectionMap[post.id] = collection
						}
					}
				}
			}
			
			// Filter posts by search query (collection name + caption)
			let filteredPosts = allPosts.filter { post in
				let captionMatches = (post.caption ?? "").lowercased().contains(query) || post.title.lowercased().contains(query)
				
				// Check if post's collection name matches
				let collectionMatches: Bool
				if let collection = newPostsCollectionMap[post.id] {
					collectionMatches = collection.name.lowercased().contains(query) || collection.description.lowercased().contains(query)
				} else {
					collectionMatches = false
				}
				
				return captionMatches || collectionMatches
			}
			
			// Use main filter function which includes access filtering, blocked users, and hidden collections
			var visiblePosts = await CollectionService.filterPosts(filteredPosts)
			
			// Additional check: filter out posts from mutually blocked users
			var finalFilteredPosts: [CollectionPost] = []
			for post in visiblePosts {
				let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: post.authorId)
				if !areMutuallyBlocked {
					finalFilteredPosts.append(post)
				}
			}
			visiblePosts = finalFilteredPosts
			
			posts = visiblePosts
			postsCollectionMap = newPostsCollectionMap.filter { key, _ in
				visiblePosts.contains(where: { $0.id == key })
			}
			
		} catch {
			print("Error searching posts: \(error)")
			posts = []
			postsCollectionMap = [:]
		}
		
		isLoadingPosts = false
	}
	
	// Search Usernames
	private func searchUsernames(query: String) async {
		isLoadingUsers = true
		
		do {
			let db = Firestore.firestore()
			guard let currentUserId = Auth.auth().currentUser?.uid else {
				users = []
				isLoadingUsers = false
				return
			}
			
			// Search in Firestore users collection
			let snapshot = try await db.collection("users")
				.whereField("username", isGreaterThanOrEqualTo: query)
				.whereField("username", isLessThanOrEqualTo: query + "\u{f8ff}")
				.limit(to: 50)
				.getDocuments()
			
			var foundUsers: [UserSearchResult] = []
			let friendService = FriendService.shared
			
			for doc in snapshot.documents {
				// Skip current user
				guard doc.documentID != currentUserId else { continue }
				
				let data = doc.data()
				let username = (data["username"] as? String ?? "").lowercased()
				
				// Additional filter for partial matches
				if username.contains(query) {
					// Check if user is blocked (mutual block check)
					let isBlocked = await friendService.isBlocked(userId: doc.documentID)
					let isBlockedBy = await friendService.isBlockedBy(userId: doc.documentID)
					
					// Filter out blocked users (mutual invisibility)
					if !isBlocked && !isBlockedBy {
						foundUsers.append(UserSearchResult(
							id: doc.documentID,
							name: data["name"] as? String ?? "",
							username: data["username"] as? String ?? "",
							profileImageURL: data["profileImageURL"] as? String
						))
					}
				}
			}
			
			// Also try backend API search
			if let usernameUser = try? await userService.getUserByUsername(query) {
				// getUserByUsername already checks mutual blocking and returns nil if blocked
				// So if we get a user here, they're not blocked
				// Only add if not already in list
				if !foundUsers.contains(where: { $0.id == usernameUser.userId }) {
					foundUsers.append(UserSearchResult(
						id: usernameUser.userId,
						name: usernameUser.name,
						username: usernameUser.username,
						profileImageURL: usernameUser.profileImageURL
					))
				}
			}
			
			users = foundUsers
		} catch {
			print("Error searching usernames: \(error)")
			users = []
		}
		
		isLoadingUsers = false
	}
	
	// MARK: - Fetch Posts Helper
	private func fetchPostsFromFirebaseForCollection(collectionId: String) async throws -> [CollectionPost] {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("posts")
			.whereField("collectionId", isEqualTo: collectionId)
			.getDocuments()
		
		let loadedPosts = snapshot.documents.compactMap { doc -> CollectionPost? in
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
			
			if allMediaItems.isEmpty, let firstMediaData = data["firstMediaItem"] as? [String: Any] {
				let firstItem = MediaItem(
					imageURL: firstMediaData["imageURL"] as? String,
					thumbnailURL: firstMediaData["thumbnailURL"] as? String,
					videoURL: firstMediaData["videoURL"] as? String,
					videoDuration: firstMediaData["videoDuration"] as? Double,
					isVideo: firstMediaData["isVideo"] as? Bool ?? false
				)
				allMediaItems = [firstItem]
			}
			
			let firstMediaItem = allMediaItems.first
			let isPinned = data["isPinned"] as? Bool ?? false
			_ = (data["pinnedAt"] as? Timestamp)?.dateValue()
			let caption = data["caption"] as? String
			let allowReplies = data["allowReplies"] as? Bool ?? true
			_ = data["commentCount"] as? Int ?? 0
			_ = data["allowDownload"] as? Bool ?? true
			
			return CollectionPost(
				id: doc.documentID,
				title: data["title"] as? String ?? data["caption"] as? String ?? "",
				collectionId: data["collectionId"] as? String ?? "",
				authorId: data["authorId"] as? String ?? "",
				authorName: data["authorName"] as? String ?? "",
				createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
				firstMediaItem: firstMediaItem,
				mediaItems: allMediaItems,
				isPinned: isPinned,
				caption: caption,
				allowReplies: allowReplies
			)
		}
		
		return loadedPosts
	}
	
	// MARK: - Recent Searches Management
	private func loadRecentSearches() {
		if let data = UserDefaults.standard.array(forKey: recentSearchesKey) as? [String] {
			recentSearches = data
		}
	}
	
	private func saveToRecentSearches(_ search: String) {
		let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		
		recentSearches.removeAll { $0.lowercased() == trimmed.lowercased() }
		recentSearches.insert(trimmed, at: 0)
		recentSearches = Array(recentSearches.prefix(10)) // Keep only last 10
		
		UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
	}
	
	private func removeRecentSearch(_ search: String) {
		recentSearches.removeAll { $0 == search }
		UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
	}
	
	private func clearRecentSearches() {
		recentSearches = []
		UserDefaults.standard.removeObject(forKey: recentSearchesKey)
	}
	
	private func handleCollectionTap(collection: CollectionData) async {
		// Check if this is a private collection
		if !collection.isPublic {
			// Check if current user is owner or member
			let currentUserId = authService.user?.uid ?? ""
			let isOwner = collection.ownerId == currentUserId
			let isMember = collection.members.contains(currentUserId)
			let isInOwners = collection.owners.contains(currentUserId)
			
			if isOwner || isMember || isInOwners {
				// User is owner or member - require Face ID/Touch ID
				let authManager = BiometricAuthManager()
				let success = await authManager.authenticateWithFallback(reason: "Access \(collection.name)")
				
				if success {
					await MainActor.run {
						selectedCollectionForNavigation = collection
						showingInsideCollection = true
					}
				}
				// If authentication fails, do nothing (user stays on current screen)
				return
			}
		}
		
		// For public collections or non-members, proceed normally
		await MainActor.run {
			selectedCollectionForNavigation = collection
			showingInsideCollection = true
		}
	}
	
	private func handleCollectionAction(collection: CollectionData) async {
		guard let currentUserId = authService.user?.uid else { return }
		
		let isMember = collection.members.contains(currentUserId) || collection.owners.contains(currentUserId)
		let isOwner = collection.ownerId == currentUserId
		
		// Handle Request action for Request-type collections
		if collection.type == "Request" && !isMember && !isOwner {
			// Check if there's already a pending request
			let hasRequested = CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id)
			
			// Post notification immediately for synchronization
			if let currentUserId = authService.user?.uid {
				if hasRequested {
					// Post cancellation notification immediately
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionRequestCancelled"),
						object: collection.id,
						userInfo: ["requesterId": currentUserId, "collectionId": collection.id]
					)
				} else {
					// Post request notification immediately
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionRequestSent"),
						object: collection.id,
						userInfo: ["requesterId": currentUserId, "collectionId": collection.id]
					)
				}
			}
			
			do {
				if hasRequested {
					// Cancel/unrequest
					try await CollectionService.shared.cancelCollectionRequest(collectionId: collection.id)
				} else {
					// Send request
					try await CollectionService.shared.sendCollectionRequest(collectionId: collection.id)
				}
				// Refresh collections to update button state
				await performSearch()
			} catch {
				print("Error \(hasRequested ? "cancelling" : "sending") collection request: \(error.localizedDescription)")
				// Revert the notification on error
				if let currentUserId = authService.user?.uid {
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
		// Handle Join action for Open collections
		else if collection.type == "Open" && !isMember && !isOwner {
			do {
				try await CollectionService.shared.joinCollection(collectionId: collection.id)
				// Refresh collections to update button state
				await performSearch()
			} catch {
				print("Error joining collection: \(error.localizedDescription)")
			}
		}
		// Handle Leave action for Open collections
		else if collection.type == "Open" && isMember && !isOwner {
			do {
				guard let currentUserId = authService.user?.uid else { return }
				try await CollectionService.shared.leaveCollection(collectionId: collection.id, userId: currentUserId)
				// Refresh collections to update button state
				await performSearch()
			} catch {
				print("Error leaving collection: \(error.localizedDescription)")
			}
		}
	}
	
	// MARK: - Refresh Functions (matching SearchView behavior)
	/// Refresh collections: Check for new content, reorder if none found
	@MainActor
	private func refreshCollections() async {
		// Only refresh if we have an active search
		guard !searchText.isEmpty else { return }
		let query = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return }
		
		// Store current collection IDs to check for new content
		let currentCollectionIds = Set(collections.map { $0.id })
		
		// Fetch fresh data
		await searchCollections(query: query)
		
		// Check if we have new collections
		let newCollectionIds = Set(collections.map { $0.id })
		let hasNewCollections = !newCollectionIds.subtracting(currentCollectionIds).isEmpty
		
		if !hasNewCollections && !collections.isEmpty {
			// No new collections - reorder/shuffle existing feed
			var reorderedCollections = collections
			reorderedCollections.shuffle()
			collections = reorderedCollections
		}
	}
	
	/// Refresh posts: Check for new content, reorder if none found
	@MainActor
	private func refreshPosts() async {
		// Only refresh if we have an active search
		guard !searchText.isEmpty else { return }
		let query = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return }
		
		// Store current post IDs to check for new content
		let currentPostIds = Set(posts.map { $0.id })
		
		// Fetch fresh data
		await searchPosts(query: query)
		
		// Check if we have new posts
		let newPostIds = Set(posts.map { $0.id })
		let hasNewPosts = !newPostIds.subtracting(currentPostIds).isEmpty
		
		if !hasNewPosts && !posts.isEmpty {
			// No new posts - reorder/shuffle existing feed
			var reorderedPosts = posts
			reorderedPosts.shuffle()
			posts = reorderedPosts
		}
	}
	
	/// Refresh usernames: Check for new content, reorder if none found
	@MainActor
	private func refreshUsernames() async {
		// Only refresh if we have an active search
		guard !searchText.isEmpty else { return }
		let query = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return }
		
		// Store current user IDs to check for new content
		let currentUserIds = Set(users.map { $0.id })
		
		// Fetch fresh data
		await searchUsernames(query: query)
		
		// Check if we have new users
		let newUserIds = Set(users.map { $0.id })
		let hasNewUsers = !newUserIds.subtracting(currentUserIds).isEmpty
		
		if !hasNewUsers && !users.isEmpty {
			// No new users - reorder/shuffle existing feed
			var reorderedUsers = users
			reorderedUsers.shuffle()
			users = reorderedUsers
		}
	}
}


