import SwiftUI
import PhotosUI
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth

struct CYBuildCollectionDesign: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var collectionName = ""
	@State private var description = ""
	@State private var isPublic = true
	@State private var selectedType: String? = nil
	@State private var selectedImage: UIImage?
	@State private var showPhotoPicker = false
	@State private var showInviteSheet = false
	@State private var searchText = ""
	@State private var allUsers: [User] = []
	@State private var invitedUsers: Set<String> = []
	@State private var isCreating = false
	@State private var errorMessage: String?
	@State private var showErrorAlert = false
	@State private var userAge: Int? = nil
	
	let collectionTypes = ["Individual", "Invite", "Request", "Open"]
	
	// Check if Open collection option should be disabled
	// Only disable if we KNOW the user is under 18
	// If age is nil, allow selection (we'll verify on create)
	var isOpenDisabled: Bool {
		if let age = userAge {
			return age < 18
		}
		// If age hasn't loaded yet, allow selection (we'll verify age when creating)
		return false
	}
	
	var canCreate: Bool {
		!collectionName.isEmpty &&
		selectedType != nil &&
		!isCreating &&
		!(selectedType == "Open" && isOpenDisabled) // Can't create if Open is selected but disabled
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// MARK: Fixed Header (like settings)
			HStack {
				Button(action: {
					dismiss()
				}) {
					Image(systemName: "chevron.left")
						.font(.title2)
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.frame(width: 44, height: 44)
						.contentShape(Rectangle())
				}
				
				Spacer()
				Text("Build a Collection")
					.font(.headline)
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Spacer()
				
				// Spacer to balance the back button (no Done button here - use Create button at bottom)
				Color.clear
					.frame(width: 44, height: 44)
			}
			.padding(.horizontal)
			.padding(.top, 16)
			.padding(.bottom, 10)
			.background(colorScheme == .dark ? Color.black : Color.white)
			
			// MARK: Scrollable Content
			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					// MARK: Photo Picker Section
					VStack(spacing: 12) {
						Button {
							showPhotoPicker = true
						} label: {
							ZStack {
								Circle()
									.fill(colorScheme == .dark ? Color(white: 0.15) : Color(.systemGray6))
									.frame(width: 120, height: 120)
									.overlay(Circle().stroke(Color.blue, lineWidth: 2))
								
								if let image = selectedImage {
									Image(uiImage: image)
										.resizable()
										.aspectRatio(contentMode: .fill)
										.frame(width: 116, height: 116)
										.clipShape(Circle())
								} else {
									VStack(spacing: 6) {
										Image(systemName: "camera.fill")
											.font(.system(size: 28))
											.foregroundColor(.blue)
										Text("Add Photo")
											.font(.caption)
											.foregroundColor(.blue)
									}
								}
							}
						}
						
						Text("Collection Photo")
							.font(.headline)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						
						Text("Your profile image will be used if no photo is selected")
							.font(.caption)
							.foregroundColor(.gray)
							.multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity)
					.padding(.horizontal)
					.padding(.top, 8)
					
					// MARK: Collection Name
					VStack(alignment: .leading, spacing: 8) {
						Text("Collection Name")
							.font(.headline)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						TextField("Name", text: $collectionName)
							.padding()
							.background(colorScheme == .dark ? Color(white: 0.15) : Color(.systemGray6))
							.cornerRadius(10)
					}
					.padding(.horizontal)
					
					// MARK: Description
					VStack(alignment: .leading, spacing: 8) {
						TextField("Caption (Optional)", text: $description)
							.padding()
							.background(colorScheme == .dark ? Color(white: 0.15) : Color(.systemGray6))
							.cornerRadius(10)
					}
					.padding(.horizontal)
					
					// MARK: Collection Options
					VStack(alignment: .leading, spacing: 16) {
						Text("Collection Options")
							.font(.headline)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						Text("Please select one out of the four options")
							.font(.subheadline)
							.foregroundColor(.gray)
						
						VStack(spacing: 10) {
							ForEach(collectionTypes, id: \.self) { type in
								Button {
									withAnimation {
										// Prevent selecting Open if user is under 18
										if type == "Open" && isOpenDisabled {
											errorMessage = "An open collection requires the user to be 18 or older."
											showErrorAlert = true
											return
										}
										
										selectedType = type
										// Request and Open collections must be public
										if type == "Request" || type == "Open" {
											isPublic = true
										}
									}
								} label: {
									VStack(alignment: .leading, spacing: 4) {
										Text(type)
											.font(.headline)
											.foregroundColor((type == "Open" && isOpenDisabled) ? Color.gray : (colorScheme == .dark ? .white : .black))
										
										Text(typeDescription(type))
											.font(.subheadline)
											.foregroundColor(.gray)
										
										// Show age restriction message if under 18
										if type == "Open", isOpenDisabled {
											Text("An open collection requires the user to be 18 or older.")
												.font(.caption)
												.foregroundColor(.red)
										}
									}
									.padding()
									.frame(maxWidth: .infinity, alignment: .leading)
									.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
									.cornerRadius(10)
									.overlay(
										RoundedRectangle(cornerRadius: 10)
											.stroke(selectedType == type ? Color.blue : Color.clear, lineWidth: 2)
									)
									.opacity((type == "Open" && isOpenDisabled) ? 0.5 : 1.0)
								}
								.buttonStyle(.plain)
								.disabled(type == "Open" && isOpenDisabled)
							}
						}
					}
					.padding(.horizontal)
					
					// MARK: Invite Users Button (for Invite collections)
					if selectedType == "Invite" {
						Button(action: {
							loadAllUsers()
							showInviteSheet = true
						}) {
							HStack {
								Image(systemName: "person.2.fill")
									.font(.headline)
								Text("Invite Users")
									.font(.headline)
									.fontWeight(.semibold)
								if !invitedUsers.isEmpty {
									Text("(\(invitedUsers.count))")
										.font(.subheadline)
								}
							}
							.foregroundColor(.gray)
							.frame(maxWidth: .infinity)
							.padding()
							.background(Color.gray.opacity(0.2))
							.cornerRadius(10)
							.overlay(
								RoundedRectangle(cornerRadius: 10)
									.stroke(Color.blue, lineWidth: 2)
							)
						}
						.padding(.horizontal)
						.padding(.top, 8)
					}
					
					// MARK: Visibility
					VStack(alignment: .leading, spacing: 8) {
						Text("Who Can View")
							.font(.headline)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						
						HStack {
							VStack(alignment: .leading, spacing: 4) {
								Text(isPublic ? "Public" : "Private")
									.font(.headline)
									.foregroundColor(colorScheme == .dark ? .white : .black)
								Text(isPublic ? "Turn off to make private" : "Turn on to make public")
									.font(.caption)
									.foregroundColor(.gray)
							}
							Spacer()
							Toggle("", isOn: $isPublic)
								.labelsHidden()
								.toggleStyle(SwitchToggleStyle(tint: .blue))
								.disabled(selectedType == "Request" || selectedType == "Open")
						}
						.padding()
						.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
						.cornerRadius(10)
						
						Text(visibilityDescription())
							.font(.footnote)
							.foregroundColor(.gray)
							.padding(.top, 2)
					}
					.padding(.horizontal)
					
					// MARK: Create Button
					Button(action: {
						Task {
							await createCollection()
						}
					}) {
						Text(isCreating ? "Creating..." : "Create")
							.font(.headline)
							.foregroundColor(.white)
							.frame(maxWidth: .infinity)
							.padding()
							.background(canCreate ? Color.blue : Color.gray.opacity(0.4))
							.cornerRadius(10)
					}
					.disabled(!canCreate)
					.padding(.horizontal)
					.padding(.bottom, 30)
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.sheet(isPresented: $showPhotoPicker) {
			PhotoPicker(selectedImage: $selectedImage)
		}
		.sheet(isPresented: $showInviteSheet) {
			InviteUsersSheet(
				allUsers: $allUsers,
				invitedUsers: $invitedUsers,
				searchText: $searchText
			)
		}
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .tabBar)
		.alert("Error", isPresented: $showErrorAlert) {
			Button("OK") { }
		} message: {
			Text(errorMessage ?? "An error occurred")
		}
		.overlay {
			if isCreating {
				ZStack {
					Color.black.opacity(0.4)
						.ignoresSafeArea()
					VStack(spacing: 16) {
						ProgressView()
							.scaleEffect(1.5)
							.tint(.white)
						Text("Creating collection...")
							.font(.headline)
							.foregroundColor(.white)
					}
					.padding(30)
					.background(
						RoundedRectangle(cornerRadius: 16)
							.fill(Color.black.opacity(0.8))
					)
				}
			}
		}
		.onAppear {
			loadUserAge()
		}
	}
	
	// MARK: - Helper Functions
	
	private func loadUserAge() {
		guard let userId = authService.user?.uid else { return }
		
		Task {
			do {
				let user = try await UserService.shared.getUser(userId: userId)
				guard let user = user else { return }
				
				// Calculate age from birthday
				let age = calculateAge(birthMonth: user.birthMonth, birthDay: user.birthDay, birthYear: user.birthYear)
				
				await MainActor.run {
					self.userAge = age
					print("📅 User age loaded: \(age ?? -1) years old")
					
					// If user is under 18 and has Open selected, clear the selection
					if let age = age, age < 18, self.selectedType == "Open" {
						self.selectedType = nil
						print("⚠️ User is under 18, cleared Open collection selection")
					}
				}
			} catch {
				print("⚠️ Failed to load user age: \(error)")
			}
		}
	}
	
	private func calculateAge(birthMonth: String, birthDay: String, birthYear: String) -> Int? {
		// Convert month string to number
		let months = ["January", "February", "March", "April", "May", "June",
					 "July", "August", "September", "October", "November", "December"]
		guard let monthIndex = months.firstIndex(of: birthMonth),
			  let day = Int(birthDay),
			  let year = Int(birthYear) else {
			return nil
		}
		
		let calendar = Calendar.current
		let today = Date()
		let birthDateComponents = DateComponents(year: year, month: monthIndex + 1, day: day)
		
		guard let birthDate = calendar.date(from: birthDateComponents) else {
			return nil
		}
		
		let ageComponents = calendar.dateComponents([.year], from: birthDate, to: today)
		return ageComponents.year
	}
	
	private func typeDescription(_ type: String) -> String {
		switch type {
		case "Individual": return "Only you can post in this collection."
		case "Invite": return "Only users you invite can post in this collection with you."
		case "Request": return "Users must request access to post. You'll need to approve or deny their request before they can post."
		case "Open": return "Anyone can post freely."
		default: return ""
		}
	}
	
	private func visibilityDescription() -> String {
		if selectedType == "Request" || selectedType == "Open" {
			return "Request and Open collections must be public so users can see them before requesting or joining."
		} else if isPublic {
			return "Anyone can view this collection."
		} else {
			return "Only members/owners can view this collection."
		}
	}
	
	private func loadAllUsers() {
		Task {
			do {
				let userService = UserService.shared
				let users = try await userService.getAllUsers()
				await MainActor.run {
					self.allUsers = users
				}
			} catch {
				print("Error loading users: \(error)")
				await MainActor.run {
					self.allUsers = []
				}
			}
		}
	}
	
	private func createCollection() async {
		isCreating = true
		errorMessage = nil
		
		guard let user = authService.user else {
			await MainActor.run {
				self.errorMessage = "User not authenticated"
				self.showErrorAlert = true
				self.isCreating = false
			}
			return
		}
		
		guard let collectionType = selectedType else {
			await MainActor.run {
				self.errorMessage = "Please select a collection type"
				self.showErrorAlert = true
				self.isCreating = false
			}
			return
		}
		
		// Age validation for Open collections
		if collectionType == "Open" {
			// Re-check age if not already loaded
			if userAge == nil {
				do {
					let userData = try await UserService.shared.getUser(userId: user.uid)
					if let userData = userData {
						userAge = calculateAge(birthMonth: userData.birthMonth, birthDay: userData.birthDay, birthYear: userData.birthYear)
					}
				} catch {
					print("⚠️ Failed to verify user age: \(error)")
				}
			}
			
			if let age = userAge, age < 18 {
				await MainActor.run {
					self.errorMessage = "An open collection requires the user to be 18 or older."
					self.showErrorAlert = true
					self.isCreating = false
				}
				return
			}
		}
		
		// Dismiss immediately and create in background for better UX
		await MainActor.run {
			self.dismiss()
		}
		
		// Create collection in background
		Task.detached(priority: .userInitiated) {
			do {
				let collectionId = try await CollectionService.shared.createCollection(
					name: self.collectionName,
					description: self.description,
					type: collectionType,
					isPublic: self.isPublic,
					ownerId: user.uid,
					ownerName: user.displayName ?? "Unknown",
					image: self.selectedImage,
					invitedUsers: Array(self.invitedUsers)
				)
				
				print("✅ Successfully created collection with ID: \(collectionId)")
				
				// Post notification with the new collection ID to add it without reloading
				await MainActor.run {
					print("📢 Posting CollectionCreated notification with ID: \(collectionId)")
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionCreated"),
						object: collectionId
					)
				}
				
			} catch {
				await MainActor.run {
					print("❌ Failed to create collection: \(error.localizedDescription)")
				}
			}
		}
	}
	
	private func uploadImage(_ image: UIImage, path: String) async throws -> String {
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			throw NSError(domain: "ImageConversionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
		}
		
		let storage = Storage.storage()
		let storageRef = storage.reference().child(path)
		
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		let _ = try await storageRef.putDataAsync(imageData, metadata: metadata)
		let downloadURL = try await storageRef.downloadURL()
		
		return downloadURL.absoluteString
	}
}

