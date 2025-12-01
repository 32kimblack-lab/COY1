import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Wrapper to handle tab bar visibility
struct ChatScreenWrapper: View {
	let chatId: String
	let otherUserId: String
	@Binding var isChatScreenVisible: Bool
	
	var body: some View {
		ChatScreen(chatId: chatId, otherUserId: otherUserId)
			.toolbar(.hidden, for: .tabBar)
			.onAppear {
				isChatScreenVisible = true
			}
			.onDisappear {
				isChatScreenVisible = false
			}
	}
}

// Chat navigation info for programmatic navigation
struct ChatNavigationInfo: Hashable {
	let chatId: String
	let otherUserId: String
}

struct MessageListScreen: View {
	private let chatService = ChatService.shared
	private let friendService = FriendService.shared
	@StateObject private var cyServiceManager = CYServiceManager.shared // Observe ServiceManager for real-time updates
	@State private var chatRooms: [ChatRoomModel] = []
	@State private var isLoading = true
	@State private var searchText = ""
	@State private var outgoingRequestListener: ListenerRegistration?
	@State private var chatRoomsListener: ListenerRegistration? // Real-time chat rooms listener
	@State private var unseenFriendRequestCount = 0
	@State private var friendRequestListener: ListenerRegistration?
	@State private var userDocumentListener: ListenerRegistration? // Real-time user document listener
	@State private var hasLoadedDataOnce = false // Track if data has been loaded once
	@State private var hasSetupListeners = false // Track if listeners have been set up
	@State private var isLoadingChatRooms = false // Prevent concurrent loadChatRooms calls
	@State private var isLoadingFriends = false // Prevent concurrent loadFriendsListAsync calls
	@State private var friendsSet: Set<String> = [] // Cache of friends list for filtering
	@State private var blockedUsersSet: Set<String> = [] // Cache of blocked users for filtering
	@State private var blockedByUsersSet: Set<String> = [] // Cache of users who blocked me
	@State private var selectedChat: ChatNavigationInfo?
	
	// Calculate total unread count across all chat rooms
	var totalUnreadCount: Int {
		guard let currentUid = Auth.auth().currentUser?.uid else { return 0 }
		return chatRooms.reduce(0) { total, chat in
			total + (chat.unreadCount[currentUid] ?? 0)
		}
	}
	
	// Consistent sizing system (scaled for iPad)
	private var isIPad: Bool {
		UIDevice.current.userInterfaceIdiom == .pad
	}
	private var scaleFactor: CGFloat {
		isIPad ? 1.6 : 1.0
	}
	
