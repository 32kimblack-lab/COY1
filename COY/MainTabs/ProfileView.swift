import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct ProfileView: View {
	@EnvironmentObject var authService: AuthService
	@State private var userData: [String: Any]?
	@State private var isLoadingUserData = false
	@State private var hasLoadedUserDataOnce = false
	@State private var refreshID = UUID()
	@State private var showSortMenu = false
	@State private var sortOption = "Newest to Oldest"
	@State private var profileRefreshTrigger = UUID()
	@State private var isUpdatingProfile = false
	@State private var isCustomizing = false
	@State private var selectedCollections: Set<String> = []
	@State private var customOrder: [String] = []
	@State private var allCollections: [CollectionData] = []
	@State private var userListener: ListenerRegistration?
	@State private var collectionsListener: ListenerRegistration?
	@State private var selectedCollection: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedUserId: String?
	@State private var showingProfile = false
	@State private var requestStatus: [String: Bool] = [:] // Track request status per collection
	@State private var pendingRequests: Set<String> = [] // Track collections with pending requests
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				mainContentView
			}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbarBackground(.hidden, for: .navigationBar)
			.toolbarColorScheme(.dark, for: .navigationBar)
			.navigationDestination(isPresented: $showingInsideCollection) {
				if let collection = selectedCollection {
					CYInsideCollectionView(collection: collection)
						.environmentObject(authService)
				}
			}
		.navigationDestination(isPresented: $showingProfile) {
			if let userId = selectedUserId {
				ViewerProfileView(userId: userId)
					.environmentObject(authService)
			}
		}
			.toolbar(isCustomizing ? .hidden : .automatic, for: .tabBar)
			.onAppear {
				loadSortPreference()
			// Initialize shared request state manager
			Task {
				await CollectionRequestStateManager.shared.initializeState()
			}
				
				// Start real-time listener for user data via ServiceManager
				Task {
					try? await CYServiceManager.shared.loadCurrentUser()
				}
				
				if !hasLoadedUserDataOnce {
					refreshUserData()
				} else {
					Task {
						if let cyUser = CYServiceManager.shared.currentUser {
							await MainActor.run {
								self.userData = [
									"profileImageURL": cyUser.profileImageURL,
									"backgroundImageURL": cyUser.backgroundImageURL,
									"name": cyUser.name,
									"username": cyUser.username,
									"email": "",
									"birthDay": "",
									"birthMonth": "",
									"birthYear": "",
									"collectionSortPreference": cyUser.collectionSortPreference ?? "Newest to Oldest",
									"customCollectionOrder": cyUser.customCollectionOrder
								]
								self.profileRefreshTrigger = UUID()
							}
						}
					}
				}
			}
			.onDisappear {
				userListener?.remove()
				collectionsListener?.remove()
			}
			.refreshable {
			// Complete refresh: Clear all caches and force fresh reload
			await completeRefresh()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
			handleProfileUpdate(notification)
					}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in }
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { _ in }
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToProfile"))) { _ in }
			.overlay {
				sortMenuOverlay
			}
		// Request state is managed by CollectionRequestStateManager.shared
		// No need for notification listeners here - the manager handles it
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionOrderUpdated"))) { _ in
				loadSortPreference()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionCreated"))) { _ in
				if isCustomizing {
					loadCollectionsForCustomization()
				}
			}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionRestored"))) { _ in
				loadCollectionsForCustomization()
			NotificationCenter.default.post(name: NSNotification.Name("UserCollectionsUpdated"), object: nil)
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionUpdated"))) { _ in
				loadCollectionsForCustomization()
			}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionDeleted"))) { notification in
			// Immediately remove deleted collection from the list
			if let collectionId = notification.object as? String {
				// Check if this is the current user's collection
				let ownerId = notification.userInfo?["ownerId"] as? String
				let isPermanent = notification.userInfo?["permanent"] as? Bool ?? false
				
				// If ownerId matches current user, or if it's a permanent delete, remove it
				if ownerId == authService.user?.uid || isPermanent {
					// Remove from allCollections (used in customization mode)
					allCollections.removeAll { $0.id == collectionId }
					// Also remove from selectedCollections and customOrder if present
					selectedCollections.remove(collectionId)
					customOrder.removeAll { $0 == collectionId }
					print("✅ ProfileView: Removed deleted collection \(collectionId) from allCollections immediately (permanent: \(isPermanent))")
					// Also trigger UserCollectionsUpdated to refresh the main view
					NotificationCenter.default.post(name: NSNotification.Name("UserCollectionsUpdated"), object: nil)
				}
			}
		}
		.overlay(customizeOverlay)
	}
	
	private var customizeOverlay: some View {
				Group {
					if isCustomizing {
						VStack {
							Spacer()
							HStack {
								Button("Clear") {
									selectedCollections.removeAll()
									customOrder.removeAll()
									isCustomizing = false
									if sortOption == "Customize" {
										sortOption = "Newest to Oldest"
									}
								}
								.foregroundColor(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 10)
								.background(Color.gray.opacity(0.3))
								.cornerRadius(8)
								
								Spacer()
								
								Text("\(selectedCollections.count) collection\(selectedCollections.count == 1 ? "" : "s") selected")
									.foregroundColor(.white)
									.font(.system(size: 14))
								
								Spacer()
								
								Button("Done") {
									saveCustomOrder()
								}
								.foregroundColor(.black)
								.padding(.horizontal, 20)
								.padding(.vertical, 10)
								.background(Color.white)
								.cornerRadius(8)
							}
							.padding(.horizontal, 20)
							.padding(.vertical, 15)
							.background(Color(red: 0.2, green: 0.2, blue: 0.2))
						}
					}
				}
	}
	
	private func handleProfileUpdate(_ notification: Notification) {
		if let userInfo = notification.userInfo,
		   let updatedData = userInfo["updatedData"] as? [String: Any] {
			if let userId = authService.user?.uid {
				UserService.shared.clearUserCache(userId: userId)
			}
			if self.userData == nil {
				self.userData = updatedData
			} else {
				for (key, value) in updatedData {
					self.userData?[key] = value
				}
			}
			refreshUserData(forceRefresh: true)
			self.profileRefreshTrigger = UUID()
		}
	}
	
	private var mainContentView: some View {
		GeometryReader { geometry in
			ScrollViewReader { proxy in
				ZStack(alignment: .topLeading) {
				(colorScheme == .dark ? Color.black : Color.white)
					.ignoresSafeArea()
				
					// Background Image - Full width, outside PhoneSizeContainer constraints
					if let backgroundImageURL = userData?["backgroundImageURL"] as? String, !backgroundImageURL.isEmpty {
						CachedBackgroundImageView(
							url: backgroundImageURL,
							height: 105
						)
						.aspectRatio(contentMode: .fill)
						.frame(width: geometry.size.width, height: 105)
						.clipped()
						.ignoresSafeArea(edges: .top)
						.id(backgroundImageURL)
					}
					
				VStack(spacing: 0) {
					// Top anchor for scroll-to-top
					Color.clear
						.frame(height: 0)
						.id("topAnchor")
					
					// Fixed Profile Header (doesn't scroll) - Always show
					profileHeaderSection(safeAreaTop: 0)
					.id("\(profileRefreshTrigger)-\(userData?["profileImageURL"] as? String ?? "")-\(userData?["backgroundImageURL"] as? String ?? "")")
				
				// Collections Section (List handles its own scrolling)
				if isCustomizing {
					CustomizeCollectionsView(
						allCollections: $allCollections,
						selectedCollections: $selectedCollections,
						customOrder: $customOrder
					)
					.padding(.top, -20)
				} else {
					UserCollectionsView(sortOption: sortOption)
						.padding(.top, -20)
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToTopProfile"))) { _ in
					withAnimation {
						proxy.scrollTo("topAnchor", anchor: .top)
					}
				}
			}
			}
		}
	}
	
	@ViewBuilder
	private var sortMenuOverlay: some View {
		Group {
			if showSortMenu {
				ZStack(alignment: .topLeading) {
					Color.black.opacity(0.01)
						.ignoresSafeArea()
						.onTapGesture { withAnimation { showSortMenu = false } }
					
					VStack(alignment: .leading, spacing: 0) {
						Button(action: {
							Task {
								await updateSortPreference("Newest to Oldest")
							}
							withAnimation { showSortMenu = false }
						}) {
							HStack {
								Text("Newest to Oldest")
									.font(.caption)
									.foregroundColor(sortOption == "Newest to Oldest" ? .blue : (colorScheme == .dark ? .white : .black))
								Spacer()
								if sortOption == "Newest to Oldest" {
									Image(systemName: "checkmark")
										.font(.caption)
										.foregroundColor(.blue)
								}
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 8)
						}
						
						Divider()
						
						Button(action: {
							Task {
								await updateSortPreference("Oldest to Newest")
							}
							withAnimation { showSortMenu = false }
						}) {
							HStack {
								Text("Oldest to Newest")
									.font(.caption)
									.foregroundColor(sortOption == "Oldest to Newest" ? .blue : (colorScheme == .dark ? .white : .black))
								Spacer()
								if sortOption == "Oldest to Newest" {
									Image(systemName: "checkmark")
										.font(.caption)
										.foregroundColor(.blue)
								}
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 8)
						}
						
						Divider()
						
						Button(action: {
							Task {
								await updateSortPreference("Alphabetical")
							}
							withAnimation { showSortMenu = false }
						}) {
							HStack {
								Text("Alphabetical (A-Z)")
									.font(.caption)
									.foregroundColor(sortOption == "Alphabetical" ? .blue : (colorScheme == .dark ? .white : .black))
								Spacer()
								if sortOption == "Alphabetical" {
									Image(systemName: "checkmark")
										.font(.caption)
										.foregroundColor(.blue)
								}
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 8)
						}
						
						Divider()
						
						Button(action: {
							// Enter customization mode
							withAnimation { showSortMenu = false }
							isCustomizing = true
							selectedCollections.removeAll()
							customOrder.removeAll()
							// Always reload fresh collections when entering customize mode
							// This ensures newly created collections are included
							loadCollectionsForCustomization()
						}) {
							HStack {
								Text("Customize")
									.font(.caption)
									.foregroundColor(sortOption == "Customize" ? .blue : (colorScheme == .dark ? .white : .black))
								Spacer()
								if sortOption == "Customize" {
									Image(systemName: "checkmark")
										.font(.caption)
										.foregroundColor(.blue)
								}
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 8)
						}
					}
					.frame(maxWidth: 160)
					.padding(.horizontal, 2)
					.padding(.vertical, 2)
					.background(
						RoundedRectangle(cornerRadius: 8)
							.fill(Color(.systemBackground))
							.shadow(radius: 2)
					)
					.padding(.top, 80)
					.padding(.leading, 16)
				}
			}
		}
	}
	
	private func profileHeaderSection(safeAreaTop: CGFloat) -> some View {
		ZStack(alignment: .topLeading) {
			// Background Image Area - Always reserve 105 points height, whether image exists or not
			// This ensures layout stays consistent with or without background image
			// Note: Background image is now rendered in mainContentView to extend full width
				Color.clear
					.frame(height: 105)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
					.ignoresSafeArea(edges: .top)
			
			// Top Buttons Row - Vertically centered on background (at 52.5 points from top of background)
			VStack {
				Spacer()
				HStack {
					// Left Buttons (List + Plus)
					HStack(spacing: 16) {
						Button(action: {
							showSortMenu.toggle()
						}) {
							CircleButton(systemName: "list.bullet", colorScheme: colorScheme)
						}
						NavigationLink(destination: CYBuildCollectionDesign().environmentObject(authService)) {
							CircleButton(systemName: "plus", colorScheme: colorScheme)
						}
					}
					Spacer()
					// Right Buttons (Pencil + Gear)
					HStack(spacing: 16) {
						NavigationLink(destination: EditProfileDesign().environmentObject(authService)) {
							CircleButton(systemName: "pencil", colorScheme: colorScheme)
						}
						.id(refreshID)
						NavigationLink(destination: CYSettingsView().environmentObject(authService)) {
							CircleButton(systemName: "gearshape.fill", colorScheme: colorScheme)
						}
					}
				}
				.padding(.horizontal, 16)
				Spacer()
			}
			.frame(height: 105) // Match background height
			
			// Profile Image - Half on background, half below
			// Background height is 105, profile image is 70, so center at 105 (half of image = 35 above, 35 below)
			Group {
				if let userData = userData {
					if let profileImageURL = userData["profileImageURL"] as? String, !profileImageURL.isEmpty {
						CachedProfileImageView(
							url: profileImageURL,
							size: 70
						)
						.aspectRatio(contentMode: .fill)
						.frame(width: 70, height: 70)
						.clipShape(Circle())
						.id(profileImageURL) // Force refresh when URL changes
					} else {
						DefaultProfileImageView(size: 70)
					}
				} else {
					// Show default placeholder (no loading spinner)
					DefaultProfileImageView(size: 70)
				}
			}
			.offset(y: 105 - 35) // Center at bottom edge of background (105) - half image height (35) = 70
			.frame(maxWidth: .infinity, alignment: .center)
			
			// Username + Name - Below profile image, centered
			// Position is fixed regardless of background image presence
			VStack(spacing: 4) {
				if let userData = userData {
					Text(userData["username"] as? String ?? "Username")
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Text(userData["name"] as? String ?? "Name")
						.font(.subheadline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
				} else {
					// Show loading placeholders
					Rectangle()
						.fill(Color.gray.opacity(0.3))
						.frame(width: 100, height: 20)
						.cornerRadius(4)
					Rectangle()
						.fill(Color.gray.opacity(0.3))
						.frame(width: 80, height: 16)
						.cornerRadius(4)
				}
			}
			.frame(maxWidth: .infinity)
			.offset(y: 105 + 35 + 8) // Below background (105) + half profile image (35) + spacing (8)
		}
		.frame(height: 105 + 35 + 60) // Background (105) + half profile image (35) + username/name section (60)
		.ignoresSafeArea(edges: .top)
	}
	
	private func initializeRequestState() {
		// Check for existing pending request notifications
		Task {
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			do {
				let notifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
				await MainActor.run {
					for notification in notifications {
						if notification.type == "collection_request" && notification.status == "pending",
						   let collectionId = notification.collectionId {
							requestStatus[collectionId] = true
							pendingRequests.insert(collectionId)
						}
					}
				}
			} catch {
				print("Error initializing request state: \(error)")
			}
		}
	}
	
	private func loadSortPreference() {
		Task {
			sortOption = CYServiceManager.shared.getCollectionSortPreference()
		}
	}
	
	private func updateSortPreference(_ newSortOption: String) async {
		do {
			try await CYServiceManager.shared.updateCollectionSortPreference(newSortOption)
			sortOption = newSortOption
		} catch {
			// Silent fail - user can try again
		}
	}
	
	// MARK: - Custom Organization Functions
	private func loadCollectionsForCustomization() {
		Task {
			guard let userId = authService.user?.uid else { return }
			
			do {
				// Load current user to get their custom order
				try await CYServiceManager.shared.loadCurrentUser()
				
				// Always fetch fresh collections from Firebase (don't use cache)
				// This ensures newly created collections are included
				let userCollections = try await CollectionService.shared.getUserCollections(userId: userId, forceFresh: true)
				
				// Get custom order
				let customCollectionOrder = CYServiceManager.shared.getCustomCollectionOrder()
				
				// Sort collections by custom order if available
				var sortedCollections: [CollectionData]
				if customCollectionOrder.isEmpty {
					// No custom order, use creation date (newest first)
					sortedCollections = userCollections.sorted { $0.createdAt > $1.createdAt }
				} else {
					// Sort by custom order
					sortedCollections = userCollections.sorted { (a, b) -> Bool in
						let indexA = customCollectionOrder.firstIndex(of: a.id) ?? Int.max
						let indexB = customCollectionOrder.firstIndex(of: b.id) ?? Int.max
						
						if indexA == Int.max && indexB == Int.max {
							// Both not in custom order, sort by creation date (newest first)
							return a.createdAt > b.createdAt
						}
						return indexA < indexB
					}
				}
				
				await MainActor.run {
					self.allCollections = sortedCollections
				}
			} catch {
				// Silent fail - collections will load on next refresh
			}
		}
	}
	
	private func saveCustomOrder() {
		guard authService.user?.uid != nil else {
			return
		}
		
		Task {
			do {
				// Update local state via CYServiceManager (updates local cache)
				try await CYServiceManager.shared.updateCustomCollectionOrder(customOrder)
				try await CYServiceManager.shared.updateCollectionSortPreference("Customize")
				
				await MainActor.run {
					sortOption = "Customize"
					isCustomizing = false
					selectedCollections.removeAll()
					
					// Don't clear cache or reload - UserCollectionsView will use sortedCollections computed property
					// which automatically respects the new custom order from CYServiceManager
					// This prevents collections from moving around
					
					// Only post notification to update sort preference (don't force reload)
					NotificationCenter.default.post(name: Notification.Name("CollectionOrderUpdated"), object: nil)
				}
			} catch {
				// Silent fail - user can try again
			}
		}
	}
	
	// MARK: - Load User Data from Firebase
	
	// MARK: - Complete Refresh (Pull-to-Refresh)
	/// Complete refresh: Clear all caches, reload current user, reload everything from scratch
	/// Equivalent to exiting and re-entering the app
	private func completeRefresh() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		print("🔄 ProfileView: Starting COMPLETE refresh (equivalent to app restart)")
		
		// Step 1: Clear ALL caches first (including user profile caches)
		await MainActor.run {
			CollectionPostsCache.shared.clearAllCache()
			HomeViewCache.shared.clearCache()
			// Clear user profile caches to force fresh profile image/name loads
			UserService.shared.clearUserCache(userId: currentUserId)
			print("✅ ProfileView: Cleared all caches (including user profile caches)")
		}
		
		// Step 2: Reload current user data - FORCE FRESH
		do {
			// Stop existing listener and reload fresh
			CYServiceManager.shared.stopListening()
			try await CYServiceManager.shared.loadCurrentUser()
			print("✅ ProfileView: Reloaded current user data (fresh from Firestore)")
		} catch {
			print("⚠️ ProfileView: Error reloading current user: \(error)")
		}
		
		// Step 3: Reload user profile data and collections - FORCE FRESH
		refreshUserData(forceRefresh: true)
		// Post notification to reload collections in UserCollectionsView
		NotificationCenter.default.post(name: NSNotification.Name("UserCollectionsUpdated"), object: nil)
	}
	
	private func refreshUserData(forceRefresh: Bool = false) {
		guard let userId = authService.user?.uid else {
			return
		}
		
		// Don't load if already loading
		guard !isLoadingUserData else {
			return
		}
		
		// If we have cached data and not forcing refresh, skip loading
		if hasLoadedUserDataOnce && userData != nil && !forceRefresh {
			print("⏭️ ProfileView: Using cached user data")
			return
		}
		
		isLoadingUserData = true
		Task {
			do {
				// Clear cache to force fresh data from Firebase (source of truth) only if forcing refresh
				if forceRefresh {
				UserService.shared.clearUserCache(userId: userId)
				}
				
				// Load from Firebase (source of truth)
				let user = try await UserService.shared.getUser(userId: userId)
				
				// Also load CYServiceManager data for preferences
				try await CYServiceManager.shared.loadCurrentUser()
				let cyUser = CYServiceManager.shared.currentUser
				
				await MainActor.run {
					if let user = user {
						// Use data from Firebase (source of truth)
						self.userData = [
							"profileImageURL": user.profileImageURL ?? "",
							"backgroundImageURL": user.backgroundImageURL ?? "",
							"name": user.name,
							"username": user.username,
							"email": user.email,
							"birthDay": user.birthDay,
							"birthMonth": user.birthMonth,
							"birthYear": user.birthYear,
							"collectionSortPreference": cyUser?.collectionSortPreference ?? "Newest to Oldest",
							"customCollectionOrder": cyUser?.customCollectionOrder ?? [String]()
						]
						print("✅ ProfileView: Loaded fresh user data from Firebase (source of truth)")
						print("   - Profile URL: \(user.profileImageURL ?? "nil")")
						print("   - Background URL: \(user.backgroundImageURL ?? "nil")")
						print("   - Name: \(user.name)")
						print("   - Username: \(user.username)")
					} else {
						// Fallback to CYUser data if UserService fails
						if let cyUser = cyUser {
							self.userData = [
								"profileImageURL": cyUser.profileImageURL,
								"backgroundImageURL": cyUser.backgroundImageURL,
								"name": cyUser.name,
								"username": cyUser.username,
								"email": "",
								"birthDay": "",
								"birthMonth": "",
								"birthYear": "",
								"collectionSortPreference": cyUser.collectionSortPreference ?? "Newest to Oldest",
								"customCollectionOrder": cyUser.customCollectionOrder
							]
							print("✅ ProfileView: Loaded CYUser data (fallback)")
						}
					}
					
					// Force UI refresh with new trigger ID
					self.profileRefreshTrigger = UUID()
					
					print("🔄 ProfileView: UI refreshed with trigger ID including URLs")
					
					self.isLoadingUserData = false
					self.hasLoadedUserDataOnce = true
				}
			} catch {
				print("❌ ProfileView: Error loading user data: \(error)")
				await MainActor.run {
					self.isLoadingUserData = false
					self.hasLoadedUserDataOnce = true
				}
			}
		}
	}
}

