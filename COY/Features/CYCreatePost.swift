import Foundation
import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import FirebaseAuth
import FirebaseFirestore

struct CYCreatePost: View {
	@Binding var selectedMedia: [CreatePostMediaItem]
	let collectionId: String
	@Binding var isProcessingMedia: Bool
	var onPost: ([CreatePostMediaItem]) -> Void
	let isFromCamera: Bool
	var initialCaption: String = ""
	
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	
	@StateObject private var cyServiceManager = CYServiceManager.shared
	
	@State private var caption: String = ""
	@State private var allowDownload: Bool = false
	@State private var allowReplies: Bool = true
	@State private var selectedCollection: CollectionData?
	@State private var myCollections: [CollectionData] = []
	@State private var isPosting = false
	@State private var showError = false
	@State private var errorMessage = ""
	@State private var showCollectionPicker = false
	@State private var uploadProgress: Double = 0.0
	@State private var uploadStatusMessage = "Ready to post"
	
	// Tag friends functionality
	@State private var taggedFriends: [CYUser] = []
	@State private var showTagFriendsSheet = false
	@State private var allUsers: [CYUser] = []
	@State private var isLoadingUsers = false
	
	// Custom photo picker state
	@State private var showCustomPhotoPicker = false
	
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			headerView
			
			contentScrollView
				.frame(maxHeight: .infinity)
			
			Spacer(minLength: 0)
			
