import Foundation
import FirebaseFirestore
import FirebaseAuth
import FirebaseFunctions
import Combine

@MainActor
class ChatService {
	static let shared = ChatService()
	private let db = Firestore.firestore()
	
	private init() {}
	
	var currentUid: String? {
		return Auth.auth().currentUser?.uid
	}
	
	// MARK: - Chat Room Management
	
	func getChatRoomId(uid1: String, uid2: String) -> String {
		return [uid1, uid2].sorted().joined(separator: "_")
	}
	
	func getOrCreateChatRoom(participants: [String]) async throws -> ChatRoomModel {
		guard participants.count == 2 else {
			throw ChatServiceError.invalidParticipants
		}
		
		let chatId = getChatRoomId(uid1: participants[0], uid2: participants[1])
		let chatRef = db.collection("chat_rooms").document(chatId)
		
		// Try to get existing chat room
		let snapshot = try await chatRef.getDocument()
		
		if snapshot.exists, var chatRoom = ChatRoomModel(document: snapshot) {
			// Check if users are friends and update status if needed
			let friendService = FriendService.shared
			let otherUserId = participants.first { $0 != (currentUid ?? "") } ?? participants[1]
			let areFriends = await friendService.isFriend(userId: otherUserId)
			
			// If they are friends but status is not "friends", update it
			if areFriends {
				let currentStatus = chatRoom.chatStatus[currentUid ?? ""] ?? ""
				if currentStatus != "friends" {
					// Update status to "friends" for both participants
					var updatedStatus = chatRoom.chatStatus
					updatedStatus[participants[0]] = "friends"
					updatedStatus[participants[1]] = "friends"
					chatRoom.chatStatus = updatedStatus
					
					// Update in Firestore
					try await chatRef.updateData([
						"chatStatus.\(participants[0])": "friends",
						"chatStatus.\(participants[1])": "friends"
					])
				}
			}
			
			return chatRoom
		} else {
			// Create new chat room with current timestamp
			// Check if users are friends to set proper status
			let friendService = FriendService.shared
			let areFriends = await friendService.isFriend(userId: participants.first { $0 != (currentUid ?? "") } ?? participants[1])
			
			let now = Date()
			let status = areFriends ? "friends" : "pending"
			let newChat = ChatRoomModel(
				chatId: chatId,
				participants: participants,
				lastMessageTs: now,
				lastMessage: "",
				lastMessageType: "text",
				unreadCount: [participants[0]: 0, participants[1]: 0],
				chatStatus: [participants[0]: status, participants[1]: status]
			)
			
			try await chatRef.setData(newChat.toFirestoreData())
			return newChat
		}
	}
	
	// MARK: - Get User Chat Rooms
	
