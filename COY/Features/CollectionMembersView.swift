import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CollectionMembersView: View {
	@State var collection: CollectionData
	@Environment(\.dismiss) var dismiss
	@EnvironmentObject var authService: AuthService
	
	@State private var owner: UserService.AppUser?
	@State private var admins: [UserService.AppUser] = []
	@State private var members: [UserService.AppUser] = []
	@State private var isLoading = true
	@State private var errorMessage: String?
	
	// Track join dates for sorting
	@State private var memberJoinDates: [String: Date] = [:]
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				Group {
					if isLoading {
						ProgressView()
							.frame(maxWidth: .infinity, maxHeight: .infinity)
					} else if let error = errorMessage {
						VStack(spacing: 12) {
							Image(systemName: "exclamationmark.triangle")
								.font(.system(size: 48))
								.foregroundColor(.red)
							Text("Error loading members")
								.font(.headline)
							Text(error)
								.font(.subheadline)
								.foregroundColor(.secondary)
								.multilineTextAlignment(.center)
						}
						.padding()
					} else {
						ScrollView {
							LazyVStack(spacing: 16) {
								// Owner Section
								if let owner = owner {
									SectionView(
										title: "Owner",
										users: [owner],
										collection: collection,
										currentUserId: authService.user?.uid,
										isOwner: true,
										isAdmin: false,
										onMemberRemoved: { loadMembers() },
										onMemberPromoted: { loadMembers() }
									)
								}
								
								// Admins Section
								if !admins.isEmpty {
									SectionView(
										title: "Admin",
										users: admins,
										collection: collection,
										currentUserId: authService.user?.uid,
										isOwner: isCurrentUserOwner,
										isAdmin: isCurrentUserAdmin,
										onMemberRemoved: { loadMembers() },
										onMemberPromoted: { loadMembers() }
									)
								}
								
								// Members Section
								if !members.isEmpty {
									SectionView(
										title: "Members",
										users: members,
										collection: collection,
										currentUserId: authService.user?.uid,
										isOwner: isCurrentUserOwner,
										isAdmin: isCurrentUserAdmin,
										onMemberRemoved: { loadMembers() },
										onMemberPromoted: { loadMembers() }
									)
								}
							}
							.padding()
						}
					}
				}
			}
			.navigationTitle("Members")
			.navigationBarTitleDisplayMode(.large)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
			.onAppear {
				loadMembers()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUpdated"))) { notification in
				if let updatedCollectionId = notification.object as? String,
				   updatedCollectionId == collection.id {
					// Reload collection data first, then members
					Task {
						if let updatedCollection = try? await CollectionService.shared.getCollection(collectionId: collection.id) {
							await MainActor.run {
								collection = updatedCollection
							}
						}
						loadMembers()
					}
				}
			}
		}
	}
	
	private var isCurrentUserOwner: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId
	}
	
	private var isCurrentUserAdmin: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.owners.contains(currentUserId) && collection.ownerId != currentUserId
	}
	
	private func loadMembers() {
		isLoading = true
		errorMessage = nil
		
		Task {
			do {
				// Load owner
				let ownerUser = try await UserService.shared.getUser(userId: collection.ownerId)
				
				// Load admins (users in owners array but not the owner)
				var adminUsers: [UserService.AppUser] = []
				for adminId in collection.owners where adminId != collection.ownerId {
					if let admin = try? await UserService.shared.getUser(userId: adminId) {
						adminUsers.append(admin)
					}
				}
				
				// Load members (users in members array, excluding owner and admins)
				var memberUsers: [UserService.AppUser] = []
				var joinDates: [String: Date] = [:]
				
				// Get member join dates from collection document
				let db = Firestore.firestore()
				let collectionRef = db.collection("collections").document(collection.id)
				let collectionDoc = try await collectionRef.getDocument()
				
				if let memberJoinData = collectionDoc.data()?["memberJoinDates"] as? [String: Timestamp] {
					for (userId, timestamp) in memberJoinData {
						joinDates[userId] = timestamp.dateValue()
					}
				}
				
				// Load member users
				for memberId in collection.members {
					// Skip if already in owner or admins
					if memberId == collection.ownerId || collection.owners.contains(memberId) {
						continue
					}
					
					if let member = try? await UserService.shared.getUser(userId: memberId) {
						memberUsers.append(member)
					}
				}
				
				// Sort members by join date (most recent first)
				memberUsers.sort { member1, member2 in
					let date1 = joinDates[member1.id] ?? Date.distantPast
					let date2 = joinDates[member2.id] ?? Date.distantPast
					return date1 > date2
				}
				
				await MainActor.run {
					self.owner = ownerUser
					self.admins = adminUsers
					self.members = memberUsers
					self.memberJoinDates = joinDates
					self.isLoading = false
				}
			} catch {
				await MainActor.run {
					self.errorMessage = error.localizedDescription
					self.isLoading = false
				}
			}
		}
	}
}

