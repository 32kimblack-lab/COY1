import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct SearchView: View {
	@State private var searchText = ""
	@State private var selectedTab: Int = 0
	@State private var collections: [CollectionData] = []
	@State private var posts: [CollectionPost] = []
	@State private var isLoadingCollections = false
	@State private var isLoadingPosts = false
	@State private var searchTask: Task<Void, Never>?
	// Request state is managed by CollectionRequestStateManager.shared
	@State private var selectedCollection: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedUserId: String?
	@State private var showingProfile = false
	@State private var hasLoadedOnce = false // Track if data has been loaded to prevent reloading
	@State private var followStatus: [String: Bool] = [:] // Track follow status for immediate UI updates
	@State private var membershipStatus: [String: Bool] = [:] // Track membership status for immediate UI updates
	// Request state is managed by CollectionRequestStateManager.shared
	@Environment(\.colorScheme) private var colorScheme
	@EnvironmentObject var authService: AuthService

	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				VStack(spacing: 0) {
				header
				
				searchBar
					.padding(.horizontal)
					.padding(.top, 8)

				tabSwitcher
					.padding(.top, 16)
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
				// Only load initial data on first appearance to prevent reloading
				if !hasLoadedOnce {
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
			.refreshable {
				// Force refresh on pull-to-refresh
				Task {
					await performSearch(forceRefresh: true)
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
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { _ in
				// Refresh search when a user is blocked
				Task {
					await performSearch(forceRefresh: true)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
				// Refresh search when a user is unblocked
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
			// Request state is managed by CollectionRequestStateManager.shared
			// No need for notification listeners here - the manager handles it
		}
	}

	private var header: some View {
		HStack {
			Spacer()
			Text("Discover")
				.font(.system(size: 24, weight: .bold))
				.foregroundColor(.primary)
			Spacer()
			Image(systemName: "magnifyingglass")
				.font(.system(size: 20, weight: .semibold))
				.padding(.trailing, 4)
		}
		.padding(.horizontal)
		.padding(.top, 8)
	}
	
	private var searchBar: some View {
		HStack {
			Image(systemName: "magnifyingglass")
				.foregroundColor(.secondary)
			TextField("Search...", text: $searchText)
				.textFieldStyle(.plain)
				.onChange(of: searchText) { _, _ in
					// Cancel previous search task
					searchTask?.cancel()
					
					// Debounce search
					searchTask = Task {
						try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
						if !Task.isCancelled {
							await performSearch()
						}
					}
				}
			
			if !searchText.isEmpty {
				Button {
					searchText = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundColor(.secondary)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(Color(.systemGray6))
		.cornerRadius(10)
	}

	private var tabSwitcher: some View {
		VStack(spacing: 10) {
			HStack(spacing: 40) {
				tabButton(title: "Collections", index: 0)
				tabButton(title: "Post", index: 1)
				tabButton(title: "Usernames", index: 2)
			}
			.padding(.horizontal, 24)

			// Moving underline
			GeometryReader { proxy in
				let width = (proxy.size.width - 0) / 3 // 3 tabs
				let underlineFraction: CGFloat = 0.9
				ZStack(alignment: .leading) {
					Rectangle()
						.fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.15))
						.frame(height: 1)
					Rectangle()
						.fill(colorScheme == .dark ? .white : .black)
						.frame(width: width * underlineFraction, height: 3)
						.offset(x: underlineOffset(totalWidth: proxy.size.width, fraction: underlineFraction))
						.animation(.easeInOut(duration: 0.25), value: selectedTab)
				}
			}
			.frame(height: 2)
			.padding(.horizontal)
		}
	}

	private func tabButton(title: String, index: Int) -> some View {
		Button {
			withAnimation {
				selectedTab = index
			}
			// Perform search when switching tabs
			Task {
				await performSearch()
			}
		} label: {
			Text(title)
				.font(.system(size: 16, weight: selectedTab == index ? .semibold : .regular))
				.foregroundColor(selectedTab == index ? .primary : .secondary)
		}
		.buttonStyle(.plain)
	}

	private func underlineOffset(totalWidth: CGFloat, fraction: CGFloat) -> CGFloat {
		let cellWidth = totalWidth / 3
		// Center the underline (fraction of the cell width) inside each tab cell
		let inset = (cellWidth - (cellWidth * fraction)) / 2
		return CGFloat(selectedTab) * cellWidth + inset
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
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if collections.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "square.stack.3d.up")
						.font(.system(size: 48))
						.foregroundColor(.secondary)
					Text(searchText.isEmpty ? "Discover collections from other users" : "No collections found")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 16) {
						ForEach(collections) { collection in
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
									// Navigate to owner's profile
									selectedUserId = collection.ownerId
									showingProfile = true
								},
								onCollectionTapped: {
									Task {
										await handleCollectionTap(collection: collection)
									}
								}
							)
							.padding(.horizontal)
						}
					}
					.padding(.vertical)
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
					currentUserId: Auth.auth().currentUser?.uid
				)
			}
		}
	}
	
	private var usernamesContent: some View {
		VStack(spacing: 12) {
			Image(systemName: "person.crop.circle")
				.font(.system(size: 48))
				.foregroundColor(.secondary)
			Text("Search usernames to get started")
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	@MainActor
	private func performSearch(forceRefresh: Bool = false) async {
		// If we already have data, not forcing refresh, and in discover mode (empty search), skip
		// But always search if user has typed something or switched tabs
		if hasLoadedOnce && !collections.isEmpty && !forceRefresh && searchText.isEmpty && selectedTab == 0 {
			print("⏭️ SearchView: Using cached data, skipping reload")
			return
		}
		
		// For discover mode (empty search), show all public collections/posts
		// For search mode, filter by query
		let query = searchText.isEmpty ? nil : searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			// If not logged in, don't show anything
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
			// Search collections using Firebase
			isLoadingCollections = true
			do {
				let db = Firestore.firestore()
				var queryRef: Query = db.collection("collections")
				
				if let query = query, !query.isEmpty {
					// Firestore doesn't support full-text search, so we'll search by name
					// Note: This is a simple prefix search. For better search, consider using Algolia or similar
					queryRef = queryRef.whereField("name", isGreaterThanOrEqualTo: query)
						.whereField("name", isLessThanOrEqualTo: query + "\u{f8ff}")
				}
				
				// Try query with index first, fallback to query without ordering if index is missing
				var snapshot: QuerySnapshot
				var needsSorting = false
				do {
					snapshot = try await queryRef
						.whereField("isPublic", isEqualTo: true)
						.order(by: "createdAt", descending: true)
						.limit(to: 50)
						.getDocuments()
				} catch {
					// If index is missing, use fallback query without ordering
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
				
				// Sort in memory if we used fallback query
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
				
				// Sort by createdAt descending if we used fallback query (no index)
				if needsSorting {
					allCollections.sort { $0.createdAt > $1.createdAt }
				}
				
				// Filter out collections owned by, where user is a member, hidden, or already followed
				var filteredCollections = allCollections.filter { collection in
					// Exclude if user is the owner
					if collection.ownerId == currentUserId {
						return false
					}
					// Exclude if user is a member
					if collection.members.contains(currentUserId) {
						return false
					}
					// Exclude if collection is hidden
					if hiddenCollectionIds.contains(collection.id) {
						return false
					}
					// Exclude if user is already following (should appear on home, not discover)
					if collection.followers.contains(currentUserId) {
						return false
					}
					return true
				}
				
				// Filter out collections from blocked users
				// Use main filter function which includes access filtering
				filteredCollections = await CollectionService.filterCollections(filteredCollections)
				collections = filteredCollections
				
				// Initialize follow status, membership status, and request status for all collections
				for collection in collections {
					followStatus[collection.id] = collection.followers.contains(currentUserId)
					membershipStatus[collection.id] = collection.members.contains(currentUserId) || collection.owners.contains(currentUserId)
					// Check if user has a pending request by checking notifications
					// We'll update this when we check notifications
				}
				
				// Initialize shared request state manager
				await CollectionRequestStateManager.shared.initializeState()
			} catch {
				print("Error searching collections: \(error.localizedDescription)")
				collections = []
			}
			isLoadingCollections = false
			
		case 1:
			// Search posts using Firebase
			isLoadingPosts = true
			do {
				let db = Firestore.firestore()
				var queryRef: Query = db.collection("posts")
				
				if let query = query, !query.isEmpty {
					// Search by title/caption
					queryRef = queryRef.whereField("title", isGreaterThanOrEqualTo: query)
						.whereField("title", isLessThanOrEqualTo: query + "\u{f8ff}")
				}
				// If query is nil/empty, query all posts (discover mode)
				
				let snapshot = try await queryRef
					.order(by: "createdAt", descending: true)
					.limit(to: 50)
					.getDocuments()
				
				let allPosts = snapshot.documents.compactMap { doc -> CollectionPost? in
					let data = doc.data()
					
					// Parse mediaItems
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
				
				// Filter out posts created by user
				let postsNotByUser = allPosts.filter { $0.authorId != currentUserId }
				
				// Get unique collection IDs from posts
				let collectionIds = Array(Set(postsNotByUser.map { $0.collectionId }.filter { !$0.isEmpty }))
				
				// Fetch collections in parallel to check membership
				var userCollectionIds: Set<String> = []
				if !collectionIds.isEmpty {
					await withTaskGroup(of: (String, Bool).self) { group in
						for collectionId in collectionIds {
							group.addTask {
								do {
									if let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) {
										let isUserCollection = collection.ownerId == currentUserId || collection.members.contains(currentUserId)
										return (collectionId, isUserCollection)
									}
								} catch {
									// If we can't fetch, assume it's not user's collection to be safe
									print("Error fetching collection \(collectionId): \(error.localizedDescription)")
								}
								return (collectionId, false)
							}
						}
						
						for await (collectionId, isUserCollection) in group {
							if isUserCollection {
								userCollectionIds.insert(collectionId)
							}
						}
					}
				}
				
				// Filter out posts from collections user owns, is a member of, or hidden
				var filteredPosts = postsNotByUser.filter { post in
					if post.collectionId.isEmpty {
						return true
					}
					// Exclude if from user's own collections
					if userCollectionIds.contains(post.collectionId) {
						return false
					}
					// Exclude if from hidden collections
					if hiddenCollectionIds.contains(post.collectionId) {
						return false
					}
					return true
				}
				
				// Filter out posts from blocked users
				// Use main filter function which includes access filtering
				filteredPosts = await CollectionService.filterPosts(filteredPosts)
				posts = filteredPosts
			} catch {
				print("Error searching posts: \(error.localizedDescription)")
				posts = []
			}
			isLoadingPosts = false
			
		default:
			break
		}
	}
	
	@MainActor
	private func handleFollowTapped(collection: CollectionData) async {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		let isCurrentlyFollowing = followStatus[collection.id] ?? collection.followers.contains(currentUserId)
		
		// Update UI immediately for instant feedback
		followStatus[collection.id] = !isCurrentlyFollowing
		
		do {
			if isCurrentlyFollowing {
				// Unfollow
				try await CollectionService.shared.unfollowCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
			} else {
				// Follow
				try await CollectionService.shared.followCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
				// Post notification to refresh home screen
				NotificationCenter.default.post(name: NSNotification.Name("CollectionFollowed"), object: nil, userInfo: ["collectionId": collection.id])
			}
			
			// Remove followed collection from discover list immediately (no reload needed)
			if !isCurrentlyFollowing {
				collections.removeAll { $0.id == collection.id }
			} else {
				// If unfollowing, we could add it back to the list, but that's optional
				// For now, just keep it removed until manual refresh
			}
			
			// Don't reload - just update local state
			// User can manually pull-to-refresh if they want fresh data
		} catch {
			print("❌ Error following/unfollowing collection: \(error.localizedDescription)")
			// Revert UI change on error
			followStatus[collection.id] = isCurrentlyFollowing
		}
	}
	
	private func handleCollectionAction(collection: CollectionData) {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		// Check if user is member, owner, or admin
		let isMember = collection.members.contains(currentUserId)
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		// Handle Request/Unrequest toggle for Request-type collections if user is NOT a member/owner/admin
		if collection.type == "Request" && !isMember && !isOwner && !isAdmin {
			// Get current state from shared manager
			let hasRequested = CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id)
			
			// Post notification immediately for synchronization (same pattern as follow button)
			if let currentUserId = Auth.auth().currentUser?.uid {
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
			
			Task {
				do {
					if hasRequested {
						// Cancel/unrequest
						try await CollectionService.shared.cancelCollectionRequest(collectionId: collection.id)
					} else {
						// Send request
					try await CollectionService.shared.sendCollectionRequest(collectionId: collection.id)
					}
				} catch {
					print("Error \(hasRequested ? "cancelling" : "sending") collection request: \(error.localizedDescription)")
					// Revert the notification on error
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
		}
		// Handle Join action for Open collections if user is NOT a member/owner/admin
		else if collection.type == "Open" && !isMember && !isOwner && !isAdmin {
			// Update UI immediately for instant feedback
			membershipStatus[collection.id] = true
			
			Task {
				do {
					try await CollectionService.shared.joinCollection(collectionId: collection.id)
					// Collection will appear on profile via UserCollectionsUpdated notification
					// No reload needed - state already updated
				} catch {
					print("Error joining collection: \(error.localizedDescription)")
					// Revert UI change on error
					await MainActor.run {
						membershipStatus[collection.id] = false
					}
				}
			}
		}
		// Handle Leave action for Open collections if user IS a member (but not owner)
		else if collection.type == "Open" && isMember && !isOwner {
			Task {
				do {
					try await CollectionService.shared.leaveCollection(collectionId: collection.id, userId: currentUserId)
					// Update local state - no reload needed
					// User can manually pull-to-refresh if they want fresh data
				} catch {
					print("Error leaving collection: \(error.localizedDescription)")
				}
			}
		}
	}
	
	private func handleCollectionTap(collection: CollectionData) async {
		// Check if this is a private collection
		if !collection.isPublic {
			// Check if current user is owner, admin, or member
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			let isMember = collection.members.contains(currentUserId)
			let isOwner = collection.ownerId == currentUserId
			let isAdmin = collection.owners.contains(currentUserId)
			
			// ALL authorized users (owner, admin, member) need Face ID for private collections
			if isOwner || isMember || isAdmin {
				// User is owner, admin, or member - require Face ID/Touch ID
				let authManager = BiometricAuthManager()
				let success = await authManager.authenticateWithFallback(reason: "Access \(collection.name)")
				
				if success {
					await MainActor.run {
						selectedCollection = collection
						showingInsideCollection = true
					}
				}
				// If authentication fails, do nothing (user stays on current screen)
				return
			}
		}
		
		// For public collections or non-members, proceed normally
		await MainActor.run {
			selectedCollection = collection
			showingInsideCollection = true
		}
	}
	
	// Request state is now managed by CollectionRequestStateManager.shared
	// No need for initializeRequestState() - the manager handles it
}