	func getUserChatRooms(limit: Int = 50) async throws -> [ChatRoomModel] {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Get all friends first to ensure chat rooms exist for all friends
		// This ensures friends show up in message list immediately, even without messages
		let friendService = FriendService.shared
		let userDoc = try await db.collection("users").document(currentUid).getDocument()
		let friends = (userDoc.data()?["friends"] as? [String]) ?? []
		
		// Ensure chat rooms exist for all friends (even if they don't have messages yet)
		// Use batch operations to reduce individual writes
		let batch = db.batch()
		var batchCount = 0
		
		for friendId in friends {
			// Verify they are still friends (in case friendship was removed during processing)
			let areFriends = await friendService.isFriend(userId: friendId)
			if !areFriends {
				continue
			}
			
			let chatId = getChatRoomId(uid1: currentUid, uid2: friendId)
			let chatRef = db.collection("chat_rooms").document(chatId)
			
			// Check if chat room exists
			let chatDoc = try? await chatRef.getDocument()
			
			if chatDoc?.exists != true {
				// Chat room doesn't exist - create it with "friends" status
				let now = Date()
				let newChat = ChatRoomModel(
					chatId: chatId,
					participants: [currentUid, friendId],
					lastMessageTs: now,
					lastMessage: "",
					lastMessageType: "text",
					unreadCount: [currentUid: 0, friendId: 0],
					chatStatus: [currentUid: "friends", friendId: "friends"]
				)
				batch.setData(newChat.toFirestoreData(), forDocument: chatRef)
				batchCount += 1
			} else {
				// Chat room exists - ensure status is "friends" if missing or invalid
				// But preserve unadd statuses (iUnadded, theyUnadded, bothUnadded, pendingAdd)
				let chatData = chatDoc?.data()
				let currentStatus = chatData?["chatStatus"] as? [String: String] ?? [:]
				let myStatus = currentStatus[currentUid] ?? ""
				
				// Only update if status is missing or "pending" (don't overwrite unadd statuses)
				if myStatus.isEmpty || myStatus == "pending" {
					batch.updateData([
						"chatStatus.\(currentUid)": "friends"
					], forDocument: chatRef)
					batchCount += 1
				}
			}
			
			// Firestore batch limit is 500, commit if needed
			if batchCount >= 500 {
				try? await batch.commit()
				batchCount = 0
			}
		}
		
		// Commit remaining batch operations
		if batchCount > 0 {
			try? await batch.commit()
		}
		
		// Get chat rooms - we need to include ALL friends, not just top 50 by messages
		// So we'll get all chat rooms and then sort/filter appropriately
		var allChatRooms: [ChatRoomModel] = []
		
		do {
			// First, get all chat rooms (we need all friends, not just top 50)
			// For performance, we'll still try to use the ordered query if available
			let snapshot = try await db.collection("chat_rooms")
				.whereField("participants", arrayContains: currentUid)
				.order(by: "lastMessageTs", descending: true)
				.limit(to: 100) // Increased limit to include more chats
				.getDocuments()
			
			allChatRooms = snapshot.documents.compactMap { ChatRoomModel(queryDocument: $0) }
			
			// Also ensure we have chat rooms for all friends (they might not be in top 100)
			let existingChatIds = Set(allChatRooms.map { $0.chatId })
			for friendId in friends {
				let chatId = getChatRoomId(uid1: currentUid, uid2: friendId)
				if !existingChatIds.contains(chatId) {
					// Try to get this specific chat room
					let chatRef = db.collection("chat_rooms").document(chatId)
					if let chatDoc = try? await chatRef.getDocument(),
					   let chatRoom = ChatRoomModel(document: chatDoc) {
						allChatRooms.append(chatRoom)
					}
				}
			}
		} catch {
			// If index is missing, use fallback query without ordering
			if error.localizedDescription.contains("index") {
				print("⚠️ ChatService: Index missing, using fallback query (unsorted)")
				let snapshot = try await db.collection("chat_rooms")
					.whereField("participants", arrayContains: currentUid)
					.getDocuments()
				
				allChatRooms = snapshot.documents.compactMap { ChatRoomModel(queryDocument: $0) }
			} else {
				throw error
			}
		}
		
		// Ensure we have chat rooms for ALL friends (even if they're not in top results)
		// Get chat rooms for friends that might be missing from the query results
		let existingChatIds = Set(allChatRooms.map { $0.chatId })
		for friendId in friends {
			let chatId = getChatRoomId(uid1: currentUid, uid2: friendId)
			if !existingChatIds.contains(chatId) {
				// Try to get this specific chat room (it should exist from batch creation above)
				let chatRef = db.collection("chat_rooms").document(chatId)
				if let chatDoc = try? await chatRef.getDocument(),
				   chatDoc.exists,
				   let chatRoom = ChatRoomModel(document: chatDoc) {
					allChatRooms.append(chatRoom)
				}
			}
		}
		
		// OPTIMIZATION: Batch fetch blocked users to reduce individual reads
		let otherParticipants = allChatRooms.compactMap { room in
			room.participants.first { $0 != currentUid }
		}
		
		// Add friends that might not be in chat rooms yet
		let friendParticipants = Set(friends).subtracting(Set(otherParticipants))
		let allParticipants = Set(otherParticipants).union(friendParticipants)
		
		// Batch check blocked status for all participants at once
		let blockedStatuses = await friendService.getBlockedStatusesBatch(userIds: allParticipants)
		
		// Filter out chat rooms with blocked users (full hard block)
		var filteredChatRooms: [ChatRoomModel] = []
		
		for chatRoom in allChatRooms {
			// Get the other participant
			guard let otherParticipant = chatRoom.participants.first(where: { $0 != currentUid }) else {
				continue
			}
			
			// Check if chat is blocked (either user blocked the other)
			if let chatStatus = chatRoom.chatStatus[currentUid],
			   chatStatus == "blocked" {
				// Chat is explicitly marked as blocked, skip it
				continue
			}
			
			// Use cached blocked status instead of individual reads
			let isBlocked = blockedStatuses[otherParticipant]?.isBlocked ?? false
			let isBlockedBy = blockedStatuses[otherParticipant]?.isBlockedBy ?? false
			
			// If either direction is blocked, hide the chat completely
			if isBlocked || isBlockedBy {
				continue
			}
			
			filteredChatRooms.append(chatRoom)
		}
		
		// Also add chat rooms for friends that might not have been in the query results
		// (e.g., if they were created just now or if limit was reached)
		for friendId in friendParticipants {
			// Check if we already have this friend in filteredChatRooms
			if filteredChatRooms.contains(where: { $0.participants.contains(friendId) }) {
				continue
			}
			
			// Check if blocked
			let isBlocked = blockedStatuses[friendId]?.isBlocked ?? false
			let isBlockedBy = blockedStatuses[friendId]?.isBlockedBy ?? false
			if isBlocked || isBlockedBy {
				continue
			}
			
			// Get or create chat room for this friend
			let chatId = getChatRoomId(uid1: currentUid, uid2: friendId)
			let chatRef = db.collection("chat_rooms").document(chatId)
			let chatDoc = try? await chatRef.getDocument()
			
			if let chatDoc = chatDoc, chatDoc.exists, let chatRoom = ChatRoomModel(document: chatDoc) {
				// Check if blocked in chat status
				if let chatStatus = chatRoom.chatStatus[currentUid],
				   chatStatus == "blocked" {
					continue
				}
				filteredChatRooms.append(chatRoom)
			}
		}
		
		// Already sorted by query, but ensure consistency
		return filteredChatRooms.sorted { $0.lastMessageTs > $1.lastMessageTs }
	}
	
