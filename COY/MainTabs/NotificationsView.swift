import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct NotificationsView: View {
	@Binding var isPresented: Bool
	@EnvironmentObject var authService: AuthService
	@State private var notifications: [NotificationService.AppNotification] = []
	@State private var isLoading = true
	@State private var errorMessage: String?
	@State private var selectedJoinNotification: NotificationService.AppNotification?
	@State private var showingJoinedUsers = false
	@State private var processingNotificationIds: Set<String> = [] // Track which notifications are being processed
	@State private var selectedUserId: String? // For navigating to user profile
	@State private var showingProfile = false // For navigating to user profile
	@State private var showingAllActionsRequired = false
	@State private var selectedPostId: String? // For navigating to post
	@State private var showingPostDetail = false
	@State private var selectedCollectionId: String? // For navigating to collection
	@State private var selectedCollection: CollectionData? // Loaded collection for navigation
	@State private var showingCollection = false
	@State private var isLoadingCollection = false
	@State private var showStarArea = false // For star notifications
	@State private var showComments = false // For comment notifications
	
	// Computed properties to split notifications
	private var actionRequiredNotifications: [NotificationService.AppNotification] {
		let actionTypes = Set(["collection_request", "collection_invite"])
		return notifications.filter { notification in
			actionTypes.contains(notification.type) && notification.status == "pending"
		}
	}
	
	private var updateNotifications: [NotificationService.AppNotification] {
		let updateTypes = Set(["collection_star", "collection_post", "comment", "comment_reply"])
		return notifications.filter { notification in
			updateTypes.contains(notification.type)
		}
	}
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				contentView
			}
			.navigationTitle("Notifications")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button {
						isPresented = false
					} label: {
						Image(systemName: "xmark")
							.font(.system(size: 16, weight: .semibold))
					}
					.accessibilityLabel("Close")
				}
			}
			.sheet(isPresented: $showingJoinedUsers) {
				if let notification = selectedJoinNotification {
					JoinedUsersView(notification: notification)
						.environmentObject(authService)
				}
			}
			.sheet(isPresented: $showingAllActionsRequired) {
				ViewAllActionsRequiredView(
					notifications: actionRequiredNotifications,
					processingNotificationIds: $processingNotificationIds,
					onAccept: { notification in
						if notification.type == "collection_request" {
							handleAccept(notification: notification)
						} else if notification.type == "collection_invite" {
							handleAcceptInvite(notification: notification)
						}
					},
					onDeny: { notification in
						if notification.type == "collection_request" {
							handleDeny(notification: notification)
						} else if notification.type == "collection_invite" {
							handleDenyInvite(notification: notification)
						}
					},
					onProfileTapped: { userId in
						selectedUserId = userId
						showingProfile = true
					}
				)
				.environmentObject(authService)
			}
			.navigationDestination(isPresented: $showingProfile) {
				if let userId = selectedUserId {
					ViewerProfileView(userId: userId)
						.environmentObject(authService)
				}
			}
			.navigationDestination(isPresented: $showingPostDetail) {
				if let postId = selectedPostId {
					PostDetailFromNotificationView(
						postId: postId,
						showStarArea: showStarArea,
						showComments: showComments
					)
					.environmentObject(authService)
					.onDisappear {
						// Reset flags when view disappears
						showStarArea = false
						showComments = false
					}
				}
			}
			.navigationDestination(isPresented: $showingCollection) {
				if let collection = selectedCollection {
					CYInsideCollectionView(collection: collection)
						.environmentObject(authService)
						.onDisappear {
							// Reset collection when view disappears
							selectedCollection = nil
							selectedCollectionId = nil
						}
				} else if isLoadingCollection {
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.onAppear {
				// Immediately set badge count to 0 (since we're marking as read when view appears)
				NotificationCenter.default.post(
					name: NSNotification.Name("UnreadNotificationCountChanged"),
					object: nil,
					userInfo: ["count": 0]
				)
				
				// Mark all notifications as read, then load
				Task {
					await markAllNotificationsAsRead()
					await loadNotificationsSync()
				}
			}
			.onDisappear {
				// Refresh badge count when view is dismissed (should be 0 after marking as read)
				NotificationCenter.default.post(
					name: NSNotification.Name("UnreadNotificationCountChanged"),
					object: nil,
					userInfo: ["count": 0]
				)
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestSent"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestAccepted"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestDenied"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionMembersJoined"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteSent"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteAccepted"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteDenied"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionStarNotification"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionPostNotification"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentNotification"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentReplyNotification"))) { _ in
				loadNotifications()
			}
		}
	}
	
	@ViewBuilder
	private var contentView: some View {
		if isLoading {
			ProgressView()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else if notifications.isEmpty {
			emptyStateView
		} else {
			notificationsContentView
		}
	}
	
	private var emptyStateView: some View {
		VStack(spacing: 12) {
			Image(systemName: "bell.slash")
				.font(.system(size: 48))
				.foregroundColor(.secondary)
			Text("You have no notifications yet.")
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	private var notificationsContentView: some View {
		ScrollView {
			LazyVStack(spacing: 20) {
				if !actionRequiredNotifications.isEmpty {
					actionsRequiredSection
				}
				
				if !updateNotifications.isEmpty {
					updatesSection
				}
			}
			.padding(.vertical, 8)
		}
	}
	
	private var actionsRequiredSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Actions Required")
				.font(.system(size: 24, weight: .bold))
				.padding(.horizontal, 16)
			
			ForEach(Array(actionRequiredNotifications.prefix(5))) { notification in
				actionRequiredRow(notification: notification)
			}
			
			if actionRequiredNotifications.count > 5 {
				viewAllButton
			}
		}
		.padding(.top, 8)
	}
	
	private func actionRequiredRow(notification: NotificationService.AppNotification) -> some View {
		NotificationRow(
			notification: notification,
			isProcessing: processingNotificationIds.contains(notification.id),
			onAccept: {
				if notification.type == "collection_request" {
					handleAccept(notification: notification)
				} else if notification.type == "collection_invite" {
					handleAcceptInvite(notification: notification)
				}
			},
			onDeny: {
				if notification.type == "collection_request" {
					handleDeny(notification: notification)
				} else if notification.type == "collection_invite" {
					handleDenyInvite(notification: notification)
				}
			},
			onTap: {
				if notification.type == "collection_join" {
					selectedJoinNotification = notification
					showingJoinedUsers = true
				}
			},
			onProfileTapped: {
				selectedUserId = notification.userId
				showingProfile = true
			}
		)
		.padding(.horizontal, 16)
	}
	
	private var viewAllButton: some View {
		Button(action: {
			showingAllActionsRequired = true
		}) {
			Text("View All")
				.font(.system(size: 16, weight: .semibold))
				.foregroundColor(.blue)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 12)
				.background(Color(.systemGray6))
				.cornerRadius(12)
		}
		.padding(.horizontal, 16)
	}
	
	private var updatesSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Updates")
				.font(.system(size: 24, weight: .bold))
				.padding(.horizontal, 16)
			
			ForEach(updateNotifications) { notification in
				updateRow(notification: notification)
			}
		}
		.padding(.top, actionRequiredNotifications.isEmpty ? 0 : 8)
	}
	
	private func updateRow(notification: NotificationService.AppNotification) -> some View {
		NotificationUpdateRow(
			notification: notification,
			onTap: {
				handleUpdateTap(notification: notification)
			},
			onProfileTapped: {
				selectedUserId = notification.userId
				showingProfile = true
			}
		)
		.padding(.horizontal, 16)
	}
	
	private func handleUpdateTap(notification: NotificationService.AppNotification) {
		switch notification.type {
		case "collection_star":
			// Navigate to post detail and show star area
			if let postId = notification.postId {
				selectedPostId = postId
				showStarArea = true
				showingPostDetail = true
			}
		case "collection_post":
			// Navigate to collection
			if let collectionId = notification.collectionId {
				selectedCollectionId = collectionId
				loadCollectionAndNavigate(collectionId: collectionId)
			}
		case "comment", "comment_reply":
			// Navigate to post detail and show comments
			if let postId = notification.postId {
				selectedPostId = postId
				showComments = true
				showingPostDetail = true
			}
		default:
			break
		}
	}
	
	private func loadCollectionAndNavigate(collectionId: String) {
		isLoadingCollection = true
		Task {
			do {
				if let collection = try await CollectionService.shared.getCollection(collectionId: collectionId) {
					await MainActor.run {
						selectedCollection = collection
						isLoadingCollection = false
						showingCollection = true
					}
				} else {
					await MainActor.run {
						isLoadingCollection = false
					}
				}
			} catch {
				print("❌ Error loading collection: \(error)")
				await MainActor.run {
					isLoadingCollection = false
				}
			}
		}
	}
	
	private func loadNotifications() {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			isLoading = false
			return
		}
		
		Task {
			do {
				let loadedNotifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
				// Count ALL unread notifications (same as messages badge)
				let unreadCount = loadedNotifications.filter { !$0.isRead }.count
				await MainActor.run {
					notifications = loadedNotifications
					isLoading = false
					
					// Post notification with updated unread count (all unread notifications)
					NotificationCenter.default.post(
						name: NSNotification.Name("UnreadNotificationCountChanged"),
						object: nil,
						userInfo: ["count": unreadCount]
					)
				}
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
					isLoading = false
				}
			}
		}
	}
	
	private func handleAccept(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId,
			  Auth.auth().currentUser?.uid != nil else {
			return
		}
		
		// Prevent multiple taps
		guard !processingNotificationIds.contains(notification.id) else { return }
		
		// Remove notification from UI immediately for instant feedback
		notifications.removeAll { $0.id == notification.id }
		
		Task {
			_ = await MainActor.run {
				processingNotificationIds.insert(notification.id)
			}
			
			do {
				try await CollectionService.shared.acceptCollectionRequest(
					collectionId: collectionId,
					requesterId: notification.userId,
					notificationId: notification.id
				)
				
				// Reload notifications to get fresh state and update count
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					loadNotifications()
				}
			} catch {
				// Re-add notification on error
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					// Re-add the notification if operation failed
					if !notifications.contains(where: { $0.id == notification.id }) {
						notifications.append(notification)
					}
					errorMessage = error.localizedDescription
				}
			}
		}
	}
	
	private func handleDeny(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId,
			  Auth.auth().currentUser?.uid != nil else {
			return
		}
		
		// Prevent multiple taps
		guard !processingNotificationIds.contains(notification.id) else { return }
		
		// Remove notification from UI immediately for instant feedback
		notifications.removeAll { $0.id == notification.id }
		
		Task {
			_ = await MainActor.run {
				processingNotificationIds.insert(notification.id)
			}
			
			do {
				try await CollectionService.shared.denyCollectionRequest(
					collectionId: collectionId,
					requesterId: notification.userId,
					notificationId: notification.id
				)
				
				// Reload notifications to get fresh state and update count
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					loadNotifications()
				}
			} catch {
				// Re-add notification on error
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					// Re-add the notification if operation failed
					if !notifications.contains(where: { $0.id == notification.id }) {
						notifications.append(notification)
					}
					errorMessage = error.localizedDescription
				}
			}
		}
	}
	
	private func handleAcceptInvite(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId,
			  Auth.auth().currentUser?.uid != nil else {
			return
		}
		
		// Prevent multiple taps
		guard !processingNotificationIds.contains(notification.id) else { return }
		
		// Remove notification from UI immediately for instant feedback
		notifications.removeAll { $0.id == notification.id }
		
		Task {
			_ = await MainActor.run {
				processingNotificationIds.insert(notification.id)
			}
			
			do {
				try await CollectionService.shared.acceptCollectionInvite(
					collectionId: collectionId,
					notificationId: notification.id
				)
				
				print("✅ NotificationsView: Successfully accepted invite for collection \(collectionId)")
				
				// Reload notifications to get fresh state and update count
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					loadNotifications()
				}
			} catch {
				// Log error for debugging
				print("❌ NotificationsView: Error accepting invite: \(error.localizedDescription)")
				print("❌ NotificationsView: Full error: \(error)")
				
				// Re-add notification on error
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					// Re-add the notification if operation failed
					if !notifications.contains(where: { $0.id == notification.id }) {
						notifications.append(notification)
					}
					errorMessage = "Failed to accept invite: \(error.localizedDescription)"
				}
			}
		}
	}
	
	private func handleDenyInvite(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId else {
			return
		}
		
		// Prevent multiple taps
		guard !processingNotificationIds.contains(notification.id) else { return }
		
		// Remove notification from UI immediately for instant feedback
		notifications.removeAll { $0.id == notification.id }
		
		Task {
			_ = await MainActor.run {
				processingNotificationIds.insert(notification.id)
			}
			
			do {
				try await CollectionService.shared.denyCollectionInvite(
					collectionId: collectionId,
					notificationId: notification.id
				)
				
				print("✅ NotificationsView: Successfully denied invite for collection \(collectionId)")
				
				// Reload notifications to get fresh state and update count
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					loadNotifications()
				}
			} catch {
				// Log error for debugging
				print("❌ NotificationsView: Error denying invite: \(error.localizedDescription)")
				print("❌ NotificationsView: Full error: \(error)")
				
				// Re-add notification on error
				await MainActor.run {
					processingNotificationIds.remove(notification.id)
					// Re-add the notification if operation failed
					if !notifications.contains(where: { $0.id == notification.id }) {
						notifications.append(notification)
					}
					errorMessage = "Failed to deny invite: \(error.localizedDescription)"
				}
			}
		}
	}
	
	private func markAllNotificationsAsRead() async {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		// First, load notifications to get the current list
		await loadNotificationsSync()
		
		// Mark all unread notifications as read
		for notification in notifications where !notification.isRead {
			do {
				try await NotificationService.shared.markNotificationAsRead(
					notificationId: notification.id,
					userId: currentUserId
				)
			} catch {
				print("❌ Error marking notification as read: \(error)")
			}
		}
		
		// Post notification that count changed (will be 0 after marking as read)
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("UnreadNotificationCountChanged"),
				object: nil,
				userInfo: ["count": 0]
			)
		}
	}
	
	private func loadNotificationsSync() async {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			await MainActor.run {
				isLoading = false
			}
			return
		}
		
		do {
			let loadedNotifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
			// Count ALL unread notifications (same as messages badge)
			let unreadCount = loadedNotifications.filter { !$0.isRead }.count
			await MainActor.run {
				notifications = loadedNotifications
				isLoading = false
				
				// Post notification with updated unread count (all unread notifications)
				NotificationCenter.default.post(
					name: NSNotification.Name("UnreadNotificationCountChanged"),
					object: nil,
					userInfo: ["count": unreadCount]
				)
			}
		} catch {
			await MainActor.run {
				errorMessage = error.localizedDescription
				isLoading = false
			}
		}
	}
}

