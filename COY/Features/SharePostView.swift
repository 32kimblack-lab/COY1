import SwiftUI
import SDWebImageSwiftUI
import FirebaseAuth
import FirebaseFirestore

struct SharePostView: View {
	let post: CollectionPost
	
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var friends: [ShareUser] = []
	@State private var messageContacts: [ShareUser] = []
	@State private var selectedUsers: Set<String> = []
	@State private var isLoading = true
	@State private var isSharing = false
	@State private var searchText = ""
	@State private var errorMessage: String?
	@State private var showSuccessMessage = false
	
	private let userService = UserService.shared
	private let db = Firestore.firestore()
	
	var allUsers: [ShareUser] {
		let combined = friends + messageContacts
		// Remove duplicates by userId
		let unique = Dictionary(grouping: combined, by: { $0.userId })
			.compactMap { $0.value.first }
		
		if searchText.isEmpty {
			return unique.sorted { $0.username < $1.username }
		} else {
			let query = searchText.lowercased()
			return unique.filter { user in
				user.username.lowercased().contains(query) ||
				user.name.lowercased().contains(query)
			}.sorted { $0.username < $1.username }
		}
	}
	
	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				// Search bar
				HStack {
					Image(systemName: "magnifyingglass")
						.foregroundColor(.gray)
					TextField("Search friends...", text: $searchText)
						.textFieldStyle(PlainTextFieldStyle())
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.background(Color(.systemGray5))
				.cornerRadius(12)
				.padding(.horizontal)
				.padding(.vertical, 8)
				
				// Users list
				if isLoading {
					Spacer()
					ProgressView()
					Spacer()
				} else if allUsers.isEmpty {
					Spacer()
					VStack(spacing: 16) {
						Image(systemName: "person.2")
							.font(.system(size: 48))
							.foregroundColor(.secondary)
						Text("No friends or contacts found")
							.font(.headline)
							.foregroundColor(.secondary)
						Text("Add friends to share posts with them")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					Spacer()
				} else {
					ScrollView {
						LazyVStack(spacing: 0) {
							ForEach(allUsers) { user in
								ShareUserRow(
									user: user,
									isSelected: selectedUsers.contains(user.userId),
									onToggle: {
										if selectedUsers.contains(user.userId) {
											selectedUsers.remove(user.userId)
										} else {
											selectedUsers.insert(user.userId)
										}
									}
								)
							}
						}
					}
				}
				
				// Share button
				if !selectedUsers.isEmpty {
					VStack(spacing: 0) {
						Divider()
						Button(action: {
							Task {
								await sharePost()
							}
						}) {
							if isSharing {
								ProgressView()
									.progressViewStyle(CircularProgressViewStyle(tint: .white))
									.frame(maxWidth: .infinity)
									.frame(height: 50)
							} else {
								Text("Share with \(selectedUsers.count) \(selectedUsers.count == 1 ? "friend" : "friends")")
									.font(.headline)
									.foregroundColor(.white)
									.frame(maxWidth: .infinity)
									.frame(height: 50)
							}
						}
						.background(selectedUsers.isEmpty ? Color.gray : Color.blue)
						.disabled(selectedUsers.isEmpty || isSharing)
					}
					.background(colorScheme == .dark ? Color.black : Color.white)
				}
			}
			.background(colorScheme == .dark ? Color.black : Color.white)
			.navigationTitle("Share Post")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Cancel") {
						dismiss()
					}
				}
			}
			.alert("Error", isPresented: .constant(errorMessage != nil)) {
				Button("OK") {
					errorMessage = nil
				}
			} message: {
				Text(errorMessage ?? "")
			}
			.alert("Shared Successfully", isPresented: $showSuccessMessage) {
				Button("OK") {
					dismiss()
				}
			} message: {
				Text("Post shared with \(selectedUsers.count) \(selectedUsers.count == 1 ? "friend" : "friends")")
			}
			.task {
				await loadFriendsAndContacts()
			}
		}
	}
	
	private func loadFriendsAndContacts() async {
		isLoading = true
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			await MainActor.run {
				isLoading = false
			}
			return
		}
		
		// Load friends first
		let loadedFriends = await loadFriends(currentUserId: currentUserId)
		
		await MainActor.run {
			self.friends = loadedFriends
		}
		
		// Then load contacts, excluding friends
		let loadedContacts = await loadMessageContacts(currentUserId: currentUserId, friends: loadedFriends)
		
		await MainActor.run {
			self.messageContacts = loadedContacts
			self.isLoading = false
		}
	}
	
	private func loadFriends(currentUserId: String) async -> [ShareUser] {
		do {
			let userDoc = try await db.collection("users").document(currentUserId).getDocument()
			guard let data = userDoc.data(),
				  let friendIds = data["friends"] as? [String] else {
				return []
			}
			
			var loadedFriends: [ShareUser] = []
			for friendId in friendIds {
				if let user = try? await userService.getUser(userId: friendId) {
					loadedFriends.append(ShareUser(
						userId: user.id,
						username: user.username,
						name: user.name,
						profileImageURL: user.profileImageURL
					))
				}
			}
			return loadedFriends
		} catch {
			print("Error loading friends: \(error)")
			return []
		}
	}
	
	private func loadMessageContacts(currentUserId: String, friends: [ShareUser]) async -> [ShareUser] {
		do {
			// Load chat rooms directly from Firebase
			let chatRoomsSnapshot = try await db.collection("chatRooms")
				.whereField("participants", arrayContains: currentUserId)
				.getDocuments()
			
			var contactIds: Set<String> = []
			
			for doc in chatRoomsSnapshot.documents {
				if let participants = doc.data()["participants"] as? [String] {
					for participantId in participants where participantId != currentUserId {
						contactIds.insert(participantId)
					}
				}
			}
			
			// Get friend IDs to exclude from contacts
			let friendIds = Set(friends.map { $0.userId })
			
			var loadedContacts: [ShareUser] = []
			for contactId in contactIds {
				// Skip if already in friends list
				if friendIds.contains(contactId) {
					continue
				}
				
				if let user = try? await userService.getUser(userId: contactId) {
					loadedContacts.append(ShareUser(
						userId: user.id,
						username: user.username,
						name: user.name,
						profileImageURL: user.profileImageURL
					))
				}
			}
			return loadedContacts
		} catch {
			print("Error loading message contacts: \(error)")
			return []
		}
	}
	
	private func sharePost() async {
		guard !selectedUsers.isEmpty else { return }
		
		isSharing = true
		errorMessage = nil
		
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			await MainActor.run {
				errorMessage = "You must be logged in to share"
				isSharing = false
			}
			return
		}
		
		// Build share message content
		var shareContent = ""
		if let caption = post.caption, !caption.isEmpty {
			shareContent = caption
		} else if !post.title.isEmpty {
			shareContent = post.title
		} else {
			shareContent = "Check out this post!"
		}
		
		// Add post link/identifier so recipient can open it in the app
		let postLink = "coy://post/\(post.id)"
		if !shareContent.isEmpty {
			shareContent += "\n\n\(postLink)"
		} else {
			shareContent = postLink
		}
		
		// Determine message type based on post media
		// For now, send as text with link - the recipient can click to view the post
		let messageType = "text"
		
		// Share with each selected user
		var successCount = 0
		var errorCount = 0
		
		for userId in selectedUsers {
			do {
				// Get or create chat room
				let chatRoomId = try await getOrCreateChatRoom(participants: [currentUserId, userId])
				
				// Send post as message
				try await sendMessage(
					chatId: chatRoomId,
					type: messageType,
					content: shareContent
				)
				successCount += 1
			} catch {
				print("Error sharing post with \(userId): \(error)")
				errorCount += 1
			}
		}
		
		await MainActor.run {
			isSharing = false
			
			if errorCount == 0 {
				showSuccessMessage = true
			} else if successCount > 0 {
				errorMessage = "Shared with \(successCount) \(successCount == 1 ? "friend" : "friends"), but \(errorCount) \(errorCount == 1 ? "sharing failed" : "sharings failed")"
			} else {
				errorMessage = "Failed to share post. Please try again."
			}
		}
	}
	
	// MARK: - Chat Helper Functions
	private func getOrCreateChatRoom(participants: [String]) async throws -> String {
		let sortedParticipants = participants.sorted()
		
		// Try to find existing chat room
		let existingRooms = try await db.collection("chatRooms")
			.whereField("participants", isEqualTo: sortedParticipants)
			.limit(to: 1)
			.getDocuments()
		
		if let existingRoom = existingRooms.documents.first {
			return existingRoom.documentID
		}
		
		// Create new chat room
		let newRoomRef = db.collection("chatRooms").document()
		try await newRoomRef.setData([
			"participants": sortedParticipants,
			"createdAt": Timestamp(),
			"lastMessageAt": Timestamp()
		])
		
		return newRoomRef.documentID
	}
	
	private func sendMessage(chatId: String, type: String, content: String) async throws {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "SharePostView", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		let messageRef = db.collection("chatRooms").document(chatId).collection("messages").document()
		try await messageRef.setData([
			"senderId": currentUserId,
			"type": type,
			"content": content,
			"createdAt": Timestamp(),
			"read": false
		])
		
		// Update chat room's last message timestamp
		try await db.collection("chatRooms").document(chatId).updateData([
			"lastMessageAt": Timestamp()
		])
	}
}