	// MARK: - Messages
	
	func sendMessage(chatId: String, type: String, content: String, replyTo: String? = nil) async throws {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		let messageRef = db.collection("chat_rooms").document(chatId).collection("messages").document()
		let chatRef = db.collection("chat_rooms").document(chatId)
		
		// OPTIMIZATION: Get chat room once, then use batch for atomic operations
		// This reduces redundant reads while maintaining consistency
		let chatDoc = try await chatRef.getDocument()
		guard let chatData = chatDoc.data(),
			  let participants = chatData["participants"] as? [String] else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		let otherParticipant = participants.first { $0 != currentUid } ?? participants[0]
		
		// Create message
		var messageData: [String: Any] = [
			"chatId": chatId,
			"senderUid": currentUid,
			"content": content,
			"type": type,
			"timestamp": Timestamp(date: Date()),
			"isDeleted": false,
			"isEdited": false,
			"reactions": [:],
			"deletedFor": []
		]
		
		if let replyTo = replyTo {
			messageData["replyToMessageId"] = replyTo
		}
		
		// Use batch for atomic operations (more efficient than transaction for this use case)
		let batch = db.batch()
		batch.setData(messageData, forDocument: messageRef)
		
		// Update chat room
		let lastMessage = type == "text" ? content : "[\(type.capitalized)]"
		batch.updateData([
			"lastMessageTs": Timestamp(date: Date()),
			"lastMessage": lastMessage,
			"lastMessageType": type,
			"unreadCount.\(otherParticipant)": FieldValue.increment(Int64(1))
		], forDocument: chatRef)
		
		try await batch.commit()
		
		// Send push notification to receiver
		Task {
			// Get sender's user data for notification
			let senderUser = try? await UserService.shared.getUser(userId: currentUid)
			let senderName = senderUser?.username.isEmpty == false ? senderUser?.username ?? "" : senderUser?.name ?? "Someone"
			
			await MessageNotificationService.shared.sendMessageNotification(
				chatId: chatId,
				messageType: type,
				messageContent: content,
				senderUid: currentUid,
				senderName: senderName,
				senderProfileImageURL: senderUser?.profileImageURL,
				receiverUid: otherParticipant
			)
		}
	}
	
