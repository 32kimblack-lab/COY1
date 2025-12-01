import SwiftUI
import SDWebImageSwiftUI
import FirebaseAuth
import FirebaseFirestore

struct UpdatesView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.dismiss) var dismiss
	@EnvironmentObject var authService: AuthService
	@State private var updates: [UpdateItem] = []
	@State private var actionRequiredUpdates: [ActionRequiredUpdate] = []
	@State private var isLoading = false
	@State private var isLoadingActionRequired = false
	@State private var selectedPost: CollectionPost?
	@State private var selectedCollection: CollectionData?
	@State private var showPostDetail = false
	@State private var showCollectionView = false
	@State private var showStarredBy = false
	@State private var showComments = false
	@State private var starredByUsers: [CYUser] = []
	@State private var currentPostId: String?
	@State private var starListeners: [String: ListenerRegistration] = [:] // Real-time star listeners per post
	@State private var commentListeners: [String: ListenerRegistration] = [:] // Real-time comment listeners per post
	
	// MARK: - Main Content View
	private var mainContentView: some View {
		ZStack {
			// Background
			Color(colorScheme == .dark ? .black : .white)
				.ignoresSafeArea()
			
			if isLoading && updates.isEmpty && actionRequiredUpdates.isEmpty {
				ProgressView()
			} else if updates.isEmpty && actionRequiredUpdates.isEmpty && !isLoading {
				emptyStateView
			} else {
				updatesListView
			}
		}
		.fullScreenCover(isPresented: $showPostDetail) {
			if let post = selectedPost, let collection = selectedCollection {
				NavigationStack {
					PhoneSizeContainer {
						CYPostDetailView(post: post, collection: collection)
					}
					.onAppear {
						if showStarredBy {
							// Delay to ensure post detail is loaded
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
								showStarredBy = false
								// Post notification to show starred by list
								NotificationCenter.default.post(
									name: NSNotification.Name("ShowStarredBy"),
									object: currentPostId
								)
							}
						} else if showComments {
							// Delay to ensure post detail is loaded
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
								showComments = false
								// Post notification to show comments
								NotificationCenter.default.post(
									name: NSNotification.Name("ShowComments"),
									object: currentPostId
								)
							}
						}
					}
				}
			}
		}
		.fullScreenCover(isPresented: $showCollectionView) {
			if let collection = selectedCollection {
				CYInsideCollectionView(collection: collection)
			}
		}
	}
	
	// MARK: - Empty State View
	private var emptyStateView: some View {
		VStack(spacing: 16) {
			Image(systemName: "bell")
				.font(.system(size: 50))
				.foregroundColor(.secondary)
			Text("No updates yet")
				.font(.headline)
				.foregroundColor(.secondary)
			Text("You'll see updates here when someone interacts with your content.")
				.font(.subheadline)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal)
		}
	}
	
	// MARK: - Updates List View
	private var updatesListView: some View {
		ScrollView {
			LazyVStack(spacing: 16) {
				// Action Required Section (at the top)
				if !actionRequiredUpdates.isEmpty {
					actionRequiredSection
				}
				
				// Regular Updates Section
				if !updates.isEmpty {
					regularUpdatesSection
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
		}
	}
	
	// MARK: - Action Required Section
	private var actionRequiredSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Action Required")
				.font(.system(size: 18, weight: .bold))
				.foregroundColor(.primary)
				.padding(.horizontal, 16)
				.padding(.top, 8)
			
			ForEach(actionRequiredUpdates) { actionUpdate in
				ActionRequiredUpdateRow(update: actionUpdate) { action, update in
					handleActionRequired(action: action, update: update)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
				.background(
					RoundedRectangle(cornerRadius: 12)
						.fill(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.95))
				)
			}
		}
		.padding(.bottom, 8)
	}
	
	// MARK: - Regular Updates Section
	private var regularUpdatesSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Show "Updates" header if there are action required updates OR if there are regular updates
			if !actionRequiredUpdates.isEmpty || !updates.isEmpty {
				Text("Updates")
					.font(.system(size: 18, weight: .bold))
					.foregroundColor(.primary)
					.padding(.horizontal, 16)
					.padding(.top, 8)
			}
			
			ForEach(updates) { update in
				UpdateRow(update: update) { update in
					handleUpdateTap(update: update)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
				.background(
					RoundedRectangle(cornerRadius: 12)
						.fill(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.95))
				)
			}
		}
	}
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				mainContentView
			}
		}
		.navigationTitle("Updates")
		.navigationBarTitleDisplayMode(.large)
		.toolbar {
			ToolbarItem(placement: .navigationBarLeading) {
				Button(action: {
					dismiss()
				}) {
					Image(systemName: "chevron.left")
						.font(.system(size: 17, weight: .semibold))
						.foregroundColor(.primary)
				}
			}
		}
		.refreshable {
			await loadAllUpdates()
		}
		.onAppear {
			Task {
				await loadAllUpdates()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionFollowed"))) { _ in
			Task { await loadActionRequiredUpdates() }
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionMemberAdded"))) { _ in
			Task { await loadActionRequiredUpdates() }
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostStarToggled"))) { notification in
			print("🔔 UpdatesView: Received PostStarToggled notification")
			// Small delay to ensure Firestore has saved the star
			Task {
				try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
				await loadAllUpdates()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentAdded"))) { notification in
			print("🔔 UpdatesView: Received CommentAdded notification")
			// Small delay to ensure Firestore has saved the comment
			Task {
				try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
				await loadAllUpdates()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostCreated"))) { _ in
			Task { await loadAllUpdates() }
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInvitationSent"))) { _ in
			Task { await loadActionRequiredUpdates() }
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestSent"))) { _ in
			Task { await loadActionRequiredUpdates() }
		}
	}
	
	// MARK: - Complete Refresh (Pull-to-Refresh)
	/// Complete refresh: Clear all caches, reload user data, reload everything from scratch
	/// Equivalent to exiting and re-entering the app
	private func completeRefresh() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		print("🔄 UpdatesView: Starting COMPLETE refresh (equivalent to app restart)")
		
		// Step 1: Clear ALL caches first (including user profile caches)
		await MainActor.run {
			HomeViewCache.shared.clearCache()
			CollectionPostsCache.shared.clearAllCache()
			// Clear user profile caches to force fresh profile image/name loads
			UserService.shared.clearUserCache(userId: currentUserId)
			print("✅ UpdatesView: Cleared all caches (including user profile caches)")
		}
		
		// Step 2: Reload current user data - FORCE FRESH
		do {
			// Stop existing listener and reload fresh
			CYServiceManager.shared.stopListening()
			try await CYServiceManager.shared.loadCurrentUser()
			print("✅ UpdatesView: Reloaded current user data (fresh from Firestore)")
		} catch {
			print("⚠️ UpdatesView: Error reloading current user: \(error)")
		}
		
		// Step 3: Reload all updates - FORCE FRESH
		await loadAllUpdates()
	}
	
	private func loadAllUpdates() async {
		print("🔔 UpdatesView: Loading all updates...")
		isLoading = true
		isLoadingActionRequired = true
		
		// Load updates separately to better diagnose issues
		var fetchedUpdates: [UpdateItem] = []
		var fetchedActionUpdates: [ActionRequiredUpdate] = []
		
		// Load regular updates
		do {
			fetchedUpdates = try await UpdatesService.shared.fetchUpdates()
			print("✅ UpdatesView: Fetched \(fetchedUpdates.count) regular updates")
			print("   - Star updates: \(fetchedUpdates.filter { $0.type == .star }.count)")
			print("   - Comment updates: \(fetchedUpdates.filter { $0.type == .comment || $0.type == .reply }.count)")
			print("   - New post updates: \(fetchedUpdates.filter { $0.type == .newPost }.count)")
		} catch {
			print("❌ UpdatesView: Error loading regular updates: \(error.localizedDescription)")
			print("   Full error: \(error)")
			fetchedUpdates = [] // Set to empty on error
		}
		
		// Load action required updates
		do {
			fetchedActionUpdates = try await UpdatesService.shared.fetchActionRequiredUpdates()
			print("✅ UpdatesView: Fetched \(fetchedActionUpdates.count) action required updates")
		} catch {
			print("❌ UpdatesView: Error loading action required updates: \(error.localizedDescription)")
			print("   Full error: \(error)")
			fetchedActionUpdates = [] // Set to empty on error
		}
		
		await MainActor.run {
			self.updates = fetchedUpdates
			self.actionRequiredUpdates = fetchedActionUpdates
			self.isLoading = false
			self.isLoadingActionRequired = false
			print("✅ UpdatesView: Updated state - updates: \(self.updates.count), actionRequired: \(self.actionRequiredUpdates.count)")
		}
	}
	
	private func loadActionRequiredUpdates() async {
		isLoadingActionRequired = true
		do {
			let fetchedActionUpdates = try await UpdatesService.shared.fetchActionRequiredUpdates()
			await MainActor.run {
				self.actionRequiredUpdates = fetchedActionUpdates
				self.isLoadingActionRequired = false
			}
		} catch {
			print("❌ UpdatesView: Error loading action required updates: \(error)")
			await MainActor.run {
				self.isLoadingActionRequired = false
			}
		}
	}
	
	private func handleActionRequired(action: ActionButtonType, update: ActionRequiredUpdate) {
		Task {
			do {
				switch action {
				case .accept:
					if update.type == .invitation {
						// Get collectionId from update
						if let collectionId = update.collectionId {
							try await CollectionService.shared.acceptCollectionInvite(collectionId: collectionId, notificationId: update.id)
						}
					} else if update.type == .request {
						// Get collectionId and requesterId from update
						if let collectionId = update.collectionId {
							try await CollectionService.shared.acceptCollectionRequest(collectionId: collectionId, requesterId: update.userId, notificationId: update.id)
						}
					}
				case .deny:
					if update.type == .invitation {
						// Get collectionId from update
						if let collectionId = update.collectionId {
							try await CollectionService.shared.denyCollectionInvite(collectionId: collectionId, notificationId: update.id)
						}
					} else if update.type == .request {
						// Get collectionId and requesterId from update
						if let collectionId = update.collectionId {
							try await CollectionService.shared.denyCollectionRequest(collectionId: collectionId, requesterId: update.userId, notificationId: update.id)
						}
					}
				case .remove:
					// Remove notification by deleting it
					if let currentUserId = authService.user?.uid {
						try await NotificationService.shared.deleteNotification(notificationId: update.id, userId: currentUserId)
					}
				}
				
				// Reload action required updates to remove the handled one
				await loadActionRequiredUpdates()
			} catch {
				print("❌ UpdatesView: Error handling action: \(error)")
			}
		}
	}
	
	private func handleUpdateTap(update: UpdateItem) {
		// Handle different update types
		switch update.type {
		case .star, .comment, .reply:
			// Need postId for these
			guard let postId = update.postId else { return }
			loadAndShowPost(postId: postId, update: update)
		case .newPost:
			// Can show collection view directly if we have collectionId
			if let collectionId = update.collectionId, !collectionId.isEmpty {
				loadAndShowCollection(collectionId: collectionId)
			} else if let postId = update.postId {
				// Fallback to post if no collection
				loadAndShowPost(postId: postId, update: update)
			}
		}
	}
	
	private func loadAndShowPost(postId: String, update: UpdateItem) {
		Task {
			do {
				// Load post data
				let db = Firestore.firestore()
				let postDoc = try await db.collection("posts").document(postId).getDocument()
				guard let postData = postDoc.data() else { return }
				
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
				
				let authorId = postData["authorId"] as? String ?? ""
				// Subscribe to real-time updates for post author
				if !authorId.isEmpty {
					UserService.shared.subscribeToUserProfile(userId: authorId)
				}
				
				let post = CollectionPost(
					id: postDoc.documentID,
					title: postData["title"] as? String ?? "",
					collectionId: postData["collectionId"] as? String ?? "",
					authorId: authorId,
					authorName: postData["authorName"] as? String ?? "",
					createdAt: (postData["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
					firstMediaItem: mediaItems.first,
					mediaItems: mediaItems,
					isPinned: postData["isPinned"] as? Bool ?? false,
					caption: postData["caption"] as? String,
					allowReplies: postData["allowReplies"] as? Bool ?? true
				)
				
				// Load collection if needed
				var collection: CollectionData? = nil
				if let collectionId = update.collectionId, !collectionId.isEmpty {
					let collectionDoc = try await db.collection("collections").document(collectionId).getDocument()
					if let collectionData = collectionDoc.data() {
						let ownerId = collectionData["ownerId"] as? String ?? ""
						// Subscribe to real-time updates for collection owner
						if !ownerId.isEmpty {
							UserService.shared.subscribeToUserProfile(userId: ownerId)
						}
						
						collection = CollectionData(
							id: collectionId,
							name: collectionData["name"] as? String ?? "",
							description: collectionData["description"] as? String ?? "",
							type: collectionData["type"] as? String ?? "Individual",
							isPublic: collectionData["isPublic"] as? Bool ?? false,
							ownerId: ownerId,
							ownerName: collectionData["ownerName"] as? String ?? "",
							owners: collectionData["owners"] as? [String] ?? [],
							imageURL: collectionData["imageURL"] as? String,
							invitedUsers: collectionData["invitedUsers"] as? [String] ?? [],
							members: collectionData["members"] as? [String] ?? [],
							memberCount: collectionData["memberCount"] as? Int ?? 0,
							followers: collectionData["followers"] as? [String] ?? [],
							followerCount: collectionData["followerCount"] as? Int ?? 0,
							allowedUsers: collectionData["allowedUsers"] as? [String] ?? [],
							deniedUsers: collectionData["deniedUsers"] as? [String] ?? [],
							createdAt: (collectionData["createdAt"] as? Timestamp)?.dateValue() ?? Date()
						)
					}
				}
				
				await MainActor.run {
					self.selectedPost = post
					self.selectedCollection = collection
					self.currentPostId = postId
					
					switch update.type {
					case .star:
						// Show post detail and open "Starred by" list
						self.showStarredBy = true
						self.showPostDetail = true
					case .comment, .reply:
						// Show post detail and scroll to comments
						self.showComments = true
						self.showPostDetail = true
					case .newPost:
						// Show collection view if we have collection, otherwise show post
						if collection != nil {
							self.showCollectionView = true
						} else {
							self.showPostDetail = true
						}
					}
				}
			} catch {
				print("❌ UpdatesView: Error loading post: \(error)")
			}
		}
	}
	
	private func loadAndShowCollection(collectionId: String) {
		Task {
			do {
				let db = Firestore.firestore()
				let collectionDoc = try await db.collection("collections").document(collectionId).getDocument()
				guard let collectionData = collectionDoc.data() else { return }
				
				let collection = CollectionData(
					id: collectionId,
					name: collectionData["name"] as? String ?? "",
					description: collectionData["description"] as? String ?? "",
					type: collectionData["type"] as? String ?? "Individual",
					isPublic: collectionData["isPublic"] as? Bool ?? false,
					ownerId: collectionData["ownerId"] as? String ?? "",
					ownerName: collectionData["ownerName"] as? String ?? "",
					owners: collectionData["owners"] as? [String] ?? [],
					imageURL: collectionData["imageURL"] as? String,
					invitedUsers: collectionData["invitedUsers"] as? [String] ?? [],
					members: collectionData["members"] as? [String] ?? [],
					memberCount: collectionData["memberCount"] as? Int ?? 0,
					followers: collectionData["followers"] as? [String] ?? [],
					followerCount: collectionData["followerCount"] as? Int ?? 0,
					allowedUsers: collectionData["allowedUsers"] as? [String] ?? [],
					deniedUsers: collectionData["deniedUsers"] as? [String] ?? [],
					createdAt: (collectionData["createdAt"] as? Timestamp)?.dateValue() ?? Date()
				)
				
				await MainActor.run {
					self.selectedCollection = collection
					self.showCollectionView = true
				}
			} catch {
				print("❌ UpdatesView: Error loading collection: \(error)")
			}
		}
	}
}

// MARK: - Update Row
struct UpdateRow: View {
	let update: UpdateItem
	let onTap: (UpdateItem) -> Void
	@Environment(\.colorScheme) var colorScheme
	@State private var displayProfileImageURL: String? = nil
	@State private var displayUsername: String = ""
	@State private var displayText: String = ""
	@State private var displaySubText: String? = nil
	
	var body: some View {
		Button(action: {
			onTap(update)
		}) {
			HStack(spacing: 12) {
				// Profile Picture (40-50dp, circular) - real-time updates
				if let profileImageURL = displayProfileImageURL, !profileImageURL.isEmpty, let url = URL(string: profileImageURL) {
					WebImage(url: url) { image in
						image
							.resizable()
							.scaledToFill()
					} placeholder: {
						Circle()
							.fill(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.8))
					}
					.indicator(.activity)
					.frame(width: 50, height: 50)
					.clipShape(Circle())
				} else {
					DefaultProfileImageView(size: 50)
				}
				
				// Text Content (matches screenshot design) - real-time updates
				VStack(alignment: .leading, spacing: 3) {
					// Main text (username or notification text)
					if update.type == .star {
						// For stars: "New star in collection "Collection Name""
						Text(displayText.isEmpty ? update.text : displayText)
							.font(.system(size: 14, weight: .regular))
							.foregroundColor(.primary)
							.lineLimit(2)
						
						// Sub text: username (real-time)
						Text(displaySubText ?? update.subText ?? "")
								.font(.system(size: 13, weight: .medium))
								.foregroundColor(.primary)
								.lineLimit(1)
					} else if update.type == .comment || update.type == .reply {
						// For comments: username on first line (real-time)
						Text(displayText.isEmpty ? update.text : displayText)
							.font(.system(size: 14, weight: .medium))
							.foregroundColor(.primary)
							.lineLimit(1)
						
						// Comment text on second line
						Text(displaySubText ?? update.subText ?? "")
								.font(.system(size: 13, weight: .regular))
								.foregroundColor(.secondary)
								.lineLimit(2)
					} else {
						// For new posts: full text
						Text(displayText.isEmpty ? update.text : displayText)
							.font(.system(size: 14, weight: .regular))
							.foregroundColor(.primary)
							.lineLimit(2)
						
						if let subText = displaySubText ?? update.subText {
							Text(subText)
								.font(.system(size: 13, weight: .regular))
								.foregroundColor(.secondary)
								.lineLimit(1)
						}
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				
				Spacer()
				
				// Thumbnail or Chevron (matches screenshot)
				if let thumbnailURL = update.thumbnailURL, let url = URL(string: thumbnailURL) {
					WebImage(url: url) { image in
						image
							.resizable()
							.scaledToFill()
					} placeholder: {
						Rectangle()
							.fill(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.8))
					}
					.indicator(.activity)
					.frame(width: 50, height: 50)
					.clipShape(RoundedRectangle(cornerRadius: 8))
				} else if update.type == .newPost {
					// Show chevron for collection posts without thumbnail (matches screenshot)
					Image(systemName: "chevron.right")
						.font(.system(size: 12, weight: .semibold))
						.foregroundColor(.secondary)
						.padding(.trailing, 4)
				}
			}
		}
		.buttonStyle(PlainButtonStyle())
		.onAppear {
			// Initialize with update data
			displayProfileImageURL = update.profileImageURL
			displayUsername = update.username
			displayText = update.text
			displaySubText = update.subText
			
			// Subscribe to real-time updates for this user
			UserService.shared.subscribeToUserProfile(userId: update.userId)
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserProfileUpdated"))) { notificationUpdate in
			// Update display when user profile changes
			if let updatedUserId = notificationUpdate.object as? String,
			   updatedUserId == update.userId,
			   let userInfo = notificationUpdate.userInfo {
				if let newProfileImageURL = userInfo["profileImageURL"] as? String {
					displayProfileImageURL = newProfileImageURL.isEmpty ? nil : newProfileImageURL
				}
				if let newUsername = userInfo["username"] as? String {
					displayUsername = newUsername
					// Update text if it contains the username
					if update.text.contains(update.username) {
						displayText = update.text.replacingOccurrences(of: update.username, with: newUsername)
					}
					// Update subText if it contains the username
					if let subText = update.subText, subText.contains(update.username) {
						displaySubText = subText.replacingOccurrences(of: update.username, with: newUsername)
					} else if update.subText == update.username {
						displaySubText = newUsername
					}
				}
			}
		}
		.onAppear {
			// Initialize with update data
			displayProfileImageURL = update.profileImageURL
			displayUsername = update.username
			
			// Subscribe to real-time updates for this user
			UserService.shared.subscribeToUserProfile(userId: update.userId)
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserProfileUpdated"))) { notificationUpdate in
			// Update display when user profile changes
			if let updatedUserId = notificationUpdate.object as? String,
			   updatedUserId == update.userId,
			   let userInfo = notificationUpdate.userInfo {
				if let newProfileImageURL = userInfo["profileImageURL"] as? String {
					displayProfileImageURL = newProfileImageURL.isEmpty ? nil : newProfileImageURL
				}
				if let newUsername = userInfo["username"] as? String {
					displayUsername = newUsername
				}
			}
		}
	}
}

// MARK: - Action Button Type
enum ActionButtonType {
	case accept
	case deny
	case remove
}

// MARK: - Action Required Update Row
struct ActionRequiredUpdateRow: View {
	let update: ActionRequiredUpdate
	let onAction: (ActionButtonType, ActionRequiredUpdate) -> Void
	@Environment(\.colorScheme) var colorScheme
	@State private var displayProfileImageURL: String? = nil
	@State private var displayUsername: String = ""
	
	var body: some View {
		HStack(spacing: 12) {
			// Profile Picture (40-50dp, circular) - real-time updates
			if let profileImageURL = displayProfileImageURL, !profileImageURL.isEmpty, let url = URL(string: profileImageURL) {
				WebImage(url: url) { image in
					image
						.resizable()
						.scaledToFill()
				} placeholder: {
					Circle()
						.fill(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.8))
				}
				.indicator(.activity)
				.frame(width: 50, height: 50)
				.clipShape(Circle())
			} else {
				Circle()
					.fill(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.8))
					.frame(width: 50, height: 50)
					.overlay(
						Image(systemName: "person.fill")
							.foregroundColor(.secondary)
							.font(.system(size: 20))
					)
			}
			
			// Text Content - real-time updates
			VStack(alignment: .leading, spacing: 4) {
				Text(displayUsername.isEmpty ? update.username : displayUsername)
					.font(.system(size: 14, weight: .bold))
					.foregroundColor(.primary)
				
				Text(update.text)
					.font(.system(size: 13, weight: .regular))
					.foregroundColor(.primary)
					.lineLimit(2)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			
			Spacer()
			
			// Action Buttons
			HStack(spacing: 8) {
				if update.type == .invitation || update.type == .request {
					// Deny button (outlined)
					Button(action: {
						onAction(.deny, update)
					}) {
						Text("Deny")
							.font(.system(size: 13, weight: .semibold))
							.foregroundColor(.primary)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(
								RoundedRectangle(cornerRadius: 8)
									.stroke(Color.primary.opacity(0.3), lineWidth: 1)
							)
					}
					
					// Accept button (filled)
					Button(action: {
						onAction(.accept, update)
					}) {
						Text("Accept")
							.font(.system(size: 13, weight: .semibold))
							.foregroundColor(colorScheme == .dark ? .black : .white)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(
								RoundedRectangle(cornerRadius: 8)
									.fill(Color.primary)
							)
					}
				} else if update.type == .follow || update.type == .join {
					// Remove button (red/outlined)
					Button(action: {
						onAction(.remove, update)
					}) {
						Text("Remove")
							.font(.system(size: 13, weight: .semibold))
							.foregroundColor(.red)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(
								RoundedRectangle(cornerRadius: 8)
									.stroke(Color.red.opacity(0.5), lineWidth: 1)
							)
					}
				}
			}
			
			// Optional collection thumbnail
			if let collectionImageURL = update.collectionImageURL, !collectionImageURL.isEmpty, let url = URL(string: collectionImageURL) {
				WebImage(url: url) { image in
					image
						.resizable()
						.scaledToFill()
				} placeholder: {
					Rectangle()
						.fill(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.8))
				}
				.indicator(.activity)
				.frame(width: 40, height: 40)
				.clipShape(RoundedRectangle(cornerRadius: 6))
			}
		}
	}
}

