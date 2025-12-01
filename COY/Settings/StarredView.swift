
import SwiftUI
import Combine
import SDWebImageSwiftUI
import FirebaseFirestore
import FirebaseAuth

struct StarredView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@StateObject private var viewModel = StarredViewModel()
	
	// Responsive 3-column grid that adapts to screen width
	private var columns: [GridItem] {
		let spacing: CGFloat = 2
		
		return [
			GridItem(.flexible(), spacing: spacing),
			GridItem(.flexible(), spacing: spacing),
			GridItem(.flexible(), spacing: spacing)
		]
	}
	
	var body: some View {
		PhoneSizeContainer {
			mainContentView
		}
		.background(backgroundColor)
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
		.navigationDestination(isPresented: Binding(
			get: { viewModel.selectedPostId != nil },
			set: { if !$0 { viewModel.selectedPostId = nil } }
		)) {
			if let postId = viewModel.selectedPostId,
			   let post = viewModel.starredPosts.first(where: { $0.id == postId }) {
				CYPostDetailView(post: post, collection: viewModel.getCollectionForPost(post))
			}
		}
		.onAppear {
			handleOnAppear()
			viewModel.setupRealtimeListener()
		}
		.onDisappear {
			viewModel.removeRealtimeListener()
		}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostStarred"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DismissPostDetail"))) { _ in
				viewModel.selectedPost = nil
				viewModel.selectedPostId = nil
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostUnstarred"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostHidden"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostUnhidden"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CurrentUserDidChange"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionAccessGranted"))) { _ in
				// Reload when access is granted to a collection
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionAccessDenied"))) { _ in
				// Reload when access is denied to a collection
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionUpdated"))) { _ in
				// Reload when a collection is updated (access might have changed)
				Task { await viewModel.loadStarredPosts() }
			}
	}
	
	private var backgroundColor: Color {
		colorScheme == .dark ? Color.black : Color.white
	}
	
	@ViewBuilder
	private var mainContentView: some View {
		VStack {
			headerView
			contentView
		}
	}
	
	@ViewBuilder
	private var headerView: some View {
		HStack {
			Button(action: { presentationMode.wrappedValue.dismiss() }) {
				Image(systemName: "chevron.backward")
					.font(.title2)
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			Spacer()
			Text("Starred")
				.font(.title2)
				.fontWeight(.bold)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Spacer()
			Button(action: { 
				Task { await viewModel.loadStarredPosts() }
			}) {
				Image(systemName: "arrow.clockwise")
					.font(.title2)
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
		}
		.padding(.top, 10)
		.padding(.horizontal)
	}
	
	@ViewBuilder
	private var contentView: some View {
		if viewModel.isLoading {
			loadingView
		} else if viewModel.starredPosts.isEmpty {
			emptyStateView
		} else {
			postsGridView
		}
	}
	
	@ViewBuilder
	private var loadingView: some View {
		Spacer()
		VStack(spacing: 16) {
			ProgressView()
				.progressViewStyle(CircularProgressViewStyle())
			Text("Loading starred posts...")
				.font(.subheadline)
				.foregroundColor(.gray)
		}
		Spacer()
	}
	
	@ViewBuilder
	private var emptyStateView: some View {
		Spacer()
		VStack(spacing: 16) {
			Image(systemName: "star")
				.resizable()
				.scaledToFit()
				.frame(width: 100, height: 100)
				.foregroundColor(.gray)
			Text("No Starred Posts")
				.font(.headline)
				.foregroundColor(.gray)
			Text("Posts you star will appear here.")
				.font(.subheadline)
				.foregroundColor(.gray)
				.multilineTextAlignment(.center)
		}
		Spacer()
	}
	
	@ViewBuilder
	private var postsGridView: some View {
		ScrollView {
			LazyVGrid(columns: columns, alignment: .center, spacing: 2) {
				ForEach(viewModel.starredPosts, id: \.id) { post in
					Button(action: {
						Task {
							// Ensure collection is loaded first
							await viewModel.loadCollectionForPost(post)
							// Verify collection is loaded before navigating
							let collection = viewModel.getCollectionForPost(post)
							guard !collection.id.isEmpty else {
								print("⚠️ StarredView: Collection not loaded for post \(post.id), skipping navigation")
								return
							}
							// Set the selected post ID to trigger navigation
							await MainActor.run {
								viewModel.selectedPost = post
								viewModel.selectedPostId = post.id
							}
						}
					}) {
						StarredPostThumbnail(post: post)
					}
					.buttonStyle(PlainButtonStyle())
				}
			}
			.padding(.top, 16)
			.frame(maxWidth: .infinity)
		}
	}
	
	private func handleOnAppear() {
		Task {
			// Add timeout to prevent infinite loading
			await withTaskGroup(of: Void.self) { group in
				group.addTask {
					await viewModel.loadStarredPosts()
				}
				
				group.addTask {
					try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 second timeout
					print("⚠️ StarredView loading timeout reached")
				}
				
				await group.next()
				group.cancelAll()
			}
		}
	}
}

@MainActor
class StarredViewModel: ObservableObject {
	@Published var starredPosts: [CollectionPost] = []
	@Published var isLoading = false
	@Published var selectedPost: CollectionPost? = nil
	@Published var selectedPostId: String? = nil
	
	private var collectionsCache: [String: CollectionData] = [:]
	private var userListener: ListenerRegistration?
	
	func loadStarredPosts() async {
		isLoading = true
		defer { isLoading = false }
		
		let starredPostIds = CYServiceManager.shared.getStarredPostIds()
		
		if starredPostIds.isEmpty {
			starredPosts = []
			return
		}
		
		let _ = CYServiceManager.shared.getBlockedUsers() // Track blocked users for filtering
		let hiddenPostIds = Set(CYServiceManager.shared.currentUser?.hiddenPostIds ?? [])
		
		// Load posts with their starredAt timestamps in parallel
		guard let userId = Auth.auth().currentUser?.uid else {
			starredPosts = []
			return
		}
		
		let db = Firestore.firestore()
		let postsWithStarredDates = await withTaskGroup(of: (CollectionPost?, Date?, Bool).self) { group in
			var results: [(post: CollectionPost, starredAt: Date)] = []
			
			for postId in starredPostIds {
				group.addTask {
					// Load post, starredAt timestamp, and collection in parallel
					async let postTask = self.withTimeout(seconds: 10) {
						try? await CollectionService.shared.getPostById(postId: postId)
					}
					
					async let starredAtTask: Date? = {
						do {
							let starDoc = try await db.collection("posts")
								.document(postId)
								.collection("stars")
								.document(userId)
								.getDocument()
							
							if let data = starDoc.data(),
							   let timestamp = data["starredAt"] as? Timestamp {
								return timestamp.dateValue()
							}
						} catch {
							print("Error loading starredAt for post \(postId): \(error)")
						}
						return nil
					}()
					
					let post = await postTask
					let starredAt = await starredAtTask
					
					// Load collection to check access (only if post was loaded successfully)
					var hasAccess = false
					if let post = post {
						if let collection = try? await CollectionService.shared.getCollection(collectionId: post.collectionId) {
							hasAccess = CollectionService.canUserViewCollection(collection, userId: userId)
						}
					}
					
					return (post, starredAt, hasAccess)
				}
			}
			
			for await (post, starredAt, hasAccess) in group {
				if let post = post {
					// Filter out posts from collections the user doesn't have access to
					// Also filter out hidden posts
					if hasAccess && !hiddenPostIds.contains(post.id) {
						// Use starredAt if available, otherwise fall back to post creation date
						let sortDate = starredAt ?? post.createdAt
						results.append((post: post, starredAt: sortDate))
					}
				}
			}
			
			return results
		}
		
		// Sort by starredAt date (most recently starred first)
		let sortedPosts = postsWithStarredDates
			.sorted { $0.starredAt > $1.starredAt }
			.map { $0.post }
		
		starredPosts = sortedPosts
	}
	
	// Helper function for timeout protection
	private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T?) async -> T? {
		return await withTaskGroup(of: T?.self) { group in
			group.addTask {
				try? await operation()
			}
			
			group.addTask {
				try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				return nil
			}
			
			let result = await group.next()
			group.cancelAll()
			return result ?? nil
		}
	}
	
	func loadCollectionForPost(_ post: CollectionPost) async {
		// Check cache first
		if collectionsCache[post.collectionId] != nil {
			return
		}
		
		// Load actual collection from Firebase
		do {
			if let collection = try await CollectionService.shared.getCollection(collectionId: post.collectionId) {
				await MainActor.run {
					collectionsCache[post.collectionId] = collection
				}
			}
		} catch {
			print("Error loading collection for post: \(error)")
		}
	}
	
	func getCollectionForPost(_ post: CollectionPost) -> CollectionData {
		if let cached = collectionsCache[post.collectionId] {
			return cached
		}
		
		// Return a basic collection structure as fallback
		let collection = CollectionData(
			id: post.collectionId,
			name: "Collection",
			description: "",
			type: "individual",
			isPublic: true,
			ownerId: post.authorId,
			ownerName: post.authorName,
			owners: [post.authorId],
			imageURL: "",
			invitedUsers: [],
			members: [],
			memberCount: 1,
			followers: [],
			followerCount: 0,
			allowedUsers: [],
			deniedUsers: [],
			createdAt: Date()
		)
		
		collectionsCache[post.collectionId] = collection
		return collection
	}
	
	// MARK: - Real-time Listener
	func setupRealtimeListener() {
		guard let userId = Auth.auth().currentUser?.uid else { return }
		
		// Remove existing listener
		userListener?.remove()
		
		let db = Firestore.firestore()
		// Listen to user document changes for starredPostIds
		userListener = db.collection("users").document(userId)
			.addSnapshotListener { [weak self] snapshot, error in
				guard let self = self else { return }
				
				if let error = error {
					print("❌ StarredViewModel: Error listening to user document: \(error.localizedDescription)")
					return
				}
				
				guard let data = snapshot?.data(),
					  let starredPostIds = data["starredPostIds"] as? [String] else {
					return
				}
				
				// Check if starredPostIds changed
				let currentPostIds = Set(self.starredPosts.map { $0.id })
				let newPostIds = Set(starredPostIds)
				
				if currentPostIds != newPostIds {
					print("🔄 StarredViewModel: Starred posts changed, reloading...")
					Task {
						await self.loadStarredPosts()
					}
				}
			}
	}
	
	func removeRealtimeListener() {
		userListener?.remove()
		userListener = nil
	}
}