	func getMessages(chatId: String, limit: Int = 50) -> AsyncThrowingStream<[MessageModel], Error> {
		guard let currentUid = currentUid else {
			return AsyncThrowingStream { continuation in
				continuation.finish(throwing: ChatServiceError.notAuthenticated)
			}
		}
		
		return AsyncThrowingStream { continuation in
			// OPTIMIZATION: Limit initial message load to reduce reads
			// Load most recent 50 messages, can paginate for more
			let listener = db.collection("chat_rooms")
				.document(chatId)
				.collection("messages")
				.order(by: "timestamp", descending: true)
				.limit(to: limit)
				.addSnapshotListener { snapshot, error in
					if let error = error {
						continuation.finish(throwing: error)
						return
					}
					
					guard let snapshot = snapshot else {
						continuation.yield([])
						return
					}
					
					let messages = snapshot.documents
						.compactMap { MessageModel(document: $0) }
						.filter { !$0.deletedFor.contains(currentUid) } // Clear Chat support
					
					continuation.yield(messages)
				}
			
			continuation.onTermination = { @Sendable _ in
				listener.remove()
			}
		}
	}
	
	// MARK: - Message Pagination
	
	/// Load older messages for pagination (loads messages before the oldest message)
	func loadOlderMessages(chatId: String, beforeMessageId: String, limit: Int = 50) async throws -> [MessageModel] {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Get the message document to use as pagination cursor
		let messageRef = db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.document(beforeMessageId)
		
		let messageDoc = try await messageRef.getDocument()
		guard let messageData = messageDoc.data(),
			  let timestamp = messageData["timestamp"] as? Timestamp else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		// Query messages before this timestamp
		let snapshot = try await db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.whereField("timestamp", isLessThan: timestamp)
			.order(by: "timestamp", descending: true)
			.limit(to: limit)
			.getDocuments()
		
		let messages = snapshot.documents
			.compactMap { MessageModel(document: $0) }
			.filter { !$0.deletedFor.contains(currentUid) }
		
		return messages
	}
	
	/// Load newer messages after a specific message (for catching up)
	func loadNewerMessages(chatId: String, afterMessageId: String, limit: Int = 50) async throws -> [MessageModel] {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Get the message document to use as pagination cursor
		let messageRef = db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.document(afterMessageId)
		
		let messageDoc = try await messageRef.getDocument()
		guard let messageData = messageDoc.data(),
			  let timestamp = messageData["timestamp"] as? Timestamp else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		// Query messages after this timestamp
		let snapshot = try await db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.whereField("timestamp", isGreaterThan: timestamp)
			.order(by: "timestamp", descending: false)
			.limit(to: limit)
			.getDocuments()
		
		let messages = snapshot.documents
			.compactMap { MessageModel(document: $0) }
			.filter { !$0.deletedFor.contains(currentUid) }
		
		return messages
	}
	
	// MARK: - Message Actions
	
