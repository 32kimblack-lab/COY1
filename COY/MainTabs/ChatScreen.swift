import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import UIKit
import SDWebImageSwiftUI
import AVFoundation

struct ChatScreen: View {
	let chatId: String
	let otherUserId: String
	private let chatService = ChatService.shared
	private let friendService = FriendService.shared
	private let userService = UserService.shared
	@State private var messages: [MessageModel] = []
	@State private var otherUser: UserService.AppUser?
	@State private var currentUser: UserService.AppUser?
	@State private var chatRoom: ChatRoomModel?
	@State private var messageText = ""
	@State private var showActions = false
	@State private var selectedMessage: MessageModel?
	@State private var showMediaGallery = false
	@State private var showSearchMessages = false
	@State private var replyToMessage: MessageModel?
	@State private var showClearChatConfirmation = false
	@State private var isUploadingMedia = false
	@State private var uploadProgress: Double = 0.0
	@State private var isLoadingOlderMessages = false
	@State private var hasMoreMessages = true
	@State private var oldestMessageId: String?
	@State private var areActuallyFriends: Bool? = nil // Cache actual friendship status
	@State private var hasScrolledToBottom = false // Track if we've scrolled to bottom on initial load
	@State private var showVideoTooLongAlert = false
	@State private var selectedImageURL: String?
	@State private var selectedVideoURL: String?
	@State private var showBlockUserConfirmation = false
	@State private var showBlockUserError = false
	@State private var blockUserErrorMessage = ""
	@State private var showReactionDetails = false
	@State private var selectedReactionEmoji: String?
	@State private var selectedReactionMessage: MessageModel?
	@Environment(\.dismiss) var dismiss
	@EnvironmentObject var authService: AuthService
	
	var currentUid: String? {
		Auth.auth().currentUser?.uid
	}
	
	var displayUsername: String {
		// First check if user is loaded
		guard let user = otherUser else {
			return "Loading..."
		}
		
		// If username exists and is not empty, return it
		if !user.username.isEmpty {
			return user.username
		}
		
		// If username is empty but name exists, return name
		if !user.name.isEmpty {
			return user.name
		}
		
		// Last resort: show first 8 chars of user ID
		return String(otherUserId.prefix(8))
	}
	
	// MARK: - Toolbar Components
	
	private var navigationBarLeadingContent: some View {
				HStack(spacing: 12) {
					// Back Button
					Button(action: {
						dismiss()
					}) {
						Image(systemName: "chevron.backward")
							.font(.system(size: 17, weight: .semibold))
							.foregroundColor(.blue)
					}
					
					// Profile Info
			profileInfoView
		}
	}
	
	@ViewBuilder
	private var profileInfoView: some View {
					let currentUserId = Auth.auth().currentUser?.uid ?? ""
					if otherUserId != currentUserId {
						NavigationLink(destination: ViewerProfileView(userId: otherUserId).environmentObject(authService)) {
				profileInfoContent
						}
						.buttonStyle(.plain)
					} else {
						// Not clickable for own profile
			profileInfoContent
		}
	}
	
	private var profileInfoContent: some View {
						HStack(spacing: 8) {
							CachedProfileImageView(url: otherUser?.profileImageURL ?? "", size: 32)
							VStack(alignment: .leading, spacing: 2) {
				Text(displayUsername)
									.font(.system(size: 16, weight: .semibold))
									.foregroundColor(.primary)
								if let name = otherUser?.name, !name.isEmpty {
									Text(name)
										.font(.system(size: 13))
										.foregroundColor(.gray)
						}
					}
				}
			}
			
	private var navigationBarTrailingContent: some View {
				Menu {
					Button(action: {
						showSearchMessages = true
					}) {
						Label("Search messages", systemImage: "magnifyingglass")
					}
					
					Button(action: {
						showMediaGallery = true
					}) {
						Label("View photos & videos", systemImage: "photo.on.rectangle")
					}
					
					Divider()
					
					Button(action: {
						showClearChatConfirmation = true
					}) {
						Label("Clear chat", systemImage: "trash")
					}
					
					Divider()
					
					Button(role: .destructive, action: {
						showBlockUserConfirmation = true
					}) {
				Label("Block User", systemImage: "hand.raised.fill")
					}
					
			// Show Unadd option only if user hasn't already unadded
			// Hide if: iUnadded (I already unadded) or bothUnadded (both already unadded)
			// Show if: friends (can unadd), theyUnadded (they unadded me, I can unadd back), pending
			if shouldShowUnaddOption {
					Button(role: .destructive, action: {
						unaddFriend()
					}) {
						Label("Unadd", systemImage: "person.badge.minus")
				}
					}
				} label: {
					Image(systemName: "ellipsis")
				}
	}
	
	private var shouldShowUnaddOption: Bool {
		switch friendshipStatus {
		case .friends, .theyUnadded, .pending:
			return true // Can unadd
		case .iUnadded, .bothUnadded, .blocked, .unadded:
			return false // Already unadded or can't unadd
		}
	}
	
	private var mainContentView: some View {
		VStack(spacing: 0) {
			messagesScrollView
			replyPreviewSection
			uploadProgressSection
			chatInputBar
		}
	}
	
	private var contentWithToolbar: some View {
		mainContentView
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					navigationBarLeadingContent
				}
				
				ToolbarItem(placement: .navigationBarTrailing) {
					navigationBarTrailingContent
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.navigationBarBackButtonHidden(true)
			.toolbar(.hidden, for: .tabBar)
	}
	
