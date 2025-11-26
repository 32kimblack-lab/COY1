import Foundation
import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI

struct EditPostView: View {
	let post: CollectionPost
	let collection: CollectionData?
	
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var caption: String = ""
	@State private var allowDownload: Bool = false
	@State private var allowReplies: Bool = true
	@State private var isUpdating = false
	@State private var showError = false
	@State private var errorMessage = ""
	
	// Tag friends functionality
	@State private var taggedFriends: [CYUser] = []
	@State private var showTagFriendsSheet = false
	@State private var allUsers: [CYUser] = []
	@State private var isLoadingUsers = false
	
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			headerView
			
			contentScrollView
				.frame(maxHeight: .infinity)
			
			Spacer(minLength: 0)
			
			updateButton
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
			await loadInitialData()
			await loadAllUsers()
		}
		.sheet(isPresented: $showTagFriendsSheet) {
			TagFriendsView(
				allUsers: allUsers,
				taggedFriends: $taggedFriends,
				isLoadingUsers: $isLoadingUsers
			)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PostUpdated"))) { notification in
			// Dismiss when post is updated
			if let updatedPostId = notification.object as? String, updatedPostId == post.id {
				dismiss()
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
			
			Text("Edit Post")
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
				// Media preview (read-only)
				mediaPreviewSection
				postDetailsSection
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
	}
	
	private var mediaPreviewSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Media (cannot be changed)")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 10) {
					ForEach(post.mediaItems.indices, id: \.self) { index in
						let mediaItem = post.mediaItems[index]
						mediaPreviewItem(mediaItem: mediaItem, index: index)
					}
				}
				.padding(.horizontal)
			}
		}
		.padding(.top)
	}
	
	@ViewBuilder
	private func mediaPreviewItem(mediaItem: MediaItem, index: Int) -> some View {
		ZStack(alignment: .topLeading) {
			if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 150, height: 150)
					.cornerRadius(10)
					.clipped()
			} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
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
			
			// Order number overlay
			Text("\(index + 1)")
				.font(.system(size: 18, weight: .bold))
				.foregroundColor(.white)
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(Color.black.opacity(0.9))
				.cornerRadius(15)
				.padding(.top, 8)
				.padding(.leading, 8)
			
			// Video indicator
			if mediaItem.isVideo {
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
		}
		.frame(width: 150, height: 150)
	}
	
	private var postDetailsSection: some View {
		VStack(alignment: .leading, spacing: 20) {
			captionSection
			tagFriendsSection
			downloadToggleSection
			repliesToggleSection
		}
	}
	
	private var captionSection: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text("Caption")
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
	
	private var downloadToggleSection: some View {
		VStack {
			Divider().background(Color.gray)
			Toggle(isOn: $allowDownload) {
				Text("Allow Download")
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
					Text("Allow Replies")
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
				.toggleStyle(SwitchToggleStyle(tint: .blue))
				.padding(.horizontal)
			}
		}
	}
	
	// Update Button
	private var updateButton: some View {
		Button(action: {
			Task {
				await updatePost()
			}
		}) {
			HStack {
				if isUpdating {
					ProgressView()
						.progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
						.padding(.trailing, 5)
				}
				Text(isUpdating ? "Updating..." : "Update Post")
					.font(.headline)
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			.frame(maxWidth: .infinity)
			.padding()
			.background(isUpdating ? Color.gray : Color.blue)
			.cornerRadius(10)
		}
		.disabled(isUpdating)
		.padding(.horizontal)
		.padding(.bottom, 20)
	}
	
	// MARK: - Data Loading
	
	private func loadInitialData() async {
		await MainActor.run {
			// Load current post data
			caption = post.caption ?? ""
			allowDownload = post.allowDownload
			allowReplies = post.allowReplies
			
			// Load tagged users
			if !post.taggedUsers.isEmpty {
				Task {
					await loadTaggedUsers()
				}
			}
		}
	}
	
	private func loadTaggedUsers() async {
		var loadedUsers: [CYUser] = []
		
		for userId in post.taggedUsers {
			do {
				if let user = try? await UserService.shared.getUser(userId: userId) {
					loadedUsers.append(CYUser(
						id: user.id,
						name: user.name,
						username: user.username,
						profileImageURL: user.profileImageURL ?? ""
					))
				}
			}
		}
		
		await MainActor.run {
			taggedFriends = loadedUsers
		}
	}
	
	private func loadAllUsers() async {
		isLoadingUsers = true
		// TODO: Implement fetchAllUsers - for now using empty array
		// This would need to be implemented in UserService
		allUsers = []
		isLoadingUsers = false
	}
	
	// MARK: - Update Post
	
	private func updatePost() async {
		isUpdating = true
		
		do {
			let taggedUserIds = taggedFriends.map { $0.id }
			
			try await CollectionService.shared.updatePost(
				postId: post.id,
				caption: caption.isEmpty ? "" : caption, // Empty string to remove caption
				taggedUsers: taggedUserIds.isEmpty ? [] : taggedUserIds,
				allowDownload: allowDownload,
				allowReplies: allowReplies
			)
			
			print("✅ Post updated successfully")
			
			// Post notification to refresh views
			await MainActor.run {
				NotificationCenter.default.post(
					name: NSNotification.Name("PostUpdated"),
					object: post.id,
					userInfo: ["postId": post.id, "collectionId": post.collectionId]
				)
				
				// Also post general collection update notification
				NotificationCenter.default.post(
					name: NSNotification.Name("CollectionUpdated"),
					object: post.collectionId
				)
				
				dismiss()
			}
		} catch {
			print("❌ Error updating post: \(error.localizedDescription)")
			await MainActor.run {
				errorMessage = "Failed to update post. Please try again."
				showError = true
				isUpdating = false
			}
		}
	}
	
	private func hideKeyboard() {
		UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
	}
}

// Note: CYUser is defined in Models/CYUser.swift