	func deleteMessage(chatId: String, messageId: String) async throws {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Get the message first to check its type and if it's the last message
		let messageRef = db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.document(messageId)
		
		let messageDoc = try await messageRef.getDocument()
		guard let messageData = messageDoc.data(),
			  let messageType = messageData["type"] as? String,
			  let messageContent = messageData["content"] as? String,
			  let messageTimestamp = messageData["timestamp"] as? Timestamp,
			  let senderUid = messageData["senderUid"] as? String else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		// Check if this is the last message by comparing timestamp
		let chatRef = db.collection("chat_rooms").document(chatId)
		let chatDoc = try await chatRef.getDocument()
		guard let chatData = chatDoc.data(),
			  let lastMessageTs = chatData["lastMessageTs"] as? Timestamp else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		let isLastMessage = lastMessageTs.dateValue() == messageTimestamp.dateValue()
		
		// Delete media file from Storage first (for media types)
		let mediaTypes = ["image", "video", "photo"]
		if mediaTypes.contains(messageType) && !messageContent.isEmpty {
			do {
				try await StorageService.shared.deleteFile(from: messageContent)
				print("✅ ChatService: Storage file deleted successfully for message \(messageId)")
			} catch {
				print("⚠️ ChatService: Error deleting media file: \(error.localizedDescription)")
				// Continue with message deletion even if Storage deletion fails
			}
		}
		
		let batch = db.batch()
		
		// Delete the original message from Firestore
		batch.deleteDocument(messageRef)
		
		// Create a replacement "deleted" message that both users can see
		// Use the same timestamp so it appears in the same position
		let deletedMessageId = "\(messageId)_deleted"
		let deletedMessageRef = db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.document(deletedMessageId)
		
		let deletedContent = (messageType == "text") ? "This message was deleted" : "This media was deleted"
		
		// Store original media URL for later deletion (when both users clear chat)
		var deletedMessageData: [String: Any] = [
			"chatId": chatId,
			"senderUid": senderUid,
			"content": deletedContent,
			"type": messageType,
			"timestamp": messageTimestamp,
			"isDeleted": true,
			"deletedBy": currentUid,
			"deletedAt": Timestamp(date: Date()),
			"originalMessageId": messageId
		]
		
		// Store original media URL if it's a media type (so we can delete it when both users clear)
		if mediaTypes.contains(messageType) && !messageContent.isEmpty {
			deletedMessageData["originalMediaURL"] = messageContent
		}
		
		batch.setData(deletedMessageData, forDocument: deletedMessageRef)
		
		// If this was the last message, update chat room to show the deleted message
		// The deleted message will be created with the same timestamp, so it becomes the new last message
		if isLastMessage {
			// Update chat room to show the deleted message as the last message
			batch.updateData([
				"lastMessage": deletedContent,
				"lastMessageType": messageType,
				"lastMessageTs": messageTimestamp
			], forDocument: chatRef)
		}
		
		// Commit the deletion and replacement
		try await batch.commit()
		print("✅ ChatService: Successfully deleted message \(messageId) from Firestore and created replacement")
	}
	
	func editMessage(chatId: String, messageId: String, newText: String) async throws {
		// Get current message to check edit count
		let messageRef = db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.document(messageId)
		
		let messageDoc = try await messageRef.getDocument()
		guard messageDoc.exists,
			  let messageData = messageDoc.data(),
			  let timestamp = messageData["timestamp"] as? Timestamp else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		let currentEditCount = messageData["editCount"] as? Int ?? 0
		
		// Check if message can still be edited (max 2 times)
		guard currentEditCount < 2 else {
			throw ChatServiceError.messageCannotBeEdited
		}
		
		let chatRef = db.collection("chat_rooms").document(chatId)
		
		// Use batch to update both message and chat room atomically
		let batch = db.batch()
		
		// Update message with incremented edit count
		batch.updateData([
			"content": newText,
			"isEdited": true,
			"editedAt": Timestamp(date: Date()),
			"editCount": currentEditCount + 1
		], forDocument: messageRef)
		
		// Update chat room's lastMessage if this is the last message
		// Check if this message's timestamp matches the chat room's lastMessageTs
		// Use a small tolerance (1 second) to account for timestamp precision differences
		let chatDoc = try await chatRef.getDocument()
		if let chatData = chatDoc.data(),
		   let lastMessageTs = chatData["lastMessageTs"] as? Timestamp {
			let messageTime = timestamp.dateValue()
			let lastMessageTime = lastMessageTs.dateValue()
			let timeDifference = abs(messageTime.timeIntervalSince(lastMessageTime))
			
			// If timestamps match (within 1 second tolerance), this is the last message
			if timeDifference <= 1.0 {
				// This is the last message, update chat room
				batch.updateData([
					"lastMessage": newText,
					"lastMessageType": messageData["type"] as? String ?? "text"
				], forDocument: chatRef)
			}
		}
		
		try await batch.commit()
	}
	