struct StarredPostThumbnail: View {
	let post: CollectionPost
	@Environment(\.colorScheme) var colorScheme
	
	// Computed property to check if post author is blocked
	private var isPostAuthorBlocked: Bool {
		return CYServiceManager.shared.currentUser?.blockedUsers.contains(post.authorId) ?? false
	}
	
	// Get image URL from post (prioritize thumbnail, then image)
	private var imageURL: String? {
		// First try to find thumbnailURL from any mediaItem
		for mediaItem in post.mediaItems {
			if let thumbnail = mediaItem.thumbnailURL, !thumbnail.isEmpty {
				return thumbnail
			}
		}
		
		// If no thumbnail found, try to find imageURL
		for mediaItem in post.mediaItems {
			if let imgURL = mediaItem.imageURL, !imgURL.isEmpty {
				return imgURL
			}
		}
		
		// Fallback to firstMediaItem
		if let firstMedia = post.firstMediaItem {
			return firstMedia.thumbnailURL ?? firstMedia.imageURL
		}
		
		return nil
	}
	
	// Check if post has video
	private var hasVideo: Bool {
		return post.mediaItems.contains { $0.isVideo }
	}
	
	// Get video duration
	private var videoDuration: Double? {
		return post.mediaItems.first(where: { $0.isVideo })?.videoDuration
	}
	
