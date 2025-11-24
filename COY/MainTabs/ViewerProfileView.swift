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
	@State private var isFriend = false
	@State private var showUserActionsDialog = false
	@State private var showBlockReportMenu = false
	@State private var showReportUserAlert = false
	@State private var selectedCollection: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedOwnerId: String?
	@State private var profileRefreshTrigger = UUID()
	@State private var collectionsListener: ListenerRegistration?
	@State private var userSortPreference: String = "Newest to Oldest"
	@State private var userCustomOrder: [String] = []
	@Environment(\.colorScheme) var colorScheme
	
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
		ZStack(alignment: .top) {
			// Background
			(colorScheme == .dark ? Color.black : Color.white)
				.ignoresSafeArea()
			
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
			Task {
				await loadUserData()
				await loadUserSortPreference()
				await loadUserCollections()
				checkFriendshipStatus()
				checkBlockedStatus()
			}
			setupCollectionsListener()
		}
		.onDisappear {
			collectionsListener?.remove()
			collectionsListener = nil
		}
		.sheet(isPresented: $showReportUserAlert) {
			// TODO: Add ReportView when available
			Text("Report User")
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { notification in
			if let blockedUserId = notification.userInfo?["blockedUserId"] as? String,
			   blockedUserId == userId {
				Task {
					try? await CYServiceManager.shared.loadCurrentUser()
					await MainActor.run {
						checkBlockedStatus()
					}
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { notification in
			if let unblockedUserId = notification.userInfo?["unblockedUserId"] as? String,
			   unblockedUserId == userId {
				Task {
					try? await CYServiceManager.shared.loadCurrentUser()
					await MainActor.run {
						checkBlockedStatus()
					}
				}
			}
		}
		.refreshable {
			await refreshUserProfileData()
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
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
			// Update user profile when it's updated
			if let userId = notification.object as? String,
			   userId == self.userId {
				print("🔄 ViewerProfileView: User profile updated, refreshing")
				Task {
					await loadUserData()
					profileRefreshTrigger = UUID()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUpdated"))) { notification in
			// Refresh collections when a collection is updated
			if notification.object as? String != nil {
				print("🔄 ViewerProfileView: Collection updated, refreshing collections")
				Task {
					await loadUserCollections(forceFresh: true)
				}
			}
		}
	}
	
	// MARK: - Profile Header Section
	private var profileHeaderSection: some View {
		ZStack(alignment: .topLeading) {
			// Background Image - Fixed height of 105
			if !isUserBlocked {
				if let backgroundImageURL = user?.backgroundImageURL, !backgroundImageURL.isEmpty {
					CachedBackgroundImageView(
						url: backgroundImageURL,
						height: 105
					)
					.aspectRatio(contentMode: .fill)
					.frame(height: 105)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
					.clipped()
					.cornerRadius(0)
					.ignoresSafeArea(edges: .top)
					.id("\(profileRefreshTrigger)-\(backgroundImageURL)")
				}
			}
			
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
			} else if userCollections.isEmpty {
				VStack {
					Spacer()
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
					Spacer()
				}
				.frame(height: 600)
				.frame(maxWidth: .infinity)
			} else {
				List {
					ForEach(sortedCollections, id: \.id) { collection in
						SimpleCollectionRow(
							collection: collection,
							onOwnerProfileTapped: { ownerId in
								selectedOwnerId = ownerId
							}
						)
						.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
						.onTapGesture {
							Task {
								await handleCollectionTap(collection: collection)
							}
						}
					}
				}
				.listStyle(PlainListStyle())
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.environment(\.defaultMinListRowHeight, 80)
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
	
	private func loadUserCollections(forceFresh: Bool = false) async {
		do {
			await MainActor.run {
				self.isLoadingCollections = true
			}
			
			// Use privacy-aware method to only get collections the viewing user can see
			guard let currentUserId = authService.user?.uid else {
				await MainActor.run {
					self.isLoadingCollections = false
				}
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
			
			await MainActor.run {
				self.userCollections = collections
				self.isLoadingCollections = false
				self.profileRefreshTrigger = UUID()
			}
		} catch {
			print("Error loading collections: \(error)")
			await MainActor.run {
				self.isLoadingCollections = false
			}
		}
	}
	
	private func setupCollectionsListener() {
		// TODO: Implement real-time listener if needed
		// For now, collections are loaded on appear and refresh
	}
	
	private func checkFriendshipStatus() {
		Task {
			guard authService.user?.uid != nil else { return }
			
			// TODO: Implement areUsersFriends check
			await MainActor.run {
				isFriend = false
			}
		}
	}
	
	private func checkBlockedStatus() {
		let userId = self.userId
		isUserBlocked = CYServiceManager.shared.isUserBlocked(userId: userId)
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
}

// MARK: - Simple Collection Row
struct SimpleCollectionRow: View {
	let collection: CollectionData
	let onOwnerProfileTapped: ((String) -> Void)?
	@Environment(\.colorScheme) var colorScheme
	@State private var recentPosts: [CollectionPost] = []
	
	var body: some View {
		CollectionRowDesign(
			collection: collection,
			isFollowing: false,
			hasRequested: false,
			isMember: collection.members.contains(Auth.auth().currentUser?.uid ?? ""),
			isOwner: collection.ownerId == Auth.auth().currentUser?.uid,
			recentPosts: recentPosts,
			onFollowTapped: {},
			onActionTapped: {},
			onProfileTapped: {
				onOwnerProfileTapped?(collection.ownerId)
			}
		)
		.onAppear {
			loadPosts()
		}
	}
	
	private func loadPosts() {
		Task {
			do {
				let posts = try await CollectionService.shared.getCollectionPostsFromFirebase(collectionId: collection.id)
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