	func addReaction(chatId: String, messageId: String, emoji: String) async throws {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Verify user is a participant in the chat room
		let chatRoomRef = db.collection("chat_rooms").document(chatId)
		let chatRoomDoc = try await chatRoomRef.getDocument()
		
		guard chatRoomDoc.exists,
			  let chatRoomData = chatRoomDoc.data(),
			  let participants = chatRoomData["participants"] as? [String],
			  participants.contains(currentUid) else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		let messageRef = chatRoomRef
			.collection("messages")
			.document(messageId)
		
		try await messageRef.updateData([
			"reactions.\(currentUid)": emoji
		])
	}
	
	func removeReaction(chatId: String, messageId: String) async throws {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Verify user is a participant in the chat room
		let chatRoomRef = db.collection("chat_rooms").document(chatId)
		let chatRoomDoc = try await chatRoomRef.getDocument()
		
		guard chatRoomDoc.exists,
			  let chatRoomData = chatRoomDoc.data(),
			  let participants = chatRoomData["participants"] as? [String],
			  participants.contains(currentUid) else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		let messageRef = chatRoomRef
			.collection("messages")
			.document(messageId)
		
		let messageDoc = try await messageRef.getDocument()
		guard let data = messageDoc.data(),
			  var reactions = data["reactions"] as? [String: String] else {
			return
		}
		
		reactions.removeValue(forKey: currentUid)
		
		try await messageRef.updateData([
			"reactions": reactions
		])
	}
	
	// MARK: - Clear Chat (One-sided with shared deletion)
	
	func clearChatForMe(chatId: String) async throws {
		guard currentUid != nil else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Use Cloud Function to clear chat (bypasses Firestore security rules)
		let functions = Functions.functions()
		let clearChatFunction = functions.httpsCallable("clearChat")
		
		do {
			let result = try await clearChatFunction.call([
				"chatId": chatId
			])
			
			// Check if the function call was successful
			if let data = result.data as? [String: Any],
			   let success = data["success"] as? Bool,
			   success {
				print("✅ ChatService: Successfully cleared chat via Cloud Function")
				return
			} else {
				// If success is false or data is malformed, throw a generic error
				throw ChatServiceError.chatRoomNotFound
			}
		} catch {
			// If Cloud Function fails (e.g., not deployed), try fallback to direct Firestore update
			print("⚠️ ChatService: Cloud Function clearChat failed, trying fallback: \(error.localizedDescription)")
			
			// Fallback: Use deletedFor array approach (one-sided clear)
			// This will work but requires both users to clear for full deletion
			do {
				try await clearChatForMeFallback(chatId: chatId)
				print("✅ ChatService: Successfully cleared chat via fallback method")
			} catch {
				print("❌ ChatService: Fallback clear chat also failed: \(error.localizedDescription)")
				throw error
			}
		}
	}
	