			postButton
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarHidden(true)
		.navigationBarBackButtonHidden(true)
		.alert("Error", isPresented: $showError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage)
		}
		.task {
			print("Using collection ID: \(collectionId)")
			await loadAllUsers()
		}
		.onAppear {
			// Set initial caption if provided
			if !initialCaption.isEmpty {
				caption = initialCaption
			}
		}
		.sheet(isPresented: $showTagFriendsSheet) {
			TagFriendsView(
				allUsers: allUsers,
				taggedFriends: $taggedFriends,
				isLoadingUsers: $isLoadingUsers
			)
		}
		.sheet(isPresented: $showCustomPhotoPicker) {
			CustomPhotoPickerView(
				selectedMedia: $selectedMedia,
				maxSelectionCount: max(1, 5 - selectedMedia.count),
				isProcessingMedia: $isProcessingMedia
			)
		}
		.onChange(of: selectedMedia.count) { oldCount, newCount in
			// Ensure media count never exceeds 5
			if newCount > 5 {
				selectedMedia = Array(selectedMedia.prefix(5))
			}
		}
	}
	
	// MARK: - Subviews
	
	private var headerView: some View {
		HStack {
			Button(action: { 
				dismiss()
			}) {
				Image(systemName: "xmark")
					.foregroundColor(colorScheme == .dark ? .white : .black)
					.font(.title2)
					.frame(width: 44, height: 44)
			}
			.buttonStyle(PlainButtonStyle())
			
			Spacer()
			
			Text("Create Post")
				.font(.title2)
				.fontWeight(.bold)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			
			Spacer()
			
			Color.clear
				.frame(width: 44, height: 44)
		}
		.padding([.horizontal, .top])
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
	
	private var contentScrollView: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				mediaSelectionSection
				postDetailsSection
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
	
	private var mediaSelectionSection: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 10) {
				ForEach(selectedMedia.indices, id: \.self) { index in
					mediaItemView(for: selectedMedia[index], index: index)
				}
				
				// Add Media Button (Visible only if less than 5 items are selected)
				if selectedMedia.count < 5 {
					Button(action: { 
						// Ensure we don't exceed 5 items before opening picker
						guard selectedMedia.count < 5 else { return }
						showCustomPhotoPicker = true 
					}) {
						ZStack {
							RoundedRectangle(cornerRadius: 10)
								.strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
								.frame(width: 150, height: 150)
								.overlay(Image(systemName: "plus").font(.largeTitle).foregroundColor(colorScheme == .dark ? .white : .black))
								.foregroundColor(colorScheme == .dark ? .white : .black)
							
							if isProcessingMedia {
								ProgressView()
									.progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
									.scaleEffect(1.5)
							}
						}
					}
				}
			}
			.padding(.horizontal)
		}
	}
	
	@ViewBuilder
	private func mediaItemView(for item: CreatePostMediaItem, index: Int) -> some View {
		ZStack(alignment: .topLeading) {
			// Main content
			if let image = item.image {
				Image(uiImage: image)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 150, height: 150)
					.cornerRadius(10)
					.clipped()
			} else if let thumbnail = item.videoThumbnail {
				Image(uiImage: thumbnail)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 150, height: 150)
					.cornerRadius(10)
					.clipped()
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.3))
					.frame(width: 150, height: 150)
					.cornerRadius(10)
			}
			
			// Order number overlay (top-left)
			Text("\(index + 1)")
				.font(.system(size: 18, weight: .bold))
				.foregroundColor(.white)
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(Color.black.opacity(0.9))
				.cornerRadius(15)
				.overlay(
					RoundedRectangle(cornerRadius: 15)
						.stroke(Color.white, lineWidth: 2)
				)
				.padding(.top, 8)
				.padding(.leading, 8)
			
			// Remove button
			Button(action: {
				if let index = selectedMedia.firstIndex(where: { $0.id == item.id }) {
					selectedMedia.remove(at: index)
				}
			}) {
				Image(systemName: "xmark.circle.fill")
					.font(.title2)
					.foregroundColor(colorScheme == .dark ? .white : .black)
					.background((colorScheme == .dark ? Color.black : Color.white).opacity(0.7))
					.clipShape(Circle())
			}
			.padding(8)
		}
		.frame(width: 150, height: 150)
	}
	
	private var postDetailsSection: some View {
		VStack(alignment: .leading, spacing: 20) {
			captionSection
			tagFriendsSection
			downloadToggleSection
			repliesToggleSection
			
			// Collection dropdown - only show when coming from camera
			if isFromCamera {
				collectionDropdownSection
			}
		}
	}
	
	private var collectionDropdownSection: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text("Collection")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			
			Button(action: {
				showCollectionPicker = true
			}) {
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text(selectedCollection?.name ?? "Select Collection")
							.foregroundColor(selectedCollection != nil ? (colorScheme == .dark ? .white : .black) : .gray)
							.font(.system(size: 16, weight: selectedCollection != nil ? .semibold : .regular))
						
						if let collection = selectedCollection {
							Text("\(collection.memberCount) members")
								.font(.caption)
								.foregroundColor(.gray)
						}
					}
					
					Spacer()
					
					Image(systemName: "chevron.down")
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.font(.system(size: 12))
				}
				.padding(.horizontal, 15)
				.padding(.vertical, 12)
				.background(
					selectedCollection != nil 
						? Color.blue.opacity(0.15) 
						: Color.gray.opacity(0.2)
				)
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.stroke(
							selectedCollection != nil ? Color.blue : Color.gray.opacity(0.5), 
							lineWidth: selectedCollection != nil ? 2 : 1
						)
				)
				.clipShape(RoundedRectangle(cornerRadius: 8))
			}
		}
		.padding(.horizontal)
		.sheet(isPresented: $showCollectionPicker) {
			CollectionPickerView(
				collections: myCollections,
				selectedCollection: $selectedCollection
			)
		}
		.task {
			if isFromCamera {
				await loadUserCollections()
			}
		}
	}
	
	private var captionSection: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text("Caption (Optional)")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			
			ZStack(alignment: .topLeading) {
				TextEditor(text: $caption)
					.frame(height: 100)
					.background(Color.gray.opacity(0.3))
					.cornerRadius(8)
					.foregroundColor(colorScheme == .dark ? .white : .black)
					.padding(.top, 0)
				
				if caption.isEmpty {
					Text("Write here")
						.foregroundColor(Color.gray.opacity(0.6))
						.padding(.horizontal, 14)
						.padding(.vertical, 16)
						.allowsHitTesting(false)
				}
			}
		}
		.padding(.horizontal)
		.contentShape(Rectangle())
		.onTapGesture {
			hideKeyboard()
		}
	}
	
	private var tagFriendsSection: some View {
		VStack {
			Divider().background(Color.gray)
			HStack {
				Text("Tag friends")
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Spacer()
				Button(action: {
					if allUsers.isEmpty {
						Task {
							await loadAllUsers()
						}
					}
					showTagFriendsSheet = true
				}) {
					Image(systemName: "plus")
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
			}
			.padding(.horizontal)
			
			// Show tagged friends if any
			if !taggedFriends.isEmpty {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						ForEach(taggedFriends, id: \.id) { friend in
							TaggedFriendView(friend: friend) {
								if let index = taggedFriends.firstIndex(where: { $0.id == friend.id }) {
									taggedFriends.remove(at: index)
								}
							}
						}
					}
					.padding(.horizontal)
				}
				.padding(.top, 8)
			}
		}
	}
	
	private func loadAllUsers() async {
		isLoadingUsers = true
		
		guard let currentUid = Auth.auth().currentUser?.uid else {
			await MainActor.run {
		allUsers = []
		isLoadingUsers = false
			}
			return
		}
		
		do {
			let db = Firestore.firestore()
			
			// Get current user's friends list (mutual friends who have added each other back)
			let userDoc = try await db.collection("users").document(currentUid).getDocument()
			guard let userData = userDoc.data(),
				  let friendIds = userData["friends"] as? [String],
				  !friendIds.isEmpty else {
				await MainActor.run {
					allUsers = []
					isLoadingUsers = false
				}
				return
			}
			
			// Load user data for each friend in parallel
			let friends = await withTaskGroup(of: CYUser?.self) { group in
				var users: [CYUser] = []
				
				for friendId in friendIds {
					group.addTask {
						do {
							let friendDoc = try await db.collection("users").document(friendId).getDocument()
							guard let friendData = friendDoc.data(),
								  let name = friendData["name"] as? String,
								  let username = friendData["username"] as? String else {
								return nil
							}
							
							let profileImageURL = friendData["profileImageURL"] as? String ?? ""
							return CYUser(
								id: friendId,
								name: name,
								username: username,
								profileImageURL: profileImageURL
							)
						} catch {
							print("❌ CYCreatePost: Error loading friend \(friendId): \(error)")
							return nil
						}
					}
				}
				
				for await user in group {
					if let user = user {
						users.append(user)
					}
				}
				
				return users
			}
			
			// Sort by name alphabetically
			let sortedFriends = friends.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
			
			await MainActor.run {
				allUsers = sortedFriends
				isLoadingUsers = false
			}
		} catch {
			print("❌ CYCreatePost: Error loading friends: \(error)")
			await MainActor.run {
				allUsers = []
				isLoadingUsers = false
			}
		}
	}
	
	private func loadUserCollections() async {
		guard let userId = Auth.auth().currentUser?.uid else { return }
		
		do {
			myCollections = try await CollectionService.shared.getUserCollections(userId: userId, forceFresh: true)
			print("✅ Loaded \(myCollections.count) collections for user")
			if myCollections.isEmpty {
				print("⚠️ No collections found for user")
			} else {
				print("📦 Collections: \(myCollections.map { $0.name }.joined(separator: ", "))")
			}
		} catch {
			print("❌ Error loading user collections: \(error.localizedDescription)")
			await MainActor.run {
				errorMessage = "Failed to load collections: \(error.localizedDescription)"
				showError = true
			}
		}
	}
	
	private var downloadToggleSection: some View {
		VStack {
			Divider().background(Color.gray)
			Toggle(isOn: $allowDownload) {
				Text("Download")
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			.toggleStyle(SwitchToggleStyle(tint: .blue))
			.padding(.horizontal)
		}
	}
	
	private var repliesToggleSection: some View {
		VStack {
			VStack {
				Divider().background(Color.gray)
				Toggle(isOn: $allowReplies) {
					Text("Allow Comments")
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
				.toggleStyle(SwitchToggleStyle(tint: .blue))
				.padding(.horizontal)
			}
		}
	}
	
	// Post Button
	private var postButton: some View {
		VStack(spacing: 12) {
			// Progress indicator
			if isPosting {
				VStack(spacing: 8) {
					ProgressView(value: uploadProgress)
						.progressViewStyle(LinearProgressViewStyle(tint: .blue))
						.frame(height: 4)
					
					Text(uploadStatusMessage)
						.font(.caption)
						.foregroundColor(colorScheme == .dark ? .gray : .secondary)
				}
				.padding(.horizontal)
			}
			
			Button(action: {
				Task {
					await createPost()
				}
			}) {
				HStack {
					if isPosting {
						ProgressView()
							.progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
							.padding(.trailing, 5)
					}
					Text(isPosting ? "Posting..." : (isFromCamera && selectedCollection == nil) ? "Select Collection" : "Post")
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
				.frame(maxWidth: .infinity)
				.padding()
				.background(isPosting ? Color.gray : (isFromCamera && selectedCollection == nil) ? Color.gray : Color.blue)
				.cornerRadius(10)
			}
			.disabled(isPosting || selectedMedia.isEmpty || (isFromCamera && selectedCollection == nil))
		}
		.padding(.horizontal)
		.padding(.bottom, 20)
	}
	
	private func createPost() async {
		guard !selectedMedia.isEmpty else {
			errorMessage = "Please select at least one image or video to post."
			showError = true
			return
		}
		
		// Validate media count (max 5)
		guard selectedMedia.count <= 5 else {
			errorMessage = "You can only post up to 5 images or videos at once."
			showError = true
			return
		}
		
		// Validate all videos are within duration limit (2 minutes = 120 seconds)
		for mediaItem in selectedMedia {
			if let videoDuration = mediaItem.videoDuration, videoDuration > 120.0 {
				errorMessage = "One or more videos exceed the 2:00 maximum duration limit."
				showError = true
				return
			}
			if mediaItem.videoURL != nil && mediaItem.videoDuration == nil {
				errorMessage = "One or more videos could not be processed. Please try again."
				showError = true
				return
			}
		}
		
		isPosting = true
		uploadProgress = 0.0
		uploadStatusMessage = "Preparing upload..."
		
		do {
			// Use selected collection ID if coming from camera, otherwise use the provided collectionId
			let targetCollectionId = isFromCamera ? (selectedCollection?.id ?? "") : collectionId
			let collectionName = isFromCamera ? (selectedCollection?.name ?? "Unknown") : "Provided"
			
			print("📸 isFromCamera: \(isFromCamera)")
			print("📦 Selected collection: \(collectionName) (ID: \(targetCollectionId))")
			print("📊 Posting \(selectedMedia.count) media items")
			
			// Validate collection ID
			guard !targetCollectionId.isEmpty else {
				throw NSError(domain: "CYCreatePost", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please select a collection to post in"])
			}
			
			// Create post - saves to Firebase (like profile images)
			let taggedUserIds = taggedFriends.map { $0.id }
			
			print("🔍 CYCreatePost: About to create post with:")
			print("   - allowDownload: \(allowDownload)")
			print("   - allowReplies: \(allowReplies)")
			print("   - State variables: allowDownload=\(allowDownload), allowReplies=\(allowReplies)")
			
			// Create post with progress tracking
			let postId = try await PostService.shared.createPost(
				collectionId: targetCollectionId,
				caption: caption.isEmpty ? nil : caption,
				mediaItems: selectedMedia,
				taggedUsers: taggedUserIds.isEmpty ? nil : taggedUserIds,
				allowDownload: allowDownload,
				allowReplies: allowReplies,
				progressCallback: { progress in
					// Update UI with progress on main thread
					Task { @MainActor in
						self.uploadProgress = progress.overallProgress
						self.uploadStatusMessage = progress.currentFileName
					}
				}
			)
			
			print("✅ Successfully created post in collection '\(collectionName)' with ID: \(postId)")
			print("🔍 CYCreatePost: Post created with allowDownload=\(allowDownload), allowReplies=\(allowReplies)")
			
			// Update UI and dismiss on main thread
			await MainActor.run {
				onPost(selectedMedia)
				// Post notification for immediate post refresh
				NotificationCenter.default.post(
					name: NSNotification.Name("PostCreated"),
					object: targetCollectionId,
					userInfo: ["postIds": [postId]]
				)
				// Also post general collection update notification
				NotificationCenter.default.post(name: NSNotification.Name("CollectionUpdated"), object: targetCollectionId)
				dismiss()
			}
			
		} catch {
			print("❌ Error creating post: \(error.localizedDescription)")
			await MainActor.run {
				// Provide user-friendly error messages
				if error.localizedDescription.contains("invalidData") {
					errorMessage = "One or more media files could not be processed. Please try selecting different media."
				} else {
					// Generic error message - don't block on file size
					errorMessage = "Failed to post. Please try again or post items separately."
				}
				showError = true
				isPosting = false
			}
		}
	}
}

// MARK: - Supporting Views

struct TagFriendsView: View {
	let allUsers: [CYUser]
	@Binding var taggedFriends: [CYUser]
	@Binding var isLoadingUsers: Bool
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.dismiss) var dismiss
	@StateObject private var services = CYServiceManager.shared
	@State private var searchText = ""
	
	var filteredUsers: [CYUser] {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return [] }
		
		// Filter out current user by ID (not username)
		let availableUsers = allUsers.filter { $0.id != currentUserId }
		
		if searchText.isEmpty {
			return availableUsers
		} else {
			return availableUsers.filter { 
				$0.username.localizedCaseInsensitiveContains(searchText) || 
				$0.name.localizedCaseInsensitiveContains(searchText)
			}
		}
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Button("Cancel") {
					dismiss()
				}
				.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Spacer()
				
				Text("Tag Friends")
					.font(.headline)
					.fontWeight(.semibold)
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Spacer()
				
				Button("Done") {
					dismiss()
				}
				.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			.padding()
			.background(colorScheme == .dark ? Color.black : Color.white)
			
			// Search bar
			HStack {
				Image(systemName: "magnifyingglass")
					.foregroundColor(.gray)
				TextField("Search users...", text: $searchText)
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			.padding()
			.background(Color.gray.opacity(0.1))
			.cornerRadius(10)
			.padding(.horizontal)
			
			if isLoadingUsers {
				Spacer()
				ProgressView("Loading users...")
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Spacer()
			} else {
				// Users list
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(filteredUsers, id: \.id) { user in
							CompactUserRowView(
								user: user,
								isTagged: taggedFriends.contains(where: { $0.id == user.id }),
								onToggle: {
									if let index = taggedFriends.firstIndex(where: { $0.id == user.id }) {
										taggedFriends.remove(at: index)
									} else {
										taggedFriends.append(user)
									}
								}
							)
							Divider()
								.background(Color.gray.opacity(0.3))
								.padding(.leading, 60)
						}
					}
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
}

struct CompactUserRowView: View {
	let user: CYUser
	let isTagged: Bool
	let onToggle: () -> Void
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		HStack(spacing: 12) {
			// Profile image
			if !user.profileImageURL.isEmpty, let url = URL(string: user.profileImageURL) {
				AsyncImage(url: url) { image in
					image.resizable()
						.aspectRatio(contentMode: .fill)
				} placeholder: {
					DefaultProfileImageView(size: 44)
				}
				.frame(width: 44, height: 44)
				.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 44)
			}
			
			// User info
			VStack(alignment: .leading, spacing: 2) {
				Text(user.username)
					.font(.system(size: 16, weight: .medium))
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Text(user.name)
					.font(.system(size: 14))
					.foregroundColor(.gray)
			}
			
			Spacer()
			
			// Toggle button
			Button(action: onToggle) {
				Image(systemName: isTagged ? "checkmark.circle.fill" : "circle")
					.font(.title2)
					.foregroundColor(isTagged ? .blue : .gray)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(Color.clear)
		.contentShape(Rectangle())
		.onTapGesture {
			onToggle()
		}
	}
}

struct TaggedFriendView: View {
	let friend: CYUser
	let onRemove: () -> Void
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		HStack(spacing: 4) {
			// Profile image
			if !friend.profileImageURL.isEmpty, let url = URL(string: friend.profileImageURL) {
				AsyncImage(url: url) { image in
					image.resizable()
						.aspectRatio(contentMode: .fill)
				} placeholder: {
					DefaultProfileImageView(size: 24)
				}
				.frame(width: 24, height: 24)
				.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 24)
			}
			
			Text(friend.username)
				.font(.caption)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			
			Button(action: onRemove) {
				Image(systemName: "xmark.circle.fill")
					.font(.caption)
					.foregroundColor(.red)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.background(Color.gray.opacity(0.2))
		.cornerRadius(12)
	}
}

// MARK: - Photo Picker View

struct CustomPhotoPickerView: UIViewControllerRepresentable {
	@Binding var selectedMedia: [CreatePostMediaItem]
	let maxSelectionCount: Int
	@Binding var isProcessingMedia: Bool
	@Environment(\.dismiss) var dismiss
	
	func makeUIViewController(context: Context) -> PHPickerViewController {
		var configuration = PHPickerConfiguration()
		configuration.selectionLimit = maxSelectionCount
		configuration.filter = .any(of: [.images, .videos])
		configuration.preferredAssetRepresentationMode = .current
		
		let picker = PHPickerViewController(configuration: configuration)
		picker.delegate = context.coordinator
		return picker
	}
	
	func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}
	
	class Coordinator: NSObject, PHPickerViewControllerDelegate {
		let parent: CustomPhotoPickerView
		private var isProcessing = false
		
		init(_ parent: CustomPhotoPickerView) {
			self.parent = parent
		}
		
		func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
			guard !isProcessing else {
				print("⚠️ CustomPhotoPickerView: Already processing, ignoring duplicate call")
				return
			}
			
			isProcessing = true
			
			Task {
				await MainActor.run {
				parent.isProcessingMedia = true
				}
				
				if results.isEmpty {
					await MainActor.run {
						parent.dismiss()
						parent.isProcessingMedia = false
						self.isProcessing = false
					}
				} else {
					await loadSelectedResults(results)
					await MainActor.run {
						parent.dismiss()
						parent.isProcessingMedia = false
						self.isProcessing = false
					}
				}
			}
		}
		
		private func loadSelectedResults(_ results: [PHPickerResult]) async {
			var newItems: [CreatePostMediaItem] = []
			
			// Calculate remaining slots (max 5 total)
			let remainingSlots = min(results.count, 5 - parent.selectedMedia.count)
			
			for (index, result) in results.enumerated() where index < remainingSlots {
				let mediaItem = await createMediaItem(from: result)
				
				// Only add valid media items - reject videos over 2 minutes
				if mediaItem.image != nil {
					// Images are always valid
					newItems.append(mediaItem)
				} else if mediaItem.videoURL != nil, let duration = mediaItem.videoDuration {
					// Only add videos that are 2 minutes or less
					if duration <= 120.0 {
						newItems.append(mediaItem)
					} else {
						// Show simple alert for videos that are too long
						await MainActor.run {
							let alert = UIAlertController(
								title: "Video Too Long",
								message: "Video must be under 2 minutes",
								preferredStyle: .alert
							)
							alert.addAction(UIAlertAction(title: "OK", style: .default))
							
							if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
							   let window = windowScene.windows.first,
							   let rootVC = window.rootViewController {
								var topVC = rootVC
								while let presentedVC = topVC.presentedViewController {
									topVC = presentedVC
								}
								topVC.present(alert, animated: true)
							}
						}
					}
				}
			}
			
			// Show alert if trying to add more than 5 total
			if parent.selectedMedia.count + newItems.count > 5 {
				await MainActor.run {
					let alert = UIAlertController(
						title: "Maximum Items Reached",
						message: "You can only post up to 5 images or videos at once.",
						preferredStyle: .alert
					)
					alert.addAction(UIAlertAction(title: "OK", style: .default))
					
					if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
					   let window = windowScene.windows.first,
					   let rootVC = window.rootViewController {
						var topVC = rootVC
						while let presentedVC = topVC.presentedViewController {
							topVC = presentedVC
						}
						topVC.present(alert, animated: true)
					}
				}
			}
			
			await MainActor.run {
				// Only add up to the 5-item limit
				let itemsToAdd = min(newItems.count, 5 - parent.selectedMedia.count)
				if itemsToAdd > 0 {
					parent.selectedMedia.append(contentsOf: Array(newItems.prefix(itemsToAdd)))
				}
			}
		}
		
		private func createMediaItem(from result: PHPickerResult) async -> CreatePostMediaItem {
			if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
				// Handle video
				return await withCheckedContinuation { continuation in
					result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
						if let error = error {
							print("❌ Error loading video: \(error)")
							continuation.resume(returning: CreatePostMediaItem(
								image: nil,
								videoURL: nil,
								videoDuration: nil,
								videoThumbnail: nil
							))
							return
						}
						
						if let url = url {
							let originalExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
							let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(originalExtension)")
							do {
								try FileManager.default.copyItem(at: url, to: tempURL)
								
								Task {
									let asset = AVURLAsset(url: tempURL)
									let duration = try? await asset.load(.duration).seconds
									
									// Generate thumbnail for preview
									let thumbnail = try? await generateVideoThumbnail(from: tempURL)
									
									let mediaItem = CreatePostMediaItem(
										image: nil,
										videoURL: tempURL,
										videoDuration: duration,
										videoThumbnail: thumbnail
									)
									continuation.resume(returning: mediaItem)
								}
							} catch {
								print("❌ Error copying video: \(error)")
								continuation.resume(returning: CreatePostMediaItem(
									image: nil,
									videoURL: nil,
									videoDuration: nil,
									videoThumbnail: nil
								))
							}
						} else {
							continuation.resume(returning: CreatePostMediaItem(
								image: nil,
								videoURL: nil,
								videoDuration: nil,
								videoThumbnail: nil
							))
						}
					}
				}
			} else {
				// Handle image
				return await withCheckedContinuation { continuation in
					result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
						if let image = object as? UIImage {
							let mediaItem = CreatePostMediaItem(
								image: image,
								videoURL: nil,
								videoDuration: nil,
								videoThumbnail: nil
							)
							continuation.resume(returning: mediaItem)
						} else {
							continuation.resume(returning: CreatePostMediaItem(
								image: nil,
								videoURL: nil,
								videoDuration: nil,
								videoThumbnail: nil
							))
						}
					}
				}
			}
		}
	}
}

