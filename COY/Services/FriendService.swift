import Foundation
import FirebaseFirestore
import FirebaseAuth
import FirebaseFunctions

@MainActor
class FriendService {
	static let shared = FriendService()
	private let db = Firestore.firestore()
	
	// OPTIMIZATION: Cache user data to reduce reads
	private var userDataCache: [String: (data: [String: Any], timestamp: Date)] = [:]
	private let cacheExpiration: TimeInterval = 300 // 5 minutes
	
	private init() {}
	
	var currentUid: String? {
		return Auth.auth().currentUser?.uid
	}
	
	// MARK: - Cache Management
	
	private func getCachedUserData(userId: String) -> [String: Any]? {
		guard let cached = userDataCache[userId],
			  Date().timeIntervalSince(cached.timestamp) < cacheExpiration else {
			return nil
		}
		return cached.data
	}
	
	private func setCachedUserData(userId: String, data: [String: Any]) {
		userDataCache[userId] = (data: data, timestamp: Date())
	}
	
	private func clearCache() {
		userDataCache.removeAll()
	}
	
	// MARK: - Send Friend Request
	
	func sendFriendRequest(toUid: String) async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		guard currentUid != toUid else {
			throw FriendServiceError.cannotAddSelf
		}
		
		let requestId = "\(currentUid)_\(toUid)"
		let requestRef = db.collection("friend_requests").document(requestId)
		
		// Check if request already exists
		let existingDoc = try? await requestRef.getDocument()
		if let existingDoc = existingDoc, existingDoc.exists {
			if let data = existingDoc.data(),
			   let status = data["status"] as? String,
			   status == "pending" {
				// Request already pending, don't create duplicate
				throw FriendServiceError.requestAlreadyExists
			}
			// If request exists but is not pending (e.g., "accepted" or "denied"), 
			// update it to "pending" to allow re-adding
		}
		
		let request = FriendRequestModel(
			fromUid: currentUid,
			toUid: toUid,
			status: "pending"
		)
		
		let batch = db.batch()
		batch.setData(request.toFirestoreData(), forDocument: requestRef)
		
		// Update chat room status to track pending add request
		// If they unadded me, my status becomes "pendingAdd" (I'm trying to add them back)
		let sortedIds = [currentUid, toUid].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		// Get current chat status
		let chatDoc = try? await chatRoomRef.getDocument()
		let currentChatStatus = chatDoc?.data()?["chatStatus"] as? [String: String] ?? [:]
		let theirStatus = currentChatStatus[toUid] ?? "friends"
		let myCurrentStatus = currentChatStatus[currentUid] ?? "friends"
		
		// Handle both-way un-add: when both un-added each other
		if myCurrentStatus == "bothUnadded" && theirStatus == "bothUnadded" {
			// Both un-added each other - when one adds first, set their status to "pendingAdd"
			// They will see "You have been un-added by this user" until the other person also adds
			batch.updateData([
				"chatStatus.\(currentUid)": "pendingAdd"
			], forDocument: chatRoomRef)
		} else if theirStatus == "theyUnadded" {
			// They unadded me (one-way) - set my status to "pendingAdd"
			batch.updateData([
				"chatStatus.\(currentUid)": "pendingAdd"
			], forDocument: chatRoomRef)
		} else if myCurrentStatus == "iUnadded" {
			// I previously unadded them (one-way) - set my status to "pendingAdd"
			batch.updateData([
				"chatStatus.\(currentUid)": "pendingAdd"
			], forDocument: chatRoomRef)
		}
		
		try await batch.commit()
		
