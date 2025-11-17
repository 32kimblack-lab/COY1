import SwiftUI
import FirebaseAuth

struct CYInsideCollectionView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var collection: CollectionData
	@State private var posts: [CollectionPost] = []
	@State private var isLoadingPosts = false
	@State private var userProfileImageURL: String?
	@State private var showPhotoPicker = false
	@State private var selectedMedia: [CreatePostMediaItem] = []
	@State private var isProcessingMedia = false
	@State private var showCustomMenu = false
	@State private var showDeleteAlert = false
	@State private var isDeleting = false
	@State private var refreshTrigger = UUID()
	
	// Navigation states
	@State private var showEditCollection = false
	@State private var showAccessView = false
	@State private var showFollowersView = false
	@State private var isFollowing: Bool = false
	@State private var hasPendingRequest: Bool = false
	
	init(collection: CollectionData) {
		_collection = State(initialValue: collection)
	}
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				// Collection Header Section
				collectionHeaderSection
					.padding()
				
				// Pinterest Grid of Posts
				if isLoadingPosts {
					ProgressView()
						.padding()
				} else if posts.isEmpty {
					emptyStateView
						.padding()
				} else {
					PinterestPostGrid(
						posts: posts,
						collection: collection,
						isIndividualCollection: collection.type == "Individual",
						currentUserId: Auth.auth().currentUser?.uid
					)
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarTitleDisplayMode(.inline)
		.navigationBarBackButtonHidden(true)
		.toolbar {
			ToolbarItem(placement: .navigationBarLeading) {
				Button(action: { dismiss() }) {
					Image(systemName: "chevron.backward")
						.foregroundColor(.primary)
				}
			}
			ToolbarItem(placement: .navigationBarTrailing) {
				Button(action: { showCustomMenu.toggle() }) {
					Image(systemName: "ellipsis")
						.foregroundColor(.primary)
				}
			}
		}
		.onAppear {
			loadCollectionData()
			loadPosts()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostCreated"))) { notification in
			if let collectionId = notification.object as? String, collectionId == collection.id {
				loadPosts()
			}
		}
		.sheet(isPresented: $showPhotoPicker) {
			CustomPhotoPickerView(
				selectedMedia: $selectedMedia,
				maxSelectionCount: 5,
				isProcessingMedia: $isProcessingMedia
			)
		}
		.sheet(isPresented: Binding(
			get: { !selectedMedia.isEmpty && !showPhotoPicker },
			set: { _ in }
		)) {
			CYCreatePost(
				selectedMedia: $selectedMedia,
				collectionId: collection.id,
				isProcessingMedia: $isProcessingMedia,
				onPost: { _ in
					selectedMedia = []
					loadPosts()
				},
				isFromCamera: false
			)
		}
		.confirmationDialog("Collection Options", isPresented: $showCustomMenu, titleVisibility: .hidden) {
			if isCurrentUserOwner {
				Button("Edit Collection") {
					showEditCollection = true
				}
				Button("Access") {
					showAccessView = true
				}
				Button("Followers") {
					showFollowersView = true
				}
				if isCurrentUserOriginalCreator {
					Button("Delete Collection", role: .destructive) {
						showDeleteAlert = true
					}
				}
			} else if !isCurrentUserOwnerOrMember {
				Button("Report Collection", role: .destructive) { }
			}
			Button("Cancel", role: .cancel) {}
		}
		.alert("Delete Collection", isPresented: $showDeleteAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Delete", role: .destructive) {
				deleteCollection()
			}
		} message: {
			Text("Are you sure you want to delete this collection? This action cannot be undone.")
		}
	}
	
	// MARK: - Collection Header Section
	private var collectionHeaderSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Collection Image and Name
			HStack(spacing: 12) {
				// Collection Image
				if let imageURL = collection.imageURL, !imageURL.isEmpty {
					CachedProfileImageView(url: imageURL, size: 60)
				} else if let userImageURL = userProfileImageURL, !userImageURL.isEmpty {
					CachedProfileImageView(url: userImageURL, size: 60)
				} else {
					DefaultProfileImageView(size: 60)
				}
				
				// Collection Name and Info
				VStack(alignment: .leading, spacing: 4) {
					Text(collection.name)
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(.primary)
					
					Text(collection.type == "Individual" ? "Individual" : "\(collection.memberCount) members")
						.font(.subheadline)
						.foregroundColor(.secondary)
				}
				
				Spacer()
			}
			
			// Description
			if !collection.description.isEmpty {
				Text(collection.description)
					.font(.subheadline)
					.foregroundColor(.primary)
			}
			
			// Action Buttons
			HStack(spacing: 10) {
				if isCurrentUserOwner || isCurrentUserMember {
					Button(action: { showPhotoPicker = true }) {
						Text("Post")
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(.primary)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.gray.opacity(0.2))
							.cornerRadius(8)
					}
				} else {
					Button(action: {
						Task { await handleFollowAction() }
					}) {
						Text(isFollowing ? "Following" : "Follow")
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(.primary)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.gray.opacity(0.2))
							.cornerRadius(8)
					}
				}
				
				if shouldShowActionButton() {
					Button(action: {
						Task { await handleCollectionAction() }
					}) {
						Text(getActionButtonText())
							.font(.subheadline)
							.fontWeight(.medium)
							.foregroundColor(getActionButtonTextColor())
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(getActionButtonBackground())
							.cornerRadius(8)
					}
				}
			}
		}
	}
	
	// MARK: - Empty State
	private var emptyStateView: some View {
		VStack(spacing: 16) {
			Image(systemName: "photo.on.rectangle")
				.font(.system(size: 50))
				.foregroundColor(.gray)
			Text("No posts yet")
				.font(.headline)
				.foregroundColor(.secondary)
			if isCurrentUserOwner || isCurrentUserMember {
				Button(action: { showPhotoPicker = true }) {
					Text("Create First Post")
						.font(.subheadline)
						.foregroundColor(.blue)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 40)
	}
	
	// MARK: - Computed Properties
	private var isCurrentUserOwner: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId || collection.owners.contains(currentUserId)
	}
	
	private var isCurrentUserMember: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.members.contains(currentUserId)
	}
	
	private var isCurrentUserOriginalCreator: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId
	}
	
	private var isCurrentUserOwnerOrMember: Bool {
		return isCurrentUserOwner || isCurrentUserMember
	}
	
	private func shouldShowActionButton() -> Bool {
		return collection.type == "Request" || collection.type == "Open"
	}
	
	private func getActionButtonText() -> String {
		switch collection.type {
		case "Request":
			return hasPendingRequest ? "Requested" : "Request"
		case "Open":
			return isCurrentUserMember ? "Leave" : "Join"
		default:
			return ""
		}
	}
	
	private func getActionButtonTextColor() -> Color {
		if collection.type == "Request" && hasPendingRequest {
			return .blue
		}
		return .primary
	}
	
	private func getActionButtonBackground() -> Color {
		if collection.type == "Request" && hasPendingRequest {
			return Color.blue.opacity(0.1)
		}
		return Color.gray.opacity(0.2)
	}
	
	// MARK: - Functions
	private func loadCollectionData() {
		Task {
			// Load owner profile image
			do {
				if let ownerUser = try await UserService.shared.getUser(userId: collection.ownerId) {
					await MainActor.run {
						userProfileImageURL = ownerUser.profileImageURL
					}
				}
			} catch {
				print("Error loading owner profile: \(error)")
			}
			
			// Reload collection to get latest data
			do {
				if let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) {
					await MainActor.run {
						collection = updatedCollection
					}
				}
			} catch {
				print("Error reloading collection: \(error)")
			}
		}
	}
	
	private func loadPosts() {
		isLoadingPosts = true
		Task {
			do {
				// Use backend API to get collection posts
				let loadedPosts = try await APIClient.shared.getCollectionPosts(collectionId: collection.id)
				
				await MainActor.run {
					posts = loadedPosts
					isLoadingPosts = false
				}
			} catch {
				print("❌ Error loading posts: \(error)")
				await MainActor.run {
					posts = []
					isLoadingPosts = false
				}
			}
		}
	}
	
	private func handleFollowAction() async {
		// TODO: Implement follow/unfollow
		await MainActor.run {
			isFollowing.toggle()
		}
	}
	
	private func handleCollectionAction() async {
		// TODO: Implement request/join/leave
	}
	
	private func deleteCollection() {
		// TODO: Implement delete
		dismiss()
	}
}