	var filteredChatRooms: [ChatRoomModel] {
		if searchText.isEmpty {
			return chatRooms
		}
		// Filter by other user's username (would need to fetch user data)
		return chatRooms
	}
	
	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				Group {
					VStack(spacing: 0) {
						// Top anchor for scroll-to-top
						Color.clear
							.frame(height: 0)
							.id("topAnchor")
						
						// Header
						HStack {
					Text("Messages")
						.font(.system(size: 22, weight: .bold))
				Spacer()
				NavigationLink(destination: AddFriendsScreen()) {
					ZStack(alignment: .topTrailing) {
						Image(systemName: "person.badge.plus")
							.font(.system(size: 20))
							.foregroundColor(.blue)
						
						if unseenFriendRequestCount > 0 {
							Text("\(unseenFriendRequestCount)")
								.font(.caption2)
								.fontWeight(.bold)
								.foregroundColor(.white)
								.padding(4)
								.background(Color.blue)
								.clipShape(Circle())
								.offset(x: 8, y: -8)
						}
					}
				}
				}
				.padding(.horizontal)
				.padding(.top, 10)
				.padding(.bottom, 16)
				
				// Search Bar
				HStack {
					Image(systemName: "magnifyingglass")
						.foregroundColor(.gray)
						.font(.system(size: 16))
					TextField("Search friends...", text: $searchText)
						.textFieldStyle(PlainTextFieldStyle())
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.background(Color(.systemGray5))
				.cornerRadius(12)
				.padding(.horizontal)
				.padding(.bottom, 12)
				
				// Chat List
				if isLoading {
					Spacer()
					ProgressView()
					Spacer()
				} else if filteredChatRooms.isEmpty {
					Spacer()
					VStack(spacing: 20) {
						Image(systemName: "message.fill")
							.font(.system(size: 60))
							.foregroundColor(.gray)
						Text("No messages yet")
							.font(.title2)
							.fontWeight(.medium)
						Text("Start a conversation with friends.")
							.font(.body)
							.foregroundColor(.secondary)
							.multilineTextAlignment(.center)
							.padding(.horizontal)
					}
					Spacer()
				} else {
					// Filter: Show ALL friends in message list, regardless of:
					// - Whether they have messages or not
					// - Whether they unadded each other (as long as they were friends at some point)
					// - But exclude blocked users
					let currentUid = Auth.auth().currentUser?.uid
					
					// Filter chats to show - prioritize friends and chats with messages
					// IMPORTANT: Exclude all blocked users completely (mutual invisibility)
					let chatsToShow = filteredChatRooms.filter { chat in
						guard let currentUid = currentUid else { return false }
						
						// Get the other participant
						guard let otherUid = chat.participants.first(where: { $0 != currentUid }) else {
							return false
						}
						
						// EXCLUDE BLOCKED USERS - Mutual invisibility
						// If I blocked them OR they blocked me, don't show in message list
						if blockedUsersSet.contains(otherUid) || blockedByUsersSet.contains(otherUid) {
							return false
						}
						
						// Get chat status for current user
						let myStatus = chat.chatStatus[currentUid] ?? ""
						
						// Exclude blocked chats - if status is "blocked", hide completely
						if myStatus == "blocked" {
							return false
						}
						
						// Show if:
						// 1. Chat has messages (always show)
						if !chat.lastMessage.isEmpty {
							return true
						}
						
						// 2. Users are currently friends (show even without messages)
						if myStatus == "friends" {
							return true
						}
						
						// 3. Check if they are actually friends (even if status isn't set correctly)
						// This is the key check - if friendsSet is loaded and contains the user, show them
						// IMPORTANT: Always check friendsSet, even if empty (will be populated async)
						if friendsSet.contains(otherUid) {
							return true
						}
						
						// 4. Users were previously friends but unadded each other
						// Show all unadd statuses (iUnadded, theyUnadded, bothUnadded, pendingAdd)
						// This ensures friends who unadded each other still appear in message list
						if myStatus == "iUnadded" || myStatus == "theyUnadded" || 
						   myStatus == "bothUnadded" || myStatus == "pendingAdd" {
							return true
						}
						
						// 5. If status is empty or "pending", show it temporarily
						// (will be updated by ChatService when friends list loads)
						// This ensures chats show up even if friendsSet hasn't loaded yet
						// CRITICAL: Show chats with empty/pending status to catch friends
						if myStatus.isEmpty || myStatus == "pending" {
							return true
						}
						
						return false
					}
					
					if chatsToShow.isEmpty {
						// All chats are cleared or no chats exist, show empty state
						Spacer()
						VStack(spacing: 20) {
							Image(systemName: "message.fill")
								.font(.system(size: 60))
								.foregroundColor(.gray)
							Text("No messages yet")
								.font(.title2)
								.fontWeight(.medium)
							Text("Start a conversation with friends.")
								.font(.body)
								.foregroundColor(.secondary)
								.multilineTextAlignment(.center)
								.padding(.horizontal)
						}
						Spacer()
					} else {
						// Show all friends and previous friends
						List {
							ForEach(chatsToShow) { chat in
								ChatRowViewModern(chat: chat, onTap: {
									guard let currentUid = Auth.auth().currentUser?.uid else { return }
									let otherUid = chat.participants.first { $0 != currentUid } ?? chat.participants[0]
									selectedChat = ChatNavigationInfo(chatId: chat.chatId, otherUserId: otherUid)
								})
							}
						}
						.listStyle(PlainListStyle())
						.scrollContentBackground(.hidden)
					}
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToTopMessages"))) { _ in
					withAnimation {
						proxy.scrollTo("topAnchor", anchor: .top)
					}
				}
			}
		}
		.navigationBarHidden(true)
		.navigationDestination(item: $selectedChat) { chatInfo in
			ChatScreenWrapper(chatId: chatInfo.chatId, otherUserId: chatInfo.otherUserId, isChatScreenVisible: .constant(false))
		}
		.onAppear {
				// Start ServiceManager listener for real-time user updates
				Task {
					try? await CYServiceManager.shared.loadCurrentUser()
				}
				
				// Only load on first appear - preserve state when switching tabs
				// Real-time listeners will keep data fresh
				if !hasLoadedDataOnce {
						// Load friends first to ensure friendsSet is populated
						Task {
							await loadFriendsListAsync()
							
							// Load chat rooms after friends are loaded
							// This ensures we can check which friends are missing chat rooms
							await MainActor.run {
								loadChatRooms()
								hasLoadedDataOnce = true
							}
						}
					}
				
				// Only set up listeners once to prevent infinite loops
				if !hasSetupListeners {
					setupOutgoingRequestListener()
					setupChatRoomsListener()
					setupFriendRequestListener()
					setupUserDocumentListener()
					hasSetupListeners = true
				}
			}
			.refreshable {
				// Complete refresh: Clear all caches and force fresh reload
				await completeRefresh()
			}
			.onDisappear {
			// CRITICAL: Clean up all Firestore listeners when view disappears
			// This prevents memory leaks and battery drain
			outgoingRequestListener?.remove()
			outgoingRequestListener = nil
			chatRoomsListener?.remove()
			chatRoomsListener = nil
			friendRequestListener?.remove()
			friendRequestListener = nil
			userDocumentListener?.remove()
			userDocumentListener = nil
			FirestoreListenerManager.shared.removeAllListeners(for: "MessageListScreen")
			#if DEBUG
			let remainingCount = FirestoreListenerManager.shared.getActiveListenerCount()
			print("✅ MessageListScreen: Cleaned up listeners (remaining: \(remainingCount))")
			#endif
			}
			.onChange(of: totalUnreadCount) { oldValue, newValue in
				// Notify MainTabView of unread count change
				NotificationCenter.default.post(
					name: NSNotification.Name("TotalUnreadCountChanged"),
					object: nil,
					userInfo: ["count": newValue]
				)
			}
			// Removed onDisappear cleanup to preserve state when switching tabs
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestAccepted"))) { notification in
				// Reload friends list when friend request is accepted
				loadFriendsList()
				// When friend request is accepted, ensure chat room exists and has "friends" status
				if let acceptedUid = notification.object as? String,
				   let currentUid = Auth.auth().currentUser?.uid {
					// Reload friends list first to update friendsSet
					loadFriendsList()
					
					Task {
						// Create or get chat room for the new friend
						do {
							let chatRoom = try await chatService.getOrCreateChatRoom(participants: [currentUid, acceptedUid])
							
							// Update chat room status to "friends" if it's not already set
							let db = Firestore.firestore()
							let chatId = chatRoom.chatId
							let chatRef = db.collection("chat_rooms").document(chatId)
							
							// Update status to "friends" for both participants
							try await chatRef.updateData([
								"chatStatus.\(currentUid)": "friends",
								"chatStatus.\(acceptedUid)": "friends"
							])
							
							// Update local chat room status immediately
							await MainActor.run {
								// Update the chat room in our local array
								if let index = self.chatRooms.firstIndex(where: { $0.chatId == chatId }) {
									var updatedChat = self.chatRooms[index]
									var updatedStatus = updatedChat.chatStatus
									updatedStatus[currentUid] = "friends"
									updatedStatus[acceptedUid] = "friends"
									updatedChat.chatStatus = updatedStatus
									self.chatRooms[index] = updatedChat
									// Re-sort by last message timestamp
									self.chatRooms.sort { (room1: ChatRoomModel, room2: ChatRoomModel) -> Bool in
										(room1.lastMessageTs) > (room2.lastMessageTs)
									}
									print("✅ MessageListScreen: Updated local chat room \(chatId) with friends status")
								} else {
									// Chat room doesn't exist locally, add it
									var updatedChat = chatRoom
									var updatedStatus = updatedChat.chatStatus
									updatedStatus[currentUid] = "friends"
									updatedStatus[acceptedUid] = "friends"
									updatedChat.chatStatus = updatedStatus
									self.chatRooms.append(updatedChat)
									// Sort by last message timestamp
									self.chatRooms.sort { (room1: ChatRoomModel, room2: ChatRoomModel) -> Bool in
										(room1.lastMessageTs) > (room2.lastMessageTs)
									}
									print("✅ MessageListScreen: Added new chat room \(chatId) with friends status")
								}
							}
							
							// Reload chat rooms to ensure everything is up to date
							loadChatRooms()
							
							print("✅ MessageListScreen: Created/updated chat room for friend \(acceptedUid) with friends status")
						} catch {
							print("❌ MessageListScreen: Error creating/updating chat room for friend \(acceptedUid): \(error)")
							// Fallback: reload chat rooms and friends list
							loadFriendsList()
							loadChatRooms()
						}
					}
				} else {
					// Fallback: just reload chat rooms and friends list
					loadFriendsList()
					loadChatRooms()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserBlocked"))) { _ in
				// Reload blocked users and chat rooms when a user is blocked (chat should disappear)
				loadFriendsList() // This also reloads blocked users
				loadChatRooms()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserUnblocked"))) { _ in
				// Reload blocked users and chat rooms when a user is unblocked (chat may reappear)
				loadFriendsList() // This also reloads blocked users
				loadChatRooms()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
				// Immediately reload chat rooms when profile is updated to show new username/name/images
				print("🔄 MessageListScreen: Profile updated, reloading chat rooms to show new user info")
				loadChatRooms()
			}
			.onChange(of: cyServiceManager.currentUser) { oldValue, newValue in
				// Real-time update when current user's profile changes via ServiceManager
				// Only reload if profile-relevant fields actually changed (prevent infinite loops)
				guard let newValue = newValue else { return }
				
				let profileChanged = oldValue?.profileImageURL != newValue.profileImageURL ||
				oldValue?.backgroundImageURL != newValue.backgroundImageURL ||
				oldValue?.name != newValue.name ||
				oldValue?.username != newValue.username
				
				if profileChanged {
					loadChatRooms()
				}
			}
		}
	}
	
	private func loadFriendsList() {
		Task {
			await loadFriendsListAsync()
		}
	}
	
	// MARK: - Complete Refresh (Pull-to-Refresh)
	/// Complete refresh: Clear all caches, reload user data, reload everything from scratch
	/// Equivalent to exiting and re-entering the app
	private func completeRefresh() async {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		
		print("🔄 MessageListScreen: Starting COMPLETE refresh (equivalent to app restart)")
		
		// Step 1: Clear ALL caches first (including user profile caches)
		await MainActor.run {
			HomeViewCache.shared.clearCache()
			CollectionPostsCache.shared.clearAllCache()
			// Clear user profile caches to force fresh profile image/name loads
			UserService.shared.clearUserCache(userId: currentUid)
			print("✅ MessageListScreen: Cleared all caches (including user profile caches)")
		}
		
		// Step 2: Reload current user data - FORCE FRESH
		do {
			// Stop existing listener and reload fresh
			CYServiceManager.shared.stopListening()
			try await CYServiceManager.shared.loadCurrentUser()
			print("✅ MessageListScreen: Reloaded current user data (fresh from Firestore)")
		} catch {
			print("⚠️ MessageListScreen: Error reloading current user: \(error)")
		}
		
		// Step 3: Reload friends list and chat rooms - FORCE FRESH
		await loadFriendsListAsync()
		await MainActor.run {
			loadChatRooms()
		}
	}
	
	private func loadFriendsListAsync() async {
		// Prevent concurrent calls
		guard !isLoadingFriends else { return }
		
		guard let currentUid = Auth.auth().currentUser?.uid else {
			return
		}
		
		await MainActor.run {
			isLoadingFriends = true
		}
		
		defer {
			Task { @MainActor in
				isLoadingFriends = false
			}
		}
		
		do {
			let db = Firestore.firestore()
			let userDoc = try await db.collection("users").document(currentUid).getDocument()
		
			guard userDoc.exists else {
				return
			}
		
			let friends = (userDoc.data()?["friends"] as? [String]) ?? []
			
			// Load blocked users
			let blockedUsers = (userDoc.data()?["blockedUsers"] as? [String]) ?? []
			let blockedByUsers = (userDoc.data()?["blockedByUsers"] as? [String]) ?? []
			
			await MainActor.run {
				self.friendsSet = Set(friends)
				self.blockedUsersSet = Set(blockedUsers)
				self.blockedByUsersSet = Set(blockedByUsers)
			}
			
			// Only ensure chat rooms for friends if we're on first load
			// Otherwise, loadChatRooms() will handle it
			if !hasLoadedDataOnce {
				// Ensure chat rooms exist for all friends
				// This ensures friends appear in message list even if they don't have messages yet
				await ensureChatRoomsForFriends(friendIds: friends)
			}
		} catch {
			print("❌ MessageListScreen: Error loading friends list: \(error)")
		}
	}
	
	private func ensureChatRoomsForFriends(friendIds: [String]) async {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		
		print("📱 MessageListScreen: Ensuring chat rooms exist for \(friendIds.count) friends")
		
		// Ensure chat rooms exist for all friends
		// This is important so friends show up in message list even without messages
		for friendId in friendIds {
			do {
				// This will create chat room if it doesn't exist, or return existing one
				let chatRoom = try await chatService.getOrCreateChatRoom(participants: [currentUid, friendId])
				print("✅ MessageListScreen: Ensured chat room exists for friend \(friendId): \(chatRoom.chatId)")
			} catch {
				print("⚠️ MessageListScreen: Error ensuring chat room for friend \(friendId): \(error)")
			}
		}
		
		print("✅ MessageListScreen: Finished ensuring chat rooms for all friends")
	}
	
	private func loadChatRooms() {
		// Prevent concurrent calls to avoid infinite loops
		guard !isLoadingChatRooms else {
			print("⚠️ MessageListScreen: loadChatRooms() already in progress, skipping...")
			return
		}
		
		Task {
			await MainActor.run {
				isLoadingChatRooms = true
			}
			
			defer {
				Task { @MainActor in
					isLoadingChatRooms = false
				}
			}
			
			print("📱 MessageListScreen: loadChatRooms() called")
			print("📱 MessageListScreen: Current friendsSet has \(friendsSet.count) friends: \(Array(friendsSet))")
			
			do {
				// OPTIMIZATION: Use limit parameter (defaults to 50)
				var rooms = try await chatService.getUserChatRooms(limit: 50)
				print("📱 MessageListScreen: Loaded \(rooms.count) chat rooms from getUserChatRooms")
				
				// CRITICAL FIX: Ensure all friends have chat rooms in the list
				// If a friend doesn't have a chat room yet, create it and add to list
				guard let currentUid = Auth.auth().currentUser?.uid else {
					print("❌ MessageListScreen: No current user ID in loadChatRooms")
					await MainActor.run {
						self.chatRooms = rooms
						self.isLoading = false
					}
					return
				}
				
				// Get list of friend IDs that already have chat rooms
				let existingFriendIds = Set(rooms.compactMap { room in
					room.participants.first { $0 != currentUid }
				})
				print("📱 MessageListScreen: Found \(existingFriendIds.count) friends with existing chat rooms: \(Array(existingFriendIds))")
				
				// Check which friends are missing from chat rooms
				let missingFriends = friendsSet.subtracting(existingFriendIds)
				print("📱 MessageListScreen: Found \(missingFriends.count) friends missing chat rooms: \(Array(missingFriends))")
				
				// Create chat rooms for missing friends
				for friendId in missingFriends {
					do {
						let chatRoom = try await chatService.getOrCreateChatRoom(participants: [currentUid, friendId])
						rooms.append(chatRoom)
						print("✅ MessageListScreen: Created and added chat room for friend \(friendId)")
					} catch {
						print("⚠️ MessageListScreen: Error creating chat room for friend \(friendId): \(error)")
					}
				}
				
				// Sort by last message timestamp (most recent first)
				rooms.sort { $0.lastMessageTs > $1.lastMessageTs }
				
				print("📱 MessageListScreen: Final chat rooms count: \(rooms.count)")
				
				await MainActor.run {
					self.chatRooms = rooms
					self.isLoading = false
					
					// Calculate and notify total unread count
					let totalUnread = rooms.reduce(0) { total, chat in
						total + (chat.unreadCount[currentUid] ?? 0)
					}
					NotificationCenter.default.post(
						name: NSNotification.Name("TotalUnreadCountChanged"),
						object: nil,
						userInfo: ["count": totalUnread]
					)
				}
			} catch {
				print("❌ MessageListScreen: Error loading chat rooms: \(error)")
				
				// If index error, try fallback approach: load all friends and create chat rooms
				if error.localizedDescription.contains("index") {
					print("⚠️ MessageListScreen: Index missing, trying fallback approach")
					await loadChatRoomsFallback()
				} else {
					await MainActor.run {
						self.isLoading = false
					}
				}
			}
		}
	}
	
	// MARK: - Fallback Chat Rooms Loader (no index required)
	private func loadChatRoomsFallback() async {
		guard let currentUid = Auth.auth().currentUser?.uid else {
			await MainActor.run {
				self.isLoading = false
			}
			return
		}
		
		let db = Firestore.firestore()
		
		do {
			// Get all chat rooms with current user as participant (no ordering)
			let snapshot = try await db.collection("chat_rooms")
				.whereField("participants", arrayContains: currentUid)
				.getDocuments()
			
			var allChatRooms = snapshot.documents.compactMap { ChatRoomModel(document: $0) }
			
			// CRITICAL FIX: Ensure all friends have chat rooms in the list
			// Get list of friend IDs that already have chat rooms
			let existingFriendIds = Set(allChatRooms.compactMap { room in
				room.participants.first { $0 != currentUid }
			})
			
			// Check which friends are missing from chat rooms
			let missingFriends = friendsSet.subtracting(existingFriendIds)
			
			// Create chat rooms for missing friends
			for friendId in missingFriends {
				do {
					let chatRoom = try await chatService.getOrCreateChatRoom(participants: [currentUid, friendId])
					allChatRooms.append(chatRoom)
					print("✅ MessageListScreen: Created and added chat room for friend \(friendId) (fallback)")
				} catch {
					print("⚠️ MessageListScreen: Error creating chat room for friend \(friendId) (fallback): \(error)")
				}
			}
			
			// Sort client-side by lastMessageTs
			let sortedRooms = allChatRooms.sorted { $0.lastMessageTs > $1.lastMessageTs }
			
			await MainActor.run {
				self.chatRooms = sortedRooms
				self.isLoading = false
				
				// Calculate and notify total unread count
				let totalUnread = sortedRooms.reduce(0) { total, chat in
					total + (chat.unreadCount[currentUid] ?? 0)
				}
				NotificationCenter.default.post(
					name: NSNotification.Name("TotalUnreadCountChanged"),
					object: nil,
					userInfo: ["count": totalUnread]
				)
			}
		} catch {
			print("Error loading chat rooms (fallback): \(error)")
			await MainActor.run {
				self.isLoading = false
			}
		}
	}
	
	private func setupOutgoingRequestListener() {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		
		let db = Firestore.firestore()
		// Listen for all outgoing friend requests to detect when they get accepted
		outgoingRequestListener = db.collection("friend_requests")
			.whereField("fromUid", isEqualTo: currentUid)
			.addSnapshotListener { snapshot, error in
				guard error == nil, let snapshot = snapshot else {
					print("Error listening to outgoing requests: \(error?.localizedDescription ?? "unknown")")
					return
				}
				
				// Check if any request changed to "accepted" status
				for documentChange in snapshot.documentChanges {
					if documentChange.type == .modified || documentChange.type == .added {
						let data = documentChange.document.data()
						if let status = data["status"] as? String,
						   status == "accepted" {
							// A friend request was accepted, refresh chat rooms
							self.loadChatRooms()
							break
						}
					}
				}
			}
	}
	
	// MARK: - Real-time Chat Rooms Listener
	// MARK: - Friend Request Listener
	
	private func setupFriendRequestListener() {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		let db = Firestore.firestore()
		
		// Remove existing listener
		friendRequestListener?.remove()
		
		// Listen to unseen friend requests
		friendRequestListener = db.collection("friend_requests")
			.whereField("toUid", isEqualTo: currentUid)
			.whereField("status", isEqualTo: "pending")
			.whereField("seen", isEqualTo: false)
			.addSnapshotListener { snapshot, error in
				if let error = error {
					print("❌ MessageListScreen: Friend request listener error: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot else { return }
				
				// Count unseen friend requests
				let count = snapshot.documents.count
				Task { @MainActor in
					self.unseenFriendRequestCount = count
					// Notify MainTabView of friend request count change
					NotificationCenter.default.post(
						name: NSNotification.Name("FriendRequestCountChanged"),
						object: nil,
						userInfo: ["count": count]
					)
				}
			}
	}
	
	// MARK: - Real-time User Document Listener
	private func setupUserDocumentListener() {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		let db = Firestore.firestore()
		
		// Remove existing listener
		userDocumentListener?.remove()
		
		// Listen to current user's document for real-time updates to blockedUsers and blockedByUsers
		userDocumentListener = db.collection("users").document(currentUid)
			.addSnapshotListener { [self] snapshot, error in
				if let error = error {
					print("❌ MessageListScreen: User document listener error: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot, snapshot.exists,
					  let data = snapshot.data() else {
					return
				}
				
				// Update blocked users sets in real-time
				let blockedUsers = (data["blockedUsers"] as? [String]) ?? []
				let blockedByUsers = (data["blockedByUsers"] as? [String]) ?? []
				
				Task { @MainActor in
					let oldBlockedCount = self.blockedUsersSet.count
					let oldBlockedByCount = self.blockedByUsersSet.count
					
					self.blockedUsersSet = Set(blockedUsers)
					self.blockedByUsersSet = Set(blockedByUsers)
					print("✅ MessageListScreen: Updated blocked users in real-time - blocked: \(blockedUsers.count), blockedBy: \(blockedByUsers.count)")
					
					// Only reload chat rooms if blocked users actually changed (to prevent loops)
					if oldBlockedCount != blockedUsers.count || oldBlockedByCount != blockedByUsers.count {
						loadChatRooms()
					}
				}
			}
	}
	
	private func setupChatRoomsListener() {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		let db = Firestore.firestore()
		
		// Remove existing listener
		chatRoomsListener?.remove()
		
		// OPTIMIZATION: Limit listener to 50 most recent chats to reduce reads
		// Order by lastMessageTs to get most active chats first
		// Note: This query requires a composite index. If it fails, we'll use a fallback query.
		chatRoomsListener = db.collection("chat_rooms")
			.whereField("participants", arrayContains: currentUid)
			.order(by: "lastMessageTs", descending: true)
			.limit(to: 50)
			.addSnapshotListener { snapshot, error in
				if let error = error {
					print("❌ MessageListScreen: Chat rooms listener error: \(error.localizedDescription)")
					
					// If index is missing, use fallback query without ordering
					// This will still work but won't be sorted by lastMessageTs
					if error.localizedDescription.contains("index") {
						print("⚠️ MessageListScreen: Index missing, using fallback query (unsorted)")
						self.setupChatRoomsListenerFallback()
						return
					}
					return
				}
				
				guard let snapshot = snapshot else { return }
				
				// Handle document changes
				for change in snapshot.documentChanges {
					let doc = change.document
					
					if change.type == .removed {
						// Chat room was deleted
						let deletedChatId = doc.documentID
						Task { @MainActor in
							self.chatRooms.removeAll { $0.chatId == deletedChatId }
							print("🗑️ MessageListScreen: Removed deleted chat room \(deletedChatId)")
							
							// Recalculate and notify total unread count
							let uid = Auth.auth().currentUser?.uid
							let totalUnread = self.chatRooms.reduce(0) { total, chat in
								total + (chat.unreadCount[uid ?? ""] ?? 0)
							}
							NotificationCenter.default.post(
								name: NSNotification.Name("TotalUnreadCountChanged"),
								object: nil,
								userInfo: ["count": totalUnread]
							)
						}
					} else if change.type == .added || change.type == .modified {
						// New or updated chat room
						guard let chatRoom = ChatRoomModel(document: doc) else {
							print("❌ MessageListScreen: Failed to parse chat room from document")
							return
						}
						
						let chatRoomId = chatRoom.chatId
						Task { @MainActor in
							if change.type == .added {
								// New chat room - add if not already present
								if !self.chatRooms.contains(where: { $0.chatId == chatRoomId }) {
									self.chatRooms.append(chatRoom)
									// Sort by last message timestamp
									self.chatRooms.sort { (room1: ChatRoomModel, room2: ChatRoomModel) -> Bool in
										(room1.lastMessageTs) > (room2.lastMessageTs)
									}
									print("✅ MessageListScreen: Added new chat room \(chatRoomId)")
								}
							} else if change.type == .modified {
								// Updated chat room - replace existing
								if let index = self.chatRooms.firstIndex(where: { $0.chatId == chatRoomId }) {
									self.chatRooms[index] = chatRoom
									// Re-sort by last message timestamp
									self.chatRooms.sort { (room1: ChatRoomModel, room2: ChatRoomModel) -> Bool in
										(room1.lastMessageTs) > (room2.lastMessageTs)
									}
									print("🔄 MessageListScreen: Updated chat room \(chatRoomId)")
								}
							}
							
							// Calculate and notify total unread count after any change
							let uid = Auth.auth().currentUser?.uid
							let totalUnread = self.chatRooms.reduce(0) { total, chat in
								total + (chat.unreadCount[uid ?? ""] ?? 0)
							}
							NotificationCenter.default.post(
								name: NSNotification.Name("TotalUnreadCountChanged"),
								object: nil,
								userInfo: ["count": totalUnread]
							)
						}
					}
				}
			}
		}
	
	// MARK: - Fallback Chat Rooms Listener (no index required)
	private func setupChatRoomsListenerFallback() {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		let db = Firestore.firestore()
		
		// Remove existing listener
		chatRoomsListener?.remove()
		
		// Fallback query: Get all chat rooms with current user as participant (no ordering)
		// We'll sort client-side instead
		chatRoomsListener = db.collection("chat_rooms")
			.whereField("participants", arrayContains: currentUid)
			.addSnapshotListener { snapshot, error in
				if let error = error {
					print("❌ MessageListScreen: Fallback chat rooms listener error: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot else { return }
				
				// Handle document changes
				for change in snapshot.documentChanges {
					let doc = change.document
					
					if change.type == .removed {
						// Chat room was deleted
						let deletedChatId = doc.documentID
						Task { @MainActor in
							self.chatRooms.removeAll { $0.chatId == deletedChatId }
							print("🗑️ MessageListScreen: Removed deleted chat room \(deletedChatId)")
							
							// Recalculate and notify total unread count
							let uid = Auth.auth().currentUser?.uid
							let totalUnread = self.chatRooms.reduce(0) { total, chat in
								total + (chat.unreadCount[uid ?? ""] ?? 0)
							}
							NotificationCenter.default.post(
								name: NSNotification.Name("TotalUnreadCountChanged"),
								object: nil,
								userInfo: ["count": totalUnread]
							)
						}
					} else if change.type == .added || change.type == .modified {
						// New or updated chat room
						guard let chatRoom = ChatRoomModel(document: doc) else {
							print("❌ MessageListScreen: Failed to parse chat room from document")
							return
						}
						
						let chatRoomId = chatRoom.chatId
						Task { @MainActor in
							if change.type == .added {
								// New chat room - add if not already present
								if !self.chatRooms.contains(where: { $0.chatId == chatRoomId }) {
									self.chatRooms.append(chatRoom)
									// Sort by last message timestamp (client-side)
									self.chatRooms.sort { (room1: ChatRoomModel, room2: ChatRoomModel) -> Bool in
										(room1.lastMessageTs) > (room2.lastMessageTs)
									}
									print("✅ MessageListScreen: Added new chat room \(chatRoomId)")
								}
							} else if change.type == .modified {
								// Updated chat room - replace existing
								if let index = self.chatRooms.firstIndex(where: { $0.chatId == chatRoomId }) {
									self.chatRooms[index] = chatRoom
									// Re-sort by last message timestamp (client-side)
									self.chatRooms.sort { (room1: ChatRoomModel, room2: ChatRoomModel) -> Bool in
										(room1.lastMessageTs) > (room2.lastMessageTs)
									}
									print("🔄 MessageListScreen: Updated chat room \(chatRoomId)")
								}
							}
							
							// Calculate and notify total unread count after any change
							let uid = Auth.auth().currentUser?.uid
							let totalUnread = self.chatRooms.reduce(0) { total, chat in
								total + (chat.unreadCount[uid ?? ""] ?? 0)
							}
							NotificationCenter.default.post(
								name: NSNotification.Name("TotalUnreadCountChanged"),
								object: nil,
								userInfo: ["count": totalUnread]
							)
						}
					}
				}
			}
	}
}

// MARK: - Modern Chat Row View
struct ChatRowViewModern: View {
	let chat: ChatRoomModel
	let onTap: () -> Void
	@State private var otherUser: UserService.AppUser?
	@StateObject private var cyServiceManager = CYServiceManager.shared // Observe ServiceManager for real-time updates
	@State private var otherUserListener: ListenerRegistration? // Real-time listener for other user's profile
	@Environment(\.colorScheme) var colorScheme
	
	// Consistent sizing system (scaled for iPad)
	private var isIPad: Bool {
		UIDevice.current.userInterfaceIdiom == .pad
	}
	private var scaleFactor: CGFloat {
		isIPad ? 1.6 : 1.0
	}
	
	var currentUid: String? {
		Auth.auth().currentUser?.uid
	}
	
	var otherUid: String {
		chat.participants.first { $0 != currentUid } ?? chat.participants[0]
	}
	
	private var hasUnread: Bool {
		guard let currentUid = currentUid else { return false }
		return (chat.unreadCount[currentUid] ?? 0) > 0
	}
	
	private var unreadCount: Int {
		guard let currentUid = currentUid else { return 0 }
		return chat.unreadCount[currentUid] ?? 0
	}
	
	var body: some View {
		Button(action: onTap) {
			HStack(spacing: 16 * scaleFactor) {
				// Profile Image
				ZStack(alignment: .bottomTrailing) {
					if let otherUser = otherUser, let profileURL = otherUser.profileImageURL, !profileURL.isEmpty {
						CachedProfileImageView(url: profileURL, size: 60 * scaleFactor)
							.clipShape(Circle())
				} else {
						DefaultProfileImageView(size: 60 * scaleFactor)
					}
				}
				
				// Message Content Section
				VStack(alignment: .leading, spacing: 6 * scaleFactor) {
					// Username and Timestamp Row
					HStack(alignment: .center, spacing: 8 * scaleFactor) {
						Text(otherUser?.username ?? "Unknown")
							.font(.system(size: 17 * scaleFactor, weight: hasUnread ? .semibold : .regular))
							.foregroundColor(colorScheme == .dark ? .white : .black)
							.lineLimit(1)
						
						Spacer()
						
						Text(messageListTimeString(from: chat.lastMessageTs))
							.font(.system(size: 14 * scaleFactor, weight: hasUnread ? .medium : .regular))
							.foregroundColor(hasUnread ? (colorScheme == .dark ? .white : .black) : .gray)
					}
					
					// Message Preview Row
					HStack(alignment: .top, spacing: 6 * scaleFactor) {
						// Message type icon for media messages
						if chat.lastMessageType != "text" {
							Image(systemName: getMessageTypeIcon(chat.lastMessageType))
							.font(.system(size: 14 * scaleFactor))
								.foregroundColor(hasUnread ? .blue : .gray)
								.frame(width: 16 * scaleFactor)
						}
						
						Text(getMessagePreviewText(chat.lastMessage))
							.font(.system(size: 15 * scaleFactor, weight: hasUnread ? .medium : .regular))
							.foregroundColor(hasUnread ? (colorScheme == .dark ? .white.opacity(0.9) : .black.opacity(0.8)) : .gray)
							.lineLimit(2)
							.multilineTextAlignment(.leading)
						
						Spacer()
						
						// Unread Badge
						if hasUnread && unreadCount > 0 {
							unreadBadge
						}
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 16 * scaleFactor)
			.padding(.vertical, 12 * scaleFactor)
			.background(
				hasUnread ? 
				(colorScheme == .dark ? Color.white.opacity(0.05) : Color.blue.opacity(0.03)) :
				Color.clear
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.listRowInsets(EdgeInsets())
		.listRowSeparator(.hidden)
		.listRowBackground(Color.clear)
		.onAppear {
			loadOtherUser()
			setupOtherUserListener() // Set up real-time listener for other user's profile
		}
		.onChange(of: cyServiceManager.currentUser) { oldValue, newValue in
			// Real-time update when user profile changes via ServiceManager
			// Reload other user info to show updated username/profile image
			loadOtherUser()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
			// Reload other user info when profile is updated
			if let userId = notification.userInfo?["userId"] as? String,
			   userId == otherUid {
				loadOtherUser()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("ChatRowOtherUserProfileUpdated"))) { notification in
			// Update other user info when real-time listener detects changes
			if let chatId = notification.object as? String,
			   chatId == chat.id,
			   let otherUserId = notification.userInfo?["otherUserId"] as? String,
			   otherUserId == otherUid {
				if var updatedUser = otherUser {
					if let newProfileImageURL = notification.userInfo?["profileImageURL"] as? String {
						updatedUser.profileImageURL = newProfileImageURL
					}
					if let newName = notification.userInfo?["name"] as? String {
						updatedUser.name = newName
					}
					if let newUsername = notification.userInfo?["username"] as? String {
						updatedUser.username = newUsername
					}
					otherUser = updatedUser
					print("✅ ChatRowViewModern: Updated other user profile from real-time listener")
				} else {
					// If user not loaded yet, load it
					loadOtherUser()
				}
			}
		}
		.onDisappear {
			// Clean up listener when view disappears
			otherUserListener?.remove()
			otherUserListener = nil
		}
	}
	
	// MARK: - Unread Badge
	private var unreadBadge: some View {
		Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
			.font(.system(size: 12 * scaleFactor, weight: .bold))
			.foregroundColor(.white)
			.padding(.horizontal, (unreadCount > 9 ? 7 : 6) * scaleFactor)
			.padding(.vertical, 3 * scaleFactor)
			.background(
				LinearGradient(
					gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				)
			)
			.clipShape(Capsule())
			.frame(minWidth: 20, minHeight: 20)
			.shadow(color: Color.blue.opacity(0.3), radius: 4, x: 0, y: 2)
	}
	
	// MARK: - Real-time Listener for Other User's Profile
	private func setupOtherUserListener() {
		// Remove existing listener if any
		otherUserListener?.remove()
		
		// Set up real-time Firestore listener for the other user's profile
		// This allows seeing real-time updates when the other user edits their profile
		let db = Firestore.firestore()
		let chatId = chat.id
		let otherUserId = otherUid
		otherUserListener = db.collection("users").document(otherUserId).addSnapshotListener { snapshot, error in
			Task { @MainActor in
				if let error = error {
					print("❌ ChatRowViewModern: Error listening to other user profile updates: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot, let data = snapshot.data() else {
					return
				}
				
				// Immediately update other user info from Firestore (real-time)
				// Use NotificationCenter to update the view since we can't capture self in struct
				let newProfileImageURL = data["profileImageURL"] as? String
				let newName = data["name"] as? String ?? ""
				let newUsername = data["username"] as? String ?? ""
				NotificationCenter.default.post(
					name: Notification.Name("ChatRowOtherUserProfileUpdated"),
					object: chatId,
					userInfo: ["otherUserId": otherUserId, "profileImageURL": newProfileImageURL as Any, "name": newName, "username": newUsername]
				)
				print("🔄 ChatRowViewModern: Other user profile updated in real-time from Firestore")
			}
		}
	}
	
	// MARK: - Helper Methods
	private func loadOtherUser() {
		guard let currentUserId = currentUid else { return }
		
		let otherUserId = chat.participants.first { $0 != currentUserId }
		guard let otherUserId = otherUserId else { return }
		
		Task {
			do {
				let user = try await UserService.shared.getUser(userId: otherUserId)
				await MainActor.run {
					self.otherUser = user
				}
			} catch {
				print("Failed to load user: \(error)")
			}
		}
	}
	
	private func getMessagePreviewText(_ message: String) -> String {
		if message.isEmpty {
			return "Added new"
		}
		
		// Show deleted message text if the message is deleted
		if message == "This message was deleted" || message == "This media was deleted" {
			return message
		}
		
		if message.count > 60 {
			return String(message.prefix(57)) + "..."
		}
		
		return message
	}
	
	private func getMessageTypeIcon(_ type: String) -> String {
		switch type {
		case "text":
			return "text.bubble"
		case "image", "photo":
			return "photo.fill"
		case "video":
			return "video.fill"
		default:
			return "text.bubble"
		}
	}
	
	private func messageListTimeString(from date: Date) -> String {
		let calendar = Calendar.current
		let now = Date()
		
		if calendar.isDateInToday(date) {
			let formatter = DateFormatter()
			formatter.dateFormat = "h:mm a"
			return formatter.string(from: date)
		} else if calendar.isDateInYesterday(date) {
			return "Yesterday"
		} else if calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) ?? false {
			let formatter = DateFormatter()
			formatter.dateFormat = "EEEE"
			return formatter.string(from: date)
		} else {
			let formatter = DateFormatter()
			formatter.dateFormat = "M/d/yy"
			return formatter.string(from: date)
		}
	}
}