// MARK: - Share User Model
struct ShareUser: Identifiable {
	let id: String
	let userId: String
	let username: String
	let name: String
	let profileImageURL: String?
	
	init(userId: String, username: String, name: String, profileImageURL: String?) {
		self.id = userId
		self.userId = userId
		self.username = username
		self.name = name
		self.profileImageURL = profileImageURL
	}
}

// MARK: - Share User Row
struct ShareUserRow: View {
	let user: ShareUser
	let isSelected: Bool
	let onToggle: () -> Void
	
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		Button(action: onToggle) {
			HStack(spacing: 12) {
				// Profile image
				Group {
					if let imageURL = user.profileImageURL, !imageURL.isEmpty {
						WebImage(url: URL(string: imageURL))
							.resizable()
							.indicator(.activity)
							.scaledToFill()
							.frame(width: 50, height: 50)
							.clipShape(Circle())
					} else {
						Circle()
							.fill(Color.gray.opacity(0.3))
							.frame(width: 50, height: 50)
							.overlay(
								Text(user.name.prefix(1).uppercased())
									.font(.headline)
									.foregroundColor(.gray)
							)
					}
				}
				
				// Name and username
				VStack(alignment: .leading, spacing: 4) {
					Text(user.name)
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Text("@\(user.username)")
						.font(.subheadline)
						.foregroundColor(.secondary)
				}
				
				Spacer()
				
				// Selection indicator
				if isSelected {
					Image(systemName: "checkmark.circle.fill")
						.foregroundColor(.blue)
						.font(.system(size: 24))
				} else {
					Image(systemName: "circle")
						.foregroundColor(.gray)
						.font(.system(size: 24))
				}
			}
			.padding(.horizontal)
			.padding(.vertical, 12)
			.background(colorScheme == .dark ? Color.black : Color.white)
		}
		.buttonStyle(.plain)
		
		Divider()
			.padding(.leading, 62)
	}
}

