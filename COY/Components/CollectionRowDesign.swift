import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI

// MARK: - Shared Cache for Collection Preview Posts
class CollectionPostsCache {
	static let shared = CollectionPostsCache()
	private init() {}
	
	private var cachedPosts: [String: [CollectionPost]] = [:]
	private var loadingStates: [String: Bool] = [:]
	
	func hasCachedPosts(for collectionId: String) -> Bool {
		return cachedPosts[collectionId] != nil && !cachedPosts[collectionId]!.isEmpty
	}
	
	func getCachedPosts(for collectionId: String) -> [CollectionPost]? {
		return cachedPosts[collectionId]
	}
	
	func setCachedPosts(_ posts: [CollectionPost], for collectionId: String) {
		cachedPosts[collectionId] = posts
	}
	
	func clearCache(for collectionId: String) {
		cachedPosts.removeValue(forKey: collectionId)
	}
	
	func clearAllCache() {
		cachedPosts.removeAll()
	}
	
	func isLoading(for collectionId: String) -> Bool {
		return loadingStates[collectionId] ?? false
	}
	
	func setLoading(_ loading: Bool, for collectionId: String) {
		loadingStates[collectionId] = loading
	}
}

// MARK: - Collection Row Design (Clean & Minimal)
struct CollectionRowDesign: View {
	let collection: CollectionData
	let isFollowing: Bool
	let hasRequested: Bool
	let isMember: Bool
	let isOwner: Bool
	let isDeletedCollection: Bool // Flag to indicate if this is a deleted collection
	
	let onFollowTapped: () -> Void
	let onActionTapped: () -> Void
	let onProfileTapped: () -> Void
	let onCollectionTapped: () -> Void
	
	// Convenience initializer with default value for backward compatibility
	init(
		collection: CollectionData,
		isFollowing: Bool,
		hasRequested: Bool,
		isMember: Bool,
		isOwner: Bool,
		isDeletedCollection: Bool = false,
		onFollowTapped: @escaping () -> Void,
		onActionTapped: @escaping () -> Void,
		onProfileTapped: @escaping () -> Void,
		onCollectionTapped: @escaping () -> Void
	) {
		self.collection = collection
		self.isFollowing = isFollowing
		self.hasRequested = hasRequested
		self.isMember = isMember
		self.isOwner = isOwner
		self.isDeletedCollection = isDeletedCollection
		self.onFollowTapped = onFollowTapped
		self.onActionTapped = onActionTapped
		self.onProfileTapped = onProfileTapped
		self.onCollectionTapped = onCollectionTapped
	}
	
	@StateObject private var cyServiceManager = CYServiceManager.shared
	@StateObject private var requestStateManager = CollectionRequestStateManager.shared
	@State private var previewPosts: [CollectionPost] = []
	@State private var ownerProfileImageURL: String? // Store owner's profile image URL
	@State private var postGridRefreshId = UUID() // Force refresh when posts change
	@State private var postListener: ListenerRegistration? // Firestore listener for real-time updates
	@State private var ownerProfileListener: ListenerRegistration? // Real-time listener for owner's profile
	@State private var isOwnerBlocked = false // Track if owner is mutually blocked (either direction)
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@Environment(\.colorScheme) var colorScheme
	
	// Observe ServiceManager changes for real-time updates
	private var currentUser: CYServiceManager.CurrentUser? {
		cyServiceManager.currentUser
	}
	
	// iPad detection
	private var isIPad: Bool {
		horizontalSizeClass == .regular
	}
	
	var body: some View {
		// Don't render if collection is hidden or owner is mutually blocked - check reactively via StateObject
		if cyServiceManager.isCollectionHidden(collectionId: collection.id) || isOwnerBlocked {
			EmptyView()
		} else {
			collectionRowContent
		}
	}
	
