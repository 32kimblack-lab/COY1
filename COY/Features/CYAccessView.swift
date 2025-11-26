import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI

struct CYAccessView: View {
	let collection: CollectionData
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var searchText = ""
	@State private var allUsers: [User] = []
	@State private var isLoading = false
	@State private var isSaving = false
	@State private var showError = false
	@State private var errorMessage = ""
	@State private var selectedUsers: Set<String> = []
	
	// Determine if this is for allowing (private) or denying (public)
	private var isPrivateCollection: Bool {
		!collection.isPublic
	}
	
	private var titleText: String {
		isPrivateCollection ? "Allow Access" : "Deny Access"
	}
	
	private var descriptionText: String {
		if isPrivateCollection {
			return "Select users to allow access to this private collection. They will be able to see it everywhere."
		} else {
			return "Select users to deny access to this public collection. They will not be able to see it anywhere."
		}
	}
	
	private var buttonText: String {
		"Update"
	}
	
	private var filteredUsers: [User] {
		let availableUsers = allUsers.filter { user in
			// Filter out current collection members, owner, and admins
			!collection.members.contains(user.id) && 
			user.id != collection.ownerId &&
			!collection.owners.contains(user.id)
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
	
	var body: some View {
		PhoneSizeContainer {
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
					
					Text(titleText)
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
					VStack(spacing: 0) {
						// Description
						VStack(alignment: .leading, spacing: 8) {
							Text(descriptionText)
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
									 ? "All users are already members or admins"
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
						
						// Save Button
						VStack(spacing: 0) {
							Divider()
								.padding(.bottom, 12)
							
							Button(action: {
								Task {
									await saveAccessChanges()
								}
							}) {
								Text(buttonText)
									.font(.system(size: 16, weight: .semibold))
									.foregroundColor(.white)
									.frame(maxWidth: .infinity)
									.padding(.vertical, 14)
									.background(isSaving ? Color.gray : Color.blue)
									.cornerRadius(12)
							}
							.disabled(isSaving)
							.padding(.horizontal, 16)
							.padding(.bottom, 20)
						}
						.background(colorScheme == .dark ? Color.black : Color.white)
					}
				}
			}
		}
		.navigationBarHidden(true)
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .navigationBar)
		.onAppear {
			if !isCurrentUserOwner {
				print("⚠️ CYAccessView: Non-owner attempted to access - dismissing")
				dismiss()
				return
			}
			loadUsers()
			loadCurrentAccess()
		}
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
			// Checkbox/Circle
			Button(action: {
				if selectedUsers.contains(user.id) {
					selectedUsers.remove(user.id)
				} else {
					selectedUsers.insert(user.id)
				}
			}) {
				ZStack {
					Circle()
						.stroke(selectedUsers.contains(user.id) ? (isPrivateCollection ? Color.green : Color.red) : Color.gray, lineWidth: 2)
						.frame(width: 24, height: 24)
					
					if selectedUsers.contains(user.id) {
						Circle()
							.fill(isPrivateCollection ? Color.green : Color.red)
							.frame(width: 16, height: 16)
					}
				}
			}
			.buttonStyle(.plain)
			
			// Profile Image
			if let imageURL = user.profileImageURL, !imageURL.isEmpty {
				CachedProfileImageView(url: imageURL, size: 50)
					.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 50)
			}
			
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
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(
			RoundedRectangle(cornerRadius: 12)
				.fill(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
		)
		.padding(.horizontal, 16)
		.padding(.vertical, 4)
		.contentShape(Rectangle())
		.onTapGesture {
			// Toggle selection when tapping anywhere on the row
			if selectedUsers.contains(user.id) {
				selectedUsers.remove(user.id)
			} else {
				selectedUsers.insert(user.id)
			}
		}
	}
	
	// MARK: - Computed Properties
	private var isCurrentUserOwner: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId || collection.owners.contains(currentUserId)
	}
	
	// MARK: - Helper Functions
	private func loadUsers() {
		isLoading = true
		Task {
			do {
				try await CYServiceManager.shared.loadCurrentUser()
				let blockedUserIds = CYServiceManager.shared.getBlockedUsers()
				
				let allUsersList = try await Task.detached(priority: .userInitiated) {
					try await UserService.shared.getAllUsers()
				}.value
				
				let blockedSet = Set(blockedUserIds)
				let membersSet = Set(collection.members)
				let ownersSet = Set(collection.owners)
				let filteredUsers = allUsersList.filter { user in
					!blockedSet.contains(user.id) &&
					!membersSet.contains(user.id) &&
					!ownersSet.contains(user.id) &&
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
	
	private func loadCurrentAccess() {
		Task {
			do {
				guard let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) else {
					return
				}
				
				await MainActor.run {
					// Load current selections based on collection type
					if isPrivateCollection {
						// For private: show users who are currently allowed
						self.selectedUsers = Set(updatedCollection.allowedUsers)
					} else {
						// For public: show users who are currently denied
						self.selectedUsers = Set(updatedCollection.deniedUsers)
					}
				}
			} catch {
				print("⚠️ CYAccessView: Error loading current access: \(error)")
			}
		}
	}
	
	private func saveAccessChanges() async {
		isSaving = true
		do {
			// Get current state
			guard let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) else {
				await MainActor.run {
					errorMessage = "Failed to load collection"
					showError = true
					isSaving = false
				}
				return
			}
			
			var newAllowedUsers = updatedCollection.allowedUsers
			var newDeniedUsers = updatedCollection.deniedUsers
			
			if isPrivateCollection {
				// For private collections: selected users go to allowedUsers
				// Remove all users from allowedUsers first, then add selected ones
				newAllowedUsers = Array(selectedUsers)
				// Remove selected users from deniedUsers (in case they were denied before)
				newDeniedUsers.removeAll { selectedUsers.contains($0) }
			} else {
				// For public collections: selected users go to deniedUsers
				// Remove all users from deniedUsers first, then add selected ones
				newDeniedUsers = Array(selectedUsers)
				// Remove selected users from allowedUsers (in case they were allowed before)
				newAllowedUsers.removeAll { selectedUsers.contains($0) }
			}
			
			// Update collection
			try await CollectionService.shared.updateCollection(
				collectionId: collection.id,
				name: nil,
				description: nil,
				image: nil,
				imageURL: nil,
				isPublic: nil,
				allowedUsers: newAllowedUsers,
				deniedUsers: newDeniedUsers
			)
			
			await MainActor.run {
				self.isSaving = false
				
				// Post notification to refresh views
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionUpdated"),
					object: collection.id
				)
				
				// Dismiss the view
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
