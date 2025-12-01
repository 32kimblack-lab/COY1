import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct ViewerProfileView: View {
	let userId: String
	@Environment(\.dismiss) var dismiss
	@EnvironmentObject var authService: AuthService
	@State private var user: UserService.AppUser?
	@State private var userCollections: [CollectionData] = []
	@State private var isLoadingCollections = false
	@State private var isUserBlocked = false
	@State private var areMutuallyBlocked = false
	@State private var isFriend = false
	@State private var hasOutgoingRequest = false // Request sent by current user
	@State private var hasIncomingRequest = false // Request sent to current user
	@State private var showUserActionsDialog = false
	@State private var showBlockReportMenu = false
	@State private var showReportUserAlert = false
	@State private var showReportSuccessAlert = false
	@State private var showReportErrorAlert = false
	@State private var reportErrorMessage = ""
	@State private var isReporting = false
	@State private var selectedCollection: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedOwnerId: String?
	@State private var profileRefreshTrigger = UUID()
	@State private var collectionsListener: ListenerRegistration?
	@State private var viewedUserListener: ListenerRegistration? // Real-time listener for the viewed user's profile
	@State private var userSortPreference: String = "Newest to Oldest"
	@State private var userCustomOrder: [String] = []
	@State private var isReloadingCollections = false // Guard to prevent concurrent reloads
	@State private var showChatScreen = false
	@State private var chatId: String?
	// Request state is managed by CollectionRequestStateManager.shared - no local state needed
	@Environment(\.colorScheme) var colorScheme
	@StateObject private var cyServiceManager = CYServiceManager.shared // Observe ServiceManager for real-time updates
	private let friendService = FriendService.shared
	private let chatService = ChatService.shared
	
	var isViewingOwnProfile: Bool {
		authService.user?.uid == userId
	}
	
	var sortedCollections: [CollectionData] {
		let collections = userCollections
		switch userSortPreference {
		case "Oldest to Newest":
			return collections.sorted { $0.createdAt < $1.createdAt }
		case "Alphabetical":
			return collections.sorted { $0.name.lowercased() < $1.name.lowercased() }
		case "Customize":
			if userCustomOrder.isEmpty {
				return collections.sorted { $0.createdAt > $1.createdAt }
			}
			return collections.sorted { (a, b) -> Bool in
				let indexA = userCustomOrder.firstIndex(of: a.id) ?? Int.max
				let indexB = userCustomOrder.firstIndex(of: b.id) ?? Int.max
				if indexA == Int.max && indexB == Int.max {
					return a.createdAt > b.createdAt
				}
				return indexA < indexB
			}
		default: // "Newest to Oldest"
			return collections.sorted { $0.createdAt > $1.createdAt }
		}
	}
	
	var body: some View {
		PhoneSizeContainer {
			// If users are mutually blocked, show nothing - user doesn't exist
			if areMutuallyBlocked {
				VStack(spacing: 0) {
					// Back button at the top
					HStack {
						Button(action: {
							dismiss()
						}) {
							HStack(spacing: 8) {
								Image(systemName: "chevron.backward")
									.font(.system(size: 18, weight: .semibold))
								Text("Back")
									.font(.system(size: 17))
							}
							.foregroundColor(colorScheme == .dark ? .white : .black)
						}
						.padding(.horizontal)
						.padding(.top, 8)
						Spacer()
					}
					
					// Content
					VStack(spacing: 16) {
						Spacer()
						Image(systemName: "eye.slash.fill")
							.font(.system(size: 48))
							.foregroundColor(.gray)
						Text("User not found")
							.font(.headline)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						Text("This user is not available")
							.font(.subheadline)
							.foregroundColor(.gray)
						Spacer()
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(colorScheme == .dark ? Color.black : Color.white)
			} else {
			GeometryReader { geometry in
			ZStack(alignment: .top) {
				// Background
				(colorScheme == .dark ? Color.black : Color.white)
					.ignoresSafeArea()
				
					// Background Image - Full width, outside PhoneSizeContainer constraints
					if !isUserBlocked, let backgroundImageURL = user?.backgroundImageURL, !backgroundImageURL.isEmpty {
						CachedBackgroundImageView(
							url: backgroundImageURL,
							height: 105
						)
						.aspectRatio(contentMode: .fill)
						.frame(width: geometry.size.width, height: 105)
						.clipped()
						.ignoresSafeArea(edges: .top)
						.id("\(profileRefreshTrigger)-\(backgroundImageURL)")
					}
					
				// Main content
				VStack(spacing: 0) {
					// Profile Header Section
					profileHeaderSection
					
					// Collections Section - only show if user is not blocked
					if !isUserBlocked {
						userCollectionsSection
							.padding(.top, -20)
							}
						}
					}
				}
			}
		}
		.navigationBarHidden(true)
		.navigationBarBackButtonHidden(true)
		.navigationDestination(isPresented: $showingInsideCollection) {
			if let collection = selectedCollection {
				CYInsideCollectionView(collection: collection)
					.environmentObject(authService)
			}
		}
		.navigationDestination(isPresented: Binding(
			get: { selectedOwnerId != nil },
			set: { if !$0 { selectedOwnerId = nil } }
		)) {
			if let ownerId = selectedOwnerId {
				ViewerProfileView(userId: ownerId)
					.environmentObject(authService)
			}
		}
		.navigationDestination(isPresented: $showChatScreen) {
			if let chatId = chatId {
				ChatScreen(chatId: chatId, otherUserId: userId)
					.environmentObject(authService)
			}
		}
		.confirmationDialog("User Options", isPresented: $showBlockReportMenu, titleVisibility: .hidden) {
			if isUserBlocked {
				Button("Unblock User") {
					unblockUser()
				}
			} else {
				Button("Block User", role: .destructive) {
					blockUser()
				}
			}
			Button("Report User", role: .destructive) {
				showReportUserAlert = true
			}
			Button("Cancel", role: .cancel) { }
		}
		.onAppear {
			// Start ServiceManager listener for real-time user updates
			Task {
				try? await CYServiceManager.shared.loadCurrentUser()
			}
			
			Task {
				// Check blocking FIRST - if mutually blocked, don't load anything
				checkBlockedStatus()
				
				// Wait a moment for blocking check to complete
				try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
				
				// Only load data if not mutually blocked
				if !areMutuallyBlocked {
				await loadUserData()
				await loadUserSortPreference()
				await loadUserCollections()
				checkFriendshipStatus()
				checkFriendRequestStatus()
				Task {
					await CollectionRequestStateManager.shared.initializeState()
					}
				}
			}
			setupCollectionsListener()
			setupViewedUserListener() // Set up real-time listener for the viewed user's profile
		}
		.onDisappear {
			// CRITICAL: Clean up Firestore listeners when view disappears
			collectionsListener?.remove()
			collectionsListener = nil
			viewedUserListener?.remove()
			viewedUserListener = nil
			FirestoreListenerManager.shared.removeAllListeners(for: "ViewerProfileView")
			#if DEBUG
			let remainingCount = FirestoreListenerManager.shared.getActiveListenerCount()
			print("✅ ViewerProfileView: Cleaned up listeners (remaining: \(remainingCount))")
			#endif
		}
		.alert("Report User", isPresented: $showReportUserAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Report", role: .destructive) {
				reportUser()
			}
		} message: {
			Text("Are you sure you want to report this user? This action will send a report to our team for review.")
		}
		.alert("Report Submitted", isPresented: $showReportSuccessAlert) {
			Button("OK") { }
		} message: {
			Text("Your report has been sent successfully. We will review it and take appropriate action.")
		}
		.alert("Error", isPresented: $showReportErrorAlert) {
			Button("OK") { }
		} message: {
			Text(reportErrorMessage.isEmpty ? "Failed to submit report. Please try again." : reportErrorMessage)
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { notification in
			if let blockedUserId = notification.userInfo?["blockedUserId"] as? String {
				Task {
					try? await CYServiceManager.shared.loadCurrentUser()
					await MainActor.run {
						checkBlockedStatus()
						// If now mutually blocked, clear everything
						if areMutuallyBlocked {
							user = nil
							userCollections = []
						} else if blockedUserId == userId {
						// Reload collections when blocking/unblocking
						Task {
							await loadUserCollections(forceFresh: false)
							}
						}
					}
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { notification in
			if let unblockedUserId = notification.userInfo?["unblockedUserId"] as? String {
				Task {
					try? await CYServiceManager.shared.loadCurrentUser()
					await MainActor.run {
						checkBlockedStatus()
						// If no longer mutually blocked, reload data
						if !areMutuallyBlocked && unblockedUserId == userId {
						Task {
								await loadUserData()
								await loadUserCollections(forceFresh: true)
							}
						}
					}
				}
			}
		}
		.refreshable {
			// Complete refresh: Clear all caches and force fresh reload
			await completeRefresh()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionDeleted"))) { notification in
			if let deletedId = notification.object as? String {
				// Remove the deleted collection from the list immediately
				userCollections.removeAll { $0.id == deletedId }
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRestored"))) { _ in
			// Reload collections to show the restored collection
			Task {
				await loadUserCollections(forceFresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionOrderUpdated"))) { _ in
			// Reload sort preference if viewing own profile
			if isViewingOwnProfile {
				Task {
					await loadUserSortPreference()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("ViewerProfileViewUserUpdated"))) { notification in
			// Update user data when real-time Firestore listener detects changes (for other users)
			if let viewedUserId = notification.object as? String,
			   viewedUserId == userId {
				if var updatedUser = user {
					if let newProfileImageURL = notification.userInfo?["profileImageURL"] as? String {
						updatedUser.profileImageURL = newProfileImageURL
					}
					if let newBackgroundImageURL = notification.userInfo?["backgroundImageURL"] as? String {
						updatedUser.backgroundImageURL = newBackgroundImageURL
					}
					if let newName = notification.userInfo?["name"] as? String {
						updatedUser.name = newName
					}
					if let newUsername = notification.userInfo?["username"] as? String {
						updatedUser.username = newUsername
					}
					user = updatedUser
					profileRefreshTrigger = UUID()
					print("✅ ViewerProfileView: Updated user profile from real-time listener")
				} else {
					// If user not loaded yet, load it
					Task {
						await loadUserData()
					}
				}
			}
		}
		.onChange(of: cyServiceManager.currentUser) { oldValue, newValue in
			// Real-time update when current user's profile changes via ServiceManager
			// Only update if profile-relevant fields actually changed (prevent infinite loops)
			guard isViewingOwnProfile, let cyUser = newValue, var updatedUser = self.user else { return }
			
			let profileChanged = oldValue?.profileImageURL != cyUser.profileImageURL ||
			oldValue?.backgroundImageURL != cyUser.backgroundImageURL ||
			oldValue?.name != cyUser.name ||
			oldValue?.username != cyUser.username
			
			if profileChanged {
				// Immediately update all fields from ServiceManager (like ProfileView)
				updatedUser.profileImageURL = cyUser.profileImageURL
				updatedUser.backgroundImageURL = cyUser.backgroundImageURL
				updatedUser.name = cyUser.name
				updatedUser.username = cyUser.username
				self.user = updatedUser
				self.profileRefreshTrigger = UUID()
				print("✅ ViewerProfileView: Immediately updated from ServiceManager onChange")
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUpdated"))) { notification in
			// Only refresh if the updated collection belongs to the viewed user
			if let collectionId = notification.object as? String,
			   userCollections.contains(where: { $0.id == collectionId }) {
				Task {
					await loadUserCollections(forceFresh: false) // Use cache if available
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserCollectionsUpdated"))) { notification in
			// Refresh collections when user's collections list changes (join/leave)
			if let updatedUserId = notification.object as? String,
			   updatedUserId == userId {
				Task {
					await loadUserCollections(forceFresh: false)
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestAccepted"))) { notification in
			// Update friend status when request is accepted
			if let acceptedUid = notification.object as? String,
			   acceptedUid == userId {
				Task {
					checkFriendshipStatus()
					checkFriendRequestStatus()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestDenied"))) { notification in
			// Update friend status when request is denied
			if let deniedUid = notification.object as? String,
			   deniedUid == userId {
				Task {
					checkFriendshipStatus()
					checkFriendRequestStatus()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestSent"))) { notification in
			// Update request status when a request is sent
			if let toUid = notification.object as? String,
			   toUid == userId {
				Task {
					checkFriendRequestStatus()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestCancelled"))) { notification in
			// Update request status when a request is cancelled
			if let toUid = notification.object as? String,
			   toUid == userId {
				Task {
					checkFriendRequestStatus()
				}
			}
		}
	}
	
	// MARK: - Profile Header Section
	private var profileHeaderSection: some View {
		ZStack(alignment: .topLeading) {
			// Background Image Area - Always reserve 105 points height, whether image exists or not
			// Note: Background image is now rendered in body to extend full width
			Color.clear
					.frame(height: 105)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
					.ignoresSafeArea(edges: .top)
			
			// Top Buttons Row
			VStack {
				Spacer()
				HStack {
					// Left Button (Back)
					Button(action: {
						dismiss()
					}) {
						CircleButton(systemName: "chevron.backward", colorScheme: colorScheme)
					}
					
					Spacer()
					
					// Right Buttons
					HStack(spacing: 16) {
						if !isViewingOwnProfile {
							// Friend Request/Message Button
							if isFriend {
								// Message button when friends
								Button(action: {
									Task {
										await navigateToChat()
									}
								}) {
									CircleButton(systemName: "message", colorScheme: colorScheme)
								}
							} else if hasIncomingRequest {
								// Accept/Deny buttons when there's an incoming request
								HStack(spacing: 8) {
									Button(action: {
										Task {
											await acceptFriendRequest()
										}
									}) {
										CircleButton(systemName: "checkmark", colorScheme: colorScheme)
									}
									Button(action: {
										Task {
											await denyFriendRequest()
										}
									}) {
										CircleButton(systemName: "xmark", colorScheme: colorScheme)
									}
								}
							} else if hasOutgoingRequest {
								// Pending button when request is sent
								Button(action: {
									Task {
										await cancelFriendRequest()
									}
								}) {
									CircleButton(systemName: "clock", colorScheme: colorScheme)
								}
							} else {
								// Add button when no request exists
								Button(action: {
									Task {
										await sendFriendRequest()
									}
								}) {
									CircleButton(systemName: "person.badge.plus", colorScheme: colorScheme)
								}
							}
							
							// Three-dot menu button
							Button(action: {
								showBlockReportMenu = true
							}) {
								CircleButton(systemName: "ellipsis", colorScheme: colorScheme)
							}
						}
					}
				}
				.padding(.horizontal, 16)
				Spacer()
			}
			.frame(height: 105)
			
			// Profile Image - Half on background, half below
			Group {
				if isUserBlocked {
					DefaultProfileImageView(size: 70)
				} else {
					if let user = user {
						if let profileImageURL = user.profileImageURL, !profileImageURL.isEmpty {
							CachedProfileImageView(
								url: profileImageURL,
								size: 70
							)
							.aspectRatio(contentMode: .fill)
							.frame(width: 70, height: 70)
							.clipShape(Circle())
							.id("\(profileRefreshTrigger)-\(profileImageURL)")
						} else {
							DefaultProfileImageView(size: 70)
						}
					} else {
						Circle()
							.fill(Color.gray.opacity(0.3))
							.frame(width: 70, height: 70)
							.overlay {
								ProgressView()
									.scaleEffect(0.8)
							}
					}
				}
			}
			.offset(y: 105 - 35)
			.frame(maxWidth: .infinity, alignment: .center)
			
			// Username + Name - Below profile image, centered
			VStack(spacing: 4) {
				if isUserBlocked {
					Text("@\(user?.username ?? "")")
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					VStack(spacing: 8) {
						Image(systemName: "hand.raised.fill")
							.font(.title)
							.foregroundColor(.gray)
						
						Text("You have blocked this user")
							.font(.headline)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						
						Text("You won't see their posts or collections")
							.font(.caption)
							.foregroundColor(.gray)
							.multilineTextAlignment(.center)
						
						Button(action: {
							unblockUser()
						}) {
							Text("Unblock")
								.font(.subheadline)
								.fontWeight(.semibold)
								.foregroundColor(.white)
								.padding(.horizontal, 24)
								.padding(.vertical, 8)
								.background(Color.blue)
								.cornerRadius(8)
						}
						.padding(.top, 4)
					}
					.padding()
					.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
					.cornerRadius(12)
					.padding(.horizontal)
				} else {
					Text(user?.username ?? "")
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.id("\(profileRefreshTrigger)-username")
					Text(user?.name ?? "")
						.font(.subheadline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.id("\(profileRefreshTrigger)-name")
				}
			}
			.frame(maxWidth: .infinity)
			.offset(y: 105 + 35 + 8)
		}
		.frame(height: 105 + 35 + 60)
		.ignoresSafeArea(edges: .top)
	}
	
	// MARK: - User Collections Section
	private var userCollectionsSection: some View {
		Group {
			if isLoadingCollections {
				HStack {
					Spacer()
					ProgressView("Loading collections...")
						.frame(maxWidth: .infinity)
					Spacer()
				}
				.frame(height: 80)
			} else {
				List {
					if userCollections.isEmpty {
					VStack(spacing: 12) {
						Text("No Collections")
							.font(.headline)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						
						Text("User has no collections")
							.font(.subheadline)
							.foregroundColor(.gray)
							.multilineTextAlignment(.center)
							.padding(.horizontal, 20)
					}
				.frame(maxWidth: .infinity)
						.listRowInsets(EdgeInsets())
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
			} else {
					ForEach(sortedCollections, id: \.id) { collection in
						SimpleCollectionRow(
							collection: collection,
							onOwnerProfileTapped: { ownerId in
								selectedOwnerId = ownerId
							},
							hasRequested: CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id),
							onActionTapped: {
								handleCollectionAction(collection: collection)
							},
							onCollectionTapped: { collection in
								await handleCollectionTap(collection: collection)
							}
						)
						.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
						}
					}
				}
				.listStyle(PlainListStyle())
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.environment(\.defaultMinListRowHeight, 80)
				.refreshable {
					await loadUserCollections(forceFresh: true)
				}
			}
		}
	}
	
	// MARK: - Helper Functions
	private func loadUserData() async {
		do {
			let loadedUser = try await UserService.shared.getUser(userId: userId)
			await MainActor.run {
				self.user = loadedUser
				self.profileRefreshTrigger = UUID()
			}
		} catch {
			print("Error loading user data: \(error)")
		}
	}
	
	private func loadUserSortPreference() async {
		if isViewingOwnProfile {
			// Use current user's sort preference from CYServiceManager
			await MainActor.run {
				userSortPreference = CYServiceManager.shared.getCollectionSortPreference()
				userCustomOrder = CYServiceManager.shared.getCustomCollectionOrder()
			}
		} else {
			// Load viewed user's sort preference from Firebase
			do {
				let db = Firestore.firestore()
				let userDoc = try await db.collection("users").document(userId).getDocument()
				
				if let data = userDoc.data() {
					await MainActor.run {
						userSortPreference = data["collectionSortPreference"] as? String ?? "Newest to Oldest"
						userCustomOrder = data["customCollectionOrder"] as? [String] ?? []
						print("✅ ViewerProfileView: Loaded sort preference from Firestore")
					}
				} else {
					// User document doesn't exist, use defaults
					await MainActor.run {
						userSortPreference = "Newest to Oldest"
						userCustomOrder = []
					}
				}
			} catch {
				print("❌ ViewerProfileView: Error loading from Firestore: \(error)")
				// Use defaults on error
				await MainActor.run {
					userSortPreference = "Newest to Oldest"
					userCustomOrder = []
				}
			}
		}
	}
	
	// MARK: - Complete Refresh (Pull-to-Refresh)
	/// Complete refresh: Clear all caches, reload user data, reload everything from scratch
	/// Equivalent to exiting and re-entering the app
	private func completeRefresh() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		print("🔄 ViewerProfileView: Starting COMPLETE refresh (equivalent to app restart)")
		
		// Step 1: Clear ALL caches first (including user profile caches)
		await MainActor.run {
			CollectionPostsCache.shared.clearAllCache()
			HomeViewCache.shared.clearCache()
			// Clear user profile caches to force fresh profile image/name loads
			UserService.shared.clearUserCache(userId: userId)
			UserService.shared.clearUserCache(userId: currentUserId)
			print("✅ ViewerProfileView: Cleared all caches (including user profile caches)")
		}
		
		// Step 2: Reload current user data - FORCE FRESH
		do {
			// Stop existing listener and reload fresh
			CYServiceManager.shared.stopListening()
			try await CYServiceManager.shared.loadCurrentUser()
			print("✅ ViewerProfileView: Reloaded current user data (fresh from Firestore)")
		} catch {
			print("⚠️ ViewerProfileView: Error reloading current user: \(error)")
		}
		
		// Step 3: Reload viewed user data and collections - FORCE FRESH
		await loadUserData()
		await loadUserCollections(forceFresh: true)
	}
	
	private func loadUserCollections(forceFresh: Bool = false) async {
		// Prevent concurrent reloads
		guard !isReloadingCollections else { return }
		
		await MainActor.run {
			isReloadingCollections = true
			if userCollections.isEmpty {
				self.isLoadingCollections = true
			}
		}
		
		defer {
			Task { @MainActor in
				isReloadingCollections = false
				isLoadingCollections = false
			}
		}
		
		do {
			// Use privacy-aware method to only get collections the viewing user can see
			guard let currentUserId = authService.user?.uid else {
				return
			}
			
			let collections: [CollectionData]
			if isViewingOwnProfile {
				// If viewing own profile, show all collections
				collections = try await CollectionService.shared.getUserCollections(userId: userId, forceFresh: forceFresh)
			} else {
				// If viewing someone else's profile, filter by privacy
				collections = try await CollectionService.shared.getVisibleCollectionsForUser(
					profileUserId: userId,
					viewingUserId: currentUserId,
					forceFresh: forceFresh
				)
			}
			
			// Filter out hidden collections and collections from blocked users
			let filteredCollections = await CollectionService.filterCollections(collections)
			
			await MainActor.run {
				self.userCollections = filteredCollections
			}
		} catch {
			print("Error loading collections: \(error)")
		}
	}
	
	private func setupCollectionsListener() {
		// TODO: Implement real-time listener if needed
		// For now, collections are loaded on appear and refresh
	}
	
	// MARK: - Real-time Listener for Viewed User's Profile
	private func setupViewedUserListener() {
		// Remove existing listener if any
		viewedUserListener?.remove()
		
		// Set up real-time Firestore listener for the viewed user's document
		// This allows other users to see real-time updates when the profile is edited
		let db = Firestore.firestore()
		let viewedUserId = userId
		viewedUserListener = db.collection("users").document(viewedUserId).addSnapshotListener { snapshot, error in
			Task { @MainActor in
				if let error = error {
					print("❌ ViewerProfileView: Error listening to viewed user updates: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot, let data = snapshot.data() else {
					return
				}
				
				// Immediately update user data from Firestore (real-time)
				// Use NotificationCenter to update the view since we can't capture self in struct
				let newProfileImageURL = data["profileImageURL"] as? String
				let newBackgroundImageURL = data["backgroundImageURL"] as? String
				let newName = data["name"] as? String ?? ""
				let newUsername = data["username"] as? String ?? ""
				NotificationCenter.default.post(
					name: Notification.Name("ViewerProfileViewUserUpdated"),
					object: viewedUserId,
					userInfo: [
						"profileImageURL": newProfileImageURL as Any,
						"backgroundImageURL": newBackgroundImageURL as Any,
						"name": newName,
						"username": newUsername
					]
				)
				print("🔄 ViewerProfileView: Viewed user profile updated in real-time from Firestore")
			}
		}
	}
	
	// Request state initialization is handled by CollectionRequestStateManager.shared
	
	private func checkFriendshipStatus() {
		Task {
			guard authService.user?.uid != nil else { return }
			
			let areFriends = await friendService.isFriend(userId: userId)
			await MainActor.run {
				isFriend = areFriends
			}
		}
	}
	
	private func checkFriendRequestStatus() {
		Task {
			guard authService.user?.uid != nil else { return }
			
			// Check for outgoing request (sent by current user)
			let outgoingRequests = try? await friendService.getOutgoingFriendRequests()
			let hasOutgoing = outgoingRequests?.contains(where: { $0.toUid == userId }) ?? false
			
			// Check for incoming request (sent to current user)
			let incomingRequests = try? await friendService.getIncomingFriendRequests()
			let hasIncoming = incomingRequests?.contains(where: { $0.fromUid == userId }) ?? false
			
			await MainActor.run {
				hasOutgoingRequest = hasOutgoing
				hasIncomingRequest = hasIncoming
			}
		}
	}
	
	private func checkBlockedStatus() {
		let userId = self.userId
		Task {
			// Check mutual blocking - if either user blocked the other, they're mutually blocked
			let mutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: userId)
			let currentBlockedOther = CYServiceManager.shared.isUserBlocked(userId: userId)
			
			await MainActor.run {
				areMutuallyBlocked = mutuallyBlocked
				isUserBlocked = currentBlockedOther
				
				// If mutually blocked, clear all user data - they don't exist
				if mutuallyBlocked {
					user = nil
					userCollections = []
					viewedUserListener?.remove()
					viewedUserListener = nil
				}
			}
		}
	}
	
	private func blockUser() {
		let userId = self.userId
		Task {
			do {
				try await CYServiceManager.shared.blockUser(userId: userId)
				await MainActor.run {
					isUserBlocked = true
				}
			} catch {
				print("Error blocking user: \(error)")
			}
		}
	}
	
	private func reportUser() {
		guard !isReporting else { return }
		isReporting = true
		
		Task {
			do {
				try await ReportService.shared.reportUser(reportedUserId: userId)
				await MainActor.run {
					isReporting = false
					showReportUserAlert = false
					showReportSuccessAlert = true
				}
			} catch {
				print("❌ ViewerProfileView: Error reporting user: \(error.localizedDescription)")
				await MainActor.run {
					isReporting = false
					showReportUserAlert = false
					reportErrorMessage = error.localizedDescription
					showReportErrorAlert = true
				}
			}
		}
	}
	
	private func unblockUser() {
		let userId = self.userId
		Task {
			do {
				try await CYServiceManager.shared.unblockUser(userId: userId)
				await MainActor.run {
					isUserBlocked = false
					NotificationCenter.default.post(name: Notification.Name("UserUnblocked"), object: userId)
				}
				await loadUserCollections(forceFresh: true)
			} catch {
				print("Error unblocking user: \(error)")
			}
		}
	}
	
	private func handleCollectionTap(collection: CollectionData) async {
		// Check if this is a private collection
		if !collection.isPublic {
			// Check if current user is owner, admin, or member
			let currentUserId = authService.user?.uid ?? ""
			let isOwner = collection.ownerId == currentUserId
			let isMember = collection.members.contains(currentUserId)
			let isAdmin = collection.owners.contains(currentUserId) // Admins are in owners array
			
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
	
	private func refreshUserProfileData() async {
		await loadUserData()
		await loadUserCollections(forceFresh: true)
		await MainActor.run {
			checkFriendshipStatus()
			checkBlockedStatus()
		}
		try? await CYServiceManager.shared.loadCurrentUser()
		await MainActor.run {
			checkBlockedStatus()
		}
	}
	
	private func handleFollowTapped(collection: CollectionData) async {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		let isCurrentlyFollowing = collection.followers.contains(currentUserId)
		
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
			}
			// Refresh collections to update follow status
			await loadUserCollections(forceFresh: true)
		} catch {
			print("❌ Error following/unfollowing collection: \(error.localizedDescription)")
		}
	}
	
	private func sendFriendRequest() async {
		guard authService.user?.uid != nil else { return }
		
		do {
			// Check if this is a one-way un-add scenario where we can restore friendship directly
			let canRestore = await friendService.canRestoreFriendship(userId: userId)
			
			if canRestore {
				// One-way un-add: restore friendship immediately (no friend request needed)
				try await friendService.restoreFriendship(userId: userId)
				await MainActor.run {
					isFriend = true
					hasOutgoingRequest = false
					hasIncomingRequest = false
				}
			} else {
				// Both-way un-add or new friend: send friend request
				try await friendService.sendFriendRequest(toUid: userId)
				await MainActor.run {
					hasOutgoingRequest = true
					hasIncomingRequest = false
				}
				// Post notification
				NotificationCenter.default.post(name: NSNotification.Name("FriendRequestSent"), object: userId)
			}
		} catch {
			print("❌ Error sending friend request: \(error.localizedDescription)")
		}
	}
	
	private func acceptFriendRequest() async {
		do {
			try await friendService.acceptRequest(fromUid: userId)
			await MainActor.run {
				isFriend = true
				hasIncomingRequest = false
				hasOutgoingRequest = false
			}
			// Post notification
			NotificationCenter.default.post(name: NSNotification.Name("FriendRequestAccepted"), object: userId)
		} catch {
			print("❌ Error accepting friend request: \(error.localizedDescription)")
		}
	}
	
	private func denyFriendRequest() async {
		do {
			try await friendService.denyRequest(fromUid: userId)
			await MainActor.run {
				hasIncomingRequest = false
				hasOutgoingRequest = false
			}
			// Post notification
			NotificationCenter.default.post(name: NSNotification.Name("FriendRequestDenied"), object: userId)
		} catch {
			print("❌ Error denying friend request: \(error.localizedDescription)")
		}
	}
	
	private func cancelFriendRequest() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		do {
			// Cancel the outgoing friend request by deleting it
			let requestId = "\(currentUserId)_\(userId)"
			let db = Firestore.firestore()
			try await db.collection("friend_requests").document(requestId).delete()
			
			await MainActor.run {
				hasOutgoingRequest = false
			}
			// Post notification
			NotificationCenter.default.post(name: NSNotification.Name("FriendRequestCancelled"), object: userId)
		} catch {
			print("❌ Error cancelling friend request: \(error.localizedDescription)")
		}
	}
	
	private func navigateToChat() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		do {
			let chatRoom = try await chatService.getOrCreateChatRoom(participants: [currentUserId, userId])
			await MainActor.run {
				chatId = chatRoom.id
				showChatScreen = true
			}
		} catch {
			print("❌ Error navigating to chat: \(error.localizedDescription)")
		}
	}
	
	private func handleCollectionAction(collection: CollectionData) {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		// Check if user is member, owner, or admin
		let isMember = collection.members.contains(currentUserId)
		let isOwner = collection.ownerId == currentUserId
		let isAdmin = collection.owners.contains(currentUserId)
		
		// Handle Request action for Request-type collections if user is NOT a member/owner/admin
		if collection.type == "Request" && !isMember && !isOwner && !isAdmin {
			Task {
				// Check if there's already a pending request
				let hasRequested = CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id)
				
				// Post notification immediately for synchronization
				if let currentUserId = authService.user?.uid {
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
				
				do {
					if hasRequested {
						// Cancel/unrequest
						try await CollectionService.shared.cancelCollectionRequest(collectionId: collection.id)
					} else {
						// Send request
						try await CollectionService.shared.sendCollectionRequest(collectionId: collection.id)
					}
					// Refresh collections to update button state
					await loadUserCollections(forceFresh: true)
				} catch {
					print("Error \(hasRequested ? "cancelling" : "sending") collection request: \(error.localizedDescription)")
					// Revert the notification on error
					if let currentUserId = authService.user?.uid {
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
			
			Task {
				do {
					try await CollectionService.shared.joinCollection(collectionId: collection.id)
					// Refresh collections to show updated membership
					await loadUserCollections(forceFresh: true)
				} catch {
					print("Error joining collection: \(error.localizedDescription)")
					// Revert notifications on error
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionLeft"),
						object: collection.id,
						userInfo: ["userId": currentUserId]
					)
				}
			}
		}
		// Handle Leave action for Open collections if user IS a member (but not owner)
		else if collection.type == "Open" && isMember && !isOwner {
			Task {
				do {
					try await CollectionService.shared.leaveCollection(collectionId: collection.id, userId: currentUserId)
					// Refresh collections to show updated membership
					await loadUserCollections(forceFresh: true)
				} catch {
					print("Error leaving collection: \(error.localizedDescription)")
				}
			}
		}
	}
}

// MARK: - Simple Collection Row
struct SimpleCollectionRow: View {
	let collection: CollectionData
	let onOwnerProfileTapped: ((String) -> Void)?
	let hasRequested: Bool
	let onActionTapped: () -> Void
	let onCollectionTapped: (CollectionData) async -> Void
	@Environment(\.colorScheme) var colorScheme
	@State private var recentPosts: [CollectionPost] = []
	
	var body: some View {
		CollectionRowDesign(
			collection: collection,
			isFollowing: collection.followers.contains(Auth.auth().currentUser?.uid ?? ""),
			hasRequested: hasRequested,
			isMember: {
				let currentUserId = Auth.auth().currentUser?.uid ?? ""
				return collection.members.contains(currentUserId) || collection.owners.contains(currentUserId)
			}(),
			isOwner: collection.ownerId == Auth.auth().currentUser?.uid,
			onFollowTapped: {
				Task {
					await handleFollowTapped(collection: collection)
				}
			},
			onActionTapped: onActionTapped,
			onProfileTapped: {
				onOwnerProfileTapped?(collection.ownerId)
			},
			onCollectionTapped: {
				Task {
					await onCollectionTapped(collection)
				}
			}
		)
		.onAppear {
			loadPosts()
		}
	}
	
	private func handleFollowTapped(collection: CollectionData) async {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		let isCurrentlyFollowing = collection.followers.contains(currentUserId)
		
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
			}
		} catch {
			print("❌ Error following/unfollowing collection: \(error.localizedDescription)")
		}
	}
	
	private func loadPosts() {
		Task {
			do {
				var posts = try await CollectionService.shared.getCollectionPostsFromFirebase(collectionId: collection.id)
				// Filter out posts from hidden collections and blocked users
				posts = await CollectionService.filterPosts(posts)
				await MainActor.run {
					// Take first 4 posts for grid preview
					self.recentPosts = Array(posts.prefix(4))
				}
			} catch {
				print("Error loading posts for collection row: \(error)")
			}
		}
	}
}