// MARK: - Update Row Component
struct NotificationUpdateRow: View {
	let notification: NotificationService.AppNotification
	let onTap: () -> Void
	let onProfileTapped: () -> Void
	
	var body: some View {
		Button(action: onTap) {
			HStack(spacing: 12) {
				// Profile Image
				Button(action: onProfileTapped) {
					if let profileImageURL = notification.userProfileImageURL, !profileImageURL.isEmpty {
						CachedProfileImageView(url: profileImageURL, size: 50)
							.clipShape(Circle())
					} else {
						DefaultProfileImageView(size: 50)
					}
				}
				.buttonStyle(.plain)
				
				// Text Content
				VStack(alignment: .leading, spacing: 4) {
					Text(topLineText)
						.font(.system(size: 15, weight: .semibold))
						.foregroundColor(.primary)
					
					Text(bottomLineText)
						.font(.system(size: 14))
						.foregroundColor(.primary)
						.lineLimit(2)
				}
				
				Spacer()
				
				// Right side content (thumbnail or arrow)
				if notification.type == "collection_post" {
					Image(systemName: "chevron.right")
						.font(.system(size: 14, weight: .semibold))
						.foregroundColor(.secondary)
				} else if let thumbnailURL = notification.postThumbnailURL, !thumbnailURL.isEmpty {
					AsyncImage(url: URL(string: thumbnailURL)) { image in
						image
							.resizable()
							.aspectRatio(contentMode: .fill)
					} placeholder: {
						Color.gray.opacity(0.3)
					}
					.frame(width: 60, height: 60)
					.clipShape(RoundedRectangle(cornerRadius: 8))
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 12)
			.background(Color(.systemGray6))
			.cornerRadius(12)
		}
		.buttonStyle(.plain)
	}
	
	private var topLineText: String {
		switch notification.type {
		case "collection_star":
			if let collectionName = notification.collectionName {
				return "New star in collection \"\(collectionName)\""
			}
			return "New star in collection"
		case "collection_post":
			return notification.username
		case "comment", "comment_reply":
			return notification.username
		default:
			return notification.message
		}
	}
	
	private var bottomLineText: String {
		switch notification.type {
		case "collection_star":
			return notification.username
		case "collection_post":
			if let collectionName = notification.collectionName {
				return "\(notification.username) has posted in the collection \"\(collectionName)\""
			}
			return "\(notification.username) has posted in a collection"
		case "comment":
			if let commentText = notification.commentText {
				return "Commented: \(commentText)"
			}
			return "Commented"
		case "comment_reply":
			if let commentText = notification.commentText {
				return "Replied: \(commentText)"
			}
			return "Replied"
		default:
			return notification.message
		}
	}
}

// MARK: - View All Actions Required View
struct ViewAllActionsRequiredView: View {
	let notifications: [NotificationService.AppNotification]
	@Binding var processingNotificationIds: Set<String>
	let onAccept: (NotificationService.AppNotification) -> Void
	let onDeny: (NotificationService.AppNotification) -> Void
	let onProfileTapped: (String) -> Void
	
