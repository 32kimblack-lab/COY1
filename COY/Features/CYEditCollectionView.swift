import SwiftUI
import PhotosUI
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth

struct CYEditCollectionView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	let collection: CollectionData
	
	// MARK: - State Variables
	@State private var collectionName: String = ""
	@State private var description: String = ""
	@State private var isPublic: Bool = false
	@State private var selectedImage: UIImage?
	@State private var showPhotoPicker: Bool = false
	@State private var showInviteSheet: Bool = false
	@State private var invitedUserIds: Set<String> = []
	@State private var allUsers: [User] = []
	@State private var searchText: String = ""
	@State private var isSaving: Bool = false
	@State private var isUploading: Bool = false
	@State private var showError: Bool = false
	@State private var errorMessage: String = ""
	@State private var ownerProfileImageURL: String?
	@State private var updatedCollectionImageURL: String? = nil
	
	// MARK: - Computed Properties
	private var isCurrentUserOwner: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		// Only the original creator is the Owner
		return collection.ownerId == currentUserId
	}
	
	private var isCurrentUserAdmin: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		// Check if user is in the owners array (admins are stored in owners)
		return collection.owners.contains(currentUserId) && collection.ownerId != currentUserId
	}
	
	// Owner and Admins can edit collections
	private var canEditCollection: Bool {
		return isCurrentUserOwner || isCurrentUserAdmin
	}
	
	private var textColor: Color {
		colorScheme == .dark ? .white : .black
	}
	
	private var inputBackgroundColor: Color {
		colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9)
	}
	
	private var sectionBackgroundColor: Color {
		colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9)
	}
	
	// MARK: - Body
	var body: some View {
		ZStack {
			(colorScheme == .dark ? Color.black : Color.white)
				.ignoresSafeArea()
			
			VStack(spacing: 0) {
				// Header
				headerView
				
				// Content
				ScrollView {
					VStack(spacing: 24) {
						collectionPhotoSection
						collectionNameSection
						captionSection
						
						// Visibility Section (only for Individual/Invite collections)
						if collection.type == "Individual" || collection.type == "Invite" {
							visibilitySection
						}
						
						// Invite Users Button (only for Invite collections)
						if collection.type == "Invite" {
							inviteUsersButton
						}
					}
					.padding(.top, 20)
					.padding(.bottom, 40)
				}
			}
			
			// Upload Progress Overlay
			if isUploading {
				uploadProgressOverlay
			}
		}
		.onAppear {
			// Defensive check: Only owners and admins can edit collections
			if !canEditCollection {
				print("⚠️ CYEditCollectionView: User without edit permission attempted to access edit view - dismissing")
				dismiss()
				return
			}
			loadCollectionData()
		}
		.sheet(isPresented: $showPhotoPicker) {
			ImagePicker(image: $selectedImage)
		}
		.sheet(isPresented: $showInviteSheet) {
			EditInviteUsersSheet(
				collection: collection,
				allUsers: $allUsers,
				invitedUsers: $invitedUserIds,
				searchText: $searchText
			)
		}
		.alert("Error", isPresented: $showError) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(errorMessage)
		}
	}
	
	// MARK: - UI Components
	
	private var headerView: some View {
		HStack {
			Button(action: {
				dismiss()
			}) {
				Image(systemName: "chevron.left")
					.font(.title2)
					.foregroundColor(textColor)
					.frame(width: 44, height: 44)
					.contentShape(Rectangle())
			}
			
			Spacer()
			
			Text("Edit Collection")
				.font(.headline)
				.foregroundColor(textColor)
			
			Spacer()
			
			Button(action: {
				Task {
					await saveCollection()
				}
			}) {
				Text("Done")
					.fontWeight(.semibold)
					.foregroundColor(isSaving ? .gray : .blue)
			}
			.disabled(isSaving)
			.frame(minWidth: 50, minHeight: 44)
			.contentShape(Rectangle())
		}
		.padding(.horizontal)
		.padding(.top, 20)
		.background(colorScheme == .dark ? Color.black : Color.white)
		.zIndex(1)
	}
	
	private var collectionPhotoSection: some View {
		VStack(spacing: 16) {
			Text("Collection Photo")
				.font(.headline)
				.foregroundColor(textColor)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal)
			
			Button(action: {
				showPhotoPicker = true
			}) {
				collectionPhotoView
			}
			.padding(.horizontal)
		}
	}
	
	private var collectionPhotoView: some View {
		Group {
			if let image = selectedImage {
				Image(uiImage: image)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 120, height: 120)
					.clipShape(Circle())
					.overlay(
						Circle()
							.stroke(Color.gray.opacity(0.3), lineWidth: 1)
					)
			} else if let imageURL = updatedCollectionImageURL ?? collection.imageURL, !imageURL.isEmpty {
				CachedProfileImageView(url: imageURL, size: 120)
					.clipShape(Circle())
					.overlay(
						Circle()
							.stroke(Color.gray.opacity(0.3), lineWidth: 1)
					)
			} else if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty {
				CachedProfileImageView(url: ownerImageURL, size: 120)
					.clipShape(Circle())
					.overlay(
						Circle()
							.stroke(Color.gray.opacity(0.3), lineWidth: 1)
					)
			} else {
				DefaultProfileImageView(size: 120)
					.overlay(
						Circle()
							.stroke(Color.gray.opacity(0.3), lineWidth: 1)
					)
			}
		}
		.overlay(
			Image(systemName: "camera.fill")
				.foregroundColor(.white)
				.padding(8)
				.background(Color.blue)
				.clipShape(Circle())
				.offset(x: 40, y: 40)
		)
	}
	
	private var collectionNameSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Collection Name")
				.font(.headline)
				.foregroundColor(textColor)
			TextField("Name", text: $collectionName)
				.padding()
				.background(inputBackgroundColor)
				.cornerRadius(10)
				.foregroundColor(textColor)
		}
		.padding(.horizontal)
	}
	
	private var captionSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Caption")
				.font(.headline)
				.foregroundColor(textColor)
			TextField("Caption (Optional)", text: $description, axis: .vertical)
				.lineLimit(3...6)
				.padding()
				.background(inputBackgroundColor)
				.cornerRadius(10)
				.foregroundColor(textColor)
		}
		.padding(.horizontal)
	}
	
	private var visibilitySection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Who Can View")
				.font(.headline)
				.foregroundColor(textColor)
			
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					Text(isPublic ? "Public" : "Private")
						.font(.headline)
						.foregroundColor(textColor)
					Text(isPublic ? "Turn off to make private" : "Turn on to make public")
						.font(.caption)
						.foregroundColor(.gray)
				}
				Spacer()
				Toggle("", isOn: $isPublic)
					.labelsHidden()
					.toggleStyle(SwitchToggleStyle(tint: .blue))
					.disabled(collection.type == "Request" || collection.type == "Open")
			}
			.padding()
			.background(sectionBackgroundColor)
			.cornerRadius(10)
			
			Text(visibilityDescription())
				.font(.footnote)
				.foregroundColor(.gray)
				.padding(.top, 2)
		}
		.padding(.horizontal)
	}
	
	private var inviteUsersButton: some View {
		Button(action: {
			loadAllUsers()
			showInviteSheet = true
		}) {
			HStack {
				Image(systemName: "person.badge.plus")
					.foregroundColor(.blue)
				Text("Invite Users")
					.font(.headline)
					.foregroundColor(.blue)
				if !invitedUserIds.isEmpty {
					Text("(\(invitedUserIds.count))")
						.font(.subheadline)
						.foregroundColor(.blue)
				}
				Spacer()
				Image(systemName: "chevron.right")
					.foregroundColor(.blue)
			}
			.padding(.vertical, 12)
			.padding(.horizontal, 16)
			.background(sectionBackgroundColor)
			.cornerRadius(10)
		}
		.buttonStyle(PlainButtonStyle())
		.padding(.horizontal)
		.padding(.top, 8)
	}
	
	private var uploadProgressOverlay: some View {
		ZStack {
			Color.black.opacity(0.7)
				.ignoresSafeArea()
			
			VStack(spacing: 16) {
				ProgressView()
					.scaleEffect(1.5)
					.tint(.white)
				Text("Uploading...")
					.font(.headline)
					.foregroundColor(.white)
				Text("Please wait")
					.font(.subheadline)
					.foregroundColor(.white.opacity(0.8))
			}
		}
	}
	
	// MARK: - Functions
	
	private func loadCollectionData() {
		collectionName = collection.name
		description = collection.description
		// CRITICAL: Load the actual isPublic value from the collection
		isPublic = collection.isPublic
		print("🔍 CYEditCollectionView: Loaded collection data - isPublic: \(isPublic), collection.isPublic: \(collection.isPublic)")
		
		// Load owner's profile image for fallback
		loadOwnerProfileImage()
		
		// Load previously invited users for this collection
		loadPreviouslyInvitedUsers()
	}
	
	private func loadOwnerProfileImage() {
		Task {
			do {
				let db = Firestore.firestore()
				let userDoc = try await db.collection("users").document(collection.ownerId).getDocument()
				if let data = userDoc.data(),
				   let profileImageURL = data["profileImageURL"] as? String {
					await MainActor.run {
						self.ownerProfileImageURL = profileImageURL
					}
				}
			} catch {
				print("⚠️ CYEditCollectionView: Could not load owner profile image: \(error)")
			}
		}
	}
	
	private func loadPreviouslyInvitedUsers() {
		Task {
			guard Auth.auth().currentUser?.uid != nil else { return }
			
			var invitedUserIds = Set<String>()
			
			// Primary source: collection's invitedUsers field
			if !collection.invitedUsers.isEmpty {
				invitedUserIds.formUnion(Set(collection.invitedUsers))
			}
			
			// Fallback: Check collection's allowedUsers field (for backward compatibility)
			let allowedUsers = collection.allowedUsers
			if !allowedUsers.isEmpty {
				let pendingInvites = allowedUsers.filter { userId in
					!collection.members.contains(userId) && 
					userId != collection.ownerId &&
					!collection.owners.contains(userId)
				}
				invitedUserIds.formUnion(Set(pendingInvites))
			}
			
			await MainActor.run {
				self.invitedUserIds = invitedUserIds
			}
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
				print("❌ CYEditCollectionView: Error loading users: \(error)")
				await MainActor.run {
					self.allUsers = []
				}
			}
		}
	}
	
	private func saveCollection() async {
		await MainActor.run {
			isSaving = true
			isUploading = true
		}
		
		do {
			var imageToUpload: UIImage?
			if let selectedImage = selectedImage {
				imageToUpload = selectedImage
			}
			
			// Always include visibility update when visibility section is shown (Individual/Invite collections)
			let shouldUpdateVisibility = collection.type == "Individual" || collection.type == "Invite"
			
			// CRITICAL: For Individual/Invite collections, ALWAYS send the current isPublic value
			let isPublicValue = shouldUpdateVisibility ? isPublic : nil
			
			// Upload image first to get the URL, then update collection
			var uploadedImageURL: String? = nil
			if let image = imageToUpload {
				do {
					let storage = Storage.storage()
					let imageRef = storage.reference().child("collection_images/\(collection.id).jpg")
					if let imageData = image.jpegData(compressionQuality: 0.8) {
						try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
							_ = imageRef.putData(imageData, metadata: nil) { metadata, error in
								if let error = error {
									continuation.resume(throwing: error)
								} else {
									continuation.resume()
								}
							}
						}
						let downloadURL = try await imageRef.downloadURL()
						uploadedImageURL = downloadURL.absoluteString
						print("✅ CYEditCollectionView: Image uploaded to Firebase Storage: \(uploadedImageURL ?? "nil")")
					}
				} catch {
					print("❌ CYEditCollectionView: Failed to upload image: \(error)")
					// Continue without image - user can retry
				}
			}
			
			// CRITICAL FIX: Always send name and description if they're being edited
			// Fields need to be present to update them properly
			let trimmedName = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
			let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
			
			// Always send name if it's not empty (user is editing it)
			let nameToSend: String? = !trimmedName.isEmpty ? trimmedName : nil
			
			// Always send description (even if empty - user might want to clear it)
			let descriptionToSend: String? = trimmedDescription
			
			// CRITICAL FIX: Clear image cache BEFORE update (like edit profile does)
			if let oldImageURL = collection.imageURL, !oldImageURL.isEmpty {
				ImageCache.shared.removeImage(for: oldImageURL)
			}
			
			// Update collection with all fields (saves to Firebase)
			try await CollectionService.shared.updateCollection(
				collectionId: collection.id,
				name: nameToSend,
				description: descriptionToSend,
				image: nil, // Don't send image - we already uploaded it above
				imageURL: uploadedImageURL, // Send Firebase Storage URL
				isPublic: isPublicValue
			)
			
			// Handle invites for Invite collections
			if collection.type == "Invite" {
				await handleInvites()
			}
			
			// CRITICAL: Reload collection from Firebase to verify update was saved (like edit profile)
			print("🔍 Verifying collection update was saved...")
			let verifiedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id)
			guard let verifiedCollection = verifiedCollection else {
				throw NSError(domain: "CollectionUpdateError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to verify collection update"])
			}
			
			print("✅ Verified update - Name: \(verifiedCollection.name), Image URL: \(verifiedCollection.imageURL ?? "nil")")
			
			// Clear image cache for old collection image
			if let oldImageURL = collection.imageURL, !oldImageURL.isEmpty {
				ImageCache.shared.removeImage(for: oldImageURL)
			}
			
			// Pre-cache the new image (like edit profile pre-caches images)
			if let uploadedURL = uploadedImageURL, let uploadedImage = imageToUpload {
				ImageCache.shared.setImage(uploadedImage, for: uploadedURL)
				print("💾 Pre-cached new collection image: \(uploadedURL)")
			}
			
			// Prepare notification data with verified data from Firebase (like edit profile)
			var immediateUpdateData: [String: Any] = [
				"collectionId": collection.id,
				"name": verifiedCollection.name,
				"description": verifiedCollection.description
			]
			
			// Use verified URLs from Firebase (these are the actual saved URLs)
			if let imageURL = verifiedCollection.imageURL, !imageURL.isEmpty {
				immediateUpdateData["imageURL"] = imageURL
			}
			
			if shouldUpdateVisibility {
				immediateUpdateData["isPublic"] = verifiedCollection.isPublic
			}
			
			// Post comprehensive notifications for real-time UI updates everywhere (like edit profile)
			await MainActor.run {
				if let uploadedURL = uploadedImageURL {
					self.updatedCollectionImageURL = uploadedURL
				}
				
				// Post CollectionUpdated notification with verified data
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionUpdated"),
					object: collection.id,
					userInfo: ["updatedData": immediateUpdateData]
				)
				
				// Post ProfileUpdated to refresh profile views (collections list)
				NotificationCenter.default.post(
					name: NSNotification.Name("ProfileUpdated"),
					object: nil,
					userInfo: ["updatedData": ["collectionId": collection.id]]
				)
				
				// Post CollectionImageUpdated for image-specific updates
				if let imageURL = verifiedCollection.imageURL, !imageURL.isEmpty {
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionImageUpdated"),
						object: collection.id,
						userInfo: ["imageURL": imageURL]
					)
				}
				
				// Post CollectionNameUpdated for name changes
				if !verifiedCollection.name.isEmpty {
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionNameUpdated"),
						object: collection.id,
						userInfo: ["name": verifiedCollection.name]
					)
				}
				
				print("📢 CYEditCollectionView: Posted comprehensive collection update notifications")
				print("   - Collection ID: \(collection.id)")
				if let name = immediateUpdateData["name"] as? String {
					print("   - Name: \(name)")
				}
				if let imageURL = immediateUpdateData["imageURL"] as? String {
					print("   - Image URL: \(imageURL)")
				}
				
				isUploading = false
				isSaving = false
			}
			
			// Small delay before dismiss (like edit profile)
			try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
			
			await MainActor.run {
				self.dismiss()
			}
		} catch {
			print("❌ CYEditCollectionView: Error saving collection: \(error)")
			await MainActor.run {
				isUploading = false
				isSaving = false
				errorMessage = error.localizedDescription
				showError = true
			}
		}
	}
	
	private func visibilityDescription() -> String {
		if collection.type == "Request" || collection.type == "Open" {
			return "Request and Open collections must be public."
		} else if collection.type == "Individual" {
			return "Public collections can be discovered by anyone. Private collections are only visible to you."
		} else if collection.type == "Invite" {
			return "Public collections can be discovered by anyone. Private collections are only visible to you and invited members."
		}
		return ""
	}
	
	// Handle sending new invites and removing uninvited users
	private func handleInvites() async {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		// Get the original invited users from the collection
		let originalInvitedUsers = Set(collection.invitedUsers)
		let newInvitedUsers = invitedUserIds
		
		// Find newly invited users (in newInvitedUsers but not in originalInvitedUsers)
		let usersToInvite = newInvitedUsers.subtracting(originalInvitedUsers)
		
		// Find users to uninvite (in originalInvitedUsers but not in newInvitedUsers)
		let usersToUninvite = originalInvitedUsers.subtracting(newInvitedUsers)
		
		// Get owner info for notifications
		guard let owner = try? await UserService.shared.getUser(userId: currentUserId) else {
			print("⚠️ CYEditCollectionView: Could not load owner info for invites")
			return
		}
		
		// Send invites to newly invited users
		for userId in usersToInvite {
			do {
				try await NotificationService.shared.sendCollectionInviteNotification(
					collectionId: collection.id,
					collectionName: collection.name,
					inviterId: currentUserId,
					inviterUsername: owner.username,
					inviterProfileImageURL: owner.profileImageURL,
					invitedUserId: userId
				)
				print("✅ CYEditCollectionView: Sent invite to user \(userId)")
			} catch {
				print("❌ CYEditCollectionView: Failed to send invite to user \(userId): \(error)")
			}
		}
		
		// Remove invites for uninvited users (delete notifications)
		if !usersToUninvite.isEmpty {
			do {
				let db = Firestore.firestore()
				// Notifications are stored in each user's notifications subcollection
				for userId in usersToUninvite {
					let notificationsSnapshot = try await db.collection("users")
						.document(userId)
						.collection("notifications")
						.whereField("type", isEqualTo: "collection_invite")
						.whereField("collectionId", isEqualTo: collection.id)
						.whereField("userId", isEqualTo: currentUserId)
						.getDocuments()
					
					for doc in notificationsSnapshot.documents {
						try await doc.reference.delete()
						print("✅ CYEditCollectionView: Removed invite notification for user \(userId)")
					}
				}
			} catch {
				print("❌ CYEditCollectionView: Failed to remove invite notifications: \(error)")
			}
		}
		
		// Update collection's invitedUsers field
		if !usersToInvite.isEmpty || !usersToUninvite.isEmpty {
			do {
				let db = Firestore.firestore()
				try await db.collection("collections").document(collection.id).updateData([
					"invitedUsers": Array(newInvitedUsers)
				])
				print("✅ CYEditCollectionView: Updated collection's invitedUsers field")
			} catch {
				print("❌ CYEditCollectionView: Failed to update collection's invitedUsers: \(error)")
			}
		}
	}
}

