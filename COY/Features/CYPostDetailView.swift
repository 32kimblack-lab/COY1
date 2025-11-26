import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import AVKit
import AVFoundation
import FirebaseAuth
import FirebaseFirestore
import Combine

struct CYPostDetailView: View {
	let post: CollectionPost
	let collection: CollectionData?
	
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var currentMediaIndex: Int = 0
	@State private var isStarred: Bool = false
	@State private var commentCount: Int = 0
	@State private var showComments: Bool = false
	@State private var showShare: Bool = false
	@State private var showStarredBy: Bool = false
	@State private var showTags: Bool = false
	@State private var showMenu: Bool = false
	@State private var showEditPost: Bool = false
	@State private var showReport: Bool = false
	@State private var showDeleteAlert: Bool = false
	@State private var isDeleting: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@State private var elapsedTimes: [Int: Double] = [:]
	@State private var timeObservers: [Int: AnyCancellable] = [:]
	@State private var userDownloadEnabled: Bool = false
	@State private var taggedUsers: [UserService.AppUser] = []
	@State private var collectionOwner: UserService.AppUser?
	@State private var maxMediaHeight: CGFloat = {
		// Initialize with 55% of screen height as default, will be recalculated based on content
		let screenHeight = UIScreen.main.bounds.height
		return screenHeight * 0.55
	}()
	
	private let screenWidth: CGFloat = UIScreen.main.bounds.width
	private var backgroundColor: Color { colorScheme == .dark ? .black : .white }
	
