import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CYAccessView: View {
	let collection: CollectionData
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var searchText = ""
	@State private var selectedUserIds: Set<String> = []
	@State private var allUsers: [User] = []
	@State private var isLoading = false
	@State private var isSaving = false
	@State private var showError = false
	@State private var errorMessage = ""
	@State private var currentAccessUsers: [String] = []
	
	// Determine if this is for allowing access (private) or denying access (public)
	private var isPrivateCollection: Bool {
		!collection.isPublic
	}
	
	private var accessTitle: String {
		isPrivateCollection ? "Allow Access" : "Limit Viewers"
	}
	
	private var accessDescription: String {
		isPrivateCollection 
			? "Allow access to users without giving them membership or ownership"
			: "Limit viewers to viewing this collection without making it private"
	}
	
	private var filteredUsers: [User] {
		let availableUsers = allUsers.filter { user in
			// Filter out current collection members and owner
			!collection.members.contains(user.id) && user.id != collection.ownerId
		}
		
		if searchText.isEmpty {
			return availableUsers
		} else {
			return availableUsers.filter { user in
				user.name.localizedCaseInsensitiveContains(searchText) ||
				user.username.localizedCaseInsensitiveContains(searchText)
			}
		}
	}
	
	// Check if there are any changes from the original access users
	private var hasChanges: Bool {
		let currentSet = Set(currentAccessUsers)
		return selectedUserIds != currentSet
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
					
					Text(accessTitle)
						.font(.system(size: 18, weight: .bold))
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					Spacer()
					
					// Done button - show when there are changes
					if hasChanges {
						Button(action: {
							Task {
								await saveAccessChanges()
							}
						}) {
							if isSaving {
								ProgressView()
									.scaleEffect(0.8)
									.frame(width: 44, height: 44)
							} else {
								Text("Done")
									.font(.system(size: 16, weight: .semibold))
									.foregroundColor(.blue)
									.frame(width: 44, height: 44)
							}
						}
						.disabled(isSaving)
					} else {
						// Invisible spacer to center the title when no changes
						Color.clear
							.frame(width: 44, height: 44)
					}
				}
				.padding(.horizontal, 16)
				.padding(.top, 20)
				.padding(.bottom, 10)
				
				if isLoading {
					ProgressView()
						.scaleEffect(1.2)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					VStack(spacing: 0) {
						// Description
						VStack(alignment: .leading, spacing: 8) {
							Text(accessDescription)
								.font(.subheadline)
								.foregroundColor(.gray)
								.multilineTextAlignment(.leading)
								.padding(.horizontal, 16)
						}
						.padding(.bottom, 20)
						
						// Search Bar
						HStack {
							Image(systemName: "magnifyingglass")
								.foregroundColor(.gray)
							TextField("Search users...", text: $searchText)
								.textFieldStyle(PlainTextFieldStyle())
						}
						.padding(.horizontal, 16)
						.padding(.vertical, 12)
						.background(
							RoundedRectangle(cornerRadius: 10)
								.fill(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
						)
						.padding(.horizontal, 16)
						.padding(.bottom, 20)
						
						// Users List
						if filteredUsers.isEmpty {
							VStack(spacing: 20) {
								Image(systemName: "person.2")
									.font(.system(size: 60))
									.foregroundColor(.gray)
								
								Text("No Users Found")
									.font(.title2)
									.fontWeight(.semibold)
									.foregroundColor(colorScheme == .dark ? .white : .black)
								
								Text(searchText.isEmpty 
									 ? "All users are already members or have access"
									 : "No users match your search")
									.font(.subheadline)
									.foregroundColor(.gray)
									.multilineTextAlignment(.center)
									.padding(.horizontal, 40)
							}
							.frame(maxWidth: .infinity, maxHeight: .infinity)
						} else {
							ScrollView {
								LazyVStack(spacing: 0) {
									ForEach(filteredUsers) { user in
										userRow(user: user)
									}
								}
							}
						}
						
						// Bottom save button (alternative to header Done button)
						// Show when there are changes and we want a more prominent save button
						if hasChanges {
							Button(action: {
								Task {
									await saveAccessChanges()
								}
							}) {
								HStack {
									if isSaving {
										ProgressView()
											.scaleEffect(0.8)
											.foregroundColor(.white)
									} else {
										Image(systemName: isPrivateCollection ? "checkmark.circle" : "xmark.circle")
											.font(.system(size: 16, weight: .medium))
										
										Text("Save Changes")
											.font(.system(size: 16, weight: .semibold))
									}
								}
								.foregroundColor(.white)
								.frame(maxWidth: .infinity)
								.padding(.vertical, 16)
								.background(
									RoundedRectangle(cornerRadius: 12)
										.fill(isPrivateCollection ? Color.green : Color.red)
								)
								.padding(.horizontal, 16)
							}
							.disabled(isSaving)
							.padding(.bottom, 20)
						}
					}
				}
			}
		}
		.navigationBarHidden(true)
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .navigationBar)
		.onAppear {
			// Defensive check: Only owners can manage access
			if !isCurrentUserOwner {
				print("⚠️ CYAccessView: Non-owner attempted to access access view - dismissing")
				dismiss()
				return
			}
			loadUsers()
			loadCurrentAccessUsers()
		}
		.alert("Error", isPresented: $showError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage)
		}
	}
	
	// MARK: - User Row
	private func userRow(user: User) -> some View {
		HStack(spacing: 12) {
			// Profile Image
			CachedProfileImageView(url: user.profileImageURL ?? "", size: 50)
			
			// User Info
			VStack(alignment: .leading, spacing: 2) {
				Text(user.username)
					.font(.system(size: 16, weight: .bold))
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Text(user.name)
					.font(.system(size: 14))
					.foregroundColor(.gray)
			}
			
			Spacer()
			
			// Selection Toggle
			Button(action: {
				if selectedUserIds.contains(user.id) {
					selectedUserIds.remove(user.id)
				} else {
					selectedUserIds.insert(user.id)
				}
			}) {
				Image(systemName: selectedUserIds.contains(user.id) ? "checkmark.circle.fill" : "circle")
					.font(.system(size: 24))
					.foregroundColor(selectedUserIds.contains(user.id) 
								   ? (isPrivateCollection ? .green : .red)
								   : .gray)
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
	
	// MARK: - Computed Properties
	
	private var isCurrentUserOwner: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		// Check if user is the original creator OR is in the owners array (promoted)
		return collection.ownerId == currentUserId || collection.owners.contains(currentUserId)
	}
	
	// MARK: - Helper Functions
	private func loadUsers() {
		isLoading = true
		Task {
			do {
				// Load current user to get blocked users list
				try await CYServiceManager.shared.loadCurrentUser()
				
				// Get blocked users list
				let blockedUserIds = CYServiceManager.shared.getBlockedUsers()
				print("🚫 CYAccessView: Filtering out \(blockedUserIds.count) blocked users")
				
				// Load all users using UserService (off main thread)
				// Note: UserService.getAllUsers() still uses Firestore to get user list
				// until backend has a search/list users endpoint
				let allUsersList = try await Task.detached(priority: .userInitiated) {
					try await UserService.shared.getAllUsers()
				}.value
				
				// Filter out blocked users and users already in collection (efficient)
				let blockedSet = Set(blockedUserIds)
				let membersSet = Set(collection.members)
				let filteredUsers = allUsersList.filter { user in
					!blockedSet.contains(user.id) &&
					!membersSet.contains(user.id) &&
					user.id != collection.ownerId
				}
				
				await MainActor.run {
					self.allUsers = filteredUsers
					self.isLoading = false
				}
			} catch {
				print("❌ CYAccessView: Error loading users: \(error)")
				await MainActor.run {
					self.isLoading = false
				}
			}
		}
	}
	
	private func loadCurrentAccessUsers() {
		Task {
			do {
				// CRITICAL FIX: Load collection access data from backend API (source of truth)
				// Backend returns allowedUsers and deniedUsers in the collection response
				guard let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) else {
					print("⚠️ CYAccessView: Collection not found")
					return
				}
				
				let allowedUsers = updatedCollection.allowedUsers
				let deniedUsers = updatedCollection.deniedUsers
				
				print("✅ CYAccessView: Loaded access data from backend")
				print("   - Allowed users: \(allowedUsers.count)")
				print("   - Denied users: \(deniedUsers.count)")
				
				let accessField = isPrivateCollection ? allowedUsers : deniedUsers
				await MainActor.run {
					self.currentAccessUsers = accessField
					self.selectedUserIds = Set(accessField)
				}
			} catch {
				print("⚠️ CYAccessView: Error loading current access users from backend: \(error)")
				// Fallback to Firestore if backend fails
				do {
					let db = Firestore.firestore()
					let doc = try await db.collection("collections").document(collection.id).getDocument()
					
					guard let data = doc.data() else {
						print("⚠️ CYAccessView: Collection document not found in Firestore")
						return
					}
					
					let allowedUsers = data["allowedUsers"] as? [String] ?? []
					let deniedUsers = data["deniedUsers"] as? [String] ?? []
					
					let accessField = isPrivateCollection ? allowedUsers : deniedUsers
					await MainActor.run {
						self.currentAccessUsers = accessField
						self.selectedUserIds = Set(accessField)
					}
					print("✅ CYAccessView: Loaded access data from Firestore fallback")
				} catch {
					print("❌ CYAccessView: Error loading from Firestore fallback: \(error)")
				}
			}
		}
	}
	
	private func saveAccessChanges() async {
		isSaving = true
		
		do {
			// CRITICAL FIX: Always send arrays, even if empty
			// Backend might require the field to be present
			let allowedUsersArray = Array(selectedUserIds)
			let deniedUsersArray = Array(selectedUserIds)
			
			// Save access changes via backend API
			if isPrivateCollection {
				// For private collections, update allowedUsers
				// CRITICAL: Send empty array if no users selected, don't send nil
				try await CollectionService.shared.updateCollection(
					collectionId: collection.id,
					name: nil,
					description: nil,
					image: nil,
					imageURL: nil,
					isPublic: nil,  // Don't change visibility
					allowedUsers: allowedUsersArray,  // Always send array, even if empty
					deniedUsers: nil  // Don't update deniedUsers for private collections
				)
			} else {
				// For public collections, update deniedUsers
				// CRITICAL: Send empty array if no users selected, don't send nil
				try await CollectionService.shared.updateCollection(
					collectionId: collection.id,
					name: nil,
					description: nil,
					image: nil,
					imageURL: nil,
					isPublic: nil,  // Don't change visibility
					allowedUsers: nil,  // Don't update allowedUsers for public collections
					deniedUsers: deniedUsersArray  // Always send array, even if empty
				)
			}
			
			// CRITICAL FIX: Verify update was saved (like edit profile)
			print("🔍 Verifying access changes were saved...")
			let verifiedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id)
			guard let verifiedCollection = verifiedCollection else {
				throw NSError(domain: "AccessUpdateError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to verify access update"])
			}
			
			let verifiedAllowedUsers = verifiedCollection.allowedUsers
			let verifiedDeniedUsers = verifiedCollection.deniedUsers
			
			print("✅ Verified access update - Allowed: \(verifiedAllowedUsers.count), Denied: \(verifiedDeniedUsers.count)")
			
			// CRITICAL FIX: Post comprehensive notifications with verified data (like edit profile)
			await MainActor.run {
				// Build update data with verified access changes from Firebase
				var updateData: [String: Any] = [
					"collectionId": collection.id
				]
				
				if isPrivateCollection {
					updateData["allowedUsers"] = verifiedAllowedUsers
				} else {
					updateData["deniedUsers"] = verifiedDeniedUsers
				}
				
				// Post CollectionUpdated with verified access data
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionUpdated"),
					object: collection.id,
					userInfo: ["updatedData": updateData]
				)
				
				// Post ProfileUpdated to refresh profile views (collections list)
				NotificationCenter.default.post(
					name: NSNotification.Name("ProfileUpdated"),
					object: nil,
					userInfo: ["updatedData": ["collectionId": collection.id]]
				)
				
				print("📢 CYAccessView: Posted comprehensive collection update notifications")
				print("   - Collection ID: \(collection.id)")
				print("   - Verified access: \(isPrivateCollection ? "allowedUsers" : "deniedUsers") = \(isPrivateCollection ? verifiedAllowedUsers.count : verifiedDeniedUsers.count) users")
				
				dismiss()
			}
			
		} catch {
			await MainActor.run {
				errorMessage = error.localizedDescription
				showError = true
				isSaving = false
			}
		}
	}
}