// MARK: - Edit Invite Users Sheet
struct EditInviteUsersSheet: View {
	let collection: CollectionData
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	@Binding var allUsers: [User]
	@Binding var invitedUsers: Set<String>
	@Binding var searchText: String
	
	// Get all existing collection members (owner, admins, members) to filter them out
	private var existingMemberIds: Set<String> {
		var memberIds = Set<String>()
		memberIds.insert(collection.ownerId)
		memberIds.formUnion(collection.owners)
		memberIds.formUnion(collection.members)
		return memberIds
	}
	
	var filteredUsers: [User] {
		guard let currentUserId = authService.user?.uid else { return [] }
		
		// Get blocked users list
		let blockedUserIds = Set(CYServiceManager.shared.currentUser?.blockedUsers ?? [])
		
		// Filter out current user, blocked users, and existing members/admins/owner
		let availableUsers = allUsers.filter { user in
			user.id != currentUserId &&
			!blockedUserIds.contains(user.id) &&
			!existingMemberIds.contains(user.id)
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
							EditInviteUserRow(
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

// MARK: - Edit Invite User Row
struct EditInviteUserRow: View {
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

// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
	@Binding var image: UIImage?
	@Environment(\.dismiss) var dismiss
	
	func makeUIViewController(context: Context) -> UIImagePickerController {
		let picker = UIImagePickerController()
		picker.delegate = context.coordinator
		picker.sourceType = .photoLibrary
		picker.allowsEditing = true
		return picker
	}
	
	func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}
	
	class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
		let parent: ImagePicker
		
		init(_ parent: ImagePicker) {
			self.parent = parent
		}
		
		func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
			if let editedImage = info[.editedImage] as? UIImage {
				parent.image = editedImage
			} else if let originalImage = info[.originalImage] as? UIImage {
				parent.image = originalImage
			}
			parent.dismiss()
		}
		
		func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
			parent.dismiss()
		}
	}
}