	var body: some View {
		contentWithToolbar
			.onAppear {
			// Load user data first to show username immediately
			loadOtherUser()
			loadCurrentUser()
			loadChatRoom()
			loadMessages()
			markAsRead()
			// Check friendship status immediately and aggressively
			checkFriendshipStatus()
			// Also check again after a short delay to ensure it's updated
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				checkFriendshipStatus()
			}
			// Reload user data after a short delay in case it failed initially
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
				if otherUser == nil {
					print("⚠️ ChatScreen: User still nil after 0.3s, retrying load")
					loadOtherUser()
				}
			}
			// Final retry after 1 second
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				if otherUser == nil {
					print("⚠️ ChatScreen: User still nil after 1.0s, final retry with fallback")
					Task {
						await loadUserFallback()
					}
				}
			}
		}
		.onChange(of: otherUser) { oldValue, newValue in
			// Force UI update when user loads
			if let user = newValue {
				print("🔄 ChatScreen: otherUser changed - username: '\(user.username)', name: '\(user.name)'")
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
			// Update user info when profile is updated
			if let userId = notification.object as? String {
				if userId == otherUserId {
					// Reload other user's profile
					loadOtherUser()
				} else if userId == currentUid {
					// Reload current user's profile
					loadCurrentUser()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestAccepted"))) { notification in
			// Reload chat room when friend request is accepted
			if let userId = notification.object as? String,
			   userId == otherUserId || userId == currentUid {
				loadChatRoom()
				checkFriendshipStatus() // Re-check immediately
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendAdded"))) { notification in
			// Reload chat room when friend is added
			if let userId = notification.object as? String,
			   userId == otherUserId || userId == currentUid {
				loadChatRoom()
				checkFriendshipStatus() // Re-check immediately
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserProfileImageUpdated"))) { notification in
			// Update profile image when it's updated
			if let userId = notification.object as? String {
				if userId == otherUserId {
					loadOtherUser()
				} else if userId == currentUid {
					loadCurrentUser()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserNameUpdated"))) { notification in
			// Update username when it's updated
			if let userId = notification.object as? String {
				if userId == otherUserId {
					loadOtherUser()
				} else if userId == currentUid {
					loadCurrentUser()
				}
			}
		}
		.overlay {
			if showActions, let message = selectedMessage {
				MessageContextMenu(
					message: message,
					isMine: message.senderUid == currentUid,
					onDismiss: {
						withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
							showActions = false
						}
					},
					onDelete: {
						deleteMessage(message)
					},
					onEdit: { newText in
						editMessage(message, newText: newText)
					},
					onReply: {
						replyToMessage = message
						showActions = false
					},
					onReact: { emoji in
						reactToMessage(message, emoji: emoji)
					},
					onCopy: {
						UIPasteboard.general.string = message.content
					}
				)
				.transition(AnyTransition.opacity.combined(with: .scale(scale: 0.9)))
				.zIndex(1000)
			}
		}
		.sheet(isPresented: $showMediaGallery) {
			ChatMediaGallery(chatId: chatId)
				.presentationCompactAdaptation(.none)
		}
		.sheet(isPresented: $showSearchMessages) {
			SearchMessagesScreen(chatId: chatId)
				.presentationCompactAdaptation(.none)
		}
		.fullScreenCover(isPresented: Binding(
			get: { selectedImageURL != nil },
			set: { if !$0 { selectedImageURL = nil } }
		)) {
			if let imageURL = selectedImageURL {
				FullScreenImageView(imageURL: imageURL)
			}
		}
		.fullScreenCover(isPresented: Binding(
			get: { selectedVideoURL != nil },
			set: { if !$0 { selectedVideoURL = nil } }
		)) {
			if let videoURL = selectedVideoURL {
				FullScreenVideoView(videoURL: videoURL)
			}
		}
		.alert("Clear Chat", isPresented: $showClearChatConfirmation) {
			Button("Cancel", role: .cancel) { }
			Button("Clear", role: .destructive) {
				clearChat()
			}
		} message: {
			Text("Are you sure you want to clear this chat? This will permanently delete all messages for you and you won't be able to get them back.")
		}
		.alert("Video Too Long", isPresented: $showVideoTooLongAlert) {
			Button("OK", role: .cancel) { }
		} message: {
			Text("Videos must be 2 minutes or shorter. Please select a shorter video.")
		}
		.alert("Block User", isPresented: $showBlockUserConfirmation) {
			Button("Cancel", role: .cancel) { }
			Button("Block", role: .destructive) {
				blockUser()
			}
		} message: {
			Text("Are you sure you want to block this user? You won't be able to see each other's messages or profiles.")
		}
		.alert("Error Blocking User", isPresented: $showBlockUserError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(blockUserErrorMessage)
		}
		.overlay {
			if showReactionDetails, let emoji = selectedReactionEmoji, let message = selectedReactionMessage {
				ReactionDetailsView(
					message: message,
					emoji: emoji,
					onRemoveReaction: { emoji in
						removeReaction(message: message, emoji: emoji)
					},
					onDismiss: {
						showReactionDetails = false
						selectedReactionEmoji = nil
						selectedReactionMessage = nil
					}
				)
				.transition(AnyTransition.opacity.combined(with: .scale(scale: 0.9)))
				.zIndex(1001)
			}
		}
	}
	
	private func loadCurrentUser() {
		guard let uid = currentUid else { return }
		Task {
			do {
				let user = try await userService.getUser(userId: uid)
				await MainActor.run {
					self.currentUser = user
				}
			} catch {
				print("Error loading current user: \(error)")
			}
		}
	}
	
	private func loadOtherUser() {
		Task {
			do {
				print("📱 ChatScreen: Loading user data for \(otherUserId)")
				let user = try await userService.getUser(userId: otherUserId)
				await MainActor.run {
					if let user = user {
					self.otherUser = user
						print("✅ ChatScreen: Loaded user - username: '\(user.username)', name: '\(user.name)'")
						print("✅ ChatScreen: otherUser state - username: '\(self.otherUser?.username ?? "nil")'")
					} else {
						print("⚠️ ChatScreen: User not found via UserService, trying fallback")
						Task {
							await loadUserFallback()
						}
					}
				}
			} catch {
				print("❌ ChatScreen: Error loading user \(otherUserId): \(error)")
				// Try to load from Firestore directly as fallback
				await loadUserFallback()
			}
		}
	}
	
	private func loadUserFallback() async {
		let db = Firestore.firestore()
		do {
			print("📱 ChatScreen: Attempting fallback load for user \(otherUserId)")
			let userDoc = try await db.collection("users").document(otherUserId).getDocument()
			
			guard userDoc.exists else {
				print("❌ ChatScreen: User document does not exist for \(otherUserId)")
				return
			}
			
			guard let data = userDoc.data() else {
				print("❌ ChatScreen: User document has no data for \(otherUserId)")
				return
			}
			
			print("📱 ChatScreen: User document data keys: \(data.keys)")
			
			let username = data["username"] as? String ?? ""
			let name = data["name"] as? String ?? ""
			let profileImageURL = data["profileImageURL"] as? String
			let backgroundImageURL = data["backgroundImageURL"] as? String
			let email = data["email"] as? String ?? ""
			let birthMonth = data["birthMonth"] as? String ?? ""
			let birthDay = data["birthDay"] as? String ?? ""
			let birthYear = data["birthYear"] as? String ?? ""
			
			print("📱 ChatScreen: Extracted username: '\(username)', name: '\(name)'")
			
			await MainActor.run {
				self.otherUser = UserService.AppUser(
					userId: otherUserId,
					name: name,
					username: username,
					profileImageURL: profileImageURL,
					backgroundImageURL: backgroundImageURL,
					birthMonth: birthMonth,
					birthDay: birthDay,
					birthYear: birthYear,
					email: email
				)
				print("✅ ChatScreen: Loaded user from fallback - username: '\(username)', name: '\(name)'")
				print("✅ ChatScreen: otherUser state updated - username: '\(self.otherUser?.username ?? "nil")'")
			}
		} catch {
			print("❌ ChatScreen: Fallback loading also failed: \(error)")
		}
	}
	
	private func loadMessages() {
		Task {
			// Check if user is blocked before loading messages
			let friendService = FriendService.shared
			let isBlocked = await friendService.isBlocked(userId: otherUserId)
			let isBlockedBy = await friendService.isBlockedBy(userId: otherUserId)
			
			// If user is blocked (mutual invisibility), don't load messages and dismiss
			if isBlocked || isBlockedBy {
				await MainActor.run {
					dismiss()
				}
				return
			}
			
			do {
				// Load most recent messages first (limit 50)
				// Messages come ordered by timestamp descending (newest first from Firestore)
				for try await messageList in chatService.getMessages(chatId: chatId, limit: 50) {
					await MainActor.run {
						let reversedList = Array(messageList.reversed())
						
						if self.messages.isEmpty {
							// First load: replace entire array
							self.messages = reversedList
						} else {
							// Subsequent updates: merge changes to preserve optimistic updates
							var updatedMessages = self.messages
							let messageDict = Dictionary(uniqueKeysWithValues: reversedList.map { ($0.messageId, $0) })
							
							guard let currentUid = currentUid else {
								// No current user - just use server data
								self.messages = reversedList
								return
							}
							
							// Update existing messages - merge server updates intelligently
							// Preserve optimistic updates until server confirms, but always show real-time updates from others
							for (index, existingMessage) in updatedMessages.enumerated() {
								if let serverMessage = messageDict[existingMessage.messageId] {
									// Check if this is an optimistic edit from current user that hasn't been confirmed yet
									let localIsEdited = existingMessage.isEdited
									let serverIsEdited = serverMessage.isEdited
									let localEditCount = existingMessage.editCount
									let serverEditCount = serverMessage.editCount
									let isMyOptimisticEdit = localIsEdited && 
										existingMessage.senderUid == currentUid &&
										(!serverIsEdited || localEditCount > serverEditCount)
									
									// Check if there are optimistic reactions from current user
									// Compare reactions: if local has current user's reaction that server doesn't have, it's optimistic
									let localMyReaction = existingMessage.reactions[currentUid]
									let serverMyReaction = serverMessage.reactions[currentUid]
									let hasMyOptimisticReaction = localMyReaction != nil && localMyReaction != serverMyReaction
									
									// Always merge reactions from server to show real-time updates from other users
									// But preserve current user's optimistic reaction if it hasn't been confirmed
									var mergedReactions = serverMessage.reactions
									if hasMyOptimisticReaction, let myReaction = localMyReaction {
										// Keep current user's optimistic reaction until server confirms
										mergedReactions[currentUid] = myReaction
									}
									
									if isMyOptimisticEdit || hasMyOptimisticReaction {
										// Keep optimistic update, but merge all other fields from server (including reactions from others)
										var mergedMessage = existingMessage
										// Preserve optimistic edit if it's from current user
										if !isMyOptimisticEdit {
											mergedMessage.content = serverMessage.content
											mergedMessage.isEdited = serverMessage.isEdited
											mergedMessage.editedAt = serverMessage.editedAt
											mergedMessage.editCount = serverMessage.editCount
										}
										// Always use merged reactions (server + optimistic)
										mergedMessage.reactions = mergedReactions
										// Always update other fields that might have changed
										mergedMessage.isDeleted = serverMessage.isDeleted
										mergedMessage.deletedFor = serverMessage.deletedFor
										updatedMessages[index] = mergedMessage
									} else {
										// No optimistic updates - use server version (includes all real-time updates)
										updatedMessages[index] = serverMessage
									}
								}
							}
							
							// Add any new messages that don't exist yet
							for newMessage in reversedList {
								if !updatedMessages.contains(where: { $0.messageId == newMessage.messageId }) {
									// Insert new message in correct position (maintain chronological order)
									if let insertIndex = updatedMessages.firstIndex(where: { $0.timestamp > newMessage.timestamp }) {
										updatedMessages.insert(newMessage, at: insertIndex)
									} else {
										updatedMessages.append(newMessage)
									}
								}
							}
							
							// Create new array reference to trigger SwiftUI update
							self.messages = updatedMessages
						}
						
						// Update pagination state
						// Since we reversed, the first one is now the oldest
						if let oldestMessage = self.messages.first {
							self.oldestMessageId = oldestMessage.messageId
							// If we got less than 50 messages, there are no more
							self.hasMoreMessages = messageList.count >= 50
						} else {
							self.hasMoreMessages = false
						}
						
						// Reset scroll flag when messages first load
						if !self.messages.isEmpty && !hasScrolledToBottom {
							hasScrolledToBottom = false
						}
					}
				}
			} catch {
				print("Error loading messages: \(error)")
			}
		}
	}
	
	private func loadOlderMessages() {
		guard !isLoadingOlderMessages,
			  hasMoreMessages,
			  let oldestId = oldestMessageId else {
			return
		}
		
		isLoadingOlderMessages = true
		
		Task {
			do {
				// Load older messages (messages before the oldest we have)
				// These come ordered by timestamp descending (newest of the old ones first)
				let olderMessages = try await chatService.loadOlderMessages(
					chatId: chatId,
					beforeMessageId: oldestId,
					limit: 50
				)
				
				await MainActor.run {
					// Prepend older messages to the beginning (they're older, so go at top)
					// Since loadOlderMessages returns descending (newest first), reverse them
					// to get chronological order (oldest first)
					self.messages = olderMessages.reversed() + self.messages
					
					// Update pagination state
					// The first message is now the oldest
					if let newOldest = self.messages.first {
						self.oldestMessageId = newOldest.messageId
					}
					
					// If we got less than 50 messages, there are no more
					self.hasMoreMessages = olderMessages.count >= 50
					self.isLoadingOlderMessages = false
				}
			} catch {
				print("Error loading older messages: \(error)")
				await MainActor.run {
					self.isLoadingOlderMessages = false
				}
			}
		}
	}
	
	private func sendMessage() {
		guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		
		Task {
			do {
				try await chatService.sendMessage(
					chatId: chatId,
					type: "text",
					content: messageText,
					replyTo: replyToMessage?.messageId
				)
				await MainActor.run {
					messageText = ""
					replyToMessage = nil
				}
			} catch {
				print("Error sending message: \(error)")
			}
		}
	}
	
	private func sendMediaMessage(image: UIImage?, videoURL: URL?) {
		Task {
			do {
				// Validate video duration before processing
				if let videoURL = videoURL {
					let duration = await getVideoDuration(url: videoURL)
					let maxDuration: TimeInterval = 120 // 2 minutes in seconds
					
					if duration > maxDuration {
						await MainActor.run {
							showVideoTooLongAlert = true
						}
						return
					}
				}
				
				await MainActor.run {
					isUploadingMedia = true
					uploadProgress = 0.1 // Start with 10% to show activity
				}
				
				let storageService = StorageService.shared
				var mediaURL: String = ""
				var messageType: String = "text"
				
				if let image = image {
					// Update progress
					await MainActor.run {
						uploadProgress = 0.3 // Image compression/resizing
					}
					
					// Upload image to Firebase Storage
					let imagePath = "chat_media/\(UUID().uuidString).jpg"
					
					await MainActor.run {
						uploadProgress = 0.5 // Starting upload
					}
					
					mediaURL = try await storageService.uploadChatImage(image, path: imagePath)
					messageType = "image"
				} else if let videoURL = videoURL {
					// Update progress
					await MainActor.run {
						uploadProgress = 0.2 // Video compression starting
					}
					
					// Upload video to Firebase Storage
					let videoPath = "chat_media/\(UUID().uuidString).mp4"
					
					await MainActor.run {
						uploadProgress = 0.6 // Compression done, starting upload
					}
					
					mediaURL = try await storageService.uploadChatVideo(videoURL, path: videoPath)
					messageType = "video"
				}
				
				await MainActor.run {
					uploadProgress = 0.9 // Upload complete, sending message
				}
				
				guard !mediaURL.isEmpty else {
					await MainActor.run {
						isUploadingMedia = false
						uploadProgress = 0.0
					}
					return
				}
				
				// Send message with media URL
				try await chatService.sendMessage(
					chatId: chatId,
					type: messageType,
					content: mediaURL,
					replyTo: replyToMessage?.messageId
				)
				
				await MainActor.run {
					uploadProgress = 1.0
					isUploadingMedia = false
					uploadProgress = 0.0
					replyToMessage = nil
				}
			} catch {
				print("Error sending media message: \(error)")
				await MainActor.run {
					isUploadingMedia = false
					uploadProgress = 0.0
				}
			}
		}
	}
	
	private func deleteMessage(_ message: MessageModel) {
		// Store original message for potential revert
		let originalMessage = message
		let messageIdToDelete = message.messageId
		
		// Optimistic update: immediately replace message with deleted version
		// The backend will delete the original and create a replacement message
		if let index = messages.firstIndex(where: { $0.messageId == messageIdToDelete }) {
			var deletedMessage = message
			deletedMessage.isDeleted = true
			deletedMessage.content = (deletedMessage.type == "text") ? "This message was deleted" : "This media was deleted"
			deletedMessage.messageId = "\(messageIdToDelete)_deleted" // Temporary ID until real-time listener updates
			messages[index] = deletedMessage
		}
		
		showActions = false
		
		Task {
			do {
				try await chatService.deleteMessage(chatId: chatId, messageId: messageIdToDelete)
				// Real-time listener will confirm the deletion and replacement message
			} catch {
				print("Error deleting message: \(error)")
				// Revert optimistic update on error - restore original message
				await MainActor.run {
					if let index = messages.firstIndex(where: { $0.messageId == "\(messageIdToDelete)_deleted" }) {
						messages[index] = originalMessage
					} else if let index = messages.firstIndex(where: { $0.messageId == messageIdToDelete }) {
						messages[index] = originalMessage
					}
				}
			}
		}
	}
	
	private func editMessage(_ message: MessageModel, newText: String) {
		// Check edit count before allowing edit
		guard message.editCount < 2 else {
			print("Message has already been edited 2 times")
			Task { @MainActor in
				showActions = false
			}
			return
		}
		
		// Optimistic update: immediately update local state on main thread
		Task { @MainActor in
			withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
				if let index = messages.firstIndex(where: { $0.messageId == message.messageId }) {
					var updatedMessage = message
					updatedMessage.content = newText
					updatedMessage.isEdited = true
					updatedMessage.editedAt = Date()
					updatedMessage.editCount = message.editCount + 1
					
					// Create a new array to trigger SwiftUI update
					var updatedMessages = messages
					updatedMessages[index] = updatedMessage
					messages = updatedMessages
				}
			}
			
			showActions = false
		}
		
		Task {
			do {
				try await chatService.editMessage(chatId: chatId, messageId: message.messageId, newText: newText)
				// Real-time listener will confirm the update
			} catch {
				print("Error editing message: \(error)")
				// Revert optimistic update on error
				await MainActor.run {
					if let index = messages.firstIndex(where: { $0.messageId == message.messageId }) {
						var updatedMessages = messages
						updatedMessages[index] = message
						messages = updatedMessages
					}
				}
			}
		}
	}
	
	private func reactToMessage(_ message: MessageModel, emoji: String) {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		
		// Optimistic update: immediately update local state on main thread
		Task { @MainActor in
			withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
				if let index = messages.firstIndex(where: { $0.messageId == message.messageId }) {
					var updatedMessage = message
					var updatedReactions = message.reactions
					
					if message.reactions[currentUid] == emoji {
						// Remove reaction if already reacted
						updatedReactions.removeValue(forKey: currentUid)
					} else {
						// Add reaction
						updatedReactions[currentUid] = emoji
					}
					
					updatedMessage.reactions = updatedReactions
					
					// Create a new array to trigger SwiftUI update
					var updatedMessages = messages
					updatedMessages[index] = updatedMessage
					messages = updatedMessages
				}
			}
			
			showActions = false
		}
		
		Task {
			do {
				// Check if user already reacted with this emoji
				if message.reactions[currentUid] == emoji {
					// Remove reaction if already reacted
					try await chatService.removeReaction(chatId: chatId, messageId: message.messageId)
				} else {
					// Add reaction
					try await chatService.addReaction(chatId: chatId, messageId: message.messageId, emoji: emoji)
				}
				// Real-time listener will confirm the update
			} catch {
				print("Error adding/removing reaction: \(error)")
				// Revert optimistic update on error
				await MainActor.run {
					if let index = messages.firstIndex(where: { $0.messageId == message.messageId }) {
						var updatedMessages = messages
						updatedMessages[index] = message
						messages = updatedMessages
					}
				}
			}
		}
	}
	
	private func removeReaction(message: MessageModel, emoji: String) {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		
		// Optimistic update: immediately update local state on main thread
		Task { @MainActor in
			withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
				if let index = messages.firstIndex(where: { $0.messageId == message.messageId }) {
					var updatedMessage = message
					var updatedReactions = message.reactions
					updatedReactions.removeValue(forKey: currentUid)
					updatedMessage.reactions = updatedReactions
					
					// Create a new array to trigger SwiftUI update
					var updatedMessages = messages
					updatedMessages[index] = updatedMessage
					messages = updatedMessages
				}
			}
		}
		
		Task {
			do {
				try await chatService.removeReaction(chatId: chatId, messageId: message.messageId)
				// Real-time listener will confirm the update
			} catch {
				print("Error removing reaction: \(error)")
				// Revert optimistic update on error
				await MainActor.run {
					if let index = messages.firstIndex(where: { $0.messageId == message.messageId }) {
						var updatedMessages = messages
						updatedMessages[index] = message
						messages = updatedMessages
					}
				}
			}
		}
	}
	
	private func clearChat() {
		Task {
			do {
				try await chatService.clearChatForMe(chatId: chatId)
			} catch {
				print("Error clearing chat: \(error)")
			}
		}
	}
	
	private func blockUser() {
		Task {
			do {
				try await friendService.blockUser(blockedUid: otherUserId)
				await MainActor.run {
					// Dismiss the chat screen after successful block
					dismiss()
				}
			} catch {
				print("Error blocking user: \(error)")
				await MainActor.run {
					blockUserErrorMessage = error.localizedDescription
					showBlockUserError = true
				}
			}
		}
	}
	
	private func unaddFriend() {
		Task {
			do {
				try await friendService.removeFriend(friendUid: otherUserId)
				// Reload chat room to get updated status
				await MainActor.run {
					loadChatRoom()
				}
			} catch {
				print("Error unadding friend: \(error)")
			}
		}
	}
	
	private func loadChatRoom() {
		Task {
			do {
				let room = try await chatService.getOrCreateChatRoom(participants: [currentUid ?? "", otherUserId])
				
				// Check if we're actually friends in the users collection
				if let currentUid = currentUid {
					let areFriends = await friendService.isFriend(userId: otherUserId)
					
					await MainActor.run {
						// Cache the actual friendship status
						self.areActuallyFriends = areFriends
						self.chatRoom = room
					}
					
					let myStatus = room.chatStatus[currentUid] ?? "friends"
					let theirStatus = room.chatStatus[otherUserId] ?? "friends"
					
					// If we're actually friends but chat status is wrong, fix it
					if areFriends && (myStatus != "friends" || theirStatus != "friends") {
						// Update chat status to friends if we're actually friends
						let chatRef = Firestore.firestore().collection("chat_rooms").document(room.chatId)
						try? await chatRef.updateData([
							"chatStatus.\(currentUid)": "friends",
							"chatStatus.\(otherUserId)": "friends"
						])
						
						// Reload chat room to get updated status
						await MainActor.run {
							loadChatRoom()
						}
					}
				} else {
					await MainActor.run {
						self.chatRoom = room
					}
				}
			} catch {
				print("Error loading chat room: \(error)")
			}
		}
	}
	
	private var canMessage: Bool {
		guard let currentUid = currentUid else {
			return false
		}
		
		// PRIORITY 1: If we've checked and they're actually friends, ALWAYS allow messaging
		// This is the most reliable check - if we're friends in the users collection, allow messaging
		if let areFriends = areActuallyFriends, areFriends {
			return true
		}
		
		// PRIORITY 2: Check chat room status
		if let chatRoom = chatRoom {
			let myStatus = chatRoom.chatStatus[currentUid] ?? "friends"
			let theirStatus = chatRoom.chatStatus[otherUserId] ?? "friends"
			
			// Can message ONLY if both are "friends"
			if myStatus == "friends" && theirStatus == "friends" {
				return true
			}
			
			// If chat status is wrong but we haven't checked friendship yet, check it
			if areActuallyFriends == nil {
				Task {
					checkFriendshipStatus()
				}
				// Don't be optimistic - only allow if status says friends
				return false
			}
		} else {
			// Chat room not loaded yet - check friendship
			if areActuallyFriends == nil {
				Task {
					checkFriendshipStatus()
				}
			}
			// Don't allow messaging until we know the status
			return false
		}
		
		// If we've checked and they're not friends, return false
		return false
	}
	
	private var friendshipStatus: ChatInputBar.FriendshipStatus {
		guard let currentUid = currentUid,
			  let chatRoom = chatRoom else {
			// If we're actually friends, return friends, otherwise check
			if let areFriends = areActuallyFriends, areFriends {
				return .friends
			}
			return .friends // Default optimistic
		}
		
		// First check: If we're actually friends in the users collection, we're friends
		if let areFriends = areActuallyFriends, areFriends {
			return .friends
		}
		
		let myStatus = chatRoom.chatStatus[currentUid] ?? "friends"
		let theirStatus = chatRoom.chatStatus[otherUserId] ?? "friends"
		
		// Both are friends (chat status)
		if myStatus == "friends" && theirStatus == "friends" {
			return .friends
		}
		
		// Both unadded each other - initial state
		// Both see "You have un-added this user" with Add button
		if myStatus == "bothUnadded" && theirStatus == "bothUnadded" {
			return .bothUnadded
		}
		
		// Both-way un-add: I added first (pendingAdd), they still have bothUnadded
		// I see "You have been un-added by this user" (waiting for them to add)
		if myStatus == "pendingAdd" && theirStatus == "bothUnadded" {
			return .theyUnadded // Show "You have been un-added by this user"
		}
		
		// Both-way un-add: They added first (pendingAdd), I still have bothUnadded
		// I see "You have un-added this user" with Add button (they're waiting for me)
		if myStatus == "bothUnadded" && theirStatus == "pendingAdd" {
			return .iUnadded // Show "You have un-added this user" with Add button
		}
		
		// Both-way un-add: Both have pendingAdd (both sent requests)
		// Both are waiting for the other to accept - show "You have been unadded by this user" (no button)
		// When one accepts the other's request, friendship is restored
		if myStatus == "pendingAdd" && theirStatus == "pendingAdd" {
			return .theyUnadded // Show "You have been unadded by this user" (waiting for request acceptance)
		}
		
		// I unadded them (myStatus = "iUnadded", theirStatus = "theyUnadded")
		// From my perspective: "You have unadded this person" + Add button
		if myStatus == "iUnadded" && theirStatus == "theyUnadded" {
			return .iUnadded // I see "Add this user back"
		}
		
		// They unadded me (theirStatus = "iUnadded", myStatus = "theyUnadded")
		// From my perspective: "You have been unadded"
		if myStatus == "theyUnadded" && theirStatus == "iUnadded" {
			return .theyUnadded // I see "This user unadded you"
		}
		
		// I unadded them (but they haven't responded yet - they're still "friends")
		// This is the initial state after I unadd them
		if myStatus == "iUnadded" && theirStatus == "friends" {
			return .iUnadded // I see "Add this user back"
		}
		
		// They unadded me (but I haven't responded yet - I'm still "friends")
		// This is the initial state after they unadd me
		if myStatus == "friends" && theirStatus == "iUnadded" {
			return .theyUnadded // I see "This user unadded you"
		}
		
		// I'm trying to add them back (pendingAdd) but they haven't added me yet (one-way un-add)
		// From my perspective: "You have been unadded" (because they haven't added me back)
		if myStatus == "pendingAdd" && (theirStatus == "theyUnadded" || theirStatus == "iUnadded") {
			return .theyUnadded // Show "You have been unadded" message
		}
		
		// They're trying to add me back (pendingAdd) but I haven't added them yet (one-way un-add)
		// From my perspective: "Add this user back" button (they're waiting for me)
		if theirStatus == "pendingAdd" && (myStatus == "iUnadded" || myStatus == "theyUnadded") {
			return .iUnadded // Show "Add this user back" button
		}
		
		// Edge case: I'm pendingAdd and they're still friends (they haven't unadded me)
		// This means I'm trying to add them back after I unadded them, but they didn't unadd me
		// In this case, if they accept, we should become friends
		// But until they accept, I should see "Add this user back" (waiting for them to accept)
		if myStatus == "pendingAdd" && theirStatus == "friends" {
			return .theyUnadded // Show "You have been unadded" (waiting for them to accept)
		}
		
		// Default fallback - check actual friendship status
		if let areFriends = areActuallyFriends {
			return areFriends ? .friends : .iUnadded
		}
		
		return .friends // Default optimistic
	}
	
	private func addFriend() {
		Task {
			do {
				// Check if we should directly restore friendship or send a request
				guard let currentUid = currentUid,
					  let chatRoom = chatRoom else {
					// No chat room - send normal friend request
					try await friendService.sendFriendRequest(toUid: otherUserId)
					await MainActor.run {
						loadChatRoom()
						checkFriendshipStatus()
					}
					return
				}
				
				let myStatus = chatRoom.chatStatus[currentUid] ?? "friends"
				let theirStatus = chatRoom.chatStatus[otherUserId] ?? "friends"
				
				// Case 1: I unadded them, they didn't unadd me (theyUnadded or friends)
				// Directly restore friendship - no request needed
				if (myStatus == "iUnadded" && (theirStatus == "theyUnadded" || theirStatus == "friends")) {
					try await friendService.restoreFriendship(userId: otherUserId)
					await MainActor.run {
						loadChatRoom()
						checkFriendshipStatus()
					}
					return
				}
				
				// Case 2: Both unadded each other
				// When one person adds first, they send a request and their status becomes "pendingAdd"
				// They will see "You have been un-added by this user" until the other person also adds
				// When the second person adds, friendship is restored immediately
				if myStatus == "bothUnadded" && theirStatus == "bothUnadded" {
					// I'm adding first - send request and wait for them to add
					try await friendService.sendFriendRequest(toUid: otherUserId)
					await MainActor.run {
						loadChatRoom()
						checkFriendshipStatus()
					}
					return
				}
				
				// Case 2b: I have pendingAdd (I added first) and they still have bothUnadded
				// They need to add me back - I'm waiting
				// Don't do anything, just reload to show waiting state
				if myStatus == "pendingAdd" && theirStatus == "bothUnadded" {
					await MainActor.run {
						loadChatRoom()
						checkFriendshipStatus()
					}
					return
				}
				
				// Case 2c: They have pendingAdd (they added first) and I have bothUnadded
				// I'm adding now - send request to set my status to pendingAdd
				// When my request is accepted, it will check if both have pendingAdd and restore friendship
				if myStatus == "bothUnadded" && theirStatus == "pendingAdd" {
					try await friendService.sendFriendRequest(toUid: otherUserId)
					await MainActor.run {
						loadChatRoom()
						checkFriendshipStatus()
					}
					return
				}
				
				// Case 2d: Both have pendingAdd (both clicked Add - both sent requests)
				// When one accepts the other's request, it will restore friendship
				// For now, if both have pendingAdd, we can restore immediately since both have added
				if myStatus == "pendingAdd" && theirStatus == "pendingAdd" {
					// Both have added each other - restore friendship
					try await friendService.restoreFriendship(userId: otherUserId)
					await MainActor.run {
						loadChatRoom()
						checkFriendshipStatus()
					}
					return
				}
				
				// Case 3: They unadded me, I haven't unadded them
				// Need to send request and wait for them to accept
				if myStatus == "theyUnadded" && theirStatus == "iUnadded" {
					try await friendService.sendFriendRequest(toUid: otherUserId)
					await MainActor.run {
						loadChatRoom()
						checkFriendshipStatus()
					}
					return
				}
				
				// Default: send normal friend request
				try await friendService.sendFriendRequest(toUid: otherUserId)
				await MainActor.run {
					loadChatRoom()
					checkFriendshipStatus()
				}
			} catch {
				print("Error adding friend: \(error)")
			}
		}
	}
	
	private func updateChatStatusForCurrentUser(to status: String) {
		guard let currentUid = currentUid,
			  let chatRoom = chatRoom else { return }
		
		Task {
			do {
				let chatRef = Firestore.firestore().collection("chat_rooms").document(chatRoom.chatId)
				try await chatRef.updateData([
					"chatStatus.\(currentUid)": status
				])
				// Reload chat room
				loadChatRoom()
			} catch {
				print("Error updating chat status: \(error)")
			}
		}
	}
	
	private func markAsRead() {
		Task {
			do {
				try await chatService.markChatAsRead(chatId: chatId)
			} catch {
				print("Error marking as read: \(error)")
			}
		}
	}
	
	private func checkFriendshipStatus() {
		Task {
			guard let currentUid = currentUid else { return }
			let areFriends = await friendService.isFriend(userId: otherUserId)
			await MainActor.run {
				// Update friendship status immediately to fix gray box
				// This will trigger UI update via canMessage computed property
				self.areActuallyFriends = areFriends
				
				// If we're friends but chat status is wrong, fix it immediately
				if areFriends {
					// Ensure chat room exists and has correct status
					Task {
						do {
							let room = try await chatService.getOrCreateChatRoom(participants: [currentUid, otherUserId])
							await MainActor.run {
								self.chatRoom = room
							}
							
							// Check if status needs fixing
							let myStatus = room.chatStatus[currentUid] ?? "friends"
							let theirStatus = room.chatStatus[otherUserId] ?? "friends"
							
							if myStatus != "friends" || theirStatus != "friends" {
								// Fix the status
								let chatRef = Firestore.firestore().collection("chat_rooms").document(room.chatId)
								try? await chatRef.updateData([
									"chatStatus.\(currentUid)": "friends",
									"chatStatus.\(otherUserId)": "friends"
								])
								// Reload to update UI
								await MainActor.run {
									loadChatRoom()
								}
							}
						} catch {
							print("Error checking/creating chat room: \(error)")
						}
					}
				}
			}
		}
	}
	
	// MARK: - View Components
	
	private var messagesScrollView: some View {
		ScrollViewReader { proxy in
			ScrollView {
				messagesListContent
					.padding()
			}
			.scrollDismissesKeyboard(.interactively)
			.onAppear {
				scrollToBottomOnAppear(proxy: proxy)
			}
			.onChange(of: messages.count) { oldCount, newCount in
				handleMessageCountChange(proxy: proxy, oldCount: oldCount, newCount: newCount)
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToMessage"))) { notification in
				if let messageId = notification.object as? String {
					// Find message in the chronological array
					if let message = messages.first(where: { $0.messageId == messageId }) {
						withAnimation {
							proxy.scrollTo(message.id, anchor: .center)
						}
					}
				}
			}
		}
	}
	
	private var messagesListContent: some View {
		LazyVStack(alignment: .leading, spacing: 12) {
			// Load more button at top (for loading older messages when scrolling up)
			loadMoreButton
			// Messages in chronological order (oldest at top, newest at bottom)
			messagesList
			// Bottom anchor for scrolling to newest messages
			bottomAnchor
		}
	}
	
	@ViewBuilder
	private var loadMoreButton: some View {
		if hasMoreMessages && !messages.isEmpty {
			Button(action: {
				loadOlderMessages()
			}) {
				HStack {
					if isLoadingOlderMessages {
						ProgressView()
							.scaleEffect(0.8)
					} else {
						Image(systemName: "arrow.up")
							.font(.system(size: 12))
					}
					Text(isLoadingOlderMessages ? "Loading older messages..." : "Load older messages")
						.font(.system(size: 14))
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 8)
				.background(Color(.systemGray6))
				.cornerRadius(20)
			}
			.disabled(isLoadingOlderMessages)
			.padding(.top, 8)
			.id("loadMoreButton")
		}
	}
	
	private var messagesList: some View {
		// Messages are already in chronological order (oldest first)
		// So we display them directly - oldest at top, newest at bottom
		ForEach(messages) { message in
			messageBubbleView(message: message)
				.id(message.id)
				.padding(.vertical, 4)
				.contentShape(Rectangle())
		}
	}
	
	private var bottomAnchor: some View {
		Color.clear
			.frame(height: 1)
			.id("bottomAnchor")
	}
	
	@ViewBuilder
	private func messageBubbleView(message: MessageModel) -> some View {
		// Find the replied-to message if this message is a reply
		let repliedToMessage: MessageModel? = {
			guard let replyToId = message.replyToMessageId else { return nil }
			return messages.first { $0.messageId == replyToId }
		}()
		
		// Get the username for the replied-to message sender
		let repliedToSenderName: String? = {
			guard let repliedTo = repliedToMessage else { return nil }
			if repliedTo.senderUid == currentUid {
				return currentUser?.username
			} else {
				return otherUser?.username
			}
		}()
		
		MessageBubble(
			message: message,
			isMe: message.senderUid == currentUid,
			senderProfileImageURL: message.senderUid == currentUid 
				? currentUser?.profileImageURL 
				: otherUser?.profileImageURL,
			repliedToMessage: repliedToMessage,
			repliedToSenderName: repliedToSenderName,
			onLongPress: {
				selectedMessage = message
				withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
					showActions = true
				}
			},
			onReplyTap: {
				// Scroll to the replied message
				if let repliedTo = repliedToMessage {
					withAnimation {
						NotificationCenter.default.post(
							name: NSNotification.Name("ScrollToMessage"),
							object: repliedTo.messageId
						)
					}
				}
			},
			onReactionTap: { emoji in
				// Remove reaction if user already reacted with this emoji
				removeReaction(message: message, emoji: emoji)
			},
			onReactionDetailsTap: { emoji in
				selectedReactionEmoji = emoji
				selectedReactionMessage = message
				showReactionDetails = true
			},
			onMediaTap: { mediaURL, mediaType in
				// Set the appropriate URL based on media type
				if mediaType == "image" {
					selectedImageURL = mediaURL
				} else if mediaType == "video" {
					selectedVideoURL = mediaURL
				}
			}
		)
	}
	
	@ViewBuilder
	private var replyPreviewSection: some View {
		if let replyTo = replyToMessage {
			HStack(spacing: 12) {
				// Cancel button (matching MediaPreviewView)
				Button(action: {
					replyToMessage = nil
				}) {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 24))
						.foregroundColor(.red)
				}
					
				// Media preview or text preview (matching MediaPreviewView size)
				Group {
					if replyTo.isDeleted {
						Text(replyTo.type == "text" ? "This message was deleted" : "This media was deleted")
							.font(.system(size: 12))
							.italic()
							.foregroundColor(.secondary)
							.lineLimit(1)
					} else {
						switch replyTo.type {
						case "text":
							VStack(alignment: .leading, spacing: 2) {
								Text(replyTo.senderUid == currentUid ? "You" : (otherUser?.username ?? "User"))
									.font(.system(size: 10, weight: .semibold))
									.foregroundColor(.blue)
							Text(replyTo.content)
									.font(.system(size: 11))
								.foregroundColor(.primary)
									.lineLimit(1)
							}
							.frame(width: 60, height: 60, alignment: .leading)
						case "image", "photo":
								if let url = URL(string: replyTo.content) {
									WebImage(url: url)
										.resizable()
										.indicator(.activity)
										.scaledToFill()
									.frame(width: 60, height: 60)
									.clipShape(RoundedRectangle(cornerRadius: 8))
										.clipped()
							}
						case "video":
							ReplyVideoThumbnailView(videoURLString: replyTo.content)
						default:
							Text("[\(replyTo.type)]")
								.font(.system(size: 11))
								.foregroundColor(.secondary)
								.frame(width: 60, height: 60, alignment: .leading)
						}
					}
				}
				
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.background(Color(.systemGray6))
			.cornerRadius(20)
			.overlay(
				Rectangle()
					.frame(height: 1)
					.foregroundColor(Color(.separator)),
				alignment: .top
			)
		}
	}
	
	@ViewBuilder
	private var uploadProgressSection: some View {
		if isUploadingMedia {
			HStack(spacing: 12) {
				ProgressView(value: uploadProgress, total: 1.0)
					.progressViewStyle(LinearProgressViewStyle())
				Text(uploadProgress < 1.0 ? "Uploading..." : "Processing...")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.padding(.horizontal)
			.padding(.vertical, 8)
			.background(Color(.systemGray6))
		}
	}
	
	private var chatInputBar: some View {
		ChatInputBar(
			messageText: $messageText,
			replyToMessage: $replyToMessage,
			onSend: {
				sendMessage()
			},
			onSendMedia: { image, videoURL in
				sendMediaMessage(image: image, videoURL: videoURL)
			},
			canMessage: canMessage,
			friendshipStatus: friendshipStatus,
			onAddFriend: {
				addFriend()
			}
		)
		.disabled(isUploadingMedia)
	}
	
	// MARK: - Scroll Helpers
	
	private func scrollToBottomOnAppear(proxy: ScrollViewProxy) {
		// Scroll to bottom anchor on initial load - use longer delay to ensure content is rendered
		// This ensures the chat starts at the bottom showing newest messages (like WhatsApp/iMessage)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
			withAnimation(.easeOut(duration: 0.3)) {
				proxy.scrollTo("bottomAnchor", anchor: .bottom)
			}
			hasScrolledToBottom = true
		}
	}
	
	private func handleMessageCountChange(proxy: ScrollViewProxy, oldCount: Int, newCount: Int) {
		// Only auto-scroll if new message was added (not when loading older messages)
		// New messages are appended to the end (newest at bottom)
		if newCount > oldCount {
			// New message added - scroll to bottom to show it
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				withAnimation(.easeOut(duration: 0.2)) {
					proxy.scrollTo("bottomAnchor", anchor: .bottom)
				}
			}
		} else if !hasScrolledToBottom && newCount > 0 {
			// Initial load - scroll to bottom to show newest messages
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
				withAnimation(.easeOut(duration: 0.3)) {
					proxy.scrollTo("bottomAnchor", anchor: .bottom)
				}
				hasScrolledToBottom = true
			}
		}
	}
	
	// MARK: - Video Duration Helper
	private func getVideoDuration(url: URL) async -> TimeInterval {
		let asset = AVAsset(url: url)
		do {
			let duration = try await asset.load(.duration)
			return CMTimeGetSeconds(duration)
		} catch {
			print("Error getting video duration: \(error)")
			return 0
		}
	}
	
}