struct CircleButton: View {
	let systemName: String
	let colorScheme: ColorScheme
	
	var body: some View {
		ZStack {
			// Darker, more transparent background
			Circle()
				.fill(Color.gray.opacity(0.4)) // Darker gray with more opacity
				.frame(width: 36, height: 36)
			Image(systemName: systemName)
				.foregroundColor(colorScheme == .dark ? .white : .black)
				.font(.system(size: 16, weight: .medium))
		}
	}
}

// MARK: - Customize Collections View
struct CustomizeCollectionsView: View {
	@Binding var allCollections: [CollectionData]
	@Binding var selectedCollections: Set<String>
	@Binding var customOrder: [String]
	@State private var selectedCollection: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedUserId: String?
	@State private var showingProfile = false
	@State private var requestStatus: [String: Bool] = [:] // Track request status per collection
	@State private var pendingRequests: Set<String> = [] // Track collections with pending requests
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	var body: some View {
		collectionsList
	}
	
	private var collectionsList: some View {
		List {
			if allCollections.isEmpty {
				emptyStateView
			} else {
				collectionsRows
			}
		}
		.listStyle(PlainListStyle())
		.scrollContentBackground(.hidden)
		.background(colorScheme == .dark ? Color.black : Color.white)
		.safeAreaInset(edge: .bottom, spacing: 0) {
			Color.clear
				.frame(height: 80)
		}
		.navigationDestination(isPresented: $showingInsideCollection) {
			if let collection = selectedCollection {
				CYInsideCollectionView(collection: collection)
					.environmentObject(authService)
			}
		}
		.navigationDestination(isPresented: $showingProfile) {
			if let userId = selectedUserId {
				ViewerProfileView(userId: userId)
					.environmentObject(authService)
			}
		}
		.onAppear {
			initializeRequestState()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestSent"))) { notification in
			// Update request status when request is sent - works for ANY collection
			if let collectionId = notification.object as? String ?? notification.userInfo?["collectionId"] as? String,
			   let requesterId = notification.userInfo?["requesterId"] as? String,
			   requesterId == Auth.auth().currentUser?.uid {
				requestStatus[collectionId] = true
				pendingRequests.insert(collectionId)
				print("✅ CustomizeCollectionsView: Request status updated to true for collection \(collectionId)")
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestCancelled"))) { notification in
			// Update request status when request is cancelled - works for ANY collection
			if let collectionId = notification.object as? String ?? notification.userInfo?["collectionId"] as? String,
			   let requesterId = notification.userInfo?["requesterId"] as? String,
			   requesterId == Auth.auth().currentUser?.uid {
				requestStatus[collectionId] = false
				pendingRequests.remove(collectionId)
				print("✅ CustomizeCollectionsView: Request status updated to false for collection \(collectionId)")
			}
		}
	}
	
	private func initializeRequestState() {
		Task {
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			do {
				let notifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
				await MainActor.run {
					for notification in notifications {
						if notification.type == "collection_request" && notification.status == "pending",
						   let collectionId = notification.collectionId {
							requestStatus[collectionId] = true
							pendingRequests.insert(collectionId)
						}
					}
				}
			} catch {
				print("Error initializing request state: \(error)")
			}
		}
	}
	
	private var emptyStateView: some View {
		VStack {
			Spacer()
			Text("No Collections")
				.font(.headline)
				.foregroundColor(.gray)
			Text("Create some collections first")
				.font(.subheadline)
				.foregroundColor(.gray)
			Spacer()
		}
		.frame(maxWidth: .infinity)
		.listRowInsets(EdgeInsets())
		.listRowSeparator(.hidden)
		.listRowBackground(Color.clear)
	}
	
	private var collectionsRows: some View {
		ForEach(allCollections, id: \.id) { collection in
			collectionRow(collection: collection)
		}
	}
	
	private func collectionRow(collection: CollectionData) -> some View {
		HStack(alignment: .center, spacing: 12) {
			// Selection circle - FIXED position from left, always visible
			selectionButton(collection: collection)
				.frame(width: 40, height: 40)
				.buttonStyle(PlainButtonStyle())
				.fixedSize(horizontal: true, vertical: false)
			
			// Collection row - flexible width with navigation
				CollectionRowDesign(
					collection: collection,
					isFollowing: false,
					hasRequested: CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id),
					isMember: {
						let currentUserId = Auth.auth().currentUser?.uid ?? ""
						return collection.members.contains(currentUserId) || collection.owners.contains(currentUserId)
					}(),
					isOwner: collection.ownerId == Auth.auth().currentUser?.uid,
					onFollowTapped: {},
					onActionTapped: {},
				onProfileTapped: {
					// Check if users are mutually blocked before navigating
					Task {
						let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: collection.ownerId)
						if !areMutuallyBlocked {
					selectedUserId = collection.ownerId
					showingProfile = true
						}
					}
				},
				onCollectionTapped: {
					Task {
						await handleCollectionTap(collection: collection)
					}
				}
				)
				.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
		}
		.padding(.vertical, 4)
		.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
		.listRowSeparator(.hidden)
		.listRowBackground(Color.clear)
	}
	
	private func selectionButton(collection: CollectionData) -> some View {
		Button(action: {
			toggleCollectionSelection(collection)
		}) {
			ZStack {
				Circle()
					.stroke(colorScheme == .dark ? Color.white : Color.black, lineWidth: 2)
					.frame(width: 24, height: 24)
				
				if selectedCollections.contains(collection.id) {
					if let index = customOrder.firstIndex(of: collection.id) {
						Text("\(index + 1)")
							.foregroundColor(colorScheme == .dark ? .white : .black)
							.font(.system(size: 12, weight: .bold))
					}
				}
			}
		}
	}
	
	private func toggleCollectionSelection(_ collection: CollectionData) {
		let collectionId = collection.id
		
		if selectedCollections.contains(collectionId) {
			selectedCollections.remove(collectionId)
			customOrder.removeAll { $0 == collectionId }
		} else {
			selectedCollections.insert(collectionId)
			customOrder.append(collectionId)
		}
	}
	
	private func handleCollectionTap(collection: CollectionData) async {
		// Check if this is a private collection
		if !collection.isPublic {
			// Check if current user is owner, admin, or member
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			let isMember = collection.members.contains(currentUserId)
			let isOwner = collection.ownerId == currentUserId
			let isAdmin = collection.owners.contains(currentUserId)
			
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
}

// MARK: - User Collections View
struct UserCollectionsView: View {
	let sortOption: String
	@EnvironmentObject var authService: AuthService
	@State private var userCollections: [CollectionData] = []
	@State private var isLoading = false
	@State private var selectedCollection: CollectionData?
	@State private var showingInsideCollection = false
	@State private var selectedUserId: String?
	@State private var showingProfile = false
	@State private var hasLoadedCollectionsOnce = false // Track if collections have been loaded
	@State private var requestStatus: [String: Bool] = [:] // Track request status per collection
	@State private var pendingRequests: Set<String> = [] // Track collections with pending requests
	@State private var showingBuildCollection = false
	@Environment(\.colorScheme) var colorScheme
	
	var sortedCollections: [CollectionData] {
		let collections = userCollections
		switch sortOption {
		case "Oldest to Newest":
			return collections.sorted { $0.createdAt < $1.createdAt }
		case "Alphabetical":
			return collections.sorted { $0.name < $1.name }
		case "Customize":
			let customOrder = CYServiceManager.shared.getCustomCollectionOrder()
			if customOrder.isEmpty {
				return collections.sorted { $0.createdAt > $1.createdAt }
			}
			return collections.sorted { (a, b) -> Bool in
				let indexA = customOrder.firstIndex(of: a.id) ?? Int.max
				let indexB = customOrder.firstIndex(of: b.id) ?? Int.max
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
		List {
			if isLoading {
				ProgressView()
					.frame(maxWidth: .infinity)
					.padding()
			} else if sortedCollections.isEmpty {
				VStack(spacing: 16) {
					Spacer()
					Text("No Collections")
						.font(.headline)
						.foregroundColor(.gray)
					Text("Create your first collection")
						.font(.subheadline)
						.foregroundColor(.gray)
					
					HStack {
						Spacer()
						Button(action: {
							showingBuildCollection = true
						}) {
							Text("Build a Collection")
								.font(.headline)
								.foregroundColor(.white)
								.padding(.horizontal, 24)
								.padding(.vertical, 12)
								.background(Color.blue)
								.cornerRadius(10)
						}
						.buttonStyle(.plain)
						.contentShape(Rectangle())
						Spacer()
					}
					.padding(.top, 8)
					
					Spacer()
				}
				.frame(maxWidth: .infinity)
				.listRowInsets(EdgeInsets())
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
			} else {
				ForEach(sortedCollections) { collection in
						CollectionRowDesign(
							collection: collection,
							isFollowing: false,
							hasRequested: CollectionRequestStateManager.shared.hasPendingRequest(for: collection.id),
							isMember: {
								let currentUserId = Auth.auth().currentUser?.uid ?? ""
								return collection.members.contains(currentUserId) || collection.owners.contains(currentUserId)
							}(),
							isOwner: collection.ownerId == Auth.auth().currentUser?.uid,
							onFollowTapped: {},
							onActionTapped: {},
						onProfileTapped: {
							// Navigate to owner's profile
							selectedUserId = collection.ownerId
							showingProfile = true
						},
						onCollectionTapped: {
							Task {
								await handleCollectionTap(collection: collection)
							}
						}
						)
						.padding(.horizontal)
						.padding(.bottom, 12)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
				}
			}
		}
		.listStyle(PlainListStyle())
		.scrollContentBackground(.hidden)
		.background(colorScheme == .dark ? Color.black : Color.white)
		.refreshable {
			// Complete refresh: Clear all caches and force fresh reload
			await completeRefreshForUserCollections()
		}
		.onAppear {
			// Only load collections if we haven't loaded them before
			// This prevents reloading when navigating back to the view
			if !hasLoadedCollectionsOnce {
			loadCollections()
			}
			// Initialize request state from notifications
			initializeRequestState()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserCollectionsUpdated"))) { _ in
			loadCollections(forceRefresh: true)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionCreated"))) { _ in
			loadCollections(forceRefresh: true)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUpdated"))) { notification in
			// Refresh when collection is updated (e.g., user joined, privacy changed, etc.)
			var shouldReload = false
			
			// Check if collection ID is in notification object
			if let collectionId = notification.object as? String {
				// Check if this collection is in the user's collections
				if userCollections.contains(where: { $0.id == collectionId }) {
					shouldReload = true
				}
			}
			
			// Also check userInfo for collectionId (fallback)
			if !shouldReload, let userInfo = notification.userInfo {
				if let updatedData = userInfo["updatedData"] as? [String: Any],
				   let collectionId = updatedData["collectionId"] as? String,
				   userCollections.contains(where: { $0.id == collectionId }) {
					shouldReload = true
				} else if let action = userInfo["action"] as? String,
				   action == "memberAdded" {
					shouldReload = true
				}
			}
			
			// Reload if this is one of the user's collections or if it's a member addition
			if shouldReload {
				loadCollections(forceRefresh: true)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteAccepted"))) { _ in
			// Refresh when user accepts an invite
			loadCollections(forceRefresh: true)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestSent"))) { notification in
			// Update request status when request is sent - works for ANY collection
			if let collectionId = notification.object as? String ?? notification.userInfo?["collectionId"] as? String,
			   let requesterId = notification.userInfo?["requesterId"] as? String,
			   requesterId == Auth.auth().currentUser?.uid {
				requestStatus[collectionId] = true
				pendingRequests.insert(collectionId)
				print("✅ UserCollectionsView: Request status updated to true for collection \(collectionId)")
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestCancelled"))) { notification in
			// Update request status when request is cancelled - works for ANY collection
			if let collectionId = notification.object as? String ?? notification.userInfo?["collectionId"] as? String,
			   let requesterId = notification.userInfo?["requesterId"] as? String,
			   requesterId == Auth.auth().currentUser?.uid {
				requestStatus[collectionId] = false
				pendingRequests.remove(collectionId)
				print("✅ UserCollectionsView: Request status updated to false for collection \(collectionId)")
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionDeleted"))) { notification in
			// Immediately remove deleted collection from the list
			if let collectionId = notification.object as? String {
				// Check if this is the current user's collection
				let ownerId = notification.userInfo?["ownerId"] as? String
				let isPermanent = notification.userInfo?["permanent"] as? Bool ?? false
				
				// If ownerId matches current user, or if it's a permanent delete, remove it
				if ownerId == authService.user?.uid || isPermanent {
					// Remove the collection from the list immediately
					userCollections.removeAll { $0.id == collectionId }
					print("✅ UserCollectionsView: Removed deleted collection \(collectionId) from list immediately (permanent: \(isPermanent))")
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionHidden"))) { notification in
			// Immediately remove hidden collection from the list
			if let collectionId = notification.object as? String {
				userCollections.removeAll { $0.id == collectionId }
				print("🚫 UserCollectionsView: Removed hidden collection \(collectionId) from list immediately")
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnhidden"))) { notification in
			// Reload collections when a collection is unhidden
			if let collectionId = notification.object as? String {
				print("✅ UserCollectionsView: Collection \(collectionId) was unhidden, reloading collections")
				loadCollections(forceRefresh: true)
			}
		}
		.navigationDestination(isPresented: $showingInsideCollection) {
			if let collection = selectedCollection {
				CYInsideCollectionView(collection: collection)
					.environmentObject(authService)
			}
		}
		.navigationDestination(isPresented: $showingProfile) {
			if let userId = selectedUserId {
				ViewerProfileView(userId: userId)
					.environmentObject(authService)
			}
		}
		.navigationDestination(isPresented: $showingBuildCollection) {
			CYBuildCollectionDesign()
				.environmentObject(authService)
		}
	}
	
	// MARK: - Complete Refresh (Pull-to-Refresh)
	/// Complete refresh: Clear all caches, reload user data, reload everything from scratch
	/// Equivalent to exiting and re-entering the app
	private func completeRefreshForUserCollections() async {
		guard let currentUserId = authService.user?.uid else { return }
		
		print("🔄 UserCollectionsView: Starting COMPLETE refresh (equivalent to app restart)")
		
		// Step 1: Clear ALL caches first (including user profile caches)
		await MainActor.run {
			CollectionPostsCache.shared.clearAllCache()
			HomeViewCache.shared.clearCache()
			// Clear user profile caches to force fresh profile image/name loads
			UserService.shared.clearUserCache(userId: currentUserId)
			print("✅ UserCollectionsView: Cleared all caches (including user profile caches)")
		}
		
		// Step 2: Reload current user data - FORCE FRESH
		do {
			// Stop existing listener and reload fresh
			CYServiceManager.shared.stopListening()
			try await CYServiceManager.shared.loadCurrentUser()
			print("✅ UserCollectionsView: Reloaded current user data (fresh from Firestore)")
		} catch {
			print("⚠️ UserCollectionsView: Error reloading current user: \(error)")
		}
		
		// Step 3: Reload collections - FORCE FRESH
		loadCollections(forceRefresh: true)
	}
	
	private func loadCollections(forceRefresh: Bool = false) {
		guard authService.user?.uid != nil else { return }
		
		// If we have cached collections and not forcing refresh, skip loading
		if hasLoadedCollectionsOnce && !userCollections.isEmpty && !forceRefresh {
			print("⏭️ UserCollectionsView: Using cached collections")
			return
		}
		
		isLoading = true
		Task {
			do {
				guard let userId = authService.user?.uid else { return }
				// Only force fresh if explicitly requested (pull-to-refresh)
				let collections = try await CollectionService.shared.getUserCollections(userId: userId, forceFresh: forceRefresh)
				await MainActor.run {
					self.userCollections = collections
					self.isLoading = false
					self.hasLoadedCollectionsOnce = true
				}
			} catch {
				print("Error loading collections: \(error)")
				await MainActor.run {
					self.isLoading = false
				}
			}
		}
	}
	
	private func initializeRequestState() {
		// Check for existing pending request notifications
		Task {
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			do {
				let notifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
				await MainActor.run {
					for notification in notifications {
						if notification.type == "collection_request" && notification.status == "pending",
						   let collectionId = notification.collectionId {
							requestStatus[collectionId] = true
							pendingRequests.insert(collectionId)
						}
					}
				}
			} catch {
				print("Error initializing request state: \(error)")
			}
		}
	}
	
	private func handleCollectionTap(collection: CollectionData) async {
		// Check if this is a private collection
		if !collection.isPublic {
			// Check if current user is owner, admin, or member
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			let isMember = collection.members.contains(currentUserId)
			let isOwner = collection.ownerId == currentUserId
			let isAdmin = collection.owners.contains(currentUserId)
			
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
}


