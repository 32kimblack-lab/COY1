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
	@State private var previewPosts: [CollectionPost] = []
	@State private var ownerProfileImageURL: String? // Store owner's profile image URL
	@State private var postGridRefreshId = UUID() // Force refresh when posts change
	@State private var postListener: ListenerRegistration? // Firestore listener for real-time updates
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Header: Image + Name + Buttons
			HStack(spacing: 12) {
				// Profile Image Placeholder
				profileImageView
				
				// Name + Type/Members
				VStack(alignment: .leading, spacing: 4) {
					HStack {
						Text(collection.name)
							.font(.headline)
							.foregroundColor(.primary)
						
						// Follow button (next to collection name)
						if !isMember && !isOwner {
							followButton
						}
					}
					
					Text(memberLabel)
						.font(.caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
				
				// Lock icon for private collections (positioned before action button)
				if !collection.isPublic {
					Image(systemName: "lock.fill")
						.foregroundColor(.primary)
				}
				
				// Action Buttons (Request/Join button on the right)
				if shouldShowActionButton {
					actionButton
						.zIndex(1) // Ensure button is on top layer
				}
			}
			.padding(.horizontal)
			
			// Description
			if !collection.description.isEmpty {
				Text(collection.description)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(2)
					.padding(.horizontal)
			}
			
			// Grid with actual post images
			postGrid
		}
		.onAppear {
			// Always check cache first and use it if available
			if let cached = CollectionPostsCache.shared.getCachedPosts(for: collection.id), !cached.isEmpty {
				// Use cached posts immediately - don't reload
				previewPosts = cached
				print("✅ CollectionRowDesign: Using cached posts for collection '\(collection.name)' (ID: \(collection.id)) - \(cached.count) posts")
			} else if previewPosts.isEmpty {
				// Only load if we have no posts at all (neither cached nor in state)
				// This ensures posts are always loaded, even for deleted collections
				print("🔄 CollectionRowDesign: No cached posts found, loading for collection '\(collection.name)' (ID: \(collection.id))")
				loadPreviewPosts()
			} else {
				// If we have posts in state but no cache, update cache to persist them
				CollectionPostsCache.shared.setCachedPosts(previewPosts, for: collection.id)
				print("✅ CollectionRowDesign: Persisting existing posts to cache for collection '\(collection.name)' (ID: \(collection.id)) - \(previewPosts.count) posts")
			}
			// Set up real-time listener for posts in this collection
			setupPostListener()
		}
		.onChange(of: collection.id) { oldId, newId in
			// Reload posts when collection changes
			if oldId != newId {
				print("🔄 CollectionRowDesign: Collection ID changed from \(oldId) to \(newId), reloading posts")
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
			// Reload posts when a new post is created in this collection
			// Check both object and userInfo for collectionId
			var createdCollectionId: String?
			if let id = notification.object as? String {
				createdCollectionId = id
			} else if let userInfo = notification.userInfo,
					  let id = userInfo["collectionId"] as? String {
				createdCollectionId = id
			}
			
			if let collectionId = createdCollectionId,
			   collectionId == collection.id {
				print("🔄 CollectionRowDesign: New post created in collection '\(collection.name)', reloading preview posts")
				// Clear cache immediately so all users see the update
				CollectionPostsCache.shared.clearCache(for: collection.id)
				loadPreviewPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostDeleted"))) { notification in
			// Reload posts when a post is deleted from this collection
			if let userInfo = notification.userInfo,
			   let deletedCollectionId = userInfo["collectionId"] as? String,
			   deletedCollectionId == collection.id {
				print("🔄 CollectionRowDesign: Post deleted from collection '\(collection.name)', reloading preview posts")
				CollectionPostsCache.shared.clearCache(for: collection.id)
				loadPreviewPosts(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionPostsUpdated"))) { notification in
			// Reload posts when real-time listener detects changes
			if let updatedCollectionId = notification.object as? String,
			   updatedCollectionId == collection.id {
				print("🔄 CollectionRowDesign: Real-time posts update for collection '\(collection.name)', reloading preview posts")
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
				print("🔄 CollectionRowDesign: Collection '\(collection.name)' was deleted, ensuring posts are cached")
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
					print("🔄 CollectionRowDesign: App returned to foreground, no cache found, reloading posts for '\(collection.name)' (ID: \(collection.id))")
					loadPreviewPosts(forceRefresh: true)
				}
			} else {
				// We have posts, ensure they're cached for next time
				CollectionPostsCache.shared.setCachedPosts(previewPosts, for: collection.id)
				print("✅ CollectionRowDesign: Ensured posts are cached after app return for '\(collection.name)' - \(previewPosts.count) posts")
			}
		}
		.onDisappear {
			// Clean up listener when view disappears
			postListener?.remove()
			postListener = nil
		}
		.onDisappear {
			// Clean up listener when view disappears
			postListener?.remove()
			postListener = nil
		}
	}
	
	// MARK: - Profile Image
	private var profileImageView: some View {
		Button(action: onProfileTapped) {
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				// Use collection's profile image if available
				CachedProfileImageView(url: imageURL, size: 50)
					.clipShape(Circle())
			} else {
				// Use owner's profile image as fallback (not current user's)
				if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty {
					CachedProfileImageView(url: ownerImageURL, size: 50)
						.clipShape(Circle())
				} else {
					// Fallback to default icon if owner has no profile image
					DefaultProfileImageView(size: 50)
				}
			}
		}
		.buttonStyle(.plain)
		.onAppear {
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
			Circle()
				.fill(isFollowing ? Color.blue : Color(.systemGray4))
				.frame(width: 28, height: 28)
				.overlay(
					Image(systemName: isFollowing ? "checkmark" : "plus")
						.font(.caption)
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
		Button(action: {
			// Explicitly call the action handler
			print("🔘 CollectionRowDesign: Action button tapped - \(actionButtonText)")
			onActionTapped()
		}) {
			Text(actionButtonText)
				.font(.subheadline)
				.fontWeight(.medium)
				.foregroundColor(actionButtonTextColor)
				.padding(.horizontal, 12)
				.padding(.vertical, 6)
				.background(actionButtonBackground)
				.cornerRadius(6)
				.overlay(
					RoundedRectangle(cornerRadius: 6)
						.stroke(actionButtonBorderColor, lineWidth: 1)
				)
		}
		.buttonStyle(.plain)
		.allowsHitTesting(true)
		.contentShape(Rectangle())
		.highPriorityGesture(
			TapGesture().onEnded {
				print("🔘 CollectionRowDesign: High priority gesture - \(actionButtonText)")
				onActionTapped()
			}
		)
	}
	
	private var actionButtonText: String {
		switch collection.type {
		case "Request":
			// Should not reach here if user is member/owner (button shouldn't show)
			// But handle it just in case
			if isMember || isOwner {
				return "" // Shouldn't show, but return empty if it does
			}
			return hasRequested ? "Requested" : "Request"
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
		if collection.type == "Request" && hasRequested {
			return .blue
		}
		return .primary
	}
	
	private var actionButtonBackground: Color {
		if collection.type == "Request" && hasRequested {
			return .blue.opacity(0.1)
		}
		return Color(.systemGray6)
	}
	
	private var actionButtonBorderColor: Color {
		if collection.type == "Request" && hasRequested {
			return .blue
		}
		return .clear
	}
	
	// MARK: - Post Grid
	private var postGrid: some View {
		Button(action: onCollectionTapped) {
		HStack(spacing: 8) {
			ForEach(0..<4, id: \.self) { idx in
				if idx < previewPosts.count {
					let post = previewPosts[idx]
					postThumbnailView(post: post, index: idx)
				} else {
					// Show gray placeholder
					Rectangle()
						.fill(Color.gray.opacity(0.3))
						.frame(width: 90, height: 130)
						.clipped()
						.id("placeholder_\(idx)")
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 20)
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
	private func postThumbnailView(post: CollectionPost, index: Int) -> some View {
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
					.frame(width: 90, height: 130)
					.clipped()
					.cornerRadius(0)
					.id("post_\(post.id)_\(index)_\(finalImageURL)")
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.3))
					.frame(width: 90, height: 130)
					.clipped()
					.id("post_\(post.id)_\(index)_empty")
			}
			
			// Video timer overlay (top right corner) - matching PinterestPostGrid style
			if hasVideo, let duration = videoDuration {
				VStack {
					HStack {
						Spacer()
						Text(formatVideoDuration(duration))
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
		.frame(width: 90, height: 130)
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
		
		// Don't reload if already loading
		if CollectionPostsCache.shared.isLoading(for: collectionId) {
			print("⏭️ CollectionRowDesign: Already loading posts for collection '\(collection.name)' (ID: \(collectionId)), skipping")
			return
		}
		
		// If we have cached posts and not forcing refresh, use cache
		if !forceRefresh, let cached = CollectionPostsCache.shared.getCachedPosts(for: collectionId), !cached.isEmpty {
			previewPosts = cached
			print("⏭️ CollectionRowDesign: Using cached posts for collection '\(collection.name)' (ID: \(collectionId)) - \(cached.count) posts")
			return 
		}
		
		// Only clear existing posts if forcing refresh AND we have no posts in state
		// This prevents clearing posts that are already displayed
		if forceRefresh && previewPosts.isEmpty {
			CollectionPostsCache.shared.clearCache(for: collectionId)
		}
		
		CollectionPostsCache.shared.setLoading(true, for: collectionId)
		print("🔄 CollectionRowDesign: Starting to load preview posts for collection '\(collection.name)' (ID: \(collectionId))")
		
		Task {
			do {
				// Fetch posts from collection (prioritize pinned, then most recent)
				var allPosts = try await CollectionService.shared.getCollectionPostsFromFirebase(collectionId: collection.id)
				print("📦 CollectionRowDesign: Fetched \(allPosts.count) posts from Firebase")
				
				// For deleted collections, skip filtering - user should see all posts
				// For regular collections, filter out posts from hidden collections and blocked users
				if !isDeletedCollection {
				allPosts = await CollectionService.filterPosts(allPosts)
				print("📦 CollectionRowDesign: After filtering: \(allPosts.count) posts remaining")
				} else {
					print("📦 CollectionRowDesign: Skipping filtering for deleted collection - showing all \(allPosts.count) posts")
				}
				
				// Sort EXACTLY like CYInsideCollectionView: pinned first (by pinnedAt, most recent first), then by date (newest first)
				// Separate pinned and unpinned posts
				let pinnedPosts = allPosts.filter { $0.isPinned }
				let unpinnedPosts = allPosts.filter { !$0.isPinned }
				
				// Sort pinned posts by pinnedAt (most recently pinned first)
				let sortedPinned = pinnedPosts.sorted { post1, post2 in
						let date1 = post1.pinnedAt ?? post1.createdAt
						let date2 = post2.pinnedAt ?? post2.createdAt
					return date1 > date2 // Most recent first
				}
				
				// Sort unpinned posts by date (newest first) - matching CYInsideCollectionView default "Newest to Oldest"
				let sortedUnpinned = unpinnedPosts.sorted { $0.createdAt > $1.createdAt }
				
				// Combine: pinned first, then unpinned
				let sortedPosts = sortedPinned + sortedUnpinned
				
				// Take first 4 posts for the grid (pinned first, then most recent)
				let displayPosts = Array(sortedPosts.prefix(4))
				print("✅ CollectionRowDesign: Displaying \(displayPosts.count) posts in preview grid (out of \(sortedPosts.count) total)")
				
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
					print("   📸 Post \(index + 1): ID=\(post.id), imageURL=\(foundImageURL ?? "nil"), isPinned=\(post.isPinned), mediaItemsCount=\(post.mediaItems.count)")
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
						print("      Post \(idx): \(post.id), willDisplayImage=\(foundImageURL != nil ? "YES (\(foundImageURL!))" : "NO")")
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
	private func setupPostListener() {
		// Remove existing listener
		postListener?.remove()
		
		let db = Firestore.firestore()
		// Listen to posts in this collection for real-time updates
		postListener = db.collection("posts")
			.whereField("collectionId", isEqualTo: collection.id)
			.order(by: "isPinned", descending: true)
			.order(by: "createdAt", descending: true)
			.limit(to: 4)
			.addSnapshotListener { [collection] snapshot, error in
				guard let snapshot = snapshot, error == nil else {
					if let error = error {
						print("❌ CollectionRowDesign: Error listening to posts: \(error.localizedDescription)")
					}
					return
				}
				
				// Only reload if there are actual changes (not just initial load)
				if !snapshot.documentChanges.isEmpty {
					print("🔄 CollectionRowDesign: Real-time update detected for collection '\(collection.name)', reloading preview posts")
					// Clear cache and reload
					CollectionPostsCache.shared.clearCache(for: collection.id)
					Task { @MainActor in
						// Small delay to ensure Firestore has the latest data
						try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
						// Trigger reload via notification
						NotificationCenter.default.post(
							name: Notification.Name("CollectionPostsUpdated"),
							object: collection.id
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