	// Fallback method for clearing chat when Cloud Function is not available
	private func clearChatForMeFallback(chatId: String) async throws {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		// Get chat room to know both participants
		let chatRef = db.collection("chat_rooms").document(chatId)
		let chatDoc = try await chatRef.getDocument()
		guard let chatData = chatDoc.data(),
			  let participants = chatData["participants"] as? [String],
			  participants.count == 2 else {
			throw ChatServiceError.chatRoomNotFound
		}
		
		// Process messages in batches
		let batchSize = 500
		var lastDocument: DocumentSnapshot?
		var hasMore = true
		var isFirstBatch = true
		
		while hasMore {
			var query = db.collection("chat_rooms")
				.document(chatId)
				.collection("messages")
				.limit(to: batchSize)
			
			if let lastDoc = lastDocument {
				query = query.start(afterDocument: lastDoc)
			}
			
			let messagesSnapshot = try await query.getDocuments()
			
			if messagesSnapshot.documents.isEmpty {
				hasMore = false
				break
			}
			
			let batch = db.batch()
			var updateCount = 0
			
			for doc in messagesSnapshot.documents {
				let data = doc.data()
				let currentDeletedFor = data["deletedFor"] as? [String] ?? []
				
				// Add current user to deletedFor if not already there
				if !currentDeletedFor.contains(currentUid) && updateCount < 500 {
					batch.updateData([
							"deletedFor": FieldValue.arrayUnion([currentUid])
						], forDocument: doc.reference)
						updateCount += 1
				}
			}
			
			// Update chat room only once (on first batch)
			if isFirstBatch {
				batch.updateData([
					"lastMessage": "",
					"lastMessageTs": Timestamp(date: Date()),
					"lastMessageType": "text"
				], forDocument: chatRef)
				isFirstBatch = false
			}
			
			// Commit batch
			if updateCount > 0 {
				try await batch.commit()
			}
			
			// Check if there are more messages
			hasMore = messagesSnapshot.documents.count == batchSize
			lastDocument = messagesSnapshot.documents.last
		}
		
		print("✅ ChatService: Successfully cleared chat via fallback (messages marked in deletedFor)")
	}
	
	// MARK: - Mark as Read
	
	func markChatAsRead(chatId: String) async throws {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		try await db.collection("chat_rooms")
			.document(chatId)
			.updateData([
				"unreadCount.\(currentUid)": 0
			])
	}
	
	// MARK: - Search Messages
	
	func searchMessages(chatId: String, query: String) async throws -> [MessageModel] {
		guard let currentUid = currentUid else {
			throw ChatServiceError.notAuthenticated
		}
		
		guard !query.isEmpty else {
			return []
		}
		
		// Get all messages and filter in memory (more reliable than Firestore text search)
		// Firestore doesn't have great text search capabilities, so we'll fetch recent messages
		// and filter them client-side
		let messagesSnapshot = try await db.collection("chat_rooms")
			.document(chatId)
			.collection("messages")
			.order(by: "timestamp", descending: true)
			.limit(to: 200) // Get last 200 messages to search through
			.getDocuments()
		
		let allMessages = messagesSnapshot.documents
			.compactMap { MessageModel(document: $0) }
			.filter { 
				!$0.deletedFor.contains(currentUid) && 
				!$0.isDeleted &&
				$0.type == "text" // Only search text messages, exclude images/videos
			}
		
		// Filter messages that contain the search query (case-insensitive)
		let lowerQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		let filteredMessages = allMessages.filter { message in
			message.content.lowercased().contains(lowerQuery)
		}
		
		return filteredMessages
	}
}

enum ChatServiceError: LocalizedError {
	case notAuthenticated
	case invalidParticipants
	case chatRoomNotFound
	case messageCannotBeEdited
	
	var errorDescription: String? {
		switch self {
		case .notAuthenticated:
			return "You must be logged in to perform this action"
		case .invalidParticipants:
			return "Chat room must have exactly 2 participants"
		case .chatRoomNotFound:
			return "Chat room not found"
		case .messageCannotBeEdited:
			return "Message has already been edited 2 times and cannot be edited again"
		}
	}
}