// MARK: - Invite Users Sheet
struct InviteUsersSheet: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	@Binding var allUsers: [User]
	@Binding var invitedUsers: Set<String>
	@Binding var searchText: String
	
	var filteredUsers: [User] {
		guard let currentUserId = authService.user?.uid else { return [] }
		
		// Get blocked users list (FIX-006)
		let blockedUserIds = Set(CYServiceManager.shared.currentUser?.blockedUsers ?? [])
		
		// Filter out current user and blocked users from invite list
		let availableUsers = allUsers.filter { user in
			user.id != currentUserId && !blockedUserIds.contains(user.id)
		}
		
		if searchText.isEmpty {
			return availableUsers
		} else {
			return availableUsers.filter { user in
				user.name.lowercased().contains(searchText.lowercased()) ||
				user.username.lowercased().contains(searchText.lowercased())
			}
		}
	}
	
	var body: some View {
		NavigationView {
			VStack(spacing: 0) {
				// Search Bar
				HStack {
					Image(systemName: "magnifyingglass")
						.foregroundColor(.gray)
					
					TextField("Search users...", text: $searchText)
						.textFieldStyle(PlainTextFieldStyle())
				}
				.padding()
				.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
				.cornerRadius(10)
				.padding(.horizontal)
				.padding(.top)
				
				// Users List
				ScrollView {
					LazyVStack(spacing: 12) {
						ForEach(filteredUsers, id: \.id) { user in
							InviteUserRow(
								user: user,
								isInvited: invitedUsers.contains(user.id),
								onInviteToggle: {
									if invitedUsers.contains(user.id) {
										invitedUsers.remove(user.id)
									} else {
										invitedUsers.insert(user.id)
									}
								}
							)
						}
					}
					.padding(.horizontal)
					.padding(.top)
				}
				
				Spacer()
			}
			.navigationTitle("Invite Users")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Cancel") {
						dismiss()
					}
				}
				
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
					.fontWeight(.semibold)
				}
			}
			.background(colorScheme == .dark ? Color.black : Color.white)
		}
	}
}

// MARK: - Invite User Row
struct InviteUserRow: View {
	let user: User
	let isInvited: Bool
	let onInviteToggle: () -> Void
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		HStack(spacing: 12) {
			// Profile Image
			if let profileImageURL = user.profileImageURL, !profileImageURL.isEmpty {
				CachedProfileImageView(url: profileImageURL, size: 50)
			} else {
				DefaultProfileImageView(size: 50)
			}
			
			// User Info
			VStack(alignment: .leading, spacing: 2) {
				Text(user.name)
					.font(.headline)
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Text("@\(user.username)")
					.font(.subheadline)
					.foregroundColor(.gray)
			}
			
			Spacer()
			
			// Invite Button
			Button(action: onInviteToggle) {
				Text(isInvited ? "Invited" : "Invite")
					.font(.subheadline)
					.fontWeight(.semibold)
					.foregroundColor(isInvited ? .gray : .blue)
					.padding(.horizontal, 16)
					.padding(.vertical, 8)
					.background(isInvited ? Color.gray.opacity(0.2) : Color.blue.opacity(0.1))
					.cornerRadius(20)
			}
			.disabled(isInvited)
		}
		.padding()
		.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
		.cornerRadius(12)
	}
}