	var body: some View {
		GeometryReader { geometry in
			let width = geometry.size.width
			let height = width * 1.35 // Make it taller (approximately 3:4 aspect ratio)
			
			ZStack(alignment: .topLeading) {
				// Post thumbnail
				if let finalImageURL = imageURL, !finalImageURL.isEmpty, let url = URL(string: finalImageURL) {
					WebImage(url: url)
						.resizable()
						.indicator(.activity)
						.transition(.fade(duration: 0.2))
						.aspectRatio(contentMode: .fill)
						.frame(width: width, height: height)
						.clipped()
				} else {
					// Fallback
					Rectangle()
						.fill(Color.gray.opacity(0.3))
						.frame(width: width, height: height)
				}
				
				// Video duration overlay (top-left corner)
				if hasVideo, let duration = videoDuration {
					VStack {
						HStack {
							Text(formatDuration(duration))
								.font(.caption2)
								.fontWeight(.semibold)
								.foregroundColor(.white)
								.padding(.horizontal, 6)
								.padding(.vertical, 3)
								.background(Color.black.opacity(0.7))
								.cornerRadius(4)
								.padding(8)
							Spacer()
						}
						Spacer()
					}
				}
				
				// Blocked user overlay
				blockedUserOverlay(size: width, height: height)
			}
			.cornerRadius(4)
		}
		.aspectRatio(1.0 / 1.35, contentMode: .fit) // Taller aspect ratio (approximately 3:4)
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { _ in
			// Trigger view update when user is blocked
			_ = isPostAuthorBlocked
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
			// Trigger view update when user is unblocked
			_ = isPostAuthorBlocked
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CurrentUserDidChange"))) { _ in
			// Trigger view update when current user changes
			_ = isPostAuthorBlocked
		}
	}
	
	@ViewBuilder
	private func blockedUserOverlay(size: CGFloat, height: CGFloat) -> some View {
		if isPostAuthorBlocked {
			Rectangle()
				.fill(.ultraThinMaterial)
				.overlay(
					VStack(spacing: 4) {
						Image(systemName: "hand.raised.fill")
							.font(.system(size: 16, weight: .semibold))
							.foregroundColor(.white)
						Text("Blocked")
							.font(.caption2)
							.fontWeight(.semibold)
							.foregroundColor(.white)
					}
				)
				.frame(width: size, height: height)
				.cornerRadius(4)
				.allowsHitTesting(false)
		}
	}
	
	private func formatDuration(_ duration: Double) -> String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}

