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
		// Check if user is in the admins array
		return collection.admins?.contains(currentUserId) ?? false
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
			// TODO: Implement EditInviteUsersView
			Text("Invite Users - Coming Soon")
				.padding()
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
			showInviteSheet = true
		}) {
			HStack {
				Image(systemName: "person.badge.plus")
					.foregroundColor(.blue)
				Text("Invite Users")
					.font(.headline)
					.foregroundColor(.blue)
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
			guard let currentUserId = Auth.auth().currentUser?.uid else { return }
			
			var invitedUserIds = Set<String>()
			
			// Method 1: Check collection's allowedUsers field
			let allowedUsers = collection.allowedUsers
			if !allowedUsers.isEmpty {
				let pendingInvites = allowedUsers.filter { userId in
					!collection.members.contains(userId) && userId != collection.ownerId
				}
				invitedUserIds.formUnion(Set(pendingInvites))
			}
			
			// Method 2: Get notifications (if available)
			do {
				let apiClient = APIClient.shared
				let notifications = try await apiClient.getNotifications()
				
				let sentInvites = notifications.filter { notification in
					notification.type == .collectionInvite &&
					notification.collectionId == collection.id &&
					notification.fromUserId == currentUserId
				}
				
				let notificationInvites = Set(sentInvites.map { $0.toUserId })
				invitedUserIds.formUnion(notificationInvites)
			} catch {
				print("⚠️ CYEditCollectionView: Could not load notifications: \(error)")
			}
			
			await MainActor.run {
				self.invitedUserIds = invitedUserIds
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
					let storageService = await MainActor.run { StorageService.shared }
					uploadedImageURL = try await storageService.uploadCollectionImage(image, collectionId: collection.id)
					print("✅ CYEditCollectionView: Image uploaded to Firebase Storage: \(uploadedImageURL ?? "nil")")
				} catch {
					print("❌ CYEditCollectionView: Failed to upload image: \(error)")
					// Continue without image - user can retry
				}
			}
			
			// CRITICAL FIX: Always send name and description if they're being edited
			// Backend needs the fields to be present to update them properly
			let trimmedName = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
			let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
			
			// Always send name if it's not empty (user is editing it)
			let nameToSend: String? = !trimmedName.isEmpty ? trimmedName : nil
			
			// Always send description (even if empty - user might want to clear it)
			let descriptionToSend: String? = trimmedDescription
			
			// Update collection with all fields
			try await CollectionService.shared.updateCollection(
				collectionId: collection.id,
				name: nameToSend,
				description: descriptionToSend,
				image: nil, // Don't send image - we already uploaded it above
				imageURL: uploadedImageURL, // Send Firebase Storage URL
				isPublic: isPublicValue
			)
			
			// CRITICAL: Reload collection from backend to verify update was saved
			print("🔍 Verifying collection update was saved...")
			if let updatedCollection = try? await CollectionService.shared.getCollection(collectionId: collection.id) {
				print("✅ Verified update - Name: \(updatedCollection.name), Image URL: \(updatedCollection.imageURL ?? "nil")")
			} else {
				print("⚠️ Could not verify collection update - collection may not have been saved")
			}
			
			// If we uploaded an image, send the imageURL to backend separately
			if let imageURL = uploadedImageURL {
				do {
					let apiClient = APIClient.shared
					_ = try await apiClient.updateCollection(
						collectionId: collection.id,
						imageURL: imageURL,
						isPublic: nil // Don't change visibility
					)
					print("✅ CYEditCollectionView: Image URL sent to backend: \(imageURL)")
				} catch {
					print("⚠️ CYEditCollectionView: Could not send imageURL to backend: \(error)")
				}
			}
			
			// Clear cache for this collection
			CYInsideCollectionCache.shared.clearCache(for: collection.id)
			
			// Clear image cache for old collection image
			if let oldImageURL = collection.imageURL, !oldImageURL.isEmpty {
				ImageCache.shared.removeImage(for: oldImageURL)
			}
			
			// Pre-cache the new image
			if let uploadedURL = uploadedImageURL, let uploadedImage = imageToUpload {
				ImageCache.shared.setImage(uploadedImage, for: uploadedURL)
			}
			
			// Post comprehensive notifications for real-time UI updates everywhere in the app
			await MainActor.run {
				if let uploadedURL = uploadedImageURL {
					self.updatedCollectionImageURL = uploadedURL
				}
				
				// Build comprehensive update data with ALL changes
				var updateData: [String: Any] = [
					"collectionId": collection.id,
					"name": collectionName.trimmingCharacters(in: .whitespacesAndNewlines),
					"description": description.trimmingCharacters(in: .whitespacesAndNewlines)
				]
				
				if let uploadedURL = uploadedImageURL {
					updateData["imageURL"] = uploadedURL
				}
				
				if shouldUpdateVisibility {
					updateData["isPublic"] = isPublic
				}
				
				// Post CollectionUpdated notification with all updated data
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
				
				// Post CollectionImageUpdated for image-specific updates
				if uploadedImageURL != nil {
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionImageUpdated"),
						object: collection.id,
						userInfo: ["imageURL": uploadedImageURL!]
					)
				}
				
				// Post CollectionNameUpdated for name changes
				if !collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionNameUpdated"),
						object: collection.id,
						userInfo: ["name": collectionName.trimmingCharacters(in: .whitespacesAndNewlines)]
					)
				}
				
				print("📢 CYEditCollectionView: Posted comprehensive collection update notifications")
				print("   - Collection ID: \(collection.id)")
				print("   - Updated data: \(updateData)")
				
				isUploading = false
				isSaving = false
			}
			
			// Small delay before dismiss
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