	private var collectionRowContent: some View {
		VStack(alignment: .leading, spacing: isIPad ? 16 : 12) {
			// Header: Image + Name + Buttons
			HStack(spacing: isIPad ? 16 : 12) {
				// Profile Image Placeholder
				profileImageView
				
				// Name + Type/Members
				VStack(alignment: .leading, spacing: isIPad ? 6 : 4) {
					HStack {
						Text(collection.name)
							.font(isIPad ? .title3 : .headline)
							.fontWeight(isIPad ? .semibold : .regular)
							.foregroundColor(.primary)
						
						// Follow button (next to collection name)
						if !isMember && !isOwner {
							followButton
						}
					}
					
					Text(memberLabel)
						.font(isIPad ? .subheadline : .caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
				
				// Lock icon for private collections (positioned before action button)
				if !collection.isPublic {
					Image(systemName: "lock.fill")
						.font(isIPad ? .title3 : .body)
						.foregroundColor(.primary)
				}
				
				// Action Buttons (Request/Join button on the right)
				if shouldShowActionButton {
					actionButton
						.zIndex(1) // Ensure button is on top layer
				}
			}
			.padding(.horizontal, isIPad ? 20 : 16)
			
			// Description
			if !collection.description.isEmpty {
				Text(collection.description)
					.font(isIPad ? .caption : .caption2)
					.foregroundColor(.secondary)
					.lineLimit(isIPad ? 3 : 2)
					.padding(.horizontal, isIPad ? 20 : 16)
			}
			
			// Grid with actual post images
			postGrid
		}
		.onChange(of: cyServiceManager.currentUser) { oldValue, newValue in
			// Real-time update when user profile changes via ServiceManager
			// IMMEDIATELY update owner profile image if this is current user's collection (like ProfileView does)
			if collection.ownerId == Auth.auth().currentUser?.uid, let cyUser = newValue {
				// Immediately update owner profile image from ServiceManager
				ownerProfileImageURL = cyUser.profileImageURL
				print("🔄 CollectionRowDesign: Immediately updated owner profile image from ServiceManager")
			}
			
			// Check mutual blocking status when current user's block list changes
			Task {
				let mutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
				await MainActor.run {
					isOwnerBlocked = mutuallyBlocked
					if mutuallyBlocked {
						print("🚫 CollectionRowDesign: Collection owner '\(collection.ownerId)' is mutually blocked, clearing cache and posts")
						CollectionPostsCache.shared.clearCache(for: collection.id)
						previewPosts = []
						postGridRefreshId = UUID()
					}
				}
			}
		}
		.onAppear {
			// Always check cache first and use it if available
			if let cached = CollectionPostsCache.shared.getCachedPosts(for: collection.id), !cached.isEmpty {
				// Use cached posts immediately - don't reload
				previewPosts = cached
				#if VERBOSE_DEBUG
				print("✅ CollectionRowDesign: Using cached posts for collection '\(collection.name)' (ID: \(collection.id)) - \(cached.count) posts")
				#endif
			} else if previewPosts.isEmpty {
				// Only load if we have no posts at all (neither cached nor in state)
				// This ensures posts are always loaded, even for deleted collections
				#if VERBOSE_DEBUG
				print("🔄 CollectionRowDesign: No cached posts found, loading for collection '\(collection.name)' (ID: \(collection.id))")
				#endif
				loadPreviewPosts()
			} else {
				// If we have posts in state but no cache, update cache to persist them
				CollectionPostsCache.shared.setCachedPosts(previewPosts, for: collection.id)
				print("✅ CollectionRowDesign: Persisting existing posts to cache for collection '\(collection.name)' (ID: \(collection.id)) - \(previewPosts.count) posts")
			}
			// Set up real-time listener for owner's profile (so other users see updates)
			setupOwnerProfileListener()
			// Set up real-time listener for posts to get immediate updates
			setupPostListener()
		}
		.onChange(of: collection.id) { oldId, newId in
			// Reload posts when collection changes
			if oldId != newId {
				#if VERBOSE_DEBUG
				print("🔄 CollectionRowDesign: Collection ID changed from \(oldId) to \(newId), reloading posts")
				#endif
				// Check cache for new collection first - don't clear unnecessarily
				if let cached = CollectionPostsCache.shared.getCachedPosts(for: newId), !cached.isEmpty {
					previewPosts = cached
					print("✅ CollectionRowDesign: Using cached posts for new collection (ID: \(newId))")
				} else {
					// Only clear if we need to load fresh
					previewPosts = []
				loadPreviewPosts()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostCreated"))) { notification in
			// Immediately update preview when a new post is created in this collection
			// Check both object and userInfo for collectionId
			var createdCollectionId: String?
			
			// Check if notification.object is collectionId or postId
			if let id = notification.object as? String {
				// Could be either collectionId or postId - check userInfo first
				if let userInfo = notification.userInfo,
				   let collectionId = userInfo["collectionId"] as? String {
					createdCollectionId = collectionId
				} else {
					// No userInfo, assume object is collectionId
				createdCollectionId = id
				}
			} else if let userInfo = notification.userInfo,
					  let id = userInfo["collectionId"] as? String {
				createdCollectionId = id
			}
			
			if let collectionId = createdCollectionId,
			   collectionId == collection.id {
				print("🔄 CollectionRowDesign: New post created in collection '\(collection.name)', immediately updating preview")
				
				// Immediately clear cache and reload to show the new post
				// This ensures the new post appears right away, just like in CYInsideCollectionView
				CollectionPostsCache.shared.clearCache(for: collection.id)
				// Force immediate reload - don't use cache
				loadPreviewPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostDeleted"))) { notification in
			// Immediately remove deleted post from preview and reload if needed
			if let userInfo = notification.userInfo,
			   let deletedCollectionId = userInfo["collectionId"] as? String,
			   deletedCollectionId == collection.id,
			   let deletedPostId = userInfo["postId"] as? String {
				print("🔄 CollectionRowDesign: Post deleted from collection '\(collection.name)', removing from preview")
				
				// Immediately remove the deleted post from previewPosts array
				previewPosts.removeAll { $0.id == deletedPostId }
				
				// Force UI refresh
				postGridRefreshId = UUID()
				
				// Clear cache and reload to get fresh posts
				CollectionPostsCache.shared.clearCache(for: collection.id)
				loadPreviewPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("ProfileUpdated"))) { notification in
			// Immediately reload owner profile image when profile is updated
			if let userId = notification.userInfo?["userId"] as? String,
			   userId == collection.ownerId {
				// If it's the current user, update immediately from ServiceManager
				if userId == Auth.auth().currentUser?.uid, let cyUser = cyServiceManager.currentUser {
					ownerProfileImageURL = cyUser.profileImageURL
					#if VERBOSE_DEBUG
					print("✅ CollectionRowDesign: Immediately updated owner profile image from ServiceManager")
				#endif
				} else {
					// For other users, reload async
					loadOwnerProfileImage()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("OwnerProfileImageUpdated"))) { notification in
			// Update owner profile image when real-time listener detects changes
			if let collectionId = notification.object as? String,
			   collectionId == collection.id,
			   let ownerId = notification.userInfo?["ownerId"] as? String,
			   ownerId == collection.ownerId,
			   let newProfileImageURL = notification.userInfo?["profileImageURL"] as? String {
				ownerProfileImageURL = newProfileImageURL
				print("✅ CollectionRowDesign: Updated owner profile image from real-time listener")
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionPostsUpdated"))) { notification in
			// Reload posts when notification is received (replaces expensive real-time listener)
			if let updatedCollectionId = notification.object as? String,
			   updatedCollectionId == collection.id {
				#if VERBOSE_DEBUG
				print("🔄 CollectionRowDesign: Received CollectionPostsUpdated notification, reloading posts")
				#endif
				loadPreviewPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRestored"))) { notification in
			// Reload posts when collection is restored from deleted collections
			if let restoredCollectionId = notification.object as? String,
			   restoredCollectionId == collection.id {
				print("🔄 CollectionRowDesign: Collection '\(collection.name)' was restored, reloading preview posts")
				// Force reload to ensure fresh data after restore
				// Don't clear cache first - let the reload update it
				loadPreviewPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionDeleted"))) { notification in
			// When a collection is deleted, ensure posts are still cached
			// Posts should still be visible in deleted collections view
			if let deletedCollectionId = notification.object as? String,
			   deletedCollectionId == collection.id {
				#if VERBOSE_DEBUG
				print("🔄 CollectionRowDesign: Collection '\(collection.name)' was deleted, ensuring posts are cached")
				#endif
				// Don't clear cache - keep posts visible in deleted collections
				// If we don't have posts loaded, load them now
				if previewPosts.isEmpty {
					loadPreviewPosts()
				} else {
					// Ensure existing posts are cached
					CollectionPostsCache.shared.setCachedPosts(previewPosts, for: collection.id)
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionHidden"))) { notification in
			// When a collection is hidden, it should disappear completely
			if let hiddenCollectionId = notification.object as? String,
			   hiddenCollectionId == collection.id {
				print("🚫 CollectionRowDesign: Collection '\(collection.name)' was hidden, clearing cache and posts")
				// Clear cache and posts - collection should not be visible
				CollectionPostsCache.shared.clearCache(for: collection.id)
				previewPosts = []
				postGridRefreshId = UUID()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnhidden"))) { notification in
			// When a collection is unhidden, reload it
			if let unhiddenCollectionId = notification.object as? String,
			   unhiddenCollectionId == collection.id {
				print("✅ CollectionRowDesign: Collection '\(collection.name)' was unhidden, reloading")
				// Reload posts when collection is unhidden
				loadPreviewPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { notification in
			// Check mutual blocking when any user is blocked (could be owner or current user)
			Task {
				let mutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
				await MainActor.run {
					isOwnerBlocked = mutuallyBlocked
					if mutuallyBlocked {
						print("🚫 CollectionRowDesign: Collection owner '\(collection.ownerId)' is mutually blocked, hiding collection")
						// Clear cache and posts - collection should not be visible
						CollectionPostsCache.shared.clearCache(for: collection.id)
						previewPosts = []
						postGridRefreshId = UUID()
					}
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { notification in
			// Check mutual blocking when any user is unblocked
			// This could be the owner OR a member who has posts in this collection
			Task {
				let mutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
				let isCollectionHidden = cyServiceManager.isCollectionHidden(collectionId: collection.id)
				
				await MainActor.run {
					isOwnerBlocked = mutuallyBlocked
					
					// Only reload if collection is visible (not hidden and owner not blocked)
					if !mutuallyBlocked && !isCollectionHidden {
						if let unblockedUserId = notification.userInfo?["unblockedUserId"] as? String {
							print("✅ CollectionRowDesign: User '\(unblockedUserId)' was unblocked, reloading posts to show their content in collection '\(collection.name)'")
						} else {
							print("✅ CollectionRowDesign: User was unblocked, reloading posts to show any previously hidden content in collection '\(collection.name)'")
						}
						// Reload posts to show any posts from the unblocked user (could be owner or member)
						loadPreviewPosts(forceRefresh: true)
					} else if !mutuallyBlocked {
						// Owner is no longer blocked, but collection might be hidden
						print("✅ CollectionRowDesign: Collection owner '\(collection.ownerId)' is no longer mutually blocked")
					}
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
			// When app returns to foreground, restore from cache if available
			// This is critical for deleted collections - posts must persist
			if previewPosts.isEmpty {
				if let cached = CollectionPostsCache.shared.getCachedPosts(for: collection.id), !cached.isEmpty {
					// Restore from cache
					previewPosts = cached
					print("✅ CollectionRowDesign: Restored posts from cache after app return for '\(collection.name)' - \(cached.count) posts")
				} else {
					// Cache is empty (lost on app exit), reload from Firebase
					// This is especially important for deleted collections
					#if VERBOSE_DEBUG
					print("🔄 CollectionRowDesign: App returned to foreground, no cache found, reloading posts for '\(collection.name)' (ID: \(collection.id))")
					#endif
					loadPreviewPosts(forceRefresh: true)
				}
			} else {
				// We have posts, ensure they're cached for next time
				CollectionPostsCache.shared.setCachedPosts(previewPosts, for: collection.id)
				print("✅ CollectionRowDesign: Ensured posts are cached after app return for '\(collection.name)' - \(previewPosts.count) posts")
			}
		}
		.onDisappear {
			// Clean up listeners when view disappears
			postListener?.remove()
			postListener = nil
			ownerProfileListener?.remove()
			ownerProfileListener = nil
		}
	}
	
	// MARK: - Profile Image
	private var profileImageView: some View {
		Button(action: onProfileTapped) {
			let imageSize: CGFloat = isIPad ? 56 : 44
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				// Use collection's profile image if available
				CachedProfileImageView(url: imageURL, size: imageSize)
					.clipShape(Circle())
			} else {
				// Use owner's profile image as fallback (not current user's)
				if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty {
					CachedProfileImageView(url: ownerImageURL, size: imageSize)
						.clipShape(Circle())
				} else {
					// Fallback to default icon if owner has no profile image
					DefaultProfileImageView(size: imageSize)
				}
			}
		}
		.buttonStyle(.plain)
		.onAppear {
			// Check mutual blocking status
			Task {
				let mutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
				await MainActor.run {
					isOwnerBlocked = mutuallyBlocked
				}
			}
			
			// Load owner's profile image if collection has no imageURL
			if collection.imageURL?.isEmpty != false {
				loadOwnerProfileImage()
			}
		}
	}
	
	// MARK: - Load Owner Profile Image
	private func loadOwnerProfileImage() {
		// Skip if already loaded
		if ownerProfileImageURL != nil {
			return
		}
		
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
					print("❌ CollectionRowDesign: Error listening to owner profile updates: \(error.localizedDescription)")
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
				#if VERBOSE_DEBUG
				print("🔄 CollectionRowDesign: Owner profile image updated in real-time from Firestore")
				#endif
			}
		}
	}
	
	// MARK: - Member Label
	private var memberLabel: String {
		if collection.type == "Individual" {
			return "Individual"
		} else {
			return "\(collection.memberCount) member\(collection.memberCount == 1 ? "" : "s")"
		}
	}
	
	// MARK: - Follow Button
	private var followButton: some View {
		Button(action: onFollowTapped) {
			let buttonSize: CGFloat = isIPad ? 36 : 28
			Circle()
				.fill(isFollowing ? Color.blue : Color(.systemGray4))
				.frame(width: buttonSize, height: buttonSize)
				.overlay(
					Image(systemName: isFollowing ? "checkmark" : "plus")
						.font(isIPad ? .subheadline : .caption)
						.fontWeight(.bold)
						.foregroundColor(isFollowing ? .white : .primary)
				)
		}
		.buttonStyle(.plain)
	}
	
	// MARK: - Action Button (Request / Join only, no Leave)
	private var shouldShowActionButton: Bool {
		// Don't show button for Individual or Invite collections
		guard collection.type == "Request" || collection.type == "Open" else {
			return false
		}
		
		// For Request collections: Only show if user is NOT a member, owner, or admin
		if collection.type == "Request" {
			// Check if user is owner
			if isOwner {
				return false
			}
			// Check if user is a member
			if isMember {
				return false
			}
			// Check if user is an admin (in owners array)
			// Note: isOwner already checks ownerId, but owners array might have multiple admins
			// Since we don't have direct access to check if current user is in owners array,
			// we rely on isMember and isOwner flags passed to the component
			return true // Show Request button if not owner/member
		}
		
		// For Open collections: Only show Join button if user is NOT a member or owner
		// Leave button should only be in CYInsideCollectionView
		if collection.type == "Open" {
			if isMember || isOwner {
				return false // Don't show Leave button here
			}
			return true // Show Join button if not a member
		}
		
		return false
	}
	
	private var actionButton: some View {
		Button(action: onActionTapped) {
			Text(actionButtonText)
				.font(isIPad ? .body : .subheadline)
				.fontWeight(.medium)
				.foregroundColor(actionButtonTextColor)
				.padding(.horizontal, isIPad ? 16 : 12)
				.padding(.vertical, isIPad ? 8 : 6)
				.background(actionButtonBackground)
				.cornerRadius(isIPad ? 8 : 6)
				.overlay(
					RoundedRectangle(cornerRadius: isIPad ? 8 : 6)
						.stroke(actionButtonBorderColor, lineWidth: 1)
				)
		}
		.buttonStyle(.plain)
	}
	
	private var actionButtonText: String {
		switch collection.type {
		case "Request":
			// Should not reach here if user is member/owner (button shouldn't show)
			// But handle it just in case
			if isMember || isOwner {
				return "" // Shouldn't show, but return empty if it does
			}
			// Read directly from state manager (same as follow button pattern)
			return requestStateManager.hasPendingRequest(for: collection.id) ? "Requested" : "Request"
		case "Open":
			// Only show Join button (Leave is only in CYInsideCollectionView)
			// Should not reach here if user is member/owner (button shouldn't show)
			if isMember || isOwner {
				return "" // Shouldn't show, but return empty if it does
			}
			return "Join"
		default:
			return ""
		}
	}
	
	private var actionButtonTextColor: Color {
		if collection.type == "Request" && requestStateManager.hasPendingRequest(for: collection.id) {
			return .blue
		}
		return .primary
	}
	
	private var actionButtonBackground: Color {
		if collection.type == "Request" && requestStateManager.hasPendingRequest(for: collection.id) {
			return .blue.opacity(0.1)
		}
		return Color(.systemGray6)
	}
	
	private var actionButtonBorderColor: Color {
		if collection.type == "Request" && requestStateManager.hasPendingRequest(for: collection.id) {
			return .blue
		}
		return .clear
	}
	
	// MARK: - Post Grid
	private var postGrid: some View {
		Button(action: onCollectionTapped) {
			// Always show 4 posts on all devices (iPhone and iPad)
			// iPad sizes are bigger to fill the space better
			let thumbnailWidth: CGFloat = isIPad ? 180 : 90
			let thumbnailHeight: CGFloat = isIPad ? 260 : 130
			let spacing: CGFloat = isIPad ? 18 : 8
			
			HStack(spacing: spacing) {
			ForEach(0..<4, id: \.self) { idx in
				if idx < previewPosts.count {
					let post = previewPosts[idx]
						postThumbnailView(post: post, index: idx, width: thumbnailWidth, height: thumbnailHeight)
				} else {
					// Show placeholder - color scheme aware
					Rectangle()
						.fill(colorScheme == .dark ? Color.white.opacity(0.3) : Color.gray.opacity(0.3))
							.frame(width: thumbnailWidth, height: thumbnailHeight)
						.clipped()
						.id("placeholder_\(idx)")
				}
			}
		}
			.padding(.horizontal, isIPad ? 20 : 16)
			.padding(.bottom, isIPad ? 24 : 20)
		}
		.buttonStyle(.plain)
		.id("postGrid_\(postGridRefreshId)_\(previewPosts.count)")
	}
	
	// Helper function to extract image URL from post
	private func getImageURL(for post: CollectionPost) -> String? {
		// First, try to find a thumbnailURL from any mediaItem
		for mediaItem in post.mediaItems {
			if let thumbnail = mediaItem.thumbnailURL, !thumbnail.isEmpty {
				return thumbnail
			}
		}
		
		// If no thumbnail found, try to find an imageURL from any mediaItem
		for mediaItem in post.mediaItems {
			if let imgURL = mediaItem.imageURL, !imgURL.isEmpty {
				return imgURL
			}
		}
		
		// Fallback to firstMediaItem if mediaItems array is empty
		if let firstMedia = post.firstMediaItem {
			return firstMedia.thumbnailURL ?? firstMedia.imageURL
		}
		
		return nil
	}
	
	// Helper view for post thumbnail
	@ViewBuilder
	private func postThumbnailView(post: CollectionPost, index: Int, width: CGFloat, height: CGFloat) -> some View {
		let imageURL = getImageURL(for: post)
		let hasVideo = post.mediaItems.contains { $0.isVideo }
		let videoDuration = post.mediaItems.first(where: { $0.isVideo })?.videoDuration
		
		ZStack(alignment: .topTrailing) {
			if let finalImageURL = imageURL, !finalImageURL.isEmpty, let url = URL(string: finalImageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.aspectRatio(contentMode: .fill)
					.frame(width: width, height: height)
					.clipped()
					.cornerRadius(0)
					.id("post_\(post.id)_\(index)_\(finalImageURL)")
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.3))
					.frame(width: width, height: height)
					.clipped()
					.id("post_\(post.id)_\(index)_empty")
			}
			
			// Video timer overlay (top right corner) - matching PinterestPostGrid style
			if hasVideo, let duration = videoDuration {
				VStack {
					HStack {
						Spacer()
						Text(formatVideoDuration(duration))
							.font(isIPad ? .caption : .caption2)
							.fontWeight(.semibold)
							.foregroundColor(.white)
							.padding(.horizontal, isIPad ? 8 : 6)
							.padding(.vertical, isIPad ? 4 : 3)
							.background(Color.black.opacity(0.7))
							.cornerRadius(isIPad ? 5 : 4)
							.padding(isIPad ? 10 : 8)
					}
					Spacer()
				}
			}
		}
		.frame(width: width, height: height)
	}
	
	// Helper to format video duration - matching PinterestPostGrid format
	private func formatVideoDuration(_ duration: Double) -> String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
	
	// MARK: - Load Preview Posts
	private func loadPreviewPosts(forceRefresh: Bool = false) {
		let collectionId = collection.id
		
		// Don't load if collection is hidden or owner is mutually blocked
		if cyServiceManager.isCollectionHidden(collectionId: collectionId) || isOwnerBlocked {
			print("🚫 CollectionRowDesign: Collection '\(collection.name)' is hidden or owner is mutually blocked, not loading posts")
			previewPosts = []
			CollectionPostsCache.shared.clearCache(for: collectionId)
			return
		}
		
		// Don't reload if already loading (unless forcing refresh for new post)
		if !forceRefresh && CollectionPostsCache.shared.isLoading(for: collectionId) {
			print("⏭️ CollectionRowDesign: Already loading posts for collection '\(collection.name)' (ID: \(collectionId)), skipping")
			return
		}
		
		// If we have cached posts and not forcing refresh, use cache
		if !forceRefresh, let cached = CollectionPostsCache.shared.getCachedPosts(for: collectionId), !cached.isEmpty {
			previewPosts = cached
			#if VERBOSE_DEBUG
			print("⏭️ CollectionRowDesign: Using cached posts for collection '\(collection.name)' (ID: \(collectionId)) - \(cached.count) posts")
			#endif
			return 
		}
		
		// If forcing refresh, always clear cache to get fresh data
		if forceRefresh {
			CollectionPostsCache.shared.clearCache(for: collectionId)
		}
		
		CollectionPostsCache.shared.setLoading(true, for: collectionId)
		print("🔄 CollectionRowDesign: Starting to load preview posts for collection '\(collection.name)' (ID: \(collectionId))")
		
		Task {
			do {
				// Fetch posts from collection - use "Pinned First" to match CYInsideCollectionView sorting
				// Load only 4 posts for preview (paginated)
				let (posts, _, _) = try await PostService.shared.getCollectionPostsPaginated(
					collectionId: collection.id,
					limit: 4,
					lastDocument: nil,
					sortBy: "Pinned First"
				)
				var allPosts = posts
				#if VERBOSE_DEBUG
				print("📦 CollectionRowDesign: Fetched \(allPosts.count) posts from Firebase (limited to 4 for preview)")
				#endif
				
				// For deleted collections, skip filtering - user should see all posts
				// For regular collections, filter out posts from hidden collections and blocked users
				if !isDeletedCollection {
				allPosts = await CollectionService.filterPosts(allPosts)
				#if VERBOSE_DEBUG
				print("📦 CollectionRowDesign: After filtering: \(allPosts.count) posts remaining")
				#endif
				} else {
					#if VERBOSE_DEBUG
					print("📦 CollectionRowDesign: Skipping filtering for deleted collection - showing all \(allPosts.count) posts")
					#endif
				}
				
				// Sort EXACTLY like CYInsideCollectionView: pinned first (by pinnedAt, most recent first), then by date (newest first)
				// Separate pinned and unpinned posts
				let pinnedPosts = allPosts.filter { $0.isPinned }
				let unpinnedPosts = allPosts.filter { !$0.isPinned }
				
				// Sort pinned posts by pinnedAt (most recently pinned first) - matching CYInsideCollectionView
				let sortedPinned = pinnedPosts.sorted { ($0.pinnedAt ?? $0.createdAt) > ($1.pinnedAt ?? $1.createdAt) }
				
				// Sort unpinned posts by date (newest first) - matching CYInsideCollectionView
				let sortedUnpinned = unpinnedPosts.sorted { $0.createdAt > $1.createdAt }
				
				// Combine: pinned first, then unpinned - matching CYInsideCollectionView order
				let sortedPosts = sortedPinned + sortedUnpinned
				
				// Take first 4 posts for the grid (pinned first, then most recent)
				let displayPosts = Array(sortedPosts.prefix(4))
				#if VERBOSE_DEBUG
				print("✅ CollectionRowDesign: Displaying \(displayPosts.count) posts in preview grid (out of \(sortedPosts.count) total)")
				#endif
				
				// Log each post's details with image URL info
				for (index, post) in displayPosts.enumerated() {
					var foundImageURL: String? = nil
					// Check all mediaItems for image
					for mediaItem in post.mediaItems {
						if let thumbnail = mediaItem.thumbnailURL, !thumbnail.isEmpty {
							foundImageURL = thumbnail
							break
						}
						if foundImageURL == nil, let imgURL = mediaItem.imageURL, !imgURL.isEmpty {
							foundImageURL = imgURL
						}
					}
					if foundImageURL == nil {
						if let firstMedia = post.firstMediaItem {
							foundImageURL = firstMedia.thumbnailURL ?? firstMedia.imageURL
						}
					}
					#if VERBOSE_DEBUG
					print("   📸 Post \(index + 1): ID=\(post.id), imageURL=\(foundImageURL ?? "nil"), isPinned=\(post.isPinned), mediaItemsCount=\(post.mediaItems.count)")
					#endif
				}
				
				await MainActor.run {
					// Always cache the posts first to ensure persistence
					CollectionPostsCache.shared.setCachedPosts(displayPosts, for: collection.id)
					
					// Update previewPosts - this ensures they persist even if view refreshes
					previewPosts = displayPosts
					CollectionPostsCache.shared.setLoading(false, for: collection.id)
					postGridRefreshId = UUID() // Force UI refresh
					print("✅ CollectionRowDesign: Updated previewPosts array with \(displayPosts.count) posts")
					print("   🔍 Current previewPosts count: \(self.previewPosts.count)")
					print("   💾 Posts cached for collection '\(collection.name)' (ID: \(collection.id))")
					for (idx, post) in self.previewPosts.enumerated() {
						// Check what image URL will be used
						var foundImageURL: String? = nil
						for mediaItem in post.mediaItems {
							if let thumbnail = mediaItem.thumbnailURL, !thumbnail.isEmpty {
								foundImageURL = thumbnail
								break
							}
							if foundImageURL == nil, let imgURL = mediaItem.imageURL, !imgURL.isEmpty {
								foundImageURL = imgURL
							}
						}
						if foundImageURL == nil, let firstMedia = post.firstMediaItem {
							foundImageURL = firstMedia.thumbnailURL ?? firstMedia.imageURL
						}
						#if VERBOSE_DEBUG
						print("      Post \(idx): \(post.id), willDisplayImage=\(foundImageURL != nil ? "YES (\(foundImageURL!))" : "NO")")
					#endif
					}
				}
			} catch {
				print("❌ CollectionRowDesign: Error loading preview posts: \(error.localizedDescription)")
				await MainActor.run {
					previewPosts = []
					CollectionPostsCache.shared.setLoading(false, for: collection.id)
				}
			}
		}
	}
	
	// MARK: - Real-time Post Listener
	/// Set up real-time Firestore listener for posts in this collection
	/// This ensures preview posts update immediately when new posts are added
	private func setupPostListener() {
		// Remove existing listener if any
		postListener?.remove()
		
		let collectionId = collection.id
		let db = Firestore.firestore()
		
		// Set up real-time listener for the 4 most recent posts (for preview)
		// This ensures immediate updates when new posts are created
		// Note: We capture collectionId and collection.name as local constants since we can't use [weak self] with structs
		let currentCollectionId = collectionId
		let currentCollectionName = collection.name
		
		postListener = db.collection("posts")
			.whereField("collectionId", isEqualTo: collectionId)
			.order(by: "createdAt", descending: true)
			.limit(to: 4)
			.addSnapshotListener { snapshot, error in
				Task { @MainActor in
					if let error = error {
						print("❌ CollectionRowDesign: Error in post listener: \(error.localizedDescription)")
						return
					}
					
					guard let snapshot = snapshot else { return }
					
					// Only update if there are actual changes (new posts added)
					guard !snapshot.documentChanges.isEmpty else { return }
					
					// Check if any changes are additions (new posts)
					let hasNewPosts = snapshot.documentChanges.contains { $0.type == .added }
					
					if hasNewPosts {
						print("🔄 CollectionRowDesign: Real-time listener detected new post(s) in collection '\(currentCollectionName)', immediately updating preview")
						// Clear cache and post notification to trigger reload
						// Since we can't directly call loadPreviewPosts (struct limitation),
						// we post a notification that will be caught by the existing PostCreated handler
						CollectionPostsCache.shared.clearCache(for: currentCollectionId)
						NotificationCenter.default.post(
							name: Notification.Name("PostCreated"),
							object: nil,
							userInfo: ["collectionId": currentCollectionId]
						)
					}
				}
			}
	}
}

// MARK: - Static Factory Method for ID-based Creation
extension CollectionRowDesign {
	static func withId(_ collectionId: String) -> some View {
		// This is a placeholder that will be replaced by actual implementation
		// The actual view should fetch the collection data by ID
		Text("Collection \(collectionId)")
			.font(.headline)
	}
}

