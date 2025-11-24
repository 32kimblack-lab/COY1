import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CYMembersView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	let collection: CollectionData
	@State private var members: [MemberInfo] = []
	@State private var isLoading = false
	@State private var showError = false
	@State private var errorMessage = ""
	
	// Current user's role
	private var currentUserRole: MemberRole {
		guard let currentUserId = authService.user?.uid else { return .member }
		if collection.ownerId == currentUserId {
			return .creator
		}
		// Check if user is in admins array (we'll need to add this to CollectionData)
		// For now, check if they're in owners array but not the original owner
		if collection.owners.contains(currentUserId) && currentUserId != collection.ownerId {
			return .admin
		}
		return .member
	}
	
	// Check if current user is creator
	private var isCurrentUserCreator: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId
	}
	
	var body: some View {
		ZStack {
			(colorScheme == .dark ? Color.black : Color.white)
				.ignoresSafeArea()
			
			VStack(spacing: 0) {
				// Header
				HStack {
					Button(action: { dismiss() }) {
						Image(systemName: "chevron.left")
							.font(.system(size: 18, weight: .medium))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					.frame(width: 44, height: 44)
					
					Spacer()
					
					Text("Members")
						.font(.system(size: 18, weight: .bold))
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					Spacer()
					
					Color.clear
						.frame(width: 44, height: 44)
				}
				.padding(.horizontal, 16)
				.padding(.top, 20)
				.padding(.bottom, 10)
				
				if isLoading {
					ProgressView()
						.scaleEffect(1.2)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					ScrollView {
						LazyVStack(spacing: 0) {
							ForEach(members) { member in
								memberRow(member: member)
							}
						}
					}
				}
			}
		}
		.navigationBarHidden(true)
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .navigationBar)
		.onAppear {
			loadMembers()
		}
		.alert("Error", isPresented: $showError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage)
		}
	}
	
	// MARK: - Member Row
	private func memberRow(member: MemberInfo) -> some View {
		HStack(spacing: 12) {
			// Profile Image
			CachedProfileImageView(url: member.profileImageURL ?? "", size: 50)
			
			// User Info
			VStack(alignment: .leading, spacing: 2) {
				Text(member.username)
					.font(.system(size: 16, weight: .bold))
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Text(member.name)
					.font(.system(size: 14))
					.foregroundColor(.gray)
			}
			
			Spacer()
			
			// Role Badge
			HStack(spacing: 8) {
				Text(member.role.displayName)
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(member.role.color)
					.padding(.horizontal, 12)
					.padding(.vertical, 6)
					.background(
						Capsule()
							.fill(member.role.color.opacity(0.1))
					)
				
				// Promote to Admin button (only creator can see this for members)
				if isCurrentUserCreator && member.role == .member {
					Button(action: {
						Task {
							await promoteToAdmin(userId: member.userId)
						}
					}) {
						Image(systemName: "arrow.up.circle")
							.font(.system(size: 20))
							.foregroundColor(.blue)
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(
			RoundedRectangle(cornerRadius: 12)
				.fill(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
		)
		.padding(.horizontal, 16)
		.padding(.vertical, 4)
	}
	
	// MARK: - Helper Functions
	private func loadMembers() {
		isLoading = true
		Task {
			do {
				// Load collection from Firestore to get current roles
				let db = Firestore.firestore()
				let doc = try await db.collection("collections").document(collection.id).getDocument()
				guard let data = doc.data() else {
					await MainActor.run {
						isLoading = false
					}
					return
				}
				
				// Get owner ID - always use collection.ownerId as fallback
				let ownerId = data["ownerId"] as? String ?? collection.ownerId
				
				// Get admins from Firestore (might not exist, so default to empty array)
				let admins = data["admins"] as? [String] ?? []
				
				// Get members list from Firestore
				var membersList = data["members"] as? [String] ?? []
				
				// For Individual collections, ensure owner is included
				if collection.type == "Individual" {
					// For Individual collections, owner is the only member
					// Make sure owner is in the list
					if !membersList.contains(ownerId) {
						membersList = [ownerId]
					}
				} else {
					// For other collection types, ensure owner is in members list if not already
					if !membersList.contains(ownerId) {
						membersList.append(ownerId)
					}
				}
				
				// Get all unique user IDs (owner, admins, members)
				// Start with owner first, then admins, then members
				var allUserIds: [String] = []
				
				// 1. Always add owner first
				allUserIds.append(ownerId)
				
				// 2. Add admins (excluding owner to avoid duplicates)
				for adminId in admins {
					if adminId != ownerId && !allUserIds.contains(adminId) {
						allUserIds.append(adminId)
					}
				}
				
				// 3. Add members (excluding owner and admins to avoid duplicates)
				for memberId in membersList {
					if memberId != ownerId && !admins.contains(memberId) && !allUserIds.contains(memberId) {
						allUserIds.append(memberId)
					}
				}
				
				// Load user info for each
				var loadedMembers: [MemberInfo] = []
				for userId in allUserIds {
					do {
						let user = try await UserService.shared.getUser(userId: userId)
						if let user = user {
							let role: MemberRole
							if userId == ownerId {
								role = .creator
							} else if admins.contains(userId) {
								role = .admin
							} else {
								role = .member
							}
							
							loadedMembers.append(MemberInfo(
								userId: userId,
								username: user.username,
								name: user.name,
								profileImageURL: user.profileImageURL,
								role: role
							))
						}
					} catch {
						print("⚠️ Failed to load user \(userId): \(error)")
					}
				}
				
				// Sort: Creator first, then admins, then members (alphabetically within each group)
				loadedMembers.sort { member1, member2 in
					// Creator always first
					if member1.role == .creator { return true }
					if member2.role == .creator { return false }
					
					// Admins before members
					if member1.role == .admin && member2.role == .member { return true }
					if member1.role == .member && member2.role == .admin { return false }
					
					// Within same role, sort alphabetically by username
					return member1.username < member2.username
				}
				
				await MainActor.run {
					self.members = loadedMembers
					self.isLoading = false
				}
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
					showError = true
					isLoading = false
				}
			}
		}
	}
	
	private func promoteToAdmin(userId: String) async {
		do {
			print("👤 CYMembersView: Promoting user \(userId) to admin")
			try await CollectionService.shared.promoteToAdmin(collectionId: collection.id, userId: userId)
			print("✅ CYMembersView: User promoted successfully")
			
			// Reload members to get latest data
			loadMembers()
		} catch {
			print("❌ CYMembersView: Error promoting to admin: \(error)")
			await MainActor.run {
				errorMessage = error.localizedDescription
				showError = true
			}
		}
	}
}

// MARK: - Member Info
struct MemberInfo: Identifiable {
	var id: String { userId }
	let userId: String
	let username: String
	let name: String
	let profileImageURL: String?
	var role: MemberRole
}

// MARK: - Member Role
enum MemberRole {
	case creator
	case admin
	case member
	
	var displayName: String {
		switch self {
		case .creator:
			return "Creator"
		case .admin:
			return "Admin"
		case .member:
			return "Member"
		}
	}
	
	var color: Color {
		switch self {
		case .creator:
			return .purple
		case .admin:
			return .blue
		case .member:
			return .gray
		}
	}
}