// MARK: - Reply Video Thumbnail View
struct ReplyVideoThumbnailView: View {
	let videoURLString: String
	@State private var thumbnail: UIImage?
	
	var body: some View {
		ZStack {
			if let thumbnail = thumbnail {
				Image(uiImage: thumbnail)
					.resizable()
					.scaledToFill()
					.frame(width: 60, height: 60)
					.clipShape(RoundedRectangle(cornerRadius: 8))
					.clipped()
			} else {
				RoundedRectangle(cornerRadius: 8)
					.fill(Color.gray.opacity(0.3))
					.frame(width: 60, height: 60)
					.overlay(
						ProgressView()
							.tint(.white)
					)
			}
			
			// Play icon overlay (matching MediaPreviewView)
			Image(systemName: "play.circle.fill")
				.font(.system(size: 24))
				.foregroundColor(.white)
		}
		.frame(width: 60, height: 60)
		.clipped()
		.onAppear {
			generateThumbnail()
		}
	}
	
	private func generateThumbnail() {
		guard let url = URL(string: videoURLString) else { return }
		
		let asset = AVAsset(url: url)
		let imageGenerator = AVAssetImageGenerator(asset: asset)
		imageGenerator.appliesPreferredTrackTransform = true
		
		Task {
			do {
				let cgImage = try await imageGenerator.image(at: CMTime.zero).image
				await MainActor.run {
					thumbnail = UIImage(cgImage: cgImage)
				}
			} catch {
				print("Error generating video thumbnail for reply: \(error)")
			}
		}
	}
}


