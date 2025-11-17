import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import FirebaseAuth

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
	@State private var isPosting = false
	@State private var showError = false
	@State private var errorMessage = ""
	
	// Tag friends
	@State private var taggedFriends: [CYUser] = []
	@State private var showTagFriendsSheet = false
	@State private var allUsers: [CYUser] = []
	
	// Photo picker
	@State private var showPhotoPicker = false
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			headerView
			
			// Content
			ScrollView {
				VStack(spacing: 20) {
					// Media Grid (Pinterest style)
					mediaGridSection
					
					// Post Options
					postOptionsSection
				}
				.padding()
			}
			
			// Post Button
			postButton
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.alert("Error", isPresented: $showError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage)
		}
		.sheet(isPresented: $showPhotoPicker) {
			SimplePhotoPicker(
				selectedMedia: $selectedMedia,
				maxSelection: 5,
				isProcessing: $isProcessingMedia
			)
		}
		.sheet(isPresented: $showTagFriendsSheet) {
			TagFriendsSheet(
				allUsers: allUsers,
				taggedFriends: $taggedFriends
			)
		}
		.task {
			if allUsers.isEmpty {
				await loadUsers()
			}
			if !initialCaption.isEmpty {
				caption = initialCaption
			}
		}
	}
	
	// MARK: - Header
	private var headerView: some View {
		HStack {
			Button(action: { dismiss() }) {
				Image(systemName: "xmark")
					.font(.title2)
					.foregroundColor(.primary)
					.frame(width: 44, height: 44)
			}
			
			Spacer()
			
			Text("Create Post")
				.font(.headline)
				.foregroundColor(.primary)
			
			Spacer()
			
			Color.clear
				.frame(width: 44, height: 44)
		}
		.padding()
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
	
	// MARK: - Media Grid (Pinterest Style)
	private var mediaGridSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Media")
				.font(.headline)
				.foregroundColor(.primary)
			
			if selectedMedia.isEmpty {
				// Empty state - add media button
				Button(action: { showPhotoPicker = true }) {
					VStack(spacing: 12) {
						Image(systemName: "plus.circle.fill")
							.font(.system(size: 50))
							.foregroundColor(.blue)
						Text("Add Photos or Videos")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity)
					.frame(height: 200)
					.background(Color.gray.opacity(0.1))
					.cornerRadius(12)
				}
			} else {
				// Pinterest-style grid
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
					ForEach(selectedMedia.indices, id: \.self) { index in
						mediaCardView(selectedMedia[index], index: index)
					}
					
					// Add more button
					if selectedMedia.count < 5 {
						addMoreButton
					}
				}
			}
		}
	}
	
	@ViewBuilder
	private func mediaCardView(_ item: CreatePostMediaItem, index: Int) -> some View {
		ZStack(alignment: .topTrailing) {
			// Media content
			if let image = item.image {
				Image(uiImage: image)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(height: 200)
					.clipped()
					.cornerRadius(12)
			} else if let thumbnail = item.videoThumbnail {
				ZStack {
					Image(uiImage: thumbnail)
						.resizable()
						.aspectRatio(contentMode: .fill)
						.frame(height: 200)
						.clipped()
						.cornerRadius(12)
					
					// Video indicator
					VStack {
						Spacer()
						HStack {
							Spacer()
							Image(systemName: "play.circle.fill")
								.font(.title2)
								.foregroundColor(.white)
								.padding(8)
						}
					}
				}
			} else {
				Rectangle()
					.fill(Color.gray.opacity(0.3))
					.frame(height: 200)
					.cornerRadius(12)
			}
			
			// Remove button
			Button(action: {
				selectedMedia.remove(at: index)
			}) {
				Image(systemName: "xmark.circle.fill")
					.font(.title3)
					.foregroundColor(.white)
					.background(Color.black.opacity(0.5))
					.clipShape(Circle())
			}
			.padding(8)
		}
	}
	
	private var addMoreButton: some View {
		Button(action: { showPhotoPicker = true }) {
			VStack(spacing: 8) {
				Image(systemName: "plus")
					.font(.title)
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity)
			.frame(height: 200)
			.background(Color.gray.opacity(0.1))
			.cornerRadius(12)
			.overlay(
				RoundedRectangle(cornerRadius: 12)
					.strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
					.foregroundColor(.secondary)
			)
		}
	}
	
	// MARK: - Post Options
	private var postOptionsSection: some View {
		VStack(alignment: .leading, spacing: 20) {
			// Caption
			VStack(alignment: .leading, spacing: 8) {
				Text("Caption")
					.font(.headline)
					.foregroundColor(.primary)
				
				TextEditor(text: $caption)
					.frame(height: 100)
					.padding(8)
					.background(Color.gray.opacity(0.1))
					.cornerRadius(8)
					.overlay(
						Group {
							if caption.isEmpty {
								VStack {
									HStack {
										Text("Write a caption...")
											.foregroundColor(.gray.opacity(0.6))
											.padding(.horizontal, 12)
											.padding(.vertical, 16)
										Spacer()
									}
									Spacer()
								}
							}
						}
					)
			}
			
			Divider()
			
			// Tag Friends
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text("Tag Friends")
						.font(.headline)
						.foregroundColor(.primary)
					
					Spacer()
					
					Button(action: { showTagFriendsSheet = true }) {
						Image(systemName: "plus.circle")
							.foregroundColor(.blue)
					}
				}
				
				if !taggedFriends.isEmpty {
					ScrollView(.horizontal, showsIndicators: false) {
						HStack(spacing: 8) {
							ForEach(taggedFriends, id: \.id) { friend in
								taggedFriendChip(friend)
							}
						}
					}
				}
			}
			
			Divider()
			
			// Toggles
			VStack(spacing: 16) {
				Toggle(isOn: $allowDownload) {
					Text("Allow Download")
						.foregroundColor(.primary)
				}
				
				Toggle(isOn: $allowReplies) {
					Text("Allow Replies")
						.foregroundColor(.primary)
				}
			}
		}
	}
	
	@ViewBuilder
	private func taggedFriendChip(_ friend: CYUser) -> some View {
		HStack(spacing: 4) {
			if !friend.profileImageURL.isEmpty, let url = URL(string: friend.profileImageURL) {
				AsyncImage(url: url) { image in
					image.resizable()
				} placeholder: {
					Circle().fill(Color.gray.opacity(0.3))
				}
				.frame(width: 20, height: 20)
				.clipShape(Circle())
			}
			
			Text(friend.username)
				.font(.caption)
				.foregroundColor(.primary)
			
			Button(action: {
				taggedFriends.removeAll { $0.id == friend.id }
			}) {
				Image(systemName: "xmark.circle.fill")
					.font(.caption2)
					.foregroundColor(.gray)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.background(Color.gray.opacity(0.2))
		.cornerRadius(12)
	}
	
	// MARK: - Post Button
	private var postButton: some View {
		Button(action: {
			Task {
				await createPost()
			}
		}) {
			HStack {
				if isPosting {
					ProgressView()
						.progressViewStyle(CircularProgressViewStyle(tint: .white))
				}
				Text(isPosting ? "Posting..." : "Post")
					.font(.headline)
					.foregroundColor(.white)
			}
			.frame(maxWidth: .infinity)
			.padding()
			.background(isPosting || selectedMedia.isEmpty ? Color.gray : Color.blue)
			.cornerRadius(12)
		}
		.disabled(isPosting || selectedMedia.isEmpty)
		.padding()
	}
	
	// MARK: - Functions
	private func loadUsers() async {
		// TODO: Implement fetchAllUsers in CYServiceManager or use backend API
		// For now, using empty array - will need to add this method
		allUsers = []
	}
	
	private func createPost() async {
		guard !selectedMedia.isEmpty else { return }
		
		isPosting = true
		
		do {
			guard !collectionId.isEmpty else {
				throw NSError(domain: "CYCreatePost", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please select a collection"])
			}
			
			// Upload media and create posts
			// This will be handled by the backend API
			// For now, we'll need to upload to backend which handles S3
			let postIds = try await uploadAndCreatePosts()
			
			await MainActor.run {
				onPost(selectedMedia)
				NotificationCenter.default.post(
					name: NSNotification.Name("PostCreated"),
					object: collectionId,
					userInfo: ["postIds": postIds]
				)
				dismiss()
			}
		} catch {
			await MainActor.run {
				errorMessage = "Failed to post: \(error.localizedDescription)"
				showError = true
				isPosting = false
			}
		}
	}
	
	private func uploadAndCreatePosts() async throws -> [String] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "CYCreatePost", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		let taggedUserIds = taggedFriends.map { $0.id }
		
		// Create post via backend API (handles S3 upload and MongoDB)
		let response = try await APIClient.shared.createPost(
			collectionId: collectionId,
			caption: caption.isEmpty ? nil : caption,
			mediaItems: selectedMedia,
			taggedUsers: taggedUserIds.isEmpty ? nil : taggedUserIds,
			allowDownload: allowDownload,
			allowReplies: allowReplies
		)
		
		return [response.postId] // Backend returns single post ID for now
	}
}

// MARK: - Simple Photo Picker
struct SimplePhotoPicker: UIViewControllerRepresentable {
	@Binding var selectedMedia: [CreatePostMediaItem]
	let maxSelection: Int
	@Binding var isProcessing: Bool
	@Environment(\.dismiss) var dismiss
	
	func makeUIViewController(context: Context) -> PHPickerViewController {
		var config = PHPickerConfiguration()
		config.selectionLimit = maxSelection
		config.filter = .any(of: [.images, .videos])
		config.preferredAssetRepresentationMode = .current
		
		let picker = PHPickerViewController(configuration: config)
		picker.delegate = context.coordinator
		return picker
	}
	
	func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}
	
	class Coordinator: NSObject, PHPickerViewControllerDelegate {
		let parent: SimplePhotoPicker
		
		init(_ parent: SimplePhotoPicker) {
			self.parent = parent
		}
		
		func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
			guard !results.isEmpty else {
				parent.dismiss()
				return
			}
			
			Task {
				parent.isProcessing = true
				await loadMedia(results)
				await MainActor.run {
					parent.isProcessing = false
					parent.dismiss()
				}
			}
		}
		
		private func loadMedia(_ results: [PHPickerResult]) async {
			var newItems: [CreatePostMediaItem] = []
			
			for result in results.prefix(parent.maxSelection - parent.selectedMedia.count) {
				if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
					// Video
					if let item = await loadVideo(result) {
						newItems.append(item)
					}
				} else {
					// Image
					if let item = await loadImage(result) {
						newItems.append(item)
					}
				}
			}
			
			await MainActor.run {
				parent.selectedMedia.append(contentsOf: newItems)
			}
		}
		
		private func loadVideo(_ result: PHPickerResult) async -> CreatePostMediaItem? {
			return await withCheckedContinuation { continuation in
				result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
					guard let url = url, error == nil else {
						continuation.resume(returning: nil)
						return
					}
					
					let tempURL = FileManager.default.temporaryDirectory
						.appendingPathComponent(UUID().uuidString + ".\(url.pathExtension)")
					
					do {
						try FileManager.default.copyItem(at: url, to: tempURL)
						
						Task {
							let asset = AVURLAsset(url: tempURL)
							let duration = try? await asset.load(.duration).seconds
							let thumbnail = try? await self.generateThumbnail(from: tempURL)
							
							let item = CreatePostMediaItem(
								image: nil,
								videoURL: tempURL,
								videoDuration: duration,
								videoThumbnail: thumbnail
							)
							continuation.resume(returning: item)
						}
					} catch {
						continuation.resume(returning: nil)
					}
				}
			}
		}
		
		private func loadImage(_ result: PHPickerResult) async -> CreatePostMediaItem? {
			return await withCheckedContinuation { continuation in
				result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
					if let image = object as? UIImage {
						let item = CreatePostMediaItem(image: image, videoURL: nil, videoDuration: nil, videoThumbnail: nil)
						continuation.resume(returning: item)
					} else {
						continuation.resume(returning: nil)
					}
				}
			}
		}
		
		private func generateThumbnail(from url: URL) async throws -> UIImage {
			let asset = AVURLAsset(url: url)
			let generator = AVAssetImageGenerator(asset: asset)
			generator.appliesPreferredTrackTransform = true
			let time = CMTime(seconds: 0.1, preferredTimescale: 600)
			let cgImage = try await generator.image(at: time).image
			return UIImage(cgImage: cgImage)
		}
	}
}