	@Environment(\.dismiss) var dismiss
	@EnvironmentObject var authService: AuthService
	@State private var selectedUserId: String?
	@State private var showingProfile = false
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				ScrollView {
					LazyVStack(spacing: 12) {
						ForEach(notifications) { notification in
							NotificationRow(
								notification: notification,
								isProcessing: processingNotificationIds.contains(notification.id),
								onAccept: {
									onAccept(notification)
								},
								onDeny: {
									onDeny(notification)
								},
								onTap: nil,
								onProfileTapped: {
									selectedUserId = notification.userId
									showingProfile = true
								}
							)
							.padding(.horizontal, 16)
						}
					}
					.padding(.vertical, 8)
				}
			}
			.navigationTitle("Actions Required")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
			.navigationDestination(isPresented: $showingProfile) {
				if let userId = selectedUserId {
					ViewerProfileView(userId: userId)
						.environmentObject(authService)
				}
			}
		}
	}
}

// MARK: - Post Detail From Notification View
struct PostDetailFromNotificationView: View {
	let postId: String
	let showStarArea: Bool
	let showComments: Bool
	@EnvironmentObject var authService: AuthService
	@State private var post: CollectionPost?
	@State private var collection: CollectionData?
	@State private var isLoading = true
	
	var body: some View {
		Group {
			if isLoading {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if let post = post {
				CYPostDetailView(
					post: post,
					collection: collection,
					allPosts: nil,
					currentPostIndex: nil
				)
				.environmentObject(authService)
				.onAppear {
					// Show star area or comments if needed
					if showStarArea {
						// Post notification to show star area
						NotificationCenter.default.post(
							name: NSNotification.Name("ShowStarArea"),
							object: postId
						)
					} else if showComments {
						// Post notification to show comments
						NotificationCenter.default.post(
							name: NSNotification.Name("ShowComments"),
							object: postId
						)
					}
				}
			} else {
				Text("Post not found")
					.foregroundColor(.secondary)
			}
		}
		.onAppear {
			Task {
				await loadPost()
			}
		}
	}
	
	private func loadPost() async {
		do {
			// Fetch post from Firestore
			let db = Firestore.firestore()
			let postDoc = try await db.collection("posts").document(postId).getDocument()
			
			guard let postData = postDoc.data() else {
				await MainActor.run {
					isLoading = false
				}
				return
			}
			
			// Parse media items
			let mediaItemsData = postData["mediaItems"] as? [[String: Any]] ?? []
			let mediaItems = mediaItemsData.map { mediaData -> MediaItem in
				MediaItem(
					imageURL: mediaData["imageURL"] as? String,
					thumbnailURL: mediaData["thumbnailURL"] as? String,
					videoURL: mediaData["videoURL"] as? String,
					videoDuration: mediaData["videoDuration"] as? Double,
					isVideo: mediaData["isVideo"] as? Bool ?? false
				)
			}
			
			let collectionId = postData["collectionId"] as? String
			var loadedCollection: CollectionData? = nil
			
			if let collectionId = collectionId {
				loadedCollection = try? await CollectionService.shared.getCollection(collectionId: collectionId)
			}
			
			let loadedPost = CollectionPost(
				id: postDoc.documentID,
				title: postData["title"] as? String ?? "",
				collectionId: collectionId ?? "",
				authorId: postData["authorId"] as? String ?? "",
				authorName: postData["authorName"] as? String ?? "",
				createdAt: (postData["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
				firstMediaItem: mediaItems.first,
				mediaItems: mediaItems,
				isPinned: postData["isPinned"] as? Bool ?? false,
				pinnedAt: (postData["pinnedAt"] as? Timestamp)?.dateValue(),
				caption: postData["caption"] as? String,
				allowReplies: postData["allowReplies"] as? Bool ?? true,
				allowDownload: postData["allowDownload"] as? Bool ?? false,
				taggedUsers: postData["taggedUsers"] as? [String] ?? []
			)
			
			await MainActor.run {
				self.post = loadedPost
				self.collection = loadedCollection
				self.isLoading = false
			}
		} catch {
			print("❌ Error loading post: \(error)")
			await MainActor.run {
				isLoading = false
			}
		}
	}
}

struct NotificationRow: View {
	let notification: NotificationService.AppNotification
	let isProcessing: Bool
	let onAccept: () -> Void
	let onDeny: () -> Void
	let onTap: (() -> Void)?
	let onProfileTapped: (() -> Void)?
	
	init(notification: NotificationService.AppNotification, isProcessing: Bool = false, onAccept: @escaping () -> Void, onDeny: @escaping () -> Void, onTap: (() -> Void)? = nil, onProfileTapped: (() -> Void)? = nil) {
		self.notification = notification
		self.isProcessing = isProcessing
		self.onAccept = onAccept
		self.onDeny = onDeny
		self.onTap = onTap
		self.onProfileTapped = onProfileTapped
	}
	
	var body: some View {
		HStack(spacing: 12) {
			// Profile Image - Tappable to navigate to user profile
			Button(action: {
				onProfileTapped?()
			}) {
				if let profileImageURL = notification.userProfileImageURL, !profileImageURL.isEmpty {
					CachedProfileImageView(url: profileImageURL, size: 50)
						.clipShape(Circle())
				} else {
					DefaultProfileImageView(size: 50)
				}
			}
			.buttonStyle(.plain)
			
			// Message
			VStack(alignment: .leading, spacing: 4) {
				highlightedMessage(notification.message)
					.font(.subheadline)
				
				Text(timeAgoString(from: notification.createdAt))
					.font(.caption)
					.foregroundColor(.secondary)
			}
			
			Spacer()
			
			// Action Buttons (for pending collection requests and invites)
			if (notification.type == "collection_request" || notification.type == "collection_invite") && notification.status == "pending" {
				HStack(spacing: 6) {
					Button(action: {
						// Prevent action if already processing
						guard !isProcessing else { return }
						onAccept()
					}) {
						Group {
							if isProcessing {
								ProgressView()
									.scaleEffect(0.8)
									.tint(.white)
							} else {
								Text("Accept")
									.font(.system(size: 12, weight: .semibold))
							}
						}
						.foregroundColor(.white)
						.frame(minWidth: 60, maxWidth: 60)
						.padding(.vertical, 6)
						.background(isProcessing ? Color.blue.opacity(0.6) : Color.blue)
						.cornerRadius(8)
					}
					.buttonStyle(.plain)
					.disabled(isProcessing)
					.allowsHitTesting(!isProcessing)
					
					Button(action: {
						// Prevent action if already processing
						guard !isProcessing else { return }
						onDeny()
					}) {
						Group {
							if isProcessing {
								ProgressView()
									.scaleEffect(0.8)
									.tint(.white)
							} else {
								Text("Deny")
									.font(.system(size: 12, weight: .semibold))
							}
						}
						.foregroundColor(.white)
						.frame(minWidth: 60, maxWidth: 60)
						.padding(.vertical, 6)
						.background(isProcessing ? Color.red.opacity(0.6) : Color.red)
						.cornerRadius(8)
					}
					.buttonStyle(.plain)
					.disabled(isProcessing)
					.allowsHitTesting(!isProcessing)
				}
			} else if notification.type == "collection_request" || notification.type == "collection_invite" {
				// Show status for accepted/denied requests/invites
				Text(notification.status == "accepted" ? "Accepted" : "Denied")
					.font(.caption)
					.foregroundColor(notification.status == "accepted" ? .green : .red)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background((notification.status == "accepted" ? Color.green : Color.red).opacity(0.1))
					.cornerRadius(6)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(Color(.systemBackground))
		.cornerRadius(12)
		.shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
		.onTapGesture {
			if notification.type == "collection_join" {
				onTap?()
			}
		}
	}
	
	private func timeAgoString(from date: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return formatter.localizedString(for: date, relativeTo: Date())
	}
	
	// MARK: - Highlighted Message
	@ViewBuilder
	private func highlightedMessage(_ message: String) -> some View {
		let wordsToHighlight = ["invite", "invited", "request", "requested", "join", "joined"]
		let components = message.components(separatedBy: " ")
		
		buildHighlightedText(components: components, wordsToHighlight: wordsToHighlight)
	}
	
	private func buildHighlightedText(components: [String], wordsToHighlight: [String]) -> Text {
		var result = Text("")
		
		for (index, word) in components.enumerated() {
			// Remove punctuation to check the base word
			let cleanedWord = word.trimmingCharacters(in: .punctuationCharacters)
			let lowercasedWord = cleanedWord.lowercased()
			
			// Check if the cleaned word (case-insensitive) should be highlighted
			let shouldHighlight = wordsToHighlight.contains { lowercasedWord == $0.lowercased() }
			
			if shouldHighlight {
				// Highlight the word with bold font and blue color
				result = result + Text(word)
					.fontWeight(.bold)
					.foregroundColor(.blue)
			} else {
				// Regular text
				result = result + Text(word)
					.foregroundColor(.primary)
			}
			
			// Add space after word (except for last word)
			if index < components.count - 1 {
				result = result + Text(" ")
			}
		}
		
		return result
	}
}