// MARK: - Section View
struct SectionView: View {
	let title: String
	let users: [UserService.AppUser]
	let collection: CollectionData
	let currentUserId: String?
	let isOwner: Bool
	let isAdmin: Bool
	let onMemberRemoved: () -> Void
	let onMemberPromoted: () -> Void
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title)
				.font(.headline)
				.foregroundColor(.primary)
				.padding(.horizontal, 4)
			
			ForEach(users) { user in
				MemberRow(
					user: user,
					collection: collection,
					currentUserId: currentUserId,
					isOwner: isOwner,
					isAdmin: isAdmin,
					onRemoved: onMemberRemoved,
					onPromoted: onMemberPromoted
				)
			}
		}
	}
}

// MARK: - Member Row
struct MemberRow: View {
	let user: UserService.AppUser
	let collection: CollectionData
	let currentUserId: String?
	let isOwner: Bool
	let isAdmin: Bool
	let onRemoved: () -> Void
	let onPromoted: () -> Void
	
	@State private var isRemoving = false
	@State private var isPromoting = false
	@State private var showRemoveAlert = false
	
	var body: some View {
		HStack(spacing: 12) {
			// Profile Image
			if let profileImageURL = user.profileImageURL, !profileImageURL.isEmpty {
				CachedProfileImageView(url: profileImageURL, size: 50)
					.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 50)
			}
			
			// User Info
			VStack(alignment: .leading, spacing: 4) {
				Text(user.name)
					.font(.subheadline)
					.fontWeight(.medium)
					.foregroundColor(.primary)
				
				Text("@\(user.username)")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			
			Spacer()
			
			// Action Buttons
			if shouldShowActions {
				HStack(spacing: 8) {
					// Promote to Admin button (only owner can promote members to admin)
					if isOwner && isMember {
						Button(action: {
							promoteToAdmin()
						}) {
							Text("Admin")
								.font(.system(size: 12, weight: .semibold))
								.foregroundColor(.white)
								.frame(minWidth: 60, maxWidth: 60)
								.padding(.vertical, 6)
								.background(isPromoting ? Color.gray : Color.blue)
								.cornerRadius(8)
						}
						.buttonStyle(.plain)
						.disabled(isPromoting)
					}
					
					// Remove button
					// - Owner can remove admins and members
					// - Admin can only remove members (not admins, not owner)
					if canRemove {
						Button(action: {
							showRemoveAlert = true
						}) {
							Text("Remove")
								.font(.system(size: 12, weight: .semibold))
								.foregroundColor(.white)
								.frame(minWidth: 60, maxWidth: 60)
								.padding(.vertical, 6)
								.background(isRemoving ? Color.gray : Color.red)
								.cornerRadius(8)
						}
						.buttonStyle(.plain)
						.disabled(isRemoving)
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(Color(.systemBackground))
		.cornerRadius(12)
		.shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
		.alert("Remove Member", isPresented: $showRemoveAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Remove", role: .destructive) {
				removeMember()
			}
		} message: {
			Text("Are you sure you want to remove \(user.name) from this collection?")
		}
	}
	
	private var isOwnerUser: Bool {
		// Check if this user is the collection owner
		return user.id == collection.ownerId
	}
	
	private var isAdminUser: Bool {
		// Check if this user is an admin (in owners array but not the owner)
		return collection.owners.contains(user.id) && user.id != collection.ownerId
	}
	
	private var isMember: Bool {
		// Check if user is a member (not owner, not admin)
		return collection.members.contains(user.id) &&
			   user.id != collection.ownerId &&
			   !collection.owners.contains(user.id)
	}
	
	private var isCurrentUser: Bool {
		guard let currentUserId = currentUserId else { return false }
		return user.id == currentUserId
	}
	
	private var shouldShowActions: Bool {
		// NEVER show actions for owner - owner should have no buttons
		if isOwnerUser {
			return false
		}
		
		// Don't show actions for current user
		if isCurrentUser {
			return false
		}
		
		// Owner (current user) can see actions for admins and members
		if isOwner {
			return isAdminUser || isMember
		}
		
		// Admin (current user) can only see actions for members (not admins, not owner)
		if isAdmin {
			return isMember
		}
		
		return false
	}
	
	private var canRemove: Bool {
		// NEVER allow removing the owner
		if isOwnerUser {
			return false
		}
		
		// Owner (current user) can remove admins and members
		if isOwner {
			return isAdminUser || isMember
		}
		
		// Admin (current user) can only remove members (not admins, not owner)
		if isAdmin {
			return isMember
		}
		
		return false
	}
	
	private func promoteToAdmin() {
		guard isOwner && isMember else { return }
		
		isPromoting = true
		
		Task {
			do {
				try await CollectionService.shared.promoteToAdmin(
					collectionId: collection.id,
					userId: user.id
				)
				
				await MainActor.run {
					isPromoting = false
					onPromoted()
				}
			} catch {
				await MainActor.run {
					isPromoting = false
					print("Error promoting member to admin: \(error.localizedDescription)")
				}
			}
		}
	}
	
	private func removeMember() {
		isRemoving = true
		
		Task {
			do {
				try await CollectionService.shared.removeUserFromCollection(
					collectionId: collection.id,
					userIdToRemove: user.id
				)
				
				await MainActor.run {
					isRemoving = false
					onRemoved()
				}
			} catch {
				await MainActor.run {
					isRemoving = false
					print("Error removing member: \(error.localizedDescription)")
				}
			}
		}
	}
}