	// Check if this is the current user's post
	private var isOwnPost: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return post.authorId == currentUserId
	}
	
	// Check if post author allows downloads
	private var canShowDownload: Bool {
		post.allowDownload && userDownloadEnabled
	}
	
	var body: some View {
		NavigationView {
			ZStack {
				backgroundColor.ignoresSafeArea()
				
				VStack(spacing: 0) {
					Color.clear.frame(height: 50)
					pagerView
				}
				
				VStack {
					headerView
					Spacer()
				}
				.zIndex(999)
			}
			.navigationBarBackButtonHidden(true)
			.navigationTitle("")
			.toolbar(.hidden, for: .tabBar)
			.ignoresSafeArea(.container, edges: .bottom)
			.sheet(isPresented: $showComments) {
				CommentsView(post: post)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showShare) {
				SharePostView(post: post)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showStarredBy) {
				StarredByView(postId: post.id)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showTags) {
				TagsView(taggedUsers: taggedUsers)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showReport) {
				ReportView(itemId: post.id, itemType: .post, itemName: post.title.isEmpty ? "Post" : post.title)
					.environmentObject(authService)
			}
			.sheet(isPresented: $showEditPost) {
				EditPostView(post: post, collection: collection)
					.environmentObject(authService)
			}
			.alert("Delete Post", isPresented: $showDeleteAlert) {
				Button("Cancel", role: .cancel) { }
				Button("Delete", role: .destructive) {
					Task {
						await deletePost()
					}
				}
			} message: {
				Text("Are you sure you want to delete this post? This action cannot be undone.")
			}
		}
		.onAppear {
			loadInitialData()
			setupListeners()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostUpdated"))) { notification in
			if let updatedPostId = notification.object as? String, updatedPostId == post.id {
				// Reload post data when post is updated
				loadInitialData()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostDeleted"))) { notification in
			if let deletedPostId = notification.object as? String, deletedPostId == post.id {
				// Dismiss view when post is deleted
				dismiss()
			}
		}
		.task {
			await calculateMaxMediaHeight()
		}
		.onDisappear {
			pauseAllVideos()
			cleanupTimeObservers()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostStarred"))) { notification in
			if (notification.object as? String) == post.id {
				isStarred = true
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostUnstarred"))) { notification in
			if (notification.object as? String) == post.id {
				isStarred = false
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentAdded"))) { notification in
			if (notification.object as? String) == post.id {
				// Real-time listener will update automatically, but we can also refresh here
				Task {
					do {
						commentCount = try await PostService.shared.getCommentCount(postId: post.id)
					} catch {
						print("Error updating comment count: \(error)")
					}
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentDeleted"))) { notification in
			if (notification.object as? String) == post.id {
				Task {
					do {
						commentCount = try await PostService.shared.getCommentCount(postId: post.id)
					} catch {
						print("Error updating comment count: \(error)")
					}
				}
			}
		}
	}
	
	// MARK: - Header View
	@ViewBuilder
	private var headerView: some View {
		HStack {
			Button(action: {
				dismiss()
			}) {
				Image(systemName: "chevron.backward")
					.font(.system(size: 18))
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			
			Spacer()
			
			if let collection = collection {
				Text(collection.name)
					.font(.system(size: 16, weight: .semibold))
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			
			Spacer()
			
			Button(action: {
				showMenu.toggle()
			}) {
				Image(systemName: "ellipsis")
					.font(.system(size: 18))
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			.confirmationDialog("", isPresented: $showMenu, titleVisibility: .hidden) {
				if canShowDownload {
					Button("Download") {
						Task {
							await handleDownload()
						}
					}
				}
				
				if isOwnPost {
					Button("Edit") {
						showEditPost = true
					}
					
					Button("Delete", role: .destructive) {
						showDeleteAlert = true
					}
				} else {
					Button("Report", role: .destructive) {
						showReport = true
					}
				}
			}
		}
		.padding()
	}
	
	// MARK: - Pager View
	@ViewBuilder
	private var pagerView: some View {
		GeometryReader { geo in
			ScrollView {
				VStack(spacing: 0) {
					VStack(spacing: 0) {
						mediaContentView
							.frame(maxWidth: geo.size.width)
							.frame(height: actualMediaHeight) // Use actual calculated height
					}
					
					postBottomControls
					Spacer(minLength: 100)
				}
			}
		}
		.padding(.top)
	}
	
	// Calculate actual media height
	// ALL posts (single and multi-media) are capped at 55% of screen height
	private var actualMediaHeight: CGFloat {
		if post.mediaItems.isEmpty {
			let maxAllowed = UIScreen.main.bounds.height * 0.55
			return maxAllowed
		}
		
		// Calculate natural height for the tallest item
		var tallestHeight: CGFloat = 0
		for mediaItem in post.mediaItems {
			let height = calculateHeight(for: mediaItem)
			tallestHeight = max(tallestHeight, height)
		}
		
		// ALWAYS cap at 55% of screen height (for both single and multi-media posts)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		return min(tallestHeight, maxAllowed)
	}
	
	// Check if content needs to scale down (exceeds 55%)
	private var needsScaling: Bool {
		if post.mediaItems.isEmpty {
			return false
		}
		
		var tallestHeight: CGFloat = 0
		for mediaItem in post.mediaItems {
			let height = calculateHeight(for: mediaItem)
			tallestHeight = max(tallestHeight, height)
		}
		
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		return tallestHeight > maxAllowed
	}
	
	// MARK: - Media Content View
	@ViewBuilder
	private var mediaContentView: some View {
		// Calculate container height: tallest item's height, capped at 55%
		let tallestNaturalHeight: CGFloat = {
			if post.mediaItems.isEmpty {
				return UIScreen.main.bounds.height * 0.55
			}
			var tallest: CGFloat = 0
			for mediaItem in post.mediaItems {
				tallest = max(tallest, calculateHeight(for: mediaItem))
			}
			let maxAllowed = UIScreen.main.bounds.height * 0.55
			return min(tallest, maxAllowed)
		}()
		
		let containerHeight = tallestNaturalHeight
		
		ZStack(alignment: .center) {
			// Media carousel - each item displays at its natural height
			TabView(selection: $currentMediaIndex) {
				ForEach(0..<post.mediaItems.count, id: \.self) { index in
					mediaView(mediaItem: post.mediaItems[index], index: index, containerHeight: containerHeight)
						.tag(index)
				}
			}
			.tabViewStyle(.page)
			.frame(maxWidth: .infinity)
			.frame(height: containerHeight) // Container height (tallest item, capped at 55%)
			.onChange(of: currentMediaIndex) { oldValue, newValue in
				handleMediaIndexChange(from: oldValue, to: newValue)
			}
			
			// Page indicator (top right, like CYInsidepicture)
			if post.mediaItems.count > 1 {
				VStack {
					HStack {
						Spacer()
						Text("\(currentMediaIndex + 1)/\(post.mediaItems.count)")
							.font(.caption)
							.fontWeight(.semibold)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
							.foregroundColor(.primary)
							.padding(.top, 12)
							.padding(.trailing, 12)
							.animation(.easeInOut(duration: 0.2), value: currentMediaIndex)
					}
					Spacer()
				}
				.allowsHitTesting(false)
			}
		}
		.frame(maxWidth: .infinity)
		.animation(.easeInOut(duration: 0.08), value: currentMediaIndex)
	}
	
	// MARK: - Blur Background
	@ViewBuilder
	private func blurBackgroundView(height: CGFloat) -> some View {
		if currentMediaIndex < post.mediaItems.count {
			let currentMedia = post.mediaItems[currentMediaIndex]
			if let imageURL = currentMedia.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: screenWidth, height: height)
					.blur(radius: 20)
					.opacity(0.6)
			} else if let thumbnailURL = currentMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: screenWidth, height: height)
					.blur(radius: 20)
					.opacity(0.6)
			} else {
				LinearGradient(
					colors: colorScheme == .dark ? 
						[Color.white.opacity(0.3), Color.white.opacity(0.1)] :
						[Color.black.opacity(0.3), Color.black.opacity(0.1)],
					startPoint: .top,
					endPoint: .bottom
				)
				.frame(height: height)
			}
		} else {
			LinearGradient(
				colors: colorScheme == .dark ? 
					[Color.white.opacity(0.3), Color.white.opacity(0.1)] :
					[Color.black.opacity(0.3), Color.black.opacity(0.1)],
				startPoint: .top,
				endPoint: .bottom
			)
			.frame(height: height)
		}
	}
	
	// MARK: - Post Bottom Controls
	@ViewBuilder
	private var postBottomControls: some View {
		VStack(spacing: 12) {
			HStack {
				HStack(spacing: 12) {
					Button(action: {
						if isOwnPost {
							showStarredBy = true
						} else {
							Task {
								await toggleStar()
							}
						}
					}) {
						Image(systemName: isStarred ? "star.fill" : "star")
							.font(.system(size: 18))
							.foregroundColor(isStarred ? .yellow : (colorScheme == .dark ? .white : .black))
					}
					
					Button(action: {
						showComments = true
					}) {
						Image(systemName: "bubble.right")
							.font(.system(size: 18))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					
					Button(action: {
						showShare = true
					}) {
						Image(systemName: "arrow.turn.up.right")
							.font(.system(size: 18))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
				}
				Spacer()
			}
			.padding(.horizontal)
			
			// Caption and Tags
			captionAndTagsView
			
			Text(post.createdAt, style: .date)
				.font(.system(size: 11))
				.foregroundColor(colorScheme == .dark ? .gray : .black.opacity(0.7))
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal)
		}
		.padding(.top, 16)
		.padding(.bottom, 20)
	}
	
	// MARK: - Bottom Actions Bar (kept for compatibility)
	private var bottomActionsBar: some View {
		HStack(spacing: 24) {
			// Star Button
			Button(action: {
				if isOwnPost {
					showStarredBy = true
				} else {
					Task {
						await toggleStar()
					}
				}
			}) {
				Image(systemName: isStarred ? "star.fill" : "star")
					.font(.system(size: 24))
					.foregroundColor(isStarred ? .yellow : (colorScheme == .dark ? .white : .black))
			}
			
			// Comment Button (with badge)
			Button(action: {
				showComments = true
			}) {
				ZStack(alignment: .topTrailing) {
					Image(systemName: "bubble.right")
						.font(.system(size: 24))
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					if commentCount > 0 {
						Circle()
							.fill(Color.blue)
							.frame(width: 8, height: 8)
							.offset(x: 4, y: -4)
					}
				}
			}
			
			// Share Button
			Button(action: {
				showShare = true
			}) {
				Image(systemName: "paperplane")
					.font(.system(size: 24))
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			
			Spacer()
			
			// Tags Button (only if there are tags)
			if !taggedUsers.isEmpty {
				Button(action: {
					showTags = true
				}) {
					Text("Tags")
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.background(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.9))
						.cornerRadius(8)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
	
	// MARK: - Caption and Tags View
	@ViewBuilder
	private var captionAndTagsView: some View {
		let hasCaption = post.caption != nil && !post.caption!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasTags = !taggedUsers.isEmpty
		
		if hasCaption || hasTags {
			VStack(alignment: .leading, spacing: 4) {
				// Caption first (if exists)
				if hasCaption {
					Text(post.caption!)
						.font(.system(size: 13))
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.frame(maxWidth: .infinity, alignment: .leading)
						.fixedSize(horizontal: false, vertical: true)
				}
				
				// Tags with @ symbol (if exists)
				if hasTags {
					// Create a single text with all tags
					let tagsText = taggedUsers.map { "@\($0.username)" }.joined(separator: " ")
					Text(tagsText)
						.font(.system(size: 13))
						.foregroundColor(.blue)
						.frame(maxWidth: .infinity, alignment: .leading)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(.horizontal)
		}
	}
	
	// MARK: - Caption Section
	private var captionAndTimerSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Caption and Tags
			captionAndTagsView
		}
		.padding(.bottom, 16)
	}
	
	// MARK: - Media Views
	@ViewBuilder
	private func mediaView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		if mediaItem.isVideo {
			videoView(mediaItem: mediaItem, index: index, containerHeight: containerHeight)
		} else {
			imageView(mediaItem: mediaItem, index: index, containerHeight: containerHeight)
		}
	}
	
	@ViewBuilder
	private func imageView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		// Calculate natural height for this image
		let imageNaturalHeight = calculateHeight(for: mediaItem)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		
		// Check if image exceeds 55% - if so, scale down to fit
		let exceedsMax = imageNaturalHeight > maxAllowed
		let displayHeight = exceedsMax ? containerHeight : imageNaturalHeight
		
		// For multi-media posts, use container height; for single posts, use calculated display height
		let itemHeight = post.mediaItems.count == 1 ? displayHeight : containerHeight
		
		// Show blur if:
		// 1. Multi-media post and item is shorter than container, OR
		// 2. Single post exceeds max and needs to scale down (will have side space)
		let showBlur = (post.mediaItems.count > 1 && imageNaturalHeight < containerHeight) || 
					   (post.mediaItems.count == 1 && exceedsMax)
		
		ZStack(alignment: .center) {
			// Blur background - fills empty space (sides when scaled down, or bottom when shorter)
			if showBlur {
				blurBackgroundView(height: itemHeight)
					.frame(width: screenWidth, height: itemHeight)
					.clipped()
			}
			
			// Image - use .fit when scaling down to show full image, .fill otherwise
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.aspectRatio(contentMode: exceedsMax ? .fit : .fill) // Use .fit when scaling down, .fill otherwise
					.frame(maxWidth: exceedsMax ? screenWidth : screenWidth) // Allow width to scale when using .fit
					.frame(maxHeight: displayHeight) // Cap at container height when scaling down
					.clipped()
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.2))
					.frame(width: screenWidth, height: displayHeight)
			}
		}
		.frame(width: screenWidth, height: itemHeight) // Container height for blur
		.clipped()
	}
	
	@ViewBuilder
	private func videoView(mediaItem: MediaItem, index: Int, containerHeight: CGFloat) -> some View {
		// Calculate natural height for this video (just like images)
		let videoNaturalHeight = calculateHeight(for: mediaItem)
		let maxAllowed = UIScreen.main.bounds.height * 0.55
		
		// Check if video exceeds 55% - if so, scale down to fit
		let exceedsMax = videoNaturalHeight > maxAllowed
		let displayHeight = exceedsMax ? containerHeight : videoNaturalHeight
		
		// For multi-media posts, use container height; for single posts, use calculated display height
		let itemHeight = post.mediaItems.count == 1 ? displayHeight : containerHeight
		
		// Show blur if:
		// 1. Multi-media post and item is shorter than container, OR
		// 2. Single post exceeds max and needs to scale down (will have side space)
		let showBlur = (post.mediaItems.count > 1 && videoNaturalHeight < containerHeight) || 
					   (post.mediaItems.count == 1 && exceedsMax)
		
		ZStack(alignment: .center) {
			// Blur background - fills empty space (sides when scaled down, or bottom when shorter)
			if showBlur {
				blurBackgroundView(height: itemHeight)
					.frame(width: screenWidth, height: itemHeight)
					.clipped()
			}
			
			// Gray placeholder - shows while video loads
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(maxWidth: exceedsMax ? screenWidth : screenWidth)
				.frame(maxHeight: displayHeight)
			
			// Video Player - use .fit when scaling down to show full video, .fill otherwise
			if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
				let player = VideoPlayerManager.shared.getOrCreatePlayer(for: videoURL, postId: "\(post.id)_\(index)")
				VideoPlayer(player: player)
					.aspectRatio(contentMode: exceedsMax ? .fit : .fill) // Use .fit when scaling down, .fill otherwise
					.frame(maxWidth: exceedsMax ? screenWidth : screenWidth) // Allow width to scale when using .fit
					.frame(maxHeight: displayHeight) // Cap at container height when scaling down
					.clipped()
					.ignoresSafeArea(.container, edges: .horizontal)
					.onAppear {
						if index == currentMediaIndex {
							playVideo(at: index)
						}
					}
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.3))
					.frame(maxWidth: exceedsMax ? screenWidth : screenWidth)
					.frame(maxHeight: displayHeight)
			}
		}
		.frame(width: screenWidth, height: itemHeight) // Container height for blur
		.clipped()
	}
	
	// MARK: - Unified Max Height Calculation
	private func calculateMaxMediaHeight() async {
		// Calculate 55% of screen height as the maximum
		let screenHeight = UIScreen.main.bounds.height
		let maxAllowedHeight = screenHeight * 0.55
		
		// If already calculated and not default, skip recalculation
		let defaultHeight = screenHeight * 0.55
		guard maxMediaHeight == defaultHeight || maxMediaHeight == 0 else { return }
		
		// If no media items, use default
		guard !post.mediaItems.isEmpty else {
			await MainActor.run {
				self.maxMediaHeight = min(400, maxAllowedHeight)
			}
			return
		}
		
		var calculatedHeight: CGFloat = 0
		let screenWidth = UIScreen.main.bounds.width
		
		for mediaItem in post.mediaItems {
			if mediaItem.isVideo {
				if let videoURL = mediaItem.videoURL, !videoURL.isEmpty, let url = URL(string: videoURL) {
					let asset = AVURLAsset(url: url)
					do {
						let tracks = try await asset.loadTracks(withMediaType: .video)
						if let track = tracks.first {
							let naturalSize = try await track.load(.naturalSize)
							let transform = try await track.load(.preferredTransform)
							let size = naturalSize.applying(transform)
							let width = abs(size.width)
							let height = abs(size.height)
							if width > 0 && height > 0 && !width.isNaN && !height.isNaN {
								let aspectRatio = width / height
								if aspectRatio.isFinite && aspectRatio > 0 {
									let fittedHeight = screenWidth / aspectRatio
									if fittedHeight.isFinite && !fittedHeight.isNaN {
										calculatedHeight = max(calculatedHeight, fittedHeight)
									}
								}
							}
						}
					} catch {
						// Use default if video loading fails
						calculatedHeight = max(calculatedHeight, 400)
					}
				}
			} else {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
					if let image = try? await loadImage(from: url) {
						let width = image.size.width
						let height = image.size.height
						if width > 0 && height > 0 && !width.isNaN && !height.isNaN {
							let aspectRatio = width / height
							if aspectRatio.isFinite && aspectRatio > 0 {
								let fittedHeight = screenWidth / aspectRatio
								if fittedHeight.isFinite && !fittedHeight.isNaN {
									calculatedHeight = max(calculatedHeight, fittedHeight)
								}
							}
						}
					}
				}
			}
		}
		
		// Use calculated height, but cap it at 60% of screen height
		// If no media loaded, use a default height
		let finalHeight = calculatedHeight > 0 ? min(calculatedHeight, maxAllowedHeight) : min(400, maxAllowedHeight)
		
		await MainActor.run {
			self.maxMediaHeight = finalHeight
		}
	}
	
	private func loadImage(from url: URL) async throws -> UIImage {
		let (data, _) = try await URLSession.shared.data(from: url)
		guard let image = UIImage(data: data) else {
			throw NSError(domain: "ImageLoadingError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
		}
		return image
	}
	
	// MARK: - Helper Functions
	private func setupListeners() {
		// Set up real-time comment count listener
		let db = Firestore.firestore()
		let commentsRef = db.collection("posts").document(post.id).collection("comments")
		
		_ = commentsRef.addSnapshotListener { snapshot, error in
			if let error = error {
				print("Error listening to comments: \(error)")
				return
			}
			
			Task { @MainActor in
				self.commentCount = snapshot?.documents.count ?? 0
			}
		}
	}
	
	private func loadInitialData() {
		Task {
			// Load star status
			do {
				isStarred = try await PostService.shared.isPostStarred(postId: post.id)
			} catch {
				print("Error loading star status: \(error)")
			}
			
			// Load comment count
			do {
				commentCount = try await PostService.shared.getCommentCount(postId: post.id)
			} catch {
				print("Error loading comment count: \(error)")
			}
			
			// Load user download setting
			do {
				userDownloadEnabled = try await PostService.shared.getUserDownloadEnabled()
			} catch {
				print("Error loading download setting: \(error)")
			}
			
			// Load tagged users
			do {
				taggedUsers = try await PostService.shared.getTaggedUsers(postId: post.id)
			} catch {
				print("Error loading tagged users: \(error)")
			}
			
			// Load collection owner
			if let collection = collection {
				do {
					collectionOwner = try await UserService.shared.getUser(userId: collection.ownerId)
				} catch {
					print("Error loading collection owner: \(error)")
				}
			}
			
			// Setup video players
			setupVideoPlayers()
			
			// Calculate aspect ratios for blur logic
			calculateImageAspectRatios()
			
			// Play first video if it's a video
			if !post.mediaItems.isEmpty && post.mediaItems[0].isVideo {
				playVideo(at: 0)
			}
		}
	}
	
	// MARK: - Calculate Image Aspect Ratios
	private func calculateImageAspectRatios() {
		// Pre-calculate aspect ratios for all media items using SDWebImage
		for mediaItem in post.mediaItems {
			if !mediaItem.isVideo {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty {
					// Load image to get dimensions
					Task {
						if let url = URL(string: imageURL) {
							// Use SDWebImage to load and get dimensions
							SDWebImageManager.shared.loadImage(
								with: url,
								options: [],
								progress: nil
							) { image, data, error, cacheType, finished, loadedImageURL in
								if let image = image, finished, let loadedImageURL = loadedImageURL {
									let aspectRatio = image.size.width / image.size.height
									DispatchQueue.main.async {
										imageAspectRatios[loadedImageURL.absoluteString] = aspectRatio
									}
								}
							}
						}
					}
				}
			} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty {
				// For videos, load thumbnail to get aspect ratio
				Task {
					if let url = URL(string: thumbnailURL) {
						SDWebImageManager.shared.loadImage(
							with: url,
							options: [],
							progress: nil
						) { image, data, error, cacheType, finished, _ in
							if let image = image, finished {
								let aspectRatio = image.size.width / image.size.height
								DispatchQueue.main.async {
									imageAspectRatios[thumbnailURL] = aspectRatio
								}
							}
						}
					}
				}
			}
		}
	}
	
	private func deletePost() async {
		guard isOwnPost else { return }
		isDeleting = true
		
		do {
			try await CollectionService.shared.deletePost(postId: post.id)
			print("✅ Post deleted successfully")
			
			// Post notification to refresh views
			await MainActor.run {
				NotificationCenter.default.post(
					name: NSNotification.Name("PostDeleted"),
					object: post.id,
					userInfo: ["postId": post.id, "collectionId": post.collectionId]
				)
				
				// Dismiss the view
				dismiss()
			}
		} catch {
			print("❌ Error deleting post: \(error)")
			await MainActor.run {
				isDeleting = false
			}
		}
	}
	
	private func toggleStar() async {
		let newStarredState = !isStarred
		do {
			try await PostService.shared.toggleStarPost(postId: post.id, isStarred: newStarredState)
			await MainActor.run {
				isStarred = newStarredState
				// Post notification to sync with Pinterest grid
				NotificationCenter.default.post(
					name: NSNotification.Name(newStarredState ? "PostStarred" : "PostUnstarred"),
					object: post.id
				)
			}
		} catch {
			print("Error toggling star: \(error)")
		}
	}
	
	private func handleDownload() async {
		do {
			let urls = try await PostService.shared.downloadPostMedia(postId: post.id)
			// TODO: Implement actual download to Photos library
			print("Download URLs: \(urls)")
		} catch {
			print("Error downloading post: \(error)")
		}
	}
	
	private func setupVideoPlayers() {
		for (index, mediaItem) in post.mediaItems.enumerated() {
			if mediaItem.isVideo, let videoURL = mediaItem.videoURL {
				_ = VideoPlayerManager.shared.getOrCreatePlayer(for: videoURL, postId: "\(post.id)_\(index)")
				setupElapsedTimeTracking(for: index, videoURL: videoURL)
			}
		}
	}
	
	private func setupElapsedTimeTracking(for index: Int, videoURL: String) {
		let playerId = "\(post.id)_\(index)_\(videoURL)"
		if let publisher = VideoPlayerManager.shared.getElapsedTimePublisher(for: playerId) {
			let cancellable = publisher.sink { time in
				Task { @MainActor in
					elapsedTimes[index] = time
				}
			}
			timeObservers[index] = cancellable
		}
	}
	
	private func playVideo(at index: Int) {
		guard index >= 0 && index < post.mediaItems.count else { return }
		guard post.mediaItems[index].isVideo,
			  let videoURL = post.mediaItems[index].videoURL else { return }
		
		// Pause all other videos
		for i in 0..<post.mediaItems.count where i != index && post.mediaItems[i].isVideo {
			if let otherVideoURL = post.mediaItems[i].videoURL {
				let otherPlayerId = "\(post.id)_\(i)_\(otherVideoURL)"
				VideoPlayerManager.shared.pauseVideo(playerId: otherPlayerId)
			}
		}
		
		// Play the current video
		let playerId = "\(post.id)_\(index)_\(videoURL)"
		VideoPlayerManager.shared.playVideo(playerId: playerId)
	}
	
	private func pauseAllVideos() {
		for (index, mediaItem) in post.mediaItems.enumerated() where mediaItem.isVideo {
			if let videoURL = mediaItem.videoURL {
				let playerId = "\(post.id)_\(index)_\(videoURL)"
				VideoPlayerManager.shared.pauseVideo(playerId: playerId)
			}
		}
	}
	
	private func handleMediaIndexChange(from oldIndex: Int, to newIndex: Int) {
		// Pause the old video
		if oldIndex >= 0 && oldIndex < post.mediaItems.count && post.mediaItems[oldIndex].isVideo,
		   let oldVideoURL = post.mediaItems[oldIndex].videoURL {
			let oldPlayerId = "\(post.id)_\(oldIndex)_\(oldVideoURL)"
			VideoPlayerManager.shared.pauseVideo(playerId: oldPlayerId)
		}
		
		// Play the new video if it's a video
		if newIndex >= 0 && newIndex < post.mediaItems.count && post.mediaItems[newIndex].isVideo {
			playVideo(at: newIndex)
		}
	}
	
	private func cleanupTimeObservers() {
		for (_, cancellable) in timeObservers {
			cancellable.cancel()
		}
		timeObservers.removeAll()
	}
	
	private func formatElapsedTime(_ seconds: Double) -> String {
		let minutes = Int(seconds) / 60
		let secs = Int(seconds) % 60
		return String(format: "%d:%02d", minutes, secs)
	}
	
	// MARK: - Height Calculation (matching Pinterest grid logic)
	// Calculate individual heights for each media item
	private func calculateHeight(for mediaItem: MediaItem) -> CGFloat {
		if mediaItem.isVideo {
			// For videos, use thumbnail aspect ratio if available, otherwise default 16:9
			if let thumbnailURL = mediaItem.thumbnailURL,
			   let aspectRatio = imageAspectRatios[thumbnailURL] {
				return screenWidth / aspectRatio
			} else {
				return screenWidth * (9.0 / 16.0) // Default 16:9
			}
		} else if let imageURL = mediaItem.imageURL,
				  let aspectRatio = imageAspectRatios[imageURL] {
			// Use calculated aspect ratio
			return screenWidth / aspectRatio
		} else {
			// Default aspect ratio for images (4:3)
			return screenWidth * (3.0 / 4.0)
		}
	}
	
	// Check if media items have different heights
	private var hasDifferentHeights: Bool {
		// Single media item - no blur needed
		if post.mediaItems.count <= 1 {
			return false
		}
		
		// Calculate heights for all items
		var heights: [CGFloat] = []
		for mediaItem in post.mediaItems {
			heights.append(calculateHeight(for: mediaItem))
		}
		
		// Check if any heights are different (with small tolerance for floating point)
		let tolerance: CGFloat = 1.0
		for i in 0..<heights.count {
			for j in (i+1)..<heights.count {
				if abs(heights[i] - heights[j]) > tolerance {
					return true
				}
			}
		}
		
		return false
	}
}

// MARK: - Tags View
struct TagsView: View {
	let taggedUsers: [UserService.AppUser]
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				List {
					ForEach(taggedUsers) { user in
						NavigationLink(destination: ViewerProfileView(userId: user.userId).environmentObject(authService)) {
							HStack(spacing: 12) {
								if let profileImageURL = user.profileImageURL, !profileImageURL.isEmpty, let url = URL(string: profileImageURL) {
									WebImage(url: url)
										.resizable()
										.scaledToFill()
										.frame(width: 50, height: 50)
										.clipShape(Circle())
								} else {
									DefaultProfileImageView(size: 50)
								}
								
								VStack(alignment: .leading, spacing: 4) {
									Text(user.username)
										.font(.system(size: 15, weight: .semibold))
										.foregroundColor(.primary)
									if !user.name.isEmpty {
										Text(user.name)
											.font(.system(size: 14))
											.foregroundColor(.secondary)
									}
								}
							}
							.padding(.vertical, 4)
						}
					}
				}
				.listStyle(PlainListStyle())
			}
			.navigationTitle("Tagged Users")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
		}
	}
}