// MARK: - Collection Picker View

struct CollectionPickerView: View {
	let collections: [CollectionData]
	@Binding var selectedCollection: CollectionData?
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		NavigationView {
			Group {
				if collections.isEmpty {
					VStack(spacing: 16) {
						Image(systemName: "folder.badge.plus")
							.font(.system(size: 60))
							.foregroundColor(.gray)
						Text("No Collections")
							.font(.title2)
							.fontWeight(.semibold)
						Text("Create a collection first to post your photos and videos")
							.font(.subheadline)
							.foregroundColor(.gray)
							.multilineTextAlignment(.center)
							.padding(.horizontal, 40)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					List(collections, id: \.id) { collection in
						collectionRow(collection)
					}
				}
			}
			.navigationTitle("Select Collection")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Cancel") {
						dismiss()
					}
				}
			}
		}
	}
	
	private func collectionRow(_ collection: CollectionData) -> some View {
		Button(action: {
			selectedCollection = collection
			dismiss()
		}) {
			HStack {
				collectionInfo(collection)
				Spacer()
				selectionIndicator(collection)
			}
		}
		.buttonStyle(PlainButtonStyle())
	}
	
	private func collectionInfo(_ collection: CollectionData) -> some View {
		VStack(alignment: .leading) {
			Text(collection.name)
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Text("\(collection.memberCount) members")
				.font(.caption)
				.foregroundColor(.gray)
		}
	}
	
	private func selectionIndicator(_ collection: CollectionData) -> some View {
		Group {
			if selectedCollection?.id == collection.id {
				Image(systemName: "checkmark")
					.foregroundColor(.blue)
			}
		}
	}
}

// MARK: - Video Thumbnail Generation

private func generateVideoThumbnail(from videoURL: URL) async throws -> UIImage {
	print("🎥 Generating thumbnail for preview: \(videoURL)")
	
	let asset = AVURLAsset(url: videoURL)
	let imageGenerator = AVAssetImageGenerator(asset: asset)
	imageGenerator.appliesPreferredTrackTransform = true
	imageGenerator.maximumSize = CGSize(width: 300, height: 300)
	imageGenerator.requestedTimeToleranceBefore = .zero
	imageGenerator.requestedTimeToleranceAfter = .zero
	
	// Get thumbnail at the very beginning (0.1 seconds) for a more representative frame
	let time = CMTime(seconds: 0.1, preferredTimescale: 600)
	
	let cgImage = try await imageGenerator.image(at: time).image
	let thumbnail = UIImage(cgImage: cgImage)
	
	print("🎥 Preview thumbnail generated successfully at 0.1 seconds")
	return thumbnail
}

// MARK: - Helper Functions

private func hideKeyboard() {
	UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
