import SwiftUI
import Combine

struct StarredView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@StateObject private var viewModel = StarredViewModel()
	
	private let columns = [
		GridItem(.fixed(135)),
		GridItem(.fixed(135)),
		GridItem(.fixed(135))
	]
	
	var body: some View {
		mainContentView
			.background(backgroundColor)
			.navigationBarBackButtonHidden(true)
			.navigationTitle("")
			.toolbar(.hidden, for: .tabBar)
			.onAppear {
				handleOnAppear()
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("PostStarred"))) { _ in
				Task { await viewModel.loadStarredPosts() }
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DismissPostDetail"))) { _ in
				viewModel.selectedPost = nil
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
			Text("Star")
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
			LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
				ForEach(viewModel.starredPosts, id: \.id) { post in
					Button(action: {
						Task {
							// Load the actual collection for this post
							await viewModel.loadCollectionForPost(post)
							await MainActor.run {
								viewModel.selectedPost = post
							}
						}
					}) {
						StarredPostThumbnail(post: post)
							.frame(width: 135, height: 200)
					}
					.buttonStyle(PlainButtonStyle())
				}
			}
			.padding(.horizontal, 16)
			.padding(.top, 16)
			.frame(maxWidth: .infinity)
		}
		.sheet(item: $viewModel.selectedPost) { post in
			PostDetailView(post: post, collection: viewModel.getCollectionForPost(post))
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
	
	private var collectionsCache: [String: CollectionData] = [:]
	
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
		
		// Load posts in parallel with timeout protection
		let posts = await withTaskGroup(of: CollectionPost?.self) { group in
			var results: [CollectionPost] = []
			
			for postId in starredPostIds {
				group.addTask {
					// Add timeout protection to prevent hanging
					return await self.withTimeout(seconds: 10) {
						try? await CollectionService.shared.getPostById(postId: postId)
					}
				}
			}
			
			for await post in group {
				if let post = post {
					// Include all starred posts (including own posts and blocked users)
					// Blocked users' posts will show with "User is blocked" overlay
					// Filter out hidden posts only
					if !hiddenPostIds.contains(post.id) {
						results.append(post)
					}
				}
			}
			
			return results
		}
		
		// Sort by creation date (most recent first)
		let sortedPosts = posts.sorted { $0.createdAt > $1.createdAt }
		
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
		
		// Load actual collection from backend
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
}

struct StarredPostThumbnail: View {
	let post: CollectionPost
	@Environment(\.colorScheme) var colorScheme
	
	// Computed property to check if post author is blocked
	private var isPostAuthorBlocked: Bool {
		return CYServiceManager.shared.currentUser?.blockedUsers.contains(post.authorId) ?? false
	}
	
	var body: some View {
		ZStack(alignment: .topLeading) {
			// Post thumbnail
			if let firstMediaItem = post.firstMediaItem {
				if firstMediaItem.isVideo {
					// Video thumbnail
					AsyncImage(url: URL(string: firstMediaItem.thumbnailURL ?? "")) { image in
						image
							.resizable()
							.aspectRatio(contentMode: .fill)
					} placeholder: {
						Rectangle()
							.fill(Color.gray.opacity(0.3))
					}
					.frame(width: 135, height: 200)
					.clipped()
					.overlay(
						// Video duration overlay
						VStack {
							HStack {
								if let duration = firstMediaItem.videoDuration {
									Text(formatDuration(duration))
										.font(.caption2)
										.foregroundColor(.white)
										.padding(.horizontal, 6)
										.padding(.vertical, 2)
										.background(Color.black.opacity(0.6))
										.cornerRadius(4)
								}
								Spacer()
							}
							Spacer()
						}
						.padding(8)
					)
				} else {
					// Image
					AsyncImage(url: URL(string: firstMediaItem.imageURL ?? "")) { image in
						image
							.resizable()
							.aspectRatio(contentMode: .fill)
					} placeholder: {
						Rectangle()
							.fill(Color.gray.opacity(0.3))
					}
					.frame(width: 135, height: 200)
					.clipped()
				}
			} else {
				// Fallback
				Rectangle()
					.fill(Color.gray.opacity(0.3))
					.frame(width: 135, height: 200)
			}
			
			// Blocked user overlay
			blockedUserOverlay
		}
		.cornerRadius(8)
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
	private var blockedUserOverlay: some View {
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
				.frame(width: 135, height: 200)
				.cornerRadius(8)
				.allowsHitTesting(false)
		}
	}
	
	private func formatDuration(_ duration: Double) -> String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}

