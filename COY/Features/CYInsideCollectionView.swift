import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

struct CYInsideCollectionView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var collection: CollectionData
	@State private var posts: [CollectionPost] = []
	@State private var isLoadingPosts = false
	@State private var isLoadingMorePosts = false
	@State private var hasMorePosts = true
	@State private var lastPostDocument: DocumentSnapshot?
	@State private var postListener: ListenerRegistration?
	@State private var userProfileImageURL: String?
	@State private var showPhotoPicker = false
	@State private var selectedMedia: [CreatePostMediaItem] = []
	@State private var isProcessingMedia = false
	@State private var isNavigatingToCreatePost = false // Prevent duplicate navigation
	@State private var showCustomMenu = false
	@State private var showDeleteAlert = false
	@State private var isDeleting = false
	@State private var showDeleteError = false
	@State private var deleteErrorMessage = ""
	@State private var refreshTrigger = UUID()
	@State private var ownerProfileListener: ListenerRegistration? // Real-time listener for owner's profile
	@StateObject private var cyServiceManager = CYServiceManager.shared // Observe ServiceManager for real-time updates
	@StateObject private var adManager = AdManager.shared
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	
	// Check if device is iPad
	private var isIPad: Bool {
		horizontalSizeClass == .regular
	}
	
	// Navigation states
	@State private var showEditCollection = false
	@State private var showAccessView = false
	@State private var showFollowersView = false
	@State private var showMembersView = false
	@State private var isFollowing: Bool = false
	// Request state is managed by CollectionRequestStateManager.shared - observe it for automatic updates
	@StateObject private var requestStateManager = CollectionRequestStateManager.shared
	@State private var selectedOwnerId: String?
	
	// Sort/Organization states
	@State private var showSortMenu = false
	@State private var sortOption: String = "Newest to Oldest"
	
	// Pin and Delete states
	@State private var pinOrder: [String: Date] = [:] // Track pin order: postId -> pinnedAt timestamp
	@State private var isProcessing = false
	@State private var postToDelete: CollectionPost?
	@State private var showPostDeleteAlert = false
	
	// Local cache for collection posts (keyed by collection ID)
	// Note: This is separate from the global CollectionPostsCache in CollectionRowDesign.swift
	private class LocalCollectionPostsCache {
		static let shared = LocalCollectionPostsCache()
		private init() {}
		
		private var cache: [String: [CollectionPost]] = [:]
		private var hasData: [String: Bool] = [:]
		
		func getCachedPosts(for collectionId: String) -> [CollectionPost]? {
			return hasData[collectionId] == true ? cache[collectionId] : nil
		}
		
		func setCachedPosts(_ posts: [CollectionPost], for collectionId: String) {
			cache[collectionId] = posts
			hasData[collectionId] = true
		}
		
		func hasDataLoaded(for collectionId: String) -> Bool {
			return hasData[collectionId] == true
		}
		
		func clearCache(for collectionId: String) {
			cache.removeValue(forKey: collectionId)
			hasData.removeValue(forKey: collectionId)
		}
	}
	
	init(collection: CollectionData) {
		_collection = State(initialValue: collection)
	}
	
	var body: some View {
		PhoneSizeContainer {
			mainContentView
		}
			.navigationBarTitleDisplayMode(.inline)
			.navigationBarBackButtonHidden(true)
			.toolbar {
				toolbarContent
			}
			.navigationDestination(isPresented: $showMembersView) {
				CollectionMembersView(collection: collection)
					.environmentObject(authService)
			}
			.refreshable {
				// Complete refresh: Clear all caches and force fresh reload
				await completeRefresh()
			}
			.onAppear {
			handleOnAppear()
			}
			.onDisappear {
				// Clean up listener when view disappears
				postListener?.remove()
				postListener = nil
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
				// Refresh request state when app comes to foreground
				Task {
					await CollectionRequestStateManager.shared.initializeState()
				}
			}
			.onChange(of: collection.id) { oldId, newId in
				// When collection changes, state is already managed by CollectionRequestStateManager
				// No action needed - the manager handles all collections
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUpdated"))) { notification in
				handleCollectionUpdated(notification)
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionFollowed"))) { notification in
				if let collectionId = notification.object as? String,
				   collectionId == collection.id,
				   let userId = notification.userInfo?["userId"] as? String,
				   userId == authService.user?.uid {
					Task {
						await updateFollowState()
						loadCollectionData()
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnfollowed"))) { notification in
				if let collectionId = notification.object as? String,
				   collectionId == collection.id,
				   let userId = notification.userInfo?["userId"] as? String,
				   userId == authService.user?.uid {
					Task {
						await updateFollowState()
						loadCollectionData()
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionJoined"))) { _ in
				// Reload collection data when user joins
				loadCollectionData()
			}
			// Request state is managed by CollectionRequestStateManager.shared
			// No need for notification listeners here - the manager handles it
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostCreated"))) { notification in
				handlePostCreated(notification)
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { _ in
				// Refresh posts when a user is blocked
				loadPosts()
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
				// Refresh posts when a user is unblocked
				loadPosts()
			}
			.onChange(of: cyServiceManager.currentUser) { oldValue, newValue in
				// Real-time update when current user's profile changes via ServiceManager
				// Only update if profile-relevant fields actually changed (prevent infinite loops)
				guard collection.ownerId == Auth.auth().currentUser?.uid, let cyUser = newValue else { return }
				
				let profileChanged = oldValue?.profileImageURL != cyUser.profileImageURL ||
				oldValue?.backgroundImageURL != cyUser.backgroundImageURL ||
				oldValue?.name != cyUser.name ||
				oldValue?.username != cyUser.username
				
				if profileChanged {
					// Immediately update owner profile image from ServiceManager
					userProfileImageURL = cyUser.profileImageURL
					print("✅ CYInsideCollectionView: Updated owner profile image from ServiceManager")
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("ProfileUpdated"))) { notification in
				// Update owner profile image when profile is updated (for both current user and other users)
				if let userId = notification.userInfo?["userId"] as? String,
				   userId == collection.ownerId {
					// If it's the current user, update immediately from ServiceManager
					if userId == Auth.auth().currentUser?.uid, let cyUser = cyServiceManager.currentUser {
						userProfileImageURL = cyUser.profileImageURL
						print("✅ CYInsideCollectionView: Updated owner profile image from ServiceManager (ProfileUpdated)")
					} else {
						// For other users, reload from Firebase
						Task {
							do {
								if let ownerUser = try await UserService.shared.getUser(userId: collection.ownerId) {
									await MainActor.run {
										userProfileImageURL = ownerUser.profileImageURL
										print("✅ CYInsideCollectionView: Updated owner profile image from Firebase (ProfileUpdated)")
									}
								}
							} catch {
								print("❌ CYInsideCollectionView: Error loading owner profile image: \(error.localizedDescription)")
							}
						}
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("OwnerProfileImageUpdated"))) { notification in
				// Update owner profile image when real-time Firestore listener detects changes (for other users)
				if let collectionId = notification.object as? String,
				   collectionId == collection.id,
				   let ownerId = notification.userInfo?["ownerId"] as? String,
				   ownerId == collection.ownerId,
				   let newProfileImageURL = notification.userInfo?["profileImageURL"] as? String {
					userProfileImageURL = newProfileImageURL
					print("✅ CYInsideCollectionView: Updated owner profile image from real-time listener")
				}
			}
			.sheet(isPresented: $showPhotoPicker) {
				photoPickerSheet
			}
			.sheet(isPresented: createPostBinding) {
				createPostSheet
					.onAppear {
						// Reset navigation flag when sheet appears
						isNavigatingToCreatePost = false
					}
			}
			.sheet(isPresented: $showCustomMenu) {
				collectionOptionsSheet
			}
			.sheet(isPresented: $showEditCollection) {
				editCollectionSheet
			}
			.sheet(isPresented: $showAccessView) {
				accessViewSheet
			}
			.sheet(isPresented: $showFollowersView) {
				followersViewSheet
			}
			.alert("Delete Collection", isPresented: $showDeleteAlert) {
				deleteCollectionAlert
			} message: {
				Text("Are you sure you want to delete this collection? This action cannot be undone.")
			}
			.alert("Delete Post", isPresented: $showPostDeleteAlert) {
				deletePostAlert
			} message: {
				Text("Are you sure you want to delete this post? This action cannot be undone.")
			}
			.alert("Error Deleting Collection", isPresented: $showDeleteError) {
				Button("OK", role: .cancel) { }
			} message: {
				Text(deleteErrorMessage.isEmpty ? "Failed to delete collection. Please try again." : deleteErrorMessage)
			}
			.onDisappear {
				// Clean up listener when view disappears
				ownerProfileListener?.remove()
				ownerProfileListener = nil
			}
		}
	
	// MARK: - View Components
	private var mainContentView: some View {
		ZStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					collectionHeaderSection
						.padding()
					
					sortSection
					
					if isLoadingPosts {
						ProgressView()
							.padding()
					} else if posts.isEmpty {
						emptyStateView
							.padding()
					} else {
					// Check if viewing own profile - hide ads if so
					let isOwnProfile = collection.ownerId == Auth.auth().currentUser?.uid
					
					PinterestPostGrid(
						posts: sortedPosts,
						collection: collection,
						isIndividualCollection: collection.type == "Individual",
						currentUserId: Auth.auth().currentUser?.uid,
						showAds: !isOwnProfile, // Hide ads on own profile
						adLocation: .insideCollection, // Use inside collection ad unit
						roundedCorners: true, // Show rounded corners in inside collection view
						onPinPost: { post in
							Task {
								await handlePinPost(post)
							}
						},
						onDeletePost: { post in
							postToDelete = post
							showPostDeleteAlert = true
						}
					)
					
					// Loading indicator at bottom when loading more
					if isLoadingMorePosts {
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
							if hasMorePosts && !isLoadingMorePosts {
								loadMorePosts()
							}
						}
					}
				}
			}
			.coordinateSpace(name: "scroll")
			.background(colorScheme == .dark ? Color.black : Color.white)
			.onChange(of: sortOption) { oldValue, newValue in
				// Reload posts with new sort option
				if oldValue != newValue {
					loadInitialPosts()
				}
			}
			
			sortMenuOverlay
		}
	}
	
	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
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
	
	private var photoPickerSheet: some View {
		CustomPhotoPickerView(
			selectedMedia: $selectedMedia,
			maxSelectionCount: 5,
			isProcessingMedia: $isProcessingMedia
		)
	}
	
	private var createPostBinding: Binding<Bool> {
		Binding(
			get: { 
				// Only show if we have media, photo picker is dismissed, and we're not already navigating
				!selectedMedia.isEmpty && !showPhotoPicker && !isNavigatingToCreatePost
			},
			set: { newValue in
				if !newValue {
					selectedMedia = []
					isNavigatingToCreatePost = false
				} else {
					// Mark as navigating to prevent duplicate triggers
					isNavigatingToCreatePost = true
				}
			}
		)
	}
	
	private var createPostSheet: some View {
		CYCreatePost(
			selectedMedia: $selectedMedia,
			collectionId: collection.id,
			isProcessingMedia: $isProcessingMedia,
			onPost: { _ in
				selectedMedia = []
				isNavigatingToCreatePost = false
				loadPosts()
			},
			isFromCamera: false
		)
		.onDisappear {
			// Reset navigation flag when sheet is dismissed
			isNavigatingToCreatePost = false
		}
	}
	
	private var editCollectionSheet: some View {
		CYEditCollectionView(collection: collection)
			.environmentObject(authService)
			.onDisappear {
				loadCollectionData()
			}
	}
	
	private var accessViewSheet: some View {
		CYAccessView(collection: collection)
			.environmentObject(authService)
	}
	
	private var followersViewSheet: some View {
		CYFollowersView(collection: collection)
			.environmentObject(authService)
	}
	
	// MARK: - Collection Options Sheet (Bottom Sheet for iPad/Tablet)
	private var collectionOptionsSheet: some View {
		VStack(spacing: 0) {
			// Handle bar
			RoundedRectangle(cornerRadius: 3)
				.fill(Color.gray.opacity(0.3))
				.frame(width: 40, height: 5)
				.padding(.top, 8)
				.padding(.bottom, 16)
			
			// Title
			Text("Collection Options")
				.font(.system(size: isIPad ? 20 : 18, weight: .bold))
				.foregroundColor(colorScheme == .dark ? .white : .black)
				.padding(.bottom, 20)
			
			// Options
			VStack(spacing: 0) {
				if isCollectionOwnerOrAdmin() {
					collectionOptionButton(title: "Edit Collection", icon: "pencil") {
						showCustomMenu = false
						showEditCollection = true
					}
					
					Divider()
						.padding(.horizontal)
					
					collectionOptionButton(title: "Access", icon: "person.2") {
						showCustomMenu = false
						showAccessView = true
					}
					
					Divider()
						.padding(.horizontal)
					
					collectionOptionButton(title: "Followers", icon: "heart") {
						showCustomMenu = false
						showFollowersView = true
					}
				} else if !isCurrentUserOwnerOrMember {
					collectionOptionButton(title: "Hide Collection", icon: "eye.slash") {
						showCustomMenu = false
						hideCollection()
					}
					
					Divider()
						.padding(.horizontal)
					
					collectionOptionButton(title: "Report Collection", icon: "exclamationmark.triangle", isDestructive: true) {
						showCustomMenu = false
						// TODO: Implement report collection
					}
				}
			}
			.padding(.horizontal)
			
			Spacer()
				.frame(height: 20)
			
			// Cancel button
			Button(action: {
				showCustomMenu = false
			}) {
				Text("Cancel")
					.font(.system(size: isIPad ? 18 : 16, weight: .medium))
					.foregroundColor(.blue)
					.frame(maxWidth: .infinity)
					.padding(.vertical, isIPad ? 16 : 14)
					.background(Color.gray.opacity(0.1))
					.cornerRadius(12)
			}
			.padding(.horizontal)
			.padding(.bottom, isIPad ? 40 : 20)
		}
		.presentationDetents([.height(isIPad ? 400 : 350)])
		.presentationDragIndicator(.visible)
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
	
	private func collectionOptionButton(title: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 16) {
				Image(systemName: icon)
					.font(.system(size: isIPad ? 20 : 18))
					.foregroundColor(isDestructive ? .red : (colorScheme == .dark ? .white : .black))
					.frame(width: isIPad ? 30 : 28)
				
				Text(title)
					.font(.system(size: isIPad ? 18 : 16))
					.foregroundColor(isDestructive ? .red : (colorScheme == .dark ? .white : .black))
				
				Spacer()
			}
			.padding(.horizontal)
			.padding(.vertical, isIPad ? 18 : 16)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
	
	@ViewBuilder
	private var deleteCollectionAlert: some View {
		Button("Cancel", role: .cancel) { }
		Button("Delete", role: .destructive) {
			deleteCollection()
		}
	}
	
	@ViewBuilder
	private var deletePostAlert: some View {
		Button("Cancel", role: .cancel) { }
		Button("Delete", role: .destructive) {
			if let post = postToDelete {
				Task {
					await deletePost(post: post)
				}
			}
		}
	}
	
	// MARK: - Notification Handlers
	private func handleCollectionUpdated(_ notification: Notification) {
		if let collectionId = notification.object as? String, collectionId == collection.id {
			print("🔄 CYInsideCollectionView: Collection updated, reloading collection data")
			loadCollectionData()
			refreshTrigger = UUID()
		}
	}
	
	private func handlePostCreated(_ notification: Notification) {
		if let collectionId = notification.object as? String, collectionId == collection.id {
			loadPosts()
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
					
					Button(action: {
						showMembersView = true
					}) {
						HStack(spacing: 4) {
							Text(collection.type == "Individual" ? "Individual" : "\(collection.memberCount) members")
								.font(.subheadline)
								.foregroundColor(.secondary)
							
							Image(systemName: "chevron.right")
								.font(.system(size: 10, weight: .semibold))
								.foregroundColor(.secondary)
						}
					}
					.buttonStyle(.plain)
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
		
		// Sort pinned posts by pinnedAt (most recently pinned first)
		let sortedPinned = pinnedPosts.sorted { post1, post2 in
			let date1 = post1.pinnedAt ?? post1.createdAt
			let date2 = post2.pinnedAt ?? post2.createdAt
			return date1 > date2 // Most recent first
		}
		
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
		
		// Return pinned posts first (sorted by pinnedAt), then sorted unpinned posts
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
			// Read from observed state manager (same as follow button pattern)
			return requestStateManager.hasPendingRequest(for: collection.id) ? "Requested" : "Request"
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
		if collection.type == "Request" && requestStateManager.hasPendingRequest(for: collection.id) {
			return .blue
		}
		return .primary
	}
	
	private func getActionButtonBackground() -> Color {
		if isCurrentUserOwner {
			return .red.opacity(0.1)
		}
		if collection.type == "Request" && requestStateManager.hasPendingRequest(for: collection.id) {
			return Color.blue.opacity(0.1)
		}
		return Color.gray.opacity(0.2)
	}
	
	private func getActionButtonBorderColor() -> Color {
		if isCurrentUserOwner {
			return .red
		}
		if collection.type == "Request" && requestStateManager.hasPendingRequest(for: collection.id) {
			return .blue
		}
		return .clear
	}
	
	// MARK: - Functions
	private func handleOnAppear() {
		loadCollectionData()
		// ALWAYS use cache first - no auto-refresh on view appearance
		if LocalCollectionPostsCache.shared.hasDataLoaded(for: collection.id) {
			if let cachedPosts = LocalCollectionPostsCache.shared.getCachedPosts(for: collection.id) {
				// Use cached data immediately (no network call)
				posts = cachedPosts
			} else {
				loadInitialPosts()
			}
		} else {
			// No cache exists, load fresh
			loadInitialPosts()
		}
		// Remove real-time listener - use pagination instead
		// setupPostListener() // REMOVED - using pagination
		// Set up real-time listener for owner's profile (so other users see updates)
		setupOwnerProfileListener()
		// Initialize shared request state manager
		Task {
			await CollectionRequestStateManager.shared.initializeState()
			// Then update follow state
			await updateFollowState()
		}
	}
	
	private func loadCollectionData() {
		Task {
			// Load collection data to get updated info
			do {
				if let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) {
					await MainActor.run {
						collection = updatedCollection
					}
				}
			} catch {
				print("Error loading collection data: \(error)")
			}
			
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
			
			// Check if current user is following
			await updateFollowState()
			
			// Request state is managed by CollectionRequestStateManager.shared
			// Initialize it if needed
			await CollectionRequestStateManager.shared.initializeState()
		}
	}
	
	// Request state is now managed by CollectionRequestStateManager.shared
	// No need for updateRequestState() - the manager handles all state updates
	
	private func updateFollowState() async {
		guard let currentUserId = authService.user?.uid else {
			await MainActor.run {
				isFollowing = false
			}
			return
		}
		
		// Check if user is in collection's followers array
		let following = collection.followers.contains(currentUserId)
		await MainActor.run {
			isFollowing = following
		}
	}
	
	// Load initial page of posts
	private func loadInitialPosts() {
		guard !isLoadingPosts else { return }
		isLoadingPosts = true
		lastPostDocument = nil
		hasMorePosts = true
		
		Task {
			do {
				let (firebasePosts, lastDoc, hasMore) = try await PostService.shared.getCollectionPostsPaginated(
					collectionId: collection.id,
					limit: isIPad ? 30 : 20,
					lastDocument: nil,
					sortBy: sortOption
				)
				
				// Filter out posts from hidden collections and blocked users
				var filteredPosts = await CollectionService.filterPosts(firebasePosts)
				
				// Handle pinned posts sorting
				if sortOption == "Pinned First" {
					// Separate pinned and unpinned
					let pinned = filteredPosts.filter { $0.isPinned }
					let unpinned = filteredPosts.filter { !$0.isPinned }
					// Sort pinned by pinnedAt, unpinned by createdAt
					let sortedPinned = pinned.sorted { ($0.pinnedAt ?? $0.createdAt) > ($1.pinnedAt ?? $1.createdAt) }
					let sortedUnpinned = unpinned.sorted { $0.createdAt > $1.createdAt }
					filteredPosts = sortedPinned + sortedUnpinned
				}
				
				await MainActor.run {
					posts = filteredPosts
					lastPostDocument = lastDoc
					hasMorePosts = hasMore
					
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
					hasMorePosts = false
				}
				print("❌ Error loading posts: \(error)")
			}
		}
	}
	
	// Load more posts (pagination)
	private func loadMorePosts() {
		guard !isLoadingMorePosts && !isLoadingPosts && hasMorePosts else { return }
		guard let lastDoc = lastPostDocument else { return }
		
		isLoadingMorePosts = true
		
		Task {
			do {
				let (newPosts, lastDoc, hasMore) = try await PostService.shared.getCollectionPostsPaginated(
					collectionId: collection.id,
					limit: isIPad ? 18 : 15,
					lastDocument: lastDoc,
					sortBy: sortOption
				)
				
				// Filter out posts from hidden collections and blocked users
				var filteredPosts = await CollectionService.filterPosts(newPosts)
				
				// Handle pinned posts sorting
				if sortOption == "Pinned First" {
					// Separate pinned and unpinned
					let pinned = filteredPosts.filter { $0.isPinned }
					let unpinned = filteredPosts.filter { !$0.isPinned }
					// Sort pinned by pinnedAt, unpinned by createdAt
					let sortedPinned = pinned.sorted { ($0.pinnedAt ?? $0.createdAt) > ($1.pinnedAt ?? $1.createdAt) }
					let sortedUnpinned = unpinned.sorted { $0.createdAt > $1.createdAt }
					filteredPosts = sortedPinned + sortedUnpinned
				}
				
				await MainActor.run {
					posts.append(contentsOf: filteredPosts)
					lastPostDocument = lastDoc
					hasMorePosts = hasMore
					isLoadingMorePosts = false
				}
			} catch {
				await MainActor.run {
					isLoadingMorePosts = false
				}
				print("❌ Error loading more posts: \(error)")
			}
		}
	}
	
	// MARK: - Complete Refresh (Pull-to-Refresh)
	/// Complete refresh: Clear all caches, reload collection data, reload everything from scratch
	/// Equivalent to exiting and re-entering the app
	private func completeRefresh() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		print("🔄 CYInsideCollectionView: Starting COMPLETE refresh (equivalent to app restart)")
		
		// Step 1: Clear ALL caches first (including user profile caches)
		await MainActor.run {
			// Clear local cache for this collection
			LocalCollectionPostsCache.shared.clearCache(for: collection.id)
			// Clear global cache (from CollectionRowDesign.swift)
			CollectionPostsCache.shared.clearAllCache()
			HomeViewCache.shared.clearCache()
			// Clear user profile caches to force fresh profile image/name loads
			UserService.shared.clearUserCache(userId: collection.ownerId)
			UserService.shared.clearUserCache(userId: currentUserId)
			print("✅ CYInsideCollectionView: Cleared all caches (including user profile caches)")
		}
		
		// Step 2: Reload current user data - FORCE FRESH
		do {
			// Stop existing listener and reload fresh
			CYServiceManager.shared.stopListening()
			try await CYServiceManager.shared.loadCurrentUser()
			print("✅ CYInsideCollectionView: Reloaded current user data (fresh from Firestore)")
		} catch {
			print("⚠️ CYInsideCollectionView: Error reloading current user: \(error)")
		}
		
		// Step 3: Reload collection data and posts - FORCE FRESH
		loadCollectionData()
		await refreshCollectionPosts()
	}
	
	// MARK: - Pull-to-Refresh with Reordering
	/// Refresh collection posts: Check for new posts, reorder if none found
	private func refreshCollectionPosts() async {
		guard !isLoadingPosts else { return }
		isLoadingPosts = true
		lastPostDocument = nil
		hasMorePosts = true
		
		// First verify collection still exists (not deleted)
		do {
			guard let freshCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) else {
				// Collection was deleted, dismiss view
				print("⚠️ CYInsideCollectionView: Collection was deleted during refresh, dismissing view")
				await MainActor.run {
					dismiss()
				}
				return
			}
			await MainActor.run {
				self.collection = freshCollection
			}
		} catch {
			print("❌ CYInsideCollectionView: Error verifying collection exists: \(error)")
		}
		
		do {
			let (firebasePosts, lastDoc, hasMore) = try await PostService.shared.getCollectionPostsPaginated(
				collectionId: collection.id,
				limit: isIPad ? 30 : 20,
				lastDocument: nil,
				sortBy: sortOption
			)
			
			// Filter out posts from hidden collections and blocked users
			var filteredPosts = await CollectionService.filterPosts(firebasePosts)
			
			// Handle pinned posts sorting
			if sortOption == "Pinned First" {
				// Separate pinned and unpinned
				let pinned = filteredPosts.filter { $0.isPinned }
				let unpinned = filteredPosts.filter { !$0.isPinned }
				// Sort pinned by pinnedAt, unpinned by createdAt
				let sortedPinned = pinned.sorted { ($0.pinnedAt ?? $0.createdAt) > ($1.pinnedAt ?? $1.createdAt) }
				let sortedUnpinned = unpinned.sorted { $0.createdAt > $1.createdAt }
				filteredPosts = sortedPinned + sortedUnpinned
			}
			
			await MainActor.run {
				// Always use fresh data from Firestore (cache was cleared in completeRefresh)
				// This ensures deleted posts are removed and new posts appear
							posts = filteredPosts
				LocalCollectionPostsCache.shared.setCachedPosts(filteredPosts, for: collection.id)
				
				lastPostDocument = lastDoc
				hasMorePosts = hasMore
				
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
				hasMorePosts = false
			}
			print("❌ Error refreshing posts: \(error)")
		}
	}
	
	// Legacy method - kept for compatibility but uses pagination
	private func loadPosts() {
		loadInitialPosts()
	}
	
	// DEPRECATED: Fetch posts directly from Firebase (source of truth) - Use pagination instead
	private func fetchPostsFromFirebase() async throws -> [CollectionPost] {
				let db = Firestore.firestore()
				// Query without orderBy to avoid index requirement, then sort in memory
				let snapshot = try await db.collection("posts")
					.whereField("collectionId", isEqualTo: collection.id)
					.limit(to: 20) // Add limit for safety
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
						pinnedAt: (data["pinnedAt"] as? Timestamp)?.dateValue(),
						caption: caption
					)
				}
				// Sort by createdAt descending (newest first)
		return loadedPosts.sorted { $0.createdAt > $1.createdAt }
	}
	
	private func handleFollowAction() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		do {
			if isFollowing {
				// Unfollow the collection
				try await CollectionService.shared.unfollowCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
				await MainActor.run {
					isFollowing = false
				}
			} else {
				// Follow the collection
				try await CollectionService.shared.followCollection(
					collectionId: collection.id,
					userId: currentUserId
				)
				await MainActor.run {
					isFollowing = true
				}
			}
			
			// Reload collection data to get updated follower count
			loadCollectionData()
		} catch {
			print("❌ Error following/unfollowing collection: \(error.localizedDescription)")
		}
	}
	
	private func handleCollectionAction() async {
		guard authService.user?.uid != nil else { return }
		
		// Handle Request/Unrequest toggle for Request-type collections
		if collection.type == "Request" && !isCurrentUserMember && !isCurrentUserOwner {
			// Get current state from observed state manager
			let wasRequested = requestStateManager.hasPendingRequest(for: collection.id)
			
			// Post notification immediately for synchronization (same pattern as follow button)
			if let currentUserId = authService.user?.uid {
				if wasRequested {
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
				if wasRequested {
					// Cancel/unrequest
					try await CollectionService.shared.cancelCollectionRequest(collectionId: collection.id)
				} else {
					// Send request
				try await CollectionService.shared.sendCollectionRequest(collectionId: collection.id)
				}
			} catch {
				print("Error \(wasRequested ? "cancelling" : "sending") collection request: \(error.localizedDescription)")
				// Revert the notification on error
				if let currentUserId = authService.user?.uid {
					if wasRequested {
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
		else if collection.type == "Open" && !isCurrentUserMember && !isCurrentUserOwner {
			guard let currentUserId = authService.user?.uid else { return }
			
			// Post notification immediately for synchronization (same pattern as follow button)
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
			
			// Update local state immediately for instant feedback
			if !collection.members.contains(currentUserId) {
				collection.members.append(currentUserId)
				collection.memberCount += 1
			}
			
			do {
				try await CollectionService.shared.joinCollection(collectionId: collection.id)
				// Reload collection data to get fresh state from server
				loadCollectionData()
			} catch {
				print("Error joining collection: \(error.localizedDescription)")
				// Revert local state and notifications on error
				if let index = collection.members.firstIndex(of: currentUserId) {
					collection.members.remove(at: index)
					collection.memberCount = max(0, collection.memberCount - 1)
				}
				// Revert notifications
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionLeft"),
					object: collection.id,
					userInfo: ["userId": currentUserId]
				)
			}
		}
		// Handle Leave action (already implemented in handleLeaveCollection)
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
	
	private func hideCollection() {
		Task {
			do {
				try await CYServiceManager.shared.hideCollection(collectionId: collection.id)
				// Dismiss the view after hiding
				await MainActor.run {
					dismiss()
				}
			} catch {
				print("❌ CYInsideCollectionView: Error hiding collection: \(error)")
				await MainActor.run {
					deleteErrorMessage = error.localizedDescription
					showDeleteError = true
				}
			}
		}
	}
	
	// MARK: - Pin and Delete Functions
	private func handlePinPost(_ post: CollectionPost) async {
		// Check permissions
		let isOwner = collection.ownerId == authService.user?.uid
		let isAdmin = collection.owners.contains(authService.user?.uid ?? "")
		let isIndividual = collection.type == "Individual"
		let isPostAuthor = post.authorId == authService.user?.uid
		
		// Individual collections: user can pin their own posts
		// Multi-member collections: only owner/admin can pin
		if isIndividual {
			guard isPostAuthor else { return }
		} else {
			guard isOwner || isAdmin else { return }
		}
		
		isProcessing = true
		do {
			let newPinState = !post.isPinned
			
			// If pinning a new post, check if there are already 4 pinned posts
			// If so, unpin the oldest one (least recently pinned)
			if newPinState {
				let pinnedPosts = posts.filter { $0.isPinned && $0.id != post.id }
				if pinnedPosts.count >= 4 {
					// Find the oldest pinned post (lowest pinnedAt date)
					if let oldestPinnedPost = pinnedPosts.min(by: { post1, post2 in
						let date1 = post1.pinnedAt ?? post1.createdAt
						let date2 = post2.pinnedAt ?? post2.createdAt
						return date1 < date2
					}) {
						print("📌 Unpinning oldest post (ID: \(oldestPinnedPost.id)) to make room for new pin")
						try await CollectionService.shared.togglePostPin(postId: oldestPinnedPost.id, isPinned: false)
					}
				}
			}
			
			// Now pin/unpin the requested post
			try await CollectionService.shared.togglePostPin(postId: post.id, isPinned: newPinState)
			print("✅ Post pin toggled successfully")
			
			// Update pin order tracking
			await MainActor.run {
				if newPinState {
					// Post is being pinned - record current time as pin order (most recent first)
					self.pinOrder[post.id] = Date()
				} else {
					// Post is being unpinned - remove from pin order
					self.pinOrder.removeValue(forKey: post.id)
				}
				
				// Reload posts to get updated pin status
				loadPosts()
				
				// Post notification to refresh views
				NotificationCenter.default.post(name: NSNotification.Name("PostCreated"), object: nil)
				NotificationCenter.default.post(name: NSNotification.Name("CollectionUpdated"), object: post.collectionId)
			}
		} catch {
			print("❌ Error toggling post pin: \(error)")
		}
		isProcessing = false
	}
	
	// Legacy function name for compatibility
	private func togglePin(post: CollectionPost) async {
		await handlePinPost(post)
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
	
	// MARK: - Real-time Listener for Owner's Profile
	private func setupOwnerProfileListener() {
		// Remove existing listener if any
		ownerProfileListener?.remove()
		
		// Set up real-time Firestore listener for the owner's profile
		// This allows other users to see real-time updates when the owner edits their profile
		let db = Firestore.firestore()
		let collectionId = collection.id
		let ownerId = collection.ownerId
		ownerProfileListener = db.collection("users").document(ownerId).addSnapshotListener { snapshot, error in
			Task { @MainActor in
				if let error = error {
					print("❌ CYInsideCollectionView: Error listening to owner profile updates: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot, let data = snapshot.data() else {
					return
				}
				
				// Immediately update owner profile image from Firestore (real-time)
				// Use NotificationCenter to update the view since we can't capture self in struct
				let newProfileImageURL = data["profileImageURL"] as? String
				NotificationCenter.default.post(
					name: Notification.Name("OwnerProfileImageUpdated"),
					object: collectionId,
					userInfo: ["ownerId": ownerId, "profileImageURL": newProfileImageURL as Any]
				)
				print("🔄 CYInsideCollectionView: Owner profile image updated in real-time from Firestore")
			}
		}
	}
	
	// MARK: - Real-time Post Listener (REMOVED - Using Pagination Instead)
	// Real-time listeners are expensive and don't scale. Using pagination + manual refresh instead.
}