		// Post updated friend request count for the recipient (toUid)
		// The recipient's count should increase when they receive a new request
		// Note: We can't directly get the recipient's count from here, so we'll rely on
		// the real-time listener in AddFriendsScreen to update the count
		// The count will be updated when the recipient's app receives the new request via listener
	}
	
	// MARK: - Restore Friendship (Direct Re-add)
	
	/// Directly restores friendship when re-adding someone you previously unadded
	/// This is used when: I unadded them, they didn't unadd me, and I'm adding them back
	/// No friend request needed - immediately restore friendship
	func restoreFriendship(userId: String) async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		guard currentUid != userId else {
			throw FriendServiceError.cannotAddSelf
		}
		
		let batch = db.batch()
		
		// Add each other back to friends arrays
		let currentUserRef = db.collection("users").document(currentUid)
		batch.updateData(["friends": FieldValue.arrayUnion([userId])], forDocument: currentUserRef)
		
		let otherUserRef = db.collection("users").document(userId)
		batch.updateData(["friends": FieldValue.arrayUnion([currentUid])], forDocument: otherUserRef)
		
		// Update chat room status to "friends" (both sides)
		let sortedIds = [currentUid, userId].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		// Check if chat room exists
		let chatDoc = try? await chatRoomRef.getDocument()
		if chatDoc?.exists == true {
			// Chat room exists - update status to friends
			batch.updateData([
				"chatStatus.\(currentUid)": "friends",
				"chatStatus.\(userId)": "friends"
			], forDocument: chatRoomRef)
		} else {
			// Create new chat room with "friends" status
			let newChat = ChatRoomModel(
				chatId: chatRoomId,
				participants: [currentUid, userId],
				lastMessageTs: Date(),
				lastMessage: "",
				lastMessageType: "text",
				unreadCount: [currentUid: 0, userId: 0],
				chatStatus: [currentUid: "friends", userId: "friends"]
			)
			batch.setData(newChat.toFirestoreData(), forDocument: chatRoomRef)
		}
		
		// Delete any pending friend requests between these users (cleanup)
		let requestId1 = "\(currentUid)_\(userId)"
		let requestId2 = "\(userId)_\(currentUid)"
		let requestRef1 = db.collection("friend_requests").document(requestId1)
		let requestRef2 = db.collection("friend_requests").document(requestId2)
		
		// Check if requests exist and delete them
		let request1Doc = try? await requestRef1.getDocument()
		let request2Doc = try? await requestRef2.getDocument()
		
		if request1Doc?.exists == true {
			batch.deleteDocument(requestRef1)
		}
		if request2Doc?.exists == true {
			batch.deleteDocument(requestRef2)
		}
		
		try await batch.commit()
		
		// Clear cache
		clearCache()
		
		// Notify that friendship was restored
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("FriendAdded"),
				object: userId
			)
		}
	}
	
	// MARK: - Accept Friend Request
	
	func acceptRequest(fromUid: String) async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		let requestId = "\(fromUid)_\(currentUid)"
		let batch = db.batch()
		
		// Update request status
		let requestRef = db.collection("friend_requests").document(requestId)
		batch.updateData(["status": "accepted"], forDocument: requestRef)
		
		// Add each other to friends array
		let currentUserRef = db.collection("users").document(currentUid)
		batch.updateData(["friends": FieldValue.arrayUnion([fromUid])], forDocument: currentUserRef)
		
		let otherUserRef = db.collection("users").document(fromUid)
		batch.updateData(["friends": FieldValue.arrayUnion([currentUid])], forDocument: otherUserRef)
		
		// Check if there's a reverse friend request (mutual re-add scenario)
		// This handles the case where both users are trying to add each other back
		let reverseRequestId = "\(currentUid)_\(fromUid)"
		let reverseRequestRef = db.collection("friend_requests").document(reverseRequestId)
		let reverseRequestDoc = try? await reverseRequestRef.getDocument()
		
		// If there's a pending reverse request (I sent them a request), accept it too (mutual re-add)
		// This means we're both trying to add each other back - accept both requests
		if let reverseDoc = reverseRequestDoc, reverseDoc.exists,
		   let reverseData = reverseDoc.data(),
		   let reverseStatus = reverseData["status"] as? String,
		   reverseStatus == "pending" {
			batch.updateData(["status": "accepted"], forDocument: reverseRequestRef)
		}
		
		// Auto-create or update chat room and set status to "friends"
		let sortedIds = [currentUid, fromUid].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		// Check if chat room exists (if it does, they were previously friends)
		let chatDoc = try? await chatRoomRef.getDocument()
		if chatDoc?.exists == true {
			// Chat room exists - check if this is a both-way un-add scenario
			let currentChatStatus = chatDoc?.data()?["chatStatus"] as? [String: String] ?? [:]
			let theirStatus = currentChatStatus[fromUid] ?? "friends"
			let myStatus = currentChatStatus[currentUid] ?? "friends"
			
			// If both have "pendingAdd" status, it means both have added each other
			// This is the second person accepting in a both-way un-add - restore friendship immediately
			if myStatus == "pendingAdd" && theirStatus == "pendingAdd" {
				// Both people have now added each other - restore friendship
				batch.updateData([
					"chatStatus.\(currentUid)": "friends",
					"chatStatus.\(fromUid)": "friends"
				], forDocument: chatRoomRef)
			} else if theirStatus == "pendingAdd" {
				// They have pendingAdd (they added me), but I don't have pendingAdd yet
				// Set my status to friends, but keep their status as pendingAdd until they accept my request
				// Actually, if they have pendingAdd and I'm accepting, we should both become friends
				batch.updateData([
					"chatStatus.\(currentUid)": "friends",
					"chatStatus.\(fromUid)": "friends"
				], forDocument: chatRoomRef)
			} else {
				// Normal acceptance - set both to "friends"
				batch.updateData([
					"chatStatus.\(currentUid)": "friends",
					"chatStatus.\(fromUid)": "friends"
				], forDocument: chatRoomRef)
			}
		} else {
			// Create new chat room with "friends" status (new friendship)
			let newChat = ChatRoomModel(
				chatId: chatRoomId,
				participants: [currentUid, fromUid],
				lastMessageTs: Date(),
				lastMessage: "",
				lastMessageType: "text",
				unreadCount: [currentUid: 0, fromUid: 0],
				chatStatus: [currentUid: "friends", fromUid: "friends"]
			)
			batch.setData(newChat.toFirestoreData(), forDocument: chatRoomRef)
		}
		
		try await batch.commit()
		
		// OPTIMIZATION: Clear cache after friend status change
		clearCache()
		
		// Get updated friend request count and post notification
		let updatedCount = try await getTotalPendingFriendRequestCount()
		
		// Notify that friend request was accepted (for UI updates)
		await MainActor.run {
			NotificationCenter.default.post(
				name: NSNotification.Name("FriendRequestAccepted"),
				object: fromUid
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("FriendAdded"),
				object: fromUid
			)
			// Post updated friend request count
			NotificationCenter.default.post(
				name: NSNotification.Name("FriendRequestCountChanged"),
				object: nil,
				userInfo: ["count": updatedCount]
			)
		}
		
		// OPTIMIZATION: Clear cache after friend status change
		clearCache()
	}
	
	// MARK: - Deny Friend Request
	
	func denyRequest(fromUid: String) async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		let requestId = "\(fromUid)_\(currentUid)"
		try await db.collection("friend_requests").document(requestId).updateData([
			"status": "denied"
		])
		
		// Get updated friend request count and post notification
		let updatedCount = try await getTotalPendingFriendRequestCount()
		
		await MainActor.run {
			// Post updated friend request count
			NotificationCenter.default.post(
				name: NSNotification.Name("FriendRequestCountChanged"),
				object: nil,
				userInfo: ["count": updatedCount]
			)
		}
	}
	
	// MARK: - Remove Friend (Unadd)
	
	func removeFriend(friendUid: String) async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		let batch = db.batch()
		
		// Remove from friends arrays
		let currentUserRef = db.collection("users").document(currentUid)
		batch.updateData(["friends": FieldValue.arrayRemove([friendUid])], forDocument: currentUserRef)
		
		let friendUserRef = db.collection("users").document(friendUid)
		batch.updateData(["friends": FieldValue.arrayRemove([currentUid])], forDocument: friendUserRef)
		
		// OPTIMIZATION: Clear cache after friend status change
		clearCache()
		
		// Update chat room status - track who unadded whom
		let sortedIds = [currentUid, friendUid].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		// Get current chat status to determine if both unadded
		let chatDoc = try? await chatRoomRef.getDocument()
		let theirCurrentStatus = chatDoc?.data()?["chatStatus"] as? [String: String] ?? [:]
		let theirStatus = theirCurrentStatus[friendUid] ?? "friends"
		
		// Determine new statuses based on who unadded whom
		var myNewStatus = "iUnadded" // I unadded them
		var theirNewStatus: String
		
		// If they already unadded me (theyUnadded), now it's bothUnadded
		if theirStatus == "theyUnadded" || theirStatus == "bothUnadded" {
			myNewStatus = "bothUnadded"
			theirNewStatus = "bothUnadded"
		} else {
			// They didn't unadd me, so from their perspective I unadded them
			// Their status should be "theyUnadded" (meaning "the other person unadded me")
			theirNewStatus = "theyUnadded"
		}
		
		// Update chat status
		batch.updateData([
			"chatStatus.\(currentUid)": myNewStatus,
			"chatStatus.\(friendUid)": theirNewStatus
		], forDocument: chatRoomRef)
		
		try await batch.commit()
		
		// OPTIMIZATION: Clear cache after friend status change
		clearCache()
	}
	
	// MARK: - Block User (Full Hard Block - Mutual Invisibility)
	
	func blockUser(blockedUid: String) async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		// Use Cloud Function to block user (bypasses Firestore security rules)
		let functions = Functions.functions()
		let blockUserFunction = functions.httpsCallable("blockUser")
		
		do {
			let result = try await blockUserFunction.call([
				"blockedUid": blockedUid
			])
			
			// Check if the function call was successful
			if let data = result.data as? [String: Any],
			   let success = data["success"] as? Bool,
			   success {
				// Clear cache after successful block
				clearCache()
				return
			} else {
				// If success is false or data is malformed, throw a generic error
				throw NSError(domain: "FriendService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to block user"])
			}
		} catch {
			// If Cloud Function fails, try fallback to direct Firestore update
			print("⚠️ FriendService: Cloud Function blockUser failed, trying fallback: \(error.localizedDescription)")
			
			// Fallback: Try to update current user's document directly
			// This might work if security rules allow it
			do {
		let currentUserRef = db.collection("users").document(currentUid)
				try await currentUserRef.updateData([
					"blockedUsers": FieldValue.arrayUnion([blockedUid])
				])
		
				// Clear cache after successful block
		clearCache()
			} catch {
				// If fallback also fails, throw the original error
				print("❌ FriendService: Fallback blockUser also failed: \(error.localizedDescription)")
				throw error
			}
		}
	}
	
	// MARK: - Unblock User
	
	func unblockUser(blockedUid: String) async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		let batch = db.batch()
		
		// Remove from current user's blockedUsers
		let currentUserRef = db.collection("users").document(currentUid)
		batch.updateData(["blockedUsers": FieldValue.arrayRemove([blockedUid])], forDocument: currentUserRef)
		
		// Remove from blocked user's blockedByUsers
		let blockedUserRef = db.collection("users").document(blockedUid)
		batch.updateData(["blockedByUsers": FieldValue.arrayRemove([currentUid])], forDocument: blockedUserRef)
		
		// Update chat room status - remove blocked status
		// If they were friends before, restore to "friends", otherwise "unadded"
		let sortedIds = [currentUid, blockedUid].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		// Check if they are friends
		let areFriends = await isFriend(userId: blockedUid)
		let status = areFriends ? "friends" : "unadded"
		
		// Check if chat room exists
		let chatDoc = try? await chatRoomRef.getDocument()
		if chatDoc?.exists == true {
			batch.updateData([
				"chatStatus.\(currentUid)": status,
				"chatStatus.\(blockedUid)": status
			], forDocument: chatRoomRef)
		}
		
		try await batch.commit()
		
		// OPTIMIZATION: Clear cache after unblock
		clearCache()
	}
	
	// MARK: - Check if Users Were Previously Friends
	
	/// Checks if users were previously friends by checking if a chat room exists between them
	func werePreviouslyFriends(userId: String) async -> Bool {
		guard let currentUid = currentUid else { return false }
		
		let sortedIds = [currentUid, userId].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		do {
			let chatDoc = try await chatRoomRef.getDocument()
			return chatDoc.exists
		} catch {
			print("Error checking if users were previously friends: \(error)")
			return false
		}
	}
	
	// MARK: - Check if One-Way Unadd (Should be Excluded from Add User List)
	
	/// Checks if there's a one-way un-add relationship between users.
	/// Returns true if one user un-added the other (but not both ways).
	/// One-way un-adds should NOT appear in Add User list - they can only be re-added from message screen.
	/// Only both-way un-adds (bothUnadded) should appear in Add User list.
	/// 
	/// IMPORTANT: Anyone with a chat room (in message list) should NOT appear in Add User UNLESS it's bothUnadded.
	func hasOneWayUnadd(userId: String) async -> Bool {
		guard let currentUid = currentUid else { return false }
		
		let sortedIds = [currentUid, userId].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		do {
			let chatDoc = try await chatRoomRef.getDocument()
			guard chatDoc.exists,
				  let data = chatDoc.data(),
				  let chatStatus = data["chatStatus"] as? [String: String] else {
				// No chat room exists - not a one-way un-add (can appear in Add User)
				return false
			}
			
			// Check if user is a participant (required by Firestore rules)
			guard let participants = data["participants"] as? [String],
				  participants.contains(currentUid) else {
				// User is not a participant - permission denied, treat as no chat room
				return false
			}
			
			let myStatus = chatStatus[currentUid] ?? "friends"
			let theirStatus = chatStatus[userId] ?? "friends"
			
			// If both un-added each other, they should NOT appear in Add User list
			// They should only be re-added from message screen
			if myStatus == "bothUnadded" && theirStatus == "bothUnadded" {
				return true
			}
			
			// If both are friends, they're in message list - exclude from Add User
			if myStatus == "friends" && theirStatus == "friends" {
				return true
			}
			
			// If one has un-added but not both, it's a one-way un-add (exclude from Add User list)
			// Cases:
			// - myStatus = "iUnadded", theirStatus = "theyUnadded" (I unadded them, they didn't unadd me)
			// - myStatus = "theyUnadded", theirStatus = "iUnadded" (They unadded me, I didn't unadd them)
			if (myStatus == "iUnadded" && theirStatus == "theyUnadded") ||
			   (myStatus == "theyUnadded" && theirStatus == "iUnadded") {
				return true
			}
			
			// Edge cases: transition states
			if myStatus == "iUnadded" && theirStatus == "friends" {
				// I unadded them but they haven't responded yet - one-way un-add
				return true
			}
			
			if myStatus == "friends" && theirStatus == "iUnadded" {
				// They unadded me but I haven't responded yet - one-way un-add
				return true
			}
			
			// If pendingAdd is involved but it's still one-way, exclude
			if (myStatus == "pendingAdd" && (theirStatus == "theyUnadded" || theirStatus == "iUnadded")) ||
			   (theirStatus == "pendingAdd" && (myStatus == "iUnadded" || myStatus == "theyUnadded")) {
				return true
			}
			
			// If one person has pendingAdd in both-way un-add, exclude (they're waiting for the other)
			if (myStatus == "pendingAdd" && theirStatus == "bothUnadded") ||
			   (theirStatus == "pendingAdd" && myStatus == "bothUnadded") {
				return true
			}
			
			// If chat room exists but status is unclear, exclude from Add User (they're in message list)
			// Anyone with a chat room should NOT appear in Add User
			return true
		} catch {
			print("Error checking one-way un-add status: \(error)")
			return false
		}
	}
	
	// MARK: - Check if Can Restore Friendship (One-Way Unadd)
	
	/// Checks if we can directly restore friendship (one-way un-add scenario).
	/// Returns true if: I unadded them, they didn't unadd me (or vice versa).
	/// In this case, tapping Add should restore friendship immediately without a friend request.
	func canRestoreFriendship(userId: String) async -> Bool {
		guard let currentUid = currentUid else { return false }
		
		let sortedIds = [currentUid, userId].sorted()
		let chatRoomId = sortedIds.joined(separator: "_")
		let chatRoomRef = db.collection("chat_rooms").document(chatRoomId)
		
		do {
			let chatDoc = try await chatRoomRef.getDocument()
			guard chatDoc.exists,
				  let data = chatDoc.data(),
				  let chatStatus = data["chatStatus"] as? [String: String] else {
				// No chat room - cannot restore (need to send request)
				return false
			}
			
			let myStatus = chatStatus[currentUid] ?? "friends"
			let theirStatus = chatStatus[userId] ?? "friends"
			
			// Case 1: I unadded them, they didn't unadd me
			// myStatus = "iUnadded", theirStatus = "theyUnadded" or "friends"
			if myStatus == "iUnadded" && (theirStatus == "theyUnadded" || theirStatus == "friends") {
				return true
			}
			
			// Case 2: They unadded me, I didn't unadd them
			// myStatus = "theyUnadded", theirStatus = "iUnadded" or "friends"
			if myStatus == "theyUnadded" && (theirStatus == "iUnadded" || theirStatus == "friends") {
				return true
			}
			
			// Case 3: I'm trying to add them back (pendingAdd) but they still have me
			if myStatus == "pendingAdd" && (theirStatus == "theyUnadded" || theirStatus == "friends") {
				return true
			}
			
			return false
		} catch {
			print("Error checking if can restore friendship: \(error)")
			return false
		}
	}
	
	// MARK: - Check Friend Status
	
	func isFriend(userId: String) async -> Bool {
		guard let currentUid = currentUid else { return false }
		
		// OPTIMIZATION: Check cache first
		if let cachedData = getCachedUserData(userId: currentUid),
		   let friends = cachedData["friends"] as? [String] {
			return friends.contains(userId)
		}
		
		do {
			let userDoc = try await db.collection("users").document(currentUid).getDocument()
			if let data = userDoc.data() {
				// Cache the data
				setCachedUserData(userId: currentUid, data: data)
				if let friends = data["friends"] as? [String] {
					return friends.contains(userId)
				}
			}
		} catch {
			print("Error checking friend status: \(error)")
		}
		
		return false
	}
	
	// MARK: - Batch Operations for Performance
	
	/// Batch check blocked statuses for multiple users (reduces reads)
	func getBlockedStatusesBatch(userIds: Set<String>) async -> [String: (isBlocked: Bool, isBlockedBy: Bool)] {
		guard let currentUid = currentUid else {
			return [:]
		}
		
		var results: [String: (isBlocked: Bool, isBlockedBy: Bool)] = [:]
		
		// Check cache first
		if let cachedData = getCachedUserData(userId: currentUid),
		   let blockedUsers = cachedData["blockedUsers"] as? [String],
		   let blockedByUsers = cachedData["blockedByUsers"] as? [String] {
			// Use cached data for current user's blocked lists
			for userId in userIds {
				results[userId] = (
					isBlocked: blockedUsers.contains(userId),
					isBlockedBy: blockedByUsers.contains(userId)
				)
			}
			return results
		}
		
		// Fetch current user's data if not cached
		do {
			let userDoc = try await db.collection("users").document(currentUid).getDocument()
			if let data = userDoc.data() {
				setCachedUserData(userId: currentUid, data: data)
				let blockedUsers = data["blockedUsers"] as? [String] ?? []
				let blockedByUsers = data["blockedByUsers"] as? [String] ?? []
				
				for userId in userIds {
					results[userId] = (
						isBlocked: blockedUsers.contains(userId),
						isBlockedBy: blockedByUsers.contains(userId)
					)
				}
			}
		} catch {
			print("Error fetching blocked statuses: \(error)")
		}
		
		return results
	}
	
	// MARK: - Get Incoming Friend Requests
	
	func getIncomingFriendRequests() async throws -> [FriendRequestModel] {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		// Query without orderBy to avoid index requirement, then sort in memory
		let snapshot = try await db.collection("friend_requests")
			.whereField("toUid", isEqualTo: currentUid)
			.whereField("status", isEqualTo: "pending")
			.getDocuments()
		
		let requests = snapshot.documents.compactMap { FriendRequestModel(document: $0) }
		// Sort by createdAt descending
		return requests.sorted { $0.createdAt > $1.createdAt }
	}
	
	// MARK: - Get Unseen Friend Request Count
	
	func getUnseenFriendRequestCount() async throws -> Int {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		let snapshot = try await db.collection("friend_requests")
			.whereField("toUid", isEqualTo: currentUid)
			.whereField("status", isEqualTo: "pending")
			.whereField("seen", isEqualTo: false)
			.getDocuments()
		
		return snapshot.documents.count
	}
	
	// MARK: - Get Total Pending Friend Request Count
	/// Get total count of ALL pending friend requests (not just unseen)
	/// This count should persist until requests are accepted or denied
	func getTotalPendingFriendRequestCount() async throws -> Int {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		let snapshot = try await db.collection("friend_requests")
			.whereField("toUid", isEqualTo: currentUid)
			.whereField("status", isEqualTo: "pending")
			.getDocuments()
		
		return snapshot.documents.count
	}
	
	// MARK: - Mark Friend Requests as Seen
	
	func markFriendRequestsAsSeen() async throws {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		// Get all unseen pending requests
		let snapshot = try await db.collection("friend_requests")
			.whereField("toUid", isEqualTo: currentUid)
			.whereField("status", isEqualTo: "pending")
			.whereField("seen", isEqualTo: false)
			.getDocuments()
		
		// Update all unseen requests to seen in batches
		let batchSize = 500
		var documents = snapshot.documents
		
		while !documents.isEmpty {
			let batch = db.batch()
			let batchDocs = documents.prefix(batchSize)
			
			for doc in batchDocs {
				batch.updateData(["seen": true], forDocument: doc.reference)
			}
			
			try await batch.commit()
			documents = Array(documents.dropFirst(batchDocs.count))
		}
	}
	
	// MARK: - Get Outgoing Friend Requests
	
	func getOutgoingFriendRequests() async throws -> [FriendRequestModel] {
		guard let currentUid = currentUid else {
			throw FriendServiceError.notAuthenticated
		}
		
		// Query without orderBy to avoid index requirement, then sort in memory
		let snapshot = try await db.collection("friend_requests")
			.whereField("fromUid", isEqualTo: currentUid)
			.whereField("status", isEqualTo: "pending")
			.getDocuments()
		
		let requests = snapshot.documents.compactMap { FriendRequestModel(document: $0) }
		// Sort by createdAt descending
		return requests.sorted { $0.createdAt > $1.createdAt }
	}
	
	// MARK: - Check if Blocked
	
	func isBlocked(userId: String) async -> Bool {
		guard let currentUid = currentUid else { return false }
		
		// OPTIMIZATION: Check cache first
		if let cachedData = getCachedUserData(userId: currentUid),
		   let blockedUsers = cachedData["blockedUsers"] as? [String] {
			return blockedUsers.contains(userId)
		}
		
		do {
			let userDoc = try await db.collection("users").document(currentUid).getDocument()
			if let data = userDoc.data() {
				setCachedUserData(userId: currentUid, data: data)
				if let blockedUsers = data["blockedUsers"] as? [String] {
					return blockedUsers.contains(userId)
				}
			}
		} catch {
			print("Error checking blocked status: \(error)")
		}
		
		return false
	}
	
	func isBlockedBy(userId: String) async -> Bool {
		guard let currentUid = currentUid else { return false }
		
		// OPTIMIZATION: Check cache first
		if let cachedData = getCachedUserData(userId: currentUid),
		   let blockedByUsers = cachedData["blockedByUsers"] as? [String] {
			return blockedByUsers.contains(userId)
		}
		
		do {
			let userDoc = try await db.collection("users").document(currentUid).getDocument()
			if let data = userDoc.data() {
				setCachedUserData(userId: currentUid, data: data)
				if let blockedByUsers = data["blockedByUsers"] as? [String] {
					return blockedByUsers.contains(userId)
				}
			}
		} catch {
			print("Error checking blocked by status: \(error)")
		}
		
		return false
	}
	
	// MARK: - Check if Users are Mutually Blocked (Full Hard Block)
	
	/// Returns true if the two users are blocked from each other (mutual invisibility)
	/// If A blocks B: A has B in blockedUsers, B has A in blockedByUsers
	/// This ensures full invisibility - both users can't see each other
	func areUsersMutuallyBlocked(userId1: String, userId2: String) async -> Bool {
		guard let currentUid = currentUid else { return false }
		
		// Check if current user blocked the other user
		let currentBlockedOther = await isBlocked(userId: userId2)
		
		// Check if other user blocked current user
		let otherBlockedCurrent = await isBlockedBy(userId: userId2)
		
		// Also check the reverse: if we're checking between two arbitrary users
		// (not necessarily the current user), check both directions
		if currentUid != userId1 && currentUid != userId2 {
			// We need to check if userId1 blocked userId2 or vice versa
			// For this, we need to check both users' blockedUsers and blockedByUsers arrays
			do {
				let user1Doc = try await db.collection("users").document(userId1).getDocument()
				let user2Doc = try await db.collection("users").document(userId2).getDocument()
				
				// Check if userId1 blocked userId2
				if let user1Data = user1Doc.data(),
				   let user1Blocked = user1Data["blockedUsers"] as? [String],
				   user1Blocked.contains(userId2) {
					return true
				}
				
				// Check if userId2 blocked userId1
				if let user2Data = user2Doc.data(),
				   let user2Blocked = user2Data["blockedUsers"] as? [String],
				   user2Blocked.contains(userId1) {
					return true
				}
			} catch {
				print("Error checking mutual block status: \(error)")
			}
		}
		
		// For current user checks, return true if either direction is blocked
		return currentBlockedOther || otherBlockedCurrent
	}
}

enum FriendServiceError: LocalizedError {
	case notAuthenticated
	case cannotAddSelf
	case requestAlreadyExists
	case userNotFound
	
	var errorDescription: String? {
		switch self {
		case .notAuthenticated:
			return "You must be logged in to perform this action"
		case .cannotAddSelf:
			return "You cannot add yourself as a friend"
		case .requestAlreadyExists:
			return "Friend request already sent"
		case .userNotFound:
			return "User not found"
		}
	}
}

