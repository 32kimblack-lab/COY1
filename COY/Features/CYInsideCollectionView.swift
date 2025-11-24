import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CYInsideCollectionView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var collection: CollectionData
	@State private var posts: [CollectionPost] = []
	@State private var isLoadingPosts = false
	@State private var userProfileImageURL: String?
	@State private var showPhotoPicker = false
	@State private var selectedMedia: [CreatePostMediaItem] = []
	@State private var isProcessingMedia = false
	@State private var showCustomMenu = false
	@State private var showDeleteAlert = false
	@State private var isDeleting = false
	@State private var showDeleteError = false
	@State private var deleteErrorMessage = ""
	@State private var refreshTrigger = UUID()
	
	// Navigation states
	@State private var showEditCollection = false
	@State private var showAccessView = false
	@State private var showFollowersView = false
	@State private var isFollowing: Bool = false
	@State private var hasPendingRequest: Bool = false
	@State private var selectedOwnerId: String?
	
	// Sort/Organization states
	@State private var showSortMenu = false
	@State private var sortOption: String = "Newest to Oldest"
	
	// Pin and Delete states
	@State private var pinOrder: [String: Date] = [:] // Track pin order: postId -> pinnedAt timestamp
	@State private var isProcessing = false
	@State private var postToDelete: CollectionPost?
	@State private var showPostDeleteAlert = false
	
	init(collection: CollectionData) {
		_collection = State(initialValue: collection)
	}
	
	var body: some View {
		ZStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					// Collection Header Section
					collectionHeaderSection
						.padding()
					
					// Sort Section with Privacy Lock
					sortSection
					
					// Pinterest Grid of Posts
					if isLoadingPosts {
						ProgressView()
							.padding()
					} else if posts.isEmpty {
						emptyStateView
							.padding()
					} else {
						PinterestPostGrid(
							posts: sortedPosts,
							collection: collection,
							isIndividualCollection: collection.type == "Individual",
							currentUserId: Auth.auth().currentUser?.uid
						)
					}
				}
			}
			.background(colorScheme == .dark ? Color.black : Color.white)
			
			// Sort Menu Overlay
			sortMenuOverlay
		}
		.navigationBarTitleDisplayMode(.inline)
		.navigationBarBackButtonHidden(true)
		.toolbar {
			ToolbarItem(placement: .navigationBarLeading) {
				Button(action: { dismiss() }) {
					Image(systemName: "chevron.backward")
						.foregroundColor(.primary)
				}
			}
			ToolbarItem(placement: .navigationBarTrailing) {
				Button(action: { showCustomMenu.toggle() }) {
					Image(systemName: "ellipsis")
						.foregroundColor(.primary)
				}
			}
		}
		.onAppear {
			loadCollectionData()
			loadPosts()
			setupPostListener()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUpdated"))) { notification in
			// CRITICAL FIX: Reload collection when it's updated (edit, access changes, etc.)
			if let collectionId = notification.object as? String, collectionId == collection.id {
				print("🔄 CYInsideCollectionView: Collection updated, reloading collection data")
				loadCollectionData()
				refreshTrigger = UUID()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostCreated"))) { notification in
			if let collectionId = notification.object as? String, collectionId == collection.id {
				loadPosts()
			}
		}
		.sheet(isPresented: $showPhotoPicker) {
			CustomPhotoPickerView(
				selectedMedia: $selectedMedia,
				maxSelectionCount: 5,
				isProcessingMedia: $isProcessingMedia
			)
		}
		.sheet(isPresented: Binding(
			get: { !selectedMedia.isEmpty && !showPhotoPicker },
			set: { newValue in
				if !newValue {
					selectedMedia = []
				}
			}
		)) {
			CYCreatePost(
				selectedMedia: $selectedMedia,
				collectionId: collection.id,
				isProcessingMedia: $isProcessingMedia,
				onPost: { _ in
					selectedMedia = []
					loadPosts()
				},
				isFromCamera: false
			)
		}
		.confirmationDialog("Collection Options", isPresented: $showCustomMenu, titleVisibility: .hidden) {
			// Owner and Admins can edit collection
			if isCollectionOwnerOrAdmin() {
				Button("Edit Collection") {
					showEditCollection = true
				}
				Button("Access") {
					showAccessView = true
				}
				Button("Followers") {
					showFollowersView = true
				}
			} else if !isCurrentUserOwnerOrMember {
				Button("Report Collection", role: .destructive) { }
			}
			Button("Cancel", role: .cancel) {}
		}
		.sheet(isPresented: $showEditCollection) {
			CYEditCollectionView(collection: collection) {
				// Reload collection data after save
				loadCollectionData()
			}
			.environmentObject(authService)
		}
		.sheet(isPresented: $showAccessView) {
			CYAccessView(collection: collection)
				.environmentObject(authService)
		}
		.alert("Delete Collection", isPresented: $showDeleteAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Delete", role: .destructive) {
				deleteCollection()
			}
		} message: {
			Text("Are you sure you want to delete this collection? This action cannot be undone.")
		}
		.alert("Delete Post", isPresented: $showPostDeleteAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Delete", role: .destructive) {
				if let post = postToDelete {
					Task {
						await deletePost(post: post)
					}
				}
			}
		} message: {
			Text("Are you sure you want to delete this post? This action cannot be undone.")
		}
		.alert("Error Deleting Collection", isPresented: $showDeleteError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(deleteErrorMessage.isEmpty ? "Failed to delete collection. Please try again." : deleteErrorMessage)
		}
	}
	
		// MARK: - Collection Header Section
	private var collectionHeaderSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Collection Image and Name
			HStack(spacing: 12) {
				// Collection Image - Clickable to navigate to owner's profile
				NavigationLink(destination: ViewerProfileView(userId: collection.ownerId).environmentObject(authService)) {
					if let imageURL = collection.imageURL, !imageURL.isEmpty {
						CachedProfileImageView(url: imageURL, size: 60)
					} else if let userImageURL = userProfileImageURL, !userImageURL.isEmpty {
						CachedProfileImageView(url: userImageURL, size: 60)
					} else {
						DefaultProfileImageView(size: 60)
					}
				}
				.buttonStyle(.plain)
				
				// Collection Name and Info
				VStack(alignment: .leading, spacing: 4) {
					Text(collection.name)
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(.primary)
					
					HStack(spacing: 4) {
						Text(collection.type == "Individual" ? "Individual" : "\(collection.memberCount) members")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
				}
				
				Spacer()
			}
			
			// Description
			if !collection.description.isEmpty {
				Text(collection.description)
					.font(.subheadline)
					.foregroundColor(.primary)
			}
			
			// Action Buttons
			HStack(spacing: 10) {
				if isCurrentUserOwner || isCurrentUserMember {
					Button(action: { showPhotoPicker = true }) {
						Text("Post")
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(.primary)
							.frame(minWidth: 80) // Ensure consistent minimum width
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.gray.opacity(0.2))
							.cornerRadius(8)
					}
				} else {
					Button(action: {
						Task { await handleFollowAction() }
					}) {
						Text(isFollowing ? "Following" : "Follow")
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(.primary)
							.frame(minWidth: 80) // Ensure consistent minimum width
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.gray.opacity(0.2))
							.cornerRadius(8)
					}
				}
				
				// Delete button for owners
				if isCurrentUserOwner {
					Button(action: {
						showDeleteAlert = true
					}) {
						Text(isDeleting ? "Deleting..." : "Delete")
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(.red)
							.frame(minWidth: 80) // Ensure consistent minimum width
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.red.opacity(0.1))
							.cornerRadius(8)
							.overlay(
								RoundedRectangle(cornerRadius: 8)
									.stroke(Color.red, lineWidth: 1)
							)
					}
					.disabled(isDeleting)
				} else if isCurrentUserMember {
					// Leave button for members (but not owners)
					Button(action: {
						Task { await handleLeaveCollection() }
					}) {
						Text("Leave")
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(.red)
							.frame(minWidth: 80) // Ensure consistent minimum width
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.red.opacity(0.1))
							.cornerRadius(8)
							.overlay(
								RoundedRectangle(cornerRadius: 8)
									.stroke(Color.red, lineWidth: 1)
							)
					}
				} else if shouldShowActionButton() {
					// Request/Join button for non-members
					Button(action: {
						Task { await handleCollectionAction() }
					}) {
						Text(getActionButtonText())
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(getActionButtonTextColor())
							.frame(minWidth: 80) // Ensure consistent minimum width
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(getActionButtonBackground())
							.cornerRadius(8)
							.overlay(
								RoundedRectangle(cornerRadius: 8)
									.stroke(getActionButtonBorderColor(), lineWidth: 1)
							)
					}
				}
			}
		}
	}
	
	// MARK: - Sort Section with Privacy Lock
	@ViewBuilder
	private var sortSection: some View {
		HStack {
			Spacer()
			HStack(spacing: 8) {
				// Privacy Lock Icon - Only show for private collections
				if !collection.isPublic {
					Image(systemName: "lock.fill")
						.font(.system(size: 16, weight: .medium))
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.padding(8)
						.background(
							Circle()
								.fill(Color.gray.opacity(0.1))
						)
				}
				
				// Organization/Sort Button
				Button(action: { 
					withAnimation {
						showSortMenu.toggle()
					}
				}) {
					Image(systemName: "line.3.horizontal")
						.font(.system(size: 16, weight: .medium))
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.padding(8)
						.background(
							Circle()
								.fill(Color.gray.opacity(0.1))
						)
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}
	
	// MARK: - Sort Menu Overlay
	@ViewBuilder
	private var sortMenuOverlay: some View {
		if showSortMenu {
			ZStack(alignment: .topTrailing) {
				// Background tap to dismiss
				Color.black.opacity(0.01)
					.ignoresSafeArea()
					.onTapGesture {
						withAnimation {
							showSortMenu = false
						}
					}
				
				// Sort Menu
				VStack(alignment: .leading, spacing: 0) {
					// Newest to Oldest
					Button(action: {
						updateSortOption("Newest to Oldest")
						withAnimation {
							showSortMenu = false
						}
					}) {
						HStack {
							Text("Newest to Oldest")
								.font(.system(size: 14))
								.foregroundColor(sortOption == "Newest to Oldest" ? .blue : (colorScheme == .dark ? .white : .black))
							Spacer()
							if sortOption == "Newest to Oldest" {
								Image(systemName: "checkmark")
									.font(.system(size: 12))
									.foregroundColor(.blue)
							}
						}
						.padding(.horizontal, 12)
						.padding(.vertical, 8)
					}
					
					Divider()
					
					// Oldest to Newest
					Button(action: {
						updateSortOption("Oldest to Newest")
						withAnimation {
							showSortMenu = false
						}
					}) {
						HStack {
							Text("Oldest to Newest")
								.font(.system(size: 14))
								.foregroundColor(sortOption == "Oldest to Newest" ? .blue : (colorScheme == .dark ? .white : .black))
							Spacer()
							if sortOption == "Oldest to Newest" {
								Image(systemName: "checkmark")
									.font(.system(size: 12))
									.foregroundColor(.blue)
							}
						}
						.padding(.horizontal, 12)
						.padding(.vertical, 8)
					}
					
					// Alphabetical - Only show for non-Individual collections
					if collection.type != "Individual" {
						Divider()
						
						Button(action: {
							updateSortOption("Alphabetical")
							withAnimation {
								showSortMenu = false
							}
						}) {
							HStack {
								Text("Alphabetical")
									.font(.system(size: 14))
									.foregroundColor(sortOption == "Alphabetical" ? .blue : (colorScheme == .dark ? .white : .black))
								Spacer()
								if sortOption == "Alphabetical" {
									Image(systemName: "checkmark")
										.font(.system(size: 12))
										.foregroundColor(.blue)
								}
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 8)
						}
					}
				}
				.frame(maxWidth: 180)
				.background(
					RoundedRectangle(cornerRadius: 10)
						.fill(colorScheme == .dark ? Color(.systemGray6) : Color.white)
						.shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
				)
				.padding(.top, 60)
				.padding(.trailing, 16)
			}
		}
	}
	
	// MARK: - Sort Option Update
	private func updateSortOption(_ newOption: String) {
		sortOption = newOption
		// Post notification for other views that might need to know about sort changes
		NotificationCenter.default.post(
			name: NSNotification.Name("CollectionSortOptionChanged"),
			object: collection.id,
			userInfo: ["sortOption": newOption]
		)
	}
	
	// MARK: - Empty State
	private var emptyStateView: some View {
		VStack(spacing: 16) {
			Image(systemName: "photo.on.rectangle")
				.font(.system(size: 50))
				.foregroundColor(.gray)
			Text("No posts yet")
				.font(.headline)
				.foregroundColor(.secondary)
			if isCurrentUserOwner || isCurrentUserMember {
				Button(action: { showPhotoPicker = true }) {
					Text("Create First Post")
						.font(.subheadline)
						.foregroundColor(.blue)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 40)
	}
	
	// MARK: - Computed Properties
	private var isCurrentUserOwner: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		// Only the original creator is the Owner
		return collection.ownerId == currentUserId
	}
	
	private var isCurrentUserAdmin: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		// Check if user is in the owners array (admins are stored in owners)
		return collection.owners.contains(currentUserId) && collection.ownerId != currentUserId
	}
	
	// Check if user is owner or admin (can pin/delete any post, edit collection)
	private func isCollectionOwnerOrAdmin() -> Bool {
		return isCurrentUserOwner || isCurrentUserAdmin
	}
	
	// Check if user is the post owner
	private func isPostOwner(post: CollectionPost) -> Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return post.authorId == currentUserId
	}
	
	// Sorted posts with pinned posts at top
	private var sortedPosts: [CollectionPost] {
		// Separate pinned and unpinned posts
		let pinnedPosts = posts.filter { $0.isPinned }
		let unpinnedPosts = posts.filter { !$0.isPinned }
		
		// Sort unpinned posts based on sort option
		let sortedUnpinned: [CollectionPost]
		switch sortOption {
		case "Newest to Oldest":
			sortedUnpinned = unpinnedPosts.sorted { $0.createdAt > $1.createdAt }
		case "Oldest to Newest":
			sortedUnpinned = unpinnedPosts.sorted { $0.createdAt < $1.createdAt }
		case "Alphabetical":
			// Alphabetical sorting only available for Invite, Request, and Open collections
			// Sort by caption (if available), otherwise by title
			if collection.type != "Individual" {
				sortedUnpinned = unpinnedPosts.sorted { post1, post2 in
					let name1: String = {
						if let caption = post1.caption, !caption.isEmpty {
							return caption
						}
						return post1.title
					}()
					let name2: String = {
						if let caption = post2.caption, !caption.isEmpty {
							return caption
						}
						return post2.title
					}()
					return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
				}
			} else {
				// Fallback for Individual collections
				sortedUnpinned = unpinnedPosts.sorted { $0.createdAt > $1.createdAt }
			}
		default:
			sortedUnpinned = unpinnedPosts.sorted { $0.createdAt > $1.createdAt }
		}
		
		// Sort pinned posts by most recently pinned first
		// Use pinOrder tracking (when available) for accurate ordering
		let sortedPinned = pinnedPosts.sorted { post1, post2 in
			let date1 = pinOrder[post1.id] ?? post1.createdAt
			let date2 = pinOrder[post2.id] ?? post2.createdAt
			return date1 > date2 // Most recently pinned first
		}
		
		// Return pinned posts first, then sorted unpinned posts
		return sortedPinned + sortedUnpinned
	}
	
	private var isCurrentUserMember: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.members.contains(currentUserId)
	}
	
	private var isCurrentUserOriginalCreator: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId
	}
	
	private var isCurrentUserOwnerOrMember: Bool {
		return isCurrentUserOwner || isCurrentUserMember
	}
	
	private func shouldShowActionButton() -> Bool {
		// Only show Request/Join button for non-members (owners and members have their own buttons)
		if isCurrentUserOwner || isCurrentUserMember {
			return false
		}
		// Show for Request/Open types if user is not a member
		return collection.type == "Request" || collection.type == "Open"
	}
	
	private func getActionButtonText() -> String {
		// Owner should see "Delete"
		if isCurrentUserOwner {
			return "Delete"
		}
		// Member (but not owner) should see "Leave"
		if isCurrentUserMember {
			return "Leave"
		}
		// Not a member - show Request or Join based on collection type
		switch collection.type {
		case "Request":
			return hasPendingRequest ? "Requested" : "Request"
		case "Open":
			return "Join"
		default:
			return ""
		}
	}
	
	private func getActionButtonTextColor() -> Color {
		if isCurrentUserOwner {
			return .red
		}
		if collection.type == "Request" && hasPendingRequest {
			return .blue
		}
		return .primary
	}
	
	private func getActionButtonBackground() -> Color {
		if isCurrentUserOwner {
			return .red.opacity(0.1)
		}
		if collection.type == "Request" && hasPendingRequest {
			return Color.blue.opacity(0.1)
		}
		return Color.gray.opacity(0.2)
	}
	
	private func getActionButtonBorderColor() -> Color {
		if isCurrentUserOwner {
			return .red
		}
		if collection.type == "Request" && hasPendingRequest {
			return .blue
		}
		return .clear
	}
	
	// MARK: - Functions
	private func loadCollectionData() {
		Task {
			// Load owner profile image
			do {
				if let ownerUser = try await UserService.shared.getUser(userId: collection.ownerId) {
					await MainActor.run {
						userProfileImageURL = ownerUser.profileImageURL
					}
				}
			} catch {
				print("Error loading owner profile: \(error)")
			}
			
			// Reload collection to get latest data
			do {
				if let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) {
					await MainActor.run {
						collection = updatedCollection
					}
				}
			} catch {
				print("Error reloading collection: \(error)")
			}
		}
	}
	
	private func loadPosts() {
		isLoadingPosts = true
		Task {
			do {
				// Fetch directly from Firebase (source of truth)
				let firebasePosts = try await fetchPostsFromFirebase()
				await MainActor.run {
					posts = firebasePosts
					
					// Initialize pin order for already-pinned posts
					for post in posts where post.isPinned {
						if self.pinOrder[post.id] == nil {
							self.pinOrder[post.id] = post.createdAt
						}
					}
					
					isLoadingPosts = false
				}
			} catch {
				await MainActor.run {
					posts = []
					isLoadingPosts = false
				}
			}
		}
	}
	
	// Fetch posts directly from Firebase (source of truth)
	private func fetchPostsFromFirebase() async throws -> [CollectionPost] {
				let db = Firestore.firestore()
				// Query without orderBy to avoid index requirement, then sort in memory
				let snapshot = try await db.collection("posts")
					.whereField("collectionId", isEqualTo: collection.id)
					.getDocuments()
				
				let loadedPosts = snapshot.documents.compactMap { doc -> CollectionPost? in
					let data = doc.data()
					
					// Parse all mediaItems
					var allMediaItems: [MediaItem] = []
					
					// First, try to get all mediaItems array
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
					
					// Fallback to firstMediaItem if mediaItems array is empty
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
					let caption = data["caption"] as? String
					
					let titleValue: String = {
						if let title = data["title"] as? String, !title.isEmpty {
							return title
						}
						return caption ?? ""
					}()
					let collectionIdValue = data["collectionId"] as? String ?? ""
					let authorIdValue = data["authorId"] as? String ?? ""
					let authorNameValue = data["authorName"] as? String ?? ""
					
					return CollectionPost(
						id: doc.documentID,
						title: titleValue,
						collectionId: collectionIdValue,
						authorId: authorIdValue,
						authorName: authorNameValue,
						createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
						firstMediaItem: firstMediaItem,
						mediaItems: allMediaItems,
						isPinned: isPinned,
						caption: caption
					)
				}
				// Sort by createdAt descending (newest first)
		return loadedPosts.sorted { $0.createdAt > $1.createdAt }
	}
	
	private func handleFollowAction() async {
		// TODO: Implement follow/unfollow
		await MainActor.run {
			isFollowing.toggle()
		}
	}
	
	private func handleCollectionAction() async {
		// TODO: Implement request/join/leave
	}
	
	private func deleteCollection() {
		isDeleting = true
		Task {
			do {
				print("🗑️ CYInsideCollectionView: Starting collection deletion...")
				try await CollectionService.shared.softDeleteCollection(collectionId: collection.id)
				print("✅ CYInsideCollectionView: Collection deleted successfully")
				
				await MainActor.run {
					isDeleting = false
					// Dismiss the view after successful deletion
					dismiss()
				}
			} catch {
				print("❌ CYInsideCollectionView: Error deleting collection: \(error)")
				await MainActor.run {
					isDeleting = false
					deleteErrorMessage = error.localizedDescription
					showDeleteError = true
				}
			}
		}
	}
	
	private func handleLeaveCollection() async {
		guard let currentUserId = authService.user?.uid else { return }
		do {
			// Leave the collection
			try await CollectionService.shared.leaveCollection(
				collectionId: collection.id,
				userId: currentUserId
			)
			print("✅ CYInsideCollectionView: User left collection successfully")
			
			// Dismiss the view after leaving (user is no longer a member)
			await MainActor.run {
				dismiss()
			}
		} catch {
			print("❌ CYInsideCollectionView: Error leaving collection: \(error)")
			// Show error alert
			await MainActor.run {
				deleteErrorMessage = error.localizedDescription
				showDeleteError = true
			}
		}
	}
	
	// MARK: - Pin and Delete Functions
	private func togglePin(post: CollectionPost) async {
		// Only owners/admins can pin/unpin posts (any post), members cannot pin
		guard isCollectionOwnerOrAdmin() else { return }
		
		// If trying to pin, check if we already have 4 pinned posts
		if !post.isPinned {
			let pinnedCount = posts.filter { $0.isPinned }.count
			if pinnedCount >= 4 {
				await MainActor.run {
					// Show alert that max 4 posts can be pinned
					let alert = UIAlertController(
						title: "Pin Limit Reached",
						message: "You can only pin up to 4 posts. Please unpin another post first.",
						preferredStyle: .alert
					)
					alert.addAction(UIAlertAction(title: "OK", style: .default))
					if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
					   let rootViewController = windowScene.windows.first?.rootViewController {
						rootViewController.present(alert, animated: true)
					}
				}
				return
			}
		}
		
		isProcessing = true
		do {
			try await CollectionService.shared.togglePostPin(postId: post.id, isPinned: !post.isPinned)
			print("✅ Post pin toggled successfully")
			
			// Update pin order tracking
			await MainActor.run {
				if !post.isPinned {
					// Post is being pinned - record current time as pin order
					self.pinOrder[post.id] = Date()
				} else {
					// Post is being unpinned - remove from pin order
					self.pinOrder.removeValue(forKey: post.id)
				}
				
				// Reload posts to get updated pin status
				loadPosts()
				
				// Post notification to refresh the collection view
				NotificationCenter.default.post(name: NSNotification.Name("CollectionUpdated"), object: post.collectionId)
			}
		} catch {
			print("❌ Error toggling post pin: \(error)")
		}
		isProcessing = false
	}
	
	private func deletePost(post: CollectionPost) async {
		// Owners/admins can delete any post, members can only delete their own posts
		guard isCollectionOwnerOrAdmin() || isPostOwner(post: post) else { return }
		isProcessing = true
		do {
			try await CollectionService.shared.deletePost(postId: post.id)
			print("✅ Post deleted successfully")
			
			// Remove from pin order if it was pinned
			await MainActor.run {
				self.pinOrder.removeValue(forKey: post.id)
				
				// Reload posts
				loadPosts()
				
				// Post notification to refresh the collection view
				NotificationCenter.default.post(name: NSNotification.Name("CollectionUpdated"), object: post.collectionId)
			}
		} catch {
			print("❌ Error deleting post: \(error)")
		}
		isProcessing = false
	}
	
	// MARK: - Real-time Post Listener
	private func setupPostListener() {
		let db = Firestore.firestore()
		db.collection("posts")
			.whereField("collectionId", isEqualTo: collection.id)
			.addSnapshotListener { [self] snapshot, error in
				if let error = error {
					print("❌ Post listener error: \(error.localizedDescription)")
					return
				}
				
				guard let documents = snapshot?.documents else { return }
				
				let loadedPosts = documents.compactMap { doc -> CollectionPost? in
					let data = doc.data()
					
					// Parse all mediaItems
					var allMediaItems: [MediaItem] = []
					
					// First, try to get all mediaItems array
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
					
					// Fallback to firstMediaItem if mediaItems array is empty
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
					let caption = data["caption"] as? String
					
					let titleValue: String = {
						if let title = data["title"] as? String, !title.isEmpty {
							return title
						}
						return caption ?? ""
					}()
					let collectionIdValue = data["collectionId"] as? String ?? ""
					let authorIdValue = data["authorId"] as? String ?? ""
					let authorNameValue = data["authorName"] as? String ?? ""
					
					return CollectionPost(
						id: doc.documentID,
						title: titleValue,
						collectionId: collectionIdValue,
						authorId: authorIdValue,
						authorName: authorNameValue,
						createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
						firstMediaItem: firstMediaItem,
						mediaItems: allMediaItems,
						isPinned: isPinned,
						caption: caption
					)
				}
				.sorted { $0.createdAt > $1.createdAt }
				
				Task { @MainActor in
					posts = loadedPosts
					isLoadingPosts = false
					print("✅ Real-time update: Loaded \(loadedPosts.count) posts")
				}
			}
	}
}

