import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct CYCollectionMembersView: View {
	let collection: CollectionData
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var authService: AuthService
	
	@State private var searchText = ""
	@State private var owner: User?
	@State private var admins: [User] = []
	@State private var members: [User] = []
	@State private var isLoading = false
	@State private var showRemoveAlert = false
	@State private var showPromoteToAdminAlert = false
	@State private var selectedUserToRemove: User?
	@State private var selectedUserToPromote: User?
	@State private var isProcessingAction = false
	@State private var showError = false
	@State private var errorMessage = ""
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Button(action: { dismiss() }) {
					Image(systemName: "chevron.left")
						.font(.system(size: 18, weight: .semibold))
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.frame(width: 44, height: 44)
				}
				
				Spacer()
				
				Text("Members")
					.font(.system(size: 18, weight: .bold))
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Spacer()
				
				Color.clear.frame(width: 44, height: 44)
			}
			.padding(.horizontal, 16)
			.padding(.top, 60)
			.padding(.bottom, 8)
			
			// Search bar
			HStack {
				Image(systemName: "magnifyingglass")
					.foregroundColor(.gray)
				TextField("Search", text: $searchText)
					.foregroundColor(colorScheme == .dark ? .white : .black)
					.textFieldStyle(PlainTextFieldStyle())
				if !searchText.isEmpty {
					Button(action: { searchText = "" }) {
						Image(systemName: "xmark.circle.fill")
							.foregroundColor(.gray)
					}
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 12)
			.background(colorScheme == .dark ? Color.gray.opacity(0.2) : Color.gray.opacity(0.1))
			.cornerRadius(12)
			.padding(.horizontal, 16)
			.padding(.top, 8)
			
			// Scrollable Content
			if isLoading {
				Spacer()
				ProgressView("Loading members...")
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Spacer()
			} else {
				ScrollView {
					VStack(alignment: .leading, spacing: 24) {
						// Owner Section
						if let owner = owner, shouldShowUser(owner) {
							VStack(alignment: .leading, spacing: 12) {
								Text("Owner")
									.font(.system(size: 18, weight: .bold))
									.foregroundColor(colorScheme == .dark ? .white : .black)
								
								memberRow(user: owner, role: .owner)
							}
						}
						
						// Admins Section
						if !filteredAdmins.isEmpty {
							VStack(alignment: .leading, spacing: 12) {
								Text("Admins")
									.font(.system(size: 18, weight: .bold))
									.foregroundColor(colorScheme == .dark ? .white : .black)
								
								LazyVStack(spacing: 8) {
									ForEach(filteredAdmins) { admin in
										memberRow(user: admin, role: .admin)
									}
								}
							}
						}
						
						// Members Section
						if !filteredMembers.isEmpty {
							VStack(alignment: .leading, spacing: 12) {
								Text("Members")
									.font(.system(size: 18, weight: .bold))
									.foregroundColor(colorScheme == .dark ? .white : .black)
								
								LazyVStack(spacing: 8) {
									ForEach(filteredMembers) { member in
										memberRow(user: member, role: .member)
									}
								}
							}
						}
						
						// No results message
						if !searchText.isEmpty && filteredAdmins.isEmpty && filteredMembers.isEmpty && (owner == nil || !shouldShowUser(owner!)) {
							VStack(spacing: 16) {
								Image(systemName: "magnifyingglass")
									.font(.system(size: 48))
									.foregroundColor(.gray)
								
								Text("No members found")
									.font(.headline)
									.foregroundColor(colorScheme == .dark ? .white : .black)
								
								Text("Try searching with a different name or username")
									.font(.subheadline)
									.foregroundColor(.gray)
									.multilineTextAlignment(.center)
							}
							.padding(.top, 40)
						}
					}
					.padding(.horizontal, 16)
					.padding(.top, 20)
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.ignoresSafeArea(edges: .top)
		.navigationBarHidden(true)
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .navigationBar)
		.onAppear {
			loadMembers()
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
			print("🔄 CYCollectionMembersView: User unblocked, refreshing members")
			loadMembers()
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { _ in
			print("🔄 CYCollectionMembersView: User blocked, refreshing members")
			loadMembers()
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionUpdated"))) { notification in
			if let collectionId = notification.object as? String, collectionId == collection.id {
				print("🔄 CYCollectionMembersView: Collection updated, refreshing members")
				loadMembers()
			}
		}
		.alert("Remove Member", isPresented: $showRemoveAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Remove", role: .destructive) {
				if let user = selectedUserToRemove {
					removeMember(user)
				}
			}
			.disabled(isProcessingAction)
		} message: {
			if let user = selectedUserToRemove {
				Text("Are you sure you want to remove \(user.name) from this collection? They will no longer have access to this collection.")
			}
		}
		.alert("Promote to Admin", isPresented: $showPromoteToAdminAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Promote", role: .none) {
				if let user = selectedUserToPromote {
					promoteToAdmin(user)
				}
			}
			.disabled(isProcessingAction)
		} message: {
			if let user = selectedUserToPromote {
				Text("Are you sure you want to promote \(user.name) to admin? They will be able to edit the collection, pin posts, and delete posts, but cannot delete the collection or promote others.")
			}
		}
		.alert("Error", isPresented: $showError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage.isEmpty ? "An error occurred. Please try again." : errorMessage)
		}
		.overlay {
			if isProcessingAction {
				ZStack {
					Color.black.opacity(0.3)
						.ignoresSafeArea()
					ProgressView()
						.scaleEffect(1.5)
						.tint(.white)
				}
			}
		}
	}
	
	// MARK: - Member Row
	private func memberRow(user: User, role: CollectionMemberRole) -> some View {
		HStack(spacing: 12) {
			// Profile Image and Info - Clickable to navigate to user profile (but not if it's current user)
			let isCurrentUser = user.id == authService.user?.uid
			if isCurrentUser {
				// Non-clickable view for current user
				HStack(spacing: 12) {
					CachedProfileImageView(url: user.profileImageURL ?? "", size: 50)
					
					VStack(alignment: .leading, spacing: 2) {
						Text(user.name)
							.font(.system(size: 16, weight: .bold))
							.foregroundColor(colorScheme == .dark ? .white : .black)
						Text("@\(user.username)")
							.font(.system(size: 14))
							.foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.7))
					}
				}
			} else {
				// Clickable NavigationLink for other users
				NavigationLink(destination: ViewerProfileView(userId: user.id).environmentObject(authService)) {
					HStack(spacing: 12) {
						CachedProfileImageView(url: user.profileImageURL ?? "", size: 50)
						
						VStack(alignment: .leading, spacing: 2) {
							Text(user.name)
								.font(.system(size: 16, weight: .bold))
								.foregroundColor(colorScheme == .dark ? .white : .black)
							Text("@\(user.username)")
								.font(.system(size: 14))
								.foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.7))
						}
					}
				}
				.buttonStyle(.plain)
			}
			
			Spacer()
			
			// Action Buttons (only Owner and Admins can see these)
			if canCurrentUserManageMembers {
				// Only show actions for Members (not Owner or Admins)
				if role == .member {
					HStack(spacing: 12) {
						// Only Owner can promote to Admin
						if isCurrentUserOwner {
							Button(action: {
								selectedUserToPromote = user
								showPromoteToAdminAlert = true
							}) {
								Text("Admin")
									.font(.system(size: 14, weight: .medium))
									.foregroundColor(.blue)
									.padding(.horizontal, 16)
									.padding(.vertical, 8)
									.overlay(
										RoundedRectangle(cornerRadius: 8)
											.stroke(Color.blue, lineWidth: 1)
									)
							}
							.disabled(isProcessingAction)
						}
						
						// Owner and Admins can remove members
						Button(action: {
							selectedUserToRemove = user
							showRemoveAlert = true
						}) {
							Text("Remove")
								.font(.system(size: 14, weight: .medium))
								.foregroundColor(.red)
								.padding(.horizontal, 16)
								.padding(.vertical, 8)
								.overlay(
									RoundedRectangle(cornerRadius: 8)
										.stroke(Color.red, lineWidth: 1)
								)
						}
						.disabled(isProcessingAction)
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(colorScheme == .dark ? Color.gray.opacity(0.2) : Color.gray.opacity(0.1))
		.cornerRadius(12)
	}
	
	// MARK: - Computed Properties
	private var filteredAdmins: [User] {
		let filtered = admins.filter { shouldShowUser($0) }
		if searchText.isEmpty {
			return filtered
		} else {
			return filtered.filter { admin in
				admin.name.localizedCaseInsensitiveContains(searchText) ||
				admin.username.localizedCaseInsensitiveContains(searchText)
			}
		}
	}
	
	private var filteredMembers: [User] {
		let filtered = members.filter { shouldShowUser($0) }
		if searchText.isEmpty {
			return filtered
		} else {
			return filtered.filter { member in
				member.name.localizedCaseInsensitiveContains(searchText) ||
				member.username.localizedCaseInsensitiveContains(searchText)
			}
		}
	}
	
	private func shouldShowUser(_ user: User) -> Bool {
		// Check if user is blocked (mutual invisibility)
		// For immediate filtering, check blockedUsers list
		// The async check will happen when loading members
		let blockedUserIds = CYServiceManager.shared.getBlockedUsers()
		// Also check if this user blocked me (blockedByUsers)
		// We need to check Firestore for blockedByUsers
		return !blockedUserIds.contains(user.id)
	}
	
	private var isCurrentUserOwner: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId
	}
	
	private var isCurrentUserAdmin: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		// Check if user is in the owners array (admins are stored in owners)
		return collection.owners.contains(currentUserId) && collection.ownerId != currentUserId
	}
	
	private var canCurrentUserManageMembers: Bool {
		return isCurrentUserOwner || isCurrentUserAdmin
	}
	
	// MARK: - Helper Functions
	private func loadMembers() {
		isLoading = true
		Task {
			// CRITICAL FIX: Reload collection from backend to get latest member/admin data
			var updatedCollection = collection
				if let freshCollection = try? await CollectionService.shared.getCollection(collectionId: collection.id) {
					updatedCollection = freshCollection
					print("✅ CYCollectionMembersView: Reloaded collection with latest data")
			}
			
			// Get blocked users (mutual blocking check)
			guard let currentUserId = authService.user?.uid else {
				await MainActor.run { isLoading = false }
				return
			}
			
			// Load current user's blocked users
			await CYServiceManager.shared.loadCurrentUser()
			let currentUserBlocked = CYServiceManager.shared.getBlockedUsers()
			
			// Check owner - use mutual blocking
			var loadedOwner: User? = nil
			let isOwnerBlocked = await areUsersMutuallyBlocked(userId1: currentUserId, userId2: updatedCollection.ownerId)
			if !isOwnerBlocked {
				do {
					loadedOwner = try await UserService.shared.getUser(userId: updatedCollection.ownerId)
				} catch {
					print("⚠️ Failed to load owner: \(error)")
				}
			}
			
			// Load admins - use updated collection data and filter blocked users
			// Admins are stored in owners array (excluding the ownerId)
			let adminIds = updatedCollection.owners.filter { $0 != updatedCollection.ownerId }
			var filteredAdminIds: [String] = []
			for adminId in adminIds {
				// Check if user is blocked (mutual block check)
				let isBlocked = await areUsersMutuallyBlocked(userId1: currentUserId, userId2: adminId)
				if !isBlocked {
					filteredAdminIds.append(adminId)
				}
			}
			var loadedAdmins: [User] = []
			await withTaskGroup(of: User?.self) { group in
				for adminId in filteredAdminIds {
					group.addTask {
						do {
							return try await UserService.shared.getUser(userId: adminId)
						} catch {
							print("⚠️ Failed to load admin \(adminId): \(error)")
							return nil
						}
					}
				}
				for await admin in group {
					if let admin = admin {
						loadedAdmins.append(admin)
					}
				}
			}
			
			// Load members (excluding owner and admins) - use updated collection data and filter blocked users
			let adminIds = updatedCollection.owners.filter { $0 != updatedCollection.ownerId }
			let allMemberIds = updatedCollection.members.filter { memberId in
				memberId != updatedCollection.ownerId &&
				!adminIds.contains(memberId)
			}
			var filteredMemberIds: [String] = []
			for memberId in allMemberIds {
				// Check if user is blocked (mutual block check)
				let isBlocked = await areUsersMutuallyBlocked(userId1: currentUserId, userId2: memberId)
				if !isBlocked {
					filteredMemberIds.append(memberId)
				}
			}
			let memberIds = filteredMemberIds
			var loadedMembers: [User] = []
			await withTaskGroup(of: User?.self) { group in
				for memberId in memberIds {
					group.addTask {
						do {
							return try await UserService.shared.getUser(userId: memberId)
						} catch {
							print("⚠️ Failed to load member \(memberId): \(error)")
							return nil
						}
					}
				}
				for await member in group {
					if let member = member {
						loadedMembers.append(member)
					}
				}
			}
			
			await MainActor.run {
				self.owner = loadedOwner
				self.admins = loadedAdmins
				self.members = loadedMembers
				self.isLoading = false
			}
		}
	}
	
	private func removeMember(_ user: User) {
		isProcessingAction = true
		Task {
			do {
				print("🗑️ CYCollectionMembersView: Removing member \(user.id) from collection \(collection.id)")
				
				// Use CollectionService which handles both backend API and Firestore
				try await CollectionService.shared.removeMember(collectionId: collection.id, userId: user.id)
				
				print("✅ CYCollectionMembersView: Member removed successfully")
				
				await MainActor.run {
					// Remove from appropriate list immediately
					members.removeAll { $0.id == user.id }
					admins.removeAll { $0.id == user.id }
					
					// Reload members to ensure we have the latest data from backend
					loadMembers()
					
					isProcessingAction = false
				}
			} catch {
				print("❌ CYCollectionMembersView: Error removing member: \(error)")
				await MainActor.run {
					errorMessage = error.localizedDescription
					showError = true
					isProcessingAction = false
				}
			}
		}
	}
	
	private func promoteToAdmin(_ user: User) {
		isProcessingAction = true
		Task {
			do {
				print("👤 CYCollectionMembersView: Promoting member \(user.id) to admin in collection \(collection.id)")
				
				// Use CollectionService which handles both backend API and Firestore
				try await CollectionService.shared.promoteToAdmin(collectionId: collection.id, userId: user.id)
				
				print("✅ CYCollectionMembersView: Member promoted successfully")
				
				await MainActor.run {
					// Move from members to admins immediately
					members.removeAll { $0.id == user.id }
					admins.append(user)
					
					// Reload members to ensure we have the latest data from backend
					loadMembers()
					
					isProcessingAction = false
				}
			} catch {
				print("❌ CYCollectionMembersView: Error promoting to admin: \(error)")
				await MainActor.run {
					errorMessage = error.localizedDescription
					showError = true
					isProcessingAction = false
				}
			}
		}
	}
	
	// MARK: - Helper Functions
	private func areUsersMutuallyBlocked(userId1: String, userId2: String) async -> Bool {
		// Load both users' blocked lists
		let db = Firestore.firestore()
		
		do {
			let user1Doc = try await db.collection("users").document(userId1).getDocument()
			let user2Doc = try await db.collection("users").document(userId2).getDocument()
			
			let user1Blocked = (user1Doc.data()?["blockedUsers"] as? [String]) ?? []
			let user2Blocked = (user2Doc.data()?["blockedUsers"] as? [String]) ?? []
			
			// Check if either user has blocked the other
			return user1Blocked.contains(userId2) || user2Blocked.contains(userId1)
		} catch {
			print("⚠️ Error checking mutual block status: \(error)")
			return false
		}
	}
}

// MARK: - Collection Member Role (separate from CYMembersView's MemberRole)
enum CollectionMemberRole {
	case owner
	case admin
	case member
}