// MARK: - Tag Friends Sheet
struct TagFriendsSheet: View {
	let allUsers: [CYUser]
	@Binding var taggedFriends: [CYUser]
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@State private var searchText = ""
	
	var filteredUsers: [CYUser] {
		if searchText.isEmpty {
			return allUsers
		}
		return allUsers.filter {
			$0.username.localizedCaseInsensitiveContains(searchText) ||
			$0.name.localizedCaseInsensitiveContains(searchText)
		}
	}
	
	var body: some View {
		NavigationView {
			VStack(spacing: 0) {
				// Search
				HStack {
					Image(systemName: "magnifyingglass")
						.foregroundColor(.gray)
					TextField("Search...", text: $searchText)
						.foregroundColor(.primary)
				}
				.padding()
				.background(Color.gray.opacity(0.1))
				.cornerRadius(10)
				.padding()
				
				// Users list
				List(filteredUsers, id: \.id) { user in
					UserRowView(
						user: user,
						isSelected: taggedFriends.contains { $0.id == user.id },
						onToggle: {
							if let index = taggedFriends.firstIndex(where: { $0.id == user.id }) {
								taggedFriends.remove(at: index)
							} else {
								taggedFriends.append(user)
							}
						}
					)
				}
			}
			.navigationTitle("Tag Friends")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
		}
	}
}

struct UserRowView: View {
	let user: CYUser
	let isSelected: Bool
	let onToggle: () -> Void
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		Button(action: onToggle) {
			HStack {
				if !user.profileImageURL.isEmpty, let url = URL(string: user.profileImageURL) {
					AsyncImage(url: url) { image in
						image.resizable()
					} placeholder: {
						Circle().fill(Color.gray.opacity(0.3))
					}
					.frame(width: 44, height: 44)
					.clipShape(Circle())
				} else {
					DefaultProfileImageView(size: 44)
				}
				
				VStack(alignment: .leading, spacing: 2) {
					Text(user.username)
						.font(.headline)
						.foregroundColor(.primary)
					Text(user.name)
						.font(.caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
				
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.foregroundColor(isSelected ? .blue : .gray)
			}
		}
		.buttonStyle(PlainButtonStyle())
	}
}

