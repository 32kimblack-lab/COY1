import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct AddFriendsScreen: View {
	private let friendService = FriendService.shared
	private let userService = UserService.shared
	@State private var incomingRequests: [FriendRequestModel] = []
	@State private var searchText = ""
	@State private var allUsers: [UserService.AppUser] = []
	@State private var isLoading = false
	@State private var isLoadingUsers = false
	@State private var isLoadingMoreUsers = false
	@State private var outgoingRequestIds: Set<String> = []
	@State private var displayedUsersCount = 15
	@State private var showAllAddedYou = false
	@State private var lastDocumentSnapshot: DocumentSnapshot?
	@State private var hasMoreUsers = true
	@State private var incomingRequestsListener: ListenerRegistration? // Real-time incoming requests listener
	@State private var outgoingRequestsListener: ListenerRegistration? // Real-time outgoing requests listener
	@Environment(\.dismiss) var dismiss
	
	var displayedAddedYou: [FriendRequestModel] {
		// Filter out requests from blocked users (mutual blocking)
		// This will be checked async, but we filter here for immediate UI update
		let filtered = incomingRequests // Will be filtered in real-time via notifications
		if showAllAddedYou {
			return filtered
		}
		return Array(filtered.prefix(5))
	}
	
	var filteredUsers: [UserService.AppUser] {
		// Filter out users who are in "Added you" section
		let incomingRequestUids = Set(incomingRequests.map { $0.fromUid })
		
		let users = allUsers.filter { user in
			// Exclude users who have sent friend requests to current user
			!incomingRequestUids.contains(user.userId)
		}
		
		// Additional filtering happens in loadAllUsers via mutual blocking check
		// This computed property just handles search and display count
		
		if searchText.isEmpty {
			return Array(users.prefix(displayedUsersCount))
		}
		let lowercaseSearch = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		let filtered = users.filter { user in
			user.username.lowercased().contains(lowercaseSearch) ||
			user.name.lowercased().contains(lowercaseSearch)
		}
		return Array(filtered.prefix(displayedUsersCount))
	}
	
	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				// Search bar at the top
				HStack {
					Image(systemName: "magnifyingglass")
						.foregroundColor(.gray)
					TextField("Search by username or name...", text: $searchText)
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.background(Color(.systemGray6))
				.cornerRadius(10)
				.padding(.horizontal)
				.padding(.top, 8)
				.padding(.bottom, 16)
				
				// "Added You" section - below search
				if !incomingRequests.isEmpty {
					VStack(alignment: .leading, spacing: 8) {
						Text("Added You")
							.font(.headline)
							.padding(.horizontal)
						
						ForEach(displayedAddedYou) { request in
							AddedYouTile(request: request)
						}
						
						// Show more button if there are more than 5 requests
						if incomingRequests.count > 5 && !showAllAddedYou {
							Button(action: {
								showAllAddedYou = true
							}) {
								Text("Show more")
									.font(.system(size: 14, weight: .semibold))
									.foregroundColor(.blue)
									.frame(maxWidth: .infinity)
									.padding(.vertical, 8)
							}
							.padding(.horizontal)
						}
					}
					.padding(.bottom, 16)
					}
					
				// "Add Users" heading above user list - aligned with "Added You"
				VStack(alignment: .leading, spacing: 8) {
					Text("Add Users")
						.font(.headline)
						.padding(.horizontal)
						}
				.padding(.bottom, 8)
				
				// User list section - always present to maintain layout
				if isLoadingUsers {
					Spacer()
					ProgressView()
					Spacer()
				} else {
					List {
						if !filteredUsers.isEmpty {
							ForEach(filteredUsers) { user in
								UserSearchRow(user: user, outgoingRequestIds: $outgoingRequestIds)
									.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
									.listRowBackground(Color.clear)
									.onAppear {
										// Load more when reaching near the end
										if let index = filteredUsers.firstIndex(where: { $0.userId == user.userId }),
										   index >= filteredUsers.count - 3 {
											if searchText.isEmpty {
												// When not searching, load more from Firestore
												if hasMoreUsers && !isLoadingMoreUsers {
													loadMoreUsers()
												}
											} else {
												// When searching, just show more from filtered list
												if displayedUsersCount < allUsers.count {
													displayedUsersCount += 15
												}
											}
										}
									}
							}
							
							// Loading indicator at bottom when loading more
							if isLoadingMoreUsers {
								HStack {
									Spacer()
									ProgressView()
										.padding()
									Spacer()
								}
								.listRowInsets(EdgeInsets())
								.listRowBackground(Color.clear)
							}
						} else if !searchText.isEmpty {
							Text("No users found")
								.foregroundColor(.secondary)
								.padding()
								.listRowInsets(EdgeInsets())
								.listRowBackground(Color.clear)
						} else {
							Text("No users available")
								.foregroundColor(.secondary)
								.padding()
								.listRowInsets(EdgeInsets())
								.listRowBackground(Color.clear)
						}
					}
					.listStyle(PlainListStyle())
					.scrollContentBackground(.hidden)
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar(.hidden, for: .tabBar)
			.onAppear {
				loadIncomingRequests()
				loadOutgoingRequests()
				loadAllUsers()
				setupFriendRequestListeners()
				// Update friend request count on appear
				updateFriendRequestCount()
				// Note: We don't mark requests as seen here anymore
				// The badge count should show ALL pending requests until they're accepted/denied
				// markFriendRequestsAsSeen() // REMOVED - count should persist
			}
			.onDisappear {
				incomingRequestsListener?.remove()
				outgoingRequestsListener?.remove()
			}
			.onChange(of: incomingRequests) { _, _ in
				// Reload users when incoming requests change to filter them out
				loadAllUsers()
			}
			.onChange(of: searchText) { _, _ in
				// Reset displayed count when search changes
				displayedUsersCount = 15
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestDenied"))) { notification in
				// Remove denied request from list
				if let deniedUid = notification.object as? String {
					incomingRequests.removeAll { $0.fromUid == deniedUid }
					loadAllUsers() // Refresh to show user in search list again
					// Update friend request count
					updateFriendRequestCount()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestAccepted"))) { notification in
				// Remove accepted request from list
				if let acceptedUid = notification.object as? String {
					incomingRequests.removeAll { $0.fromUid == acceptedUid }
					loadAllUsers() // Refresh to filter out accepted friend
					// Update friend request count
					updateFriendRequestCount()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { notification in
				// Immediately filter out blocked user from Add Users list
				if let blockedUserId = notification.userInfo?["blockedUserId"] as? String {
					Task {
						await MainActor.run {
							// Remove blocked user from list immediately
							allUsers.removeAll { $0.userId == blockedUserId }
							// Also remove from incoming requests if they sent one
							incomingRequests.removeAll { $0.fromUid == blockedUserId }
							print("🚫 AddFriendsScreen: Removed blocked user '\(blockedUserId)' from list")
						}
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { notification in
				// Reload users when someone is unblocked
				if let unblockedUserId = notification.userInfo?["unblockedUserId"] as? String {
					print("✅ AddFriendsScreen: User '\(unblockedUserId)' was unblocked, reloading users")
					loadAllUsers()
				}
			}
		}
	}
	
	// MARK: - Real-time Friend Request Listeners
	private func setupFriendRequestListeners() {
		guard let currentUid = Auth.auth().currentUser?.uid else { return }
		let db = Firestore.firestore()
		
		// Remove existing listeners
		incomingRequestsListener?.remove()
		outgoingRequestsListener?.remove()
		
		// Listen to incoming friend requests
		incomingRequestsListener = db.collection("friend_requests")
			.whereField("toUid", isEqualTo: currentUid)
			.whereField("status", isEqualTo: "pending")
			.addSnapshotListener { [self] snapshot, error in
				if let error = error {
					print("❌ AddFriendsScreen: Incoming requests listener error: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot else { return }
				
				// Handle document changes
				for change in snapshot.documentChanges {
					let doc = change.document
					let data = doc.data()
					
					if change.type == .removed {
						// Request was deleted (denied or cancelled)
						let deletedRequestId = doc.documentID
						Task { @MainActor in
							self.incomingRequests.removeAll { $0.id == deletedRequestId }
							// Reload users to show them in search list again
							self.loadAllUsers()
							// Update friend request count
							self.updateFriendRequestCount()
							print("🗑️ AddFriendsScreen: Removed deleted incoming request \(deletedRequestId)")
						}
					} else if change.type == .added {
						// New incoming request
						// Note: FriendRequestModel(document:) expects QueryDocumentSnapshot, but we have DocumentSnapshot
						// Convert DocumentSnapshot to QueryDocumentSnapshot-compatible data
						guard let fromUid = data["fromUid"] as? String,
							  let toUid = data["toUid"] as? String,
							  let timestamp = data["createdAt"] as? Timestamp else {
							print("❌ AddFriendsScreen: Failed to parse incoming request from document")
							continue
						}
						
						let request = FriendRequestModel(
							id: doc.documentID,
							fromUid: fromUid,
							toUid: toUid,
							createdAt: timestamp.dateValue(),
							status: data["status"] as? String ?? "pending"
						)
						
						Task {
							// Check mutual blocking before adding request
							let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: fromUid)
							if !areMutuallyBlocked {
								await MainActor.run {
							if !self.incomingRequests.contains(where: { $0.id == request.id }) {
								self.incomingRequests.append(request)
								// Reload users to filter out user who sent request
								self.loadAllUsers()
								// Update friend request count
								self.updateFriendRequestCount()
								print("✅ AddFriendsScreen: Added new incoming request from \(request.fromUid)")
									}
								}
							} else {
								print("🚫 AddFriendsScreen: Ignoring request from blocked user \(fromUid)")
							}
						}
					} else if change.type == .modified {
						// Request status changed (e.g., accepted)
						if let status = data["status"] as? String, status != "pending" {
							let modifiedRequestId = doc.documentID
							Task { @MainActor in
								self.incomingRequests.removeAll { $0.id == modifiedRequestId }
								// Reload users
								self.loadAllUsers()
								// Update friend request count
								self.updateFriendRequestCount()
								print("🔄 AddFriendsScreen: Request \(modifiedRequestId) status changed to \(status)")
							}
						}
					}
				}
				
				// Update count whenever the snapshot changes (new requests added or removed)
				Task { @MainActor in
					self.updateFriendRequestCount()
				}
			}
		
		// Listen to outgoing friend requests
		outgoingRequestsListener = db.collection("friend_requests")
			.whereField("fromUid", isEqualTo: currentUid)
			.addSnapshotListener { [self] snapshot, error in
				if let error = error {
					print("❌ AddFriendsScreen: Outgoing requests listener error: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot else { return }
				
				// Handle document changes
				for change in snapshot.documentChanges {
					let doc = change.document
					let data = doc.data()
					
					if change.type == .removed {
						// Request was deleted (cancelled or denied)
						if let toUid = data["toUid"] as? String {
							Task { @MainActor in
								self.outgoingRequestIds.remove(toUid)
								print("🗑️ AddFriendsScreen: Removed deleted outgoing request to \(toUid)")
							}
						}
					} else if change.type == .added || change.type == .modified {
						// New or updated outgoing request
						if let toUid = data["toUid"] as? String,
						   let status = data["status"] as? String {
							Task { @MainActor in
								if status == "pending" {
									self.outgoingRequestIds.insert(toUid)
								} else {
									self.outgoingRequestIds.remove(toUid)
								}
								print("🔄 AddFriendsScreen: Outgoing request to \(toUid) status: \(status)")
							}
						}
				}
			}
		}
	}
	
	private func loadIncomingRequests() {
		Task {
			do {
				let requests = try await friendService.getIncomingFriendRequests()
				// Filter out requests from blocked users (mutual blocking)
				var filteredRequests: [FriendRequestModel] = []
				for request in requests {
					let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: request.fromUid)
					if !areMutuallyBlocked {
						filteredRequests.append(request)
					}
				}
				await MainActor.run {
					self.incomingRequests = filteredRequests
				}
			} catch {
				print("Error loading incoming requests: \(error)")
			}
		}
	}
	
	private func markFriendRequestsAsSeen() {
		Task {
			do {
				try await friendService.markFriendRequestsAsSeen()
			} catch {
				print("Error marking friend requests as seen: \(error)")
			}
		}
	}
	
	// MARK: - Update Friend Request Count
	/// Update the friend request count badge based on total pending requests
	private func updateFriendRequestCount() {
		Task {
			do {
				let count = try await friendService.getTotalPendingFriendRequestCount()
				await MainActor.run {
					NotificationCenter.default.post(
						name: NSNotification.Name("FriendRequestCountChanged"),
						object: nil,
						userInfo: ["count": count]
					)
				}
			} catch {
				print("Error updating friend request count: \(error)")
			}
		}
	}
	
	private func loadOutgoingRequests() {
		Task {
			do {
				let requests = try await friendService.getOutgoingFriendRequests()
				await MainActor.run {
					self.outgoingRequestIds = Set(requests.map { $0.toUid })
				}
			} catch {
				print("Error loading outgoing requests: \(error)")
			}
		}
	}
	
	private func loadAllUsers() {
		guard !isLoadingUsers else { return }
		
		isLoadingUsers = true
		displayedUsersCount = 15
		lastDocumentSnapshot = nil
		hasMoreUsers = true
		
		Task {
			do {
				guard let currentUid = Auth.auth().currentUser?.uid else {
					await MainActor.run {
						self.isLoadingUsers = false
					}
					return
				}
				
				// Load first batch of users from Firestore
				let db = Firestore.firestore()
				let query = db.collection("users")
					.order(by: "username")
					.limit(to: 50) // Load 50 at a time for better performance
				
				let snapshot = try await query.getDocuments()
				
				var users: [UserService.AppUser] = []
				for doc in snapshot.documents {
					let data = doc.data()
					// Filter out current user
					guard doc.documentID != currentUid else {
						continue
					}
					
					// Check if mutually blocked (mutual block check for full invisibility)
					let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: doc.documentID)
					
					// Check if already friends
					let isFriend = await friendService.isFriend(userId: doc.documentID)
					
					// Check if there's a one-way un-add relationship
					// One-way un-adds should NOT appear in Add User list (they can only be re-added from message screen)
					// Only both-way un-adds (bothUnadded) should appear in Add User list
					let hasOneWayUnadd = await friendService.hasOneWayUnadd(userId: doc.documentID)
					
					// Only include users who are:
					// - Not mutually blocked (either direction)
					// - Not currently friends
					// - Not in a one-way un-add relationship (both-way un-adds ARE allowed in Add User list)
					// - Not in incoming requests (handled in filteredUsers)
					if !areMutuallyBlocked && !isFriend && !hasOneWayUnadd {
						let user = UserService.AppUser(
							userId: doc.documentID,
							name: data["name"] as? String ?? "",
							username: data["username"] as? String ?? "",
							profileImageURL: data["profileImageURL"] as? String,
							backgroundImageURL: data["backgroundImageURL"] as? String,
							birthMonth: data["birthMonth"] as? String ?? "",
							birthDay: data["birthDay"] as? String ?? "",
							birthYear: data["birthYear"] as? String ?? "",
							email: data["email"] as? String ?? ""
						)
						users.append(user)
					}
				}
				
				// Sort by username alphabetically
				users.sort { $0.username.lowercased() < $1.username.lowercased() }
				
				// Store last document for pagination
				let lastDoc = snapshot.documents.last
				
				await MainActor.run {
					self.allUsers = users
					self.lastDocumentSnapshot = lastDoc
					self.hasMoreUsers = snapshot.documents.count == 50 // If we got 50, there might be more
					self.isLoadingUsers = false
					print("✅ Loaded \(users.count) users for Add Users section")
				}
			} catch {
				print("❌ Error loading users: \(error)")
				await MainActor.run {
					self.isLoadingUsers = false
				}
			}
		}
	}
	
	private func loadMoreUsers() {
		guard !isLoadingMoreUsers, hasMoreUsers, let lastDoc = lastDocumentSnapshot else { return }
		
		isLoadingMoreUsers = true
		
		Task {
			do {
				guard let currentUid = Auth.auth().currentUser?.uid else {
					await MainActor.run {
						self.isLoadingMoreUsers = false
					}
					return
				}
				
				let db = Firestore.firestore()
				let query = db.collection("users")
					.order(by: "username")
					.start(afterDocument: lastDoc)
					.limit(to: 50)
				
				let snapshot = try await query.getDocuments()
				
				var users: [UserService.AppUser] = []
				for doc in snapshot.documents {
					let data = doc.data()
					guard doc.documentID != currentUid else { continue }
					
					// Check if blocked (mutual block check for full invisibility)
					let isBlocked = await friendService.isBlocked(userId: doc.documentID)
					let isBlockedBy = await friendService.isBlockedBy(userId: doc.documentID)
					let isFriend = await friendService.isFriend(userId: doc.documentID)
					
					// Check if there's a one-way un-add relationship
					// One-way un-adds should NOT appear in Add User list (they can only be re-added from message screen)
					// Only both-way un-adds (bothUnadded) should appear in Add User list
					let hasOneWayUnadd = await friendService.hasOneWayUnadd(userId: doc.documentID)
					
					// Only include users who are:
					// - Not mutually blocked
					// - Not currently friends
					// - Not in a one-way un-add relationship (both-way un-adds ARE allowed in Add User list)
					// - Not in incoming requests
					if !isBlocked && !isBlockedBy && !isFriend && !hasOneWayUnadd {
						let user = UserService.AppUser(
							userId: doc.documentID,
							name: data["name"] as? String ?? "",
							username: data["username"] as? String ?? "",
							profileImageURL: data["profileImageURL"] as? String,
							backgroundImageURL: data["backgroundImageURL"] as? String,
							birthMonth: data["birthMonth"] as? String ?? "",
							birthDay: data["birthDay"] as? String ?? "",
							birthYear: data["birthYear"] as? String ?? "",
							email: data["email"] as? String ?? ""
						)
						users.append(user)
					}
				}
				
				users.sort { $0.username.lowercased() < $1.username.lowercased() }
				
				let newLastDoc = snapshot.documents.last
				
				await MainActor.run {
					self.allUsers.append(contentsOf: users)
					self.lastDocumentSnapshot = newLastDoc
					self.hasMoreUsers = snapshot.documents.count == 50
					self.displayedUsersCount += 15
					self.isLoadingMoreUsers = false
				}
			} catch {
				print("Error loading more users: \(error)")
				await MainActor.run {
					self.isLoadingMoreUsers = false
					self.hasMoreUsers = false
				}
			}
		}
	}
}

struct AddedYouTile: View {
	let request: FriendRequestModel
	private let friendService = FriendService.shared
	private let userService = UserService.shared
	@State private var user: UserService.AppUser?
	@State private var isLoading = true
	@State private var showProfile = false
	
	// Consistent sizing system (scaled for iPad)
	private var isIPad: Bool {
		UIDevice.current.userInterfaceIdiom == .pad
	}
	private var scaleFactor: CGFloat {
		isIPad ? 1.6 : 1.0
	}
	
	var body: some View {
		HStack(spacing: 12 * scaleFactor) {
			Button(action: {
				if user != nil {
					showProfile = true
				}
			}) {
			if let user = user {
				CachedProfileImageView(url: user.profileImageURL ?? "", size: 50 * scaleFactor)
			} else {
				DefaultProfileImageView(size: 50 * scaleFactor)
			}
			}
			.buttonStyle(.plain)
			.disabled(user == nil)
			
			Button(action: {
				if user != nil {
					showProfile = true
				}
			}) {
			VStack(alignment: .leading, spacing: 4 * scaleFactor) {
				Text(user?.username ?? "Loading...")
					.font(.system(size: 16 * scaleFactor, weight: .semibold))
						.foregroundColor(.primary)
				Text(user?.name ?? "")
					.font(.system(size: 14 * scaleFactor))
					.foregroundColor(.secondary)
			}
			}
			.buttonStyle(.plain)
			.disabled(user == nil)
			
			Spacer()
			
			HStack(spacing: 8 * scaleFactor) {
				Button(action: {
					acceptRequest()
				}) {
					Text("Accept")
						.font(.system(size: 14 * scaleFactor, weight: .semibold))
						.foregroundColor(.white)
						.padding(.horizontal, 16 * scaleFactor)
						.padding(.vertical, 8 * scaleFactor)
						.background(Color.blue)
						.cornerRadius(8 * scaleFactor)
				}
				
				Button(action: {
					denyRequest()
				}) {
					Text("Deny")
						.font(.system(size: 14 * scaleFactor, weight: .semibold))
						.foregroundColor(.primary)
						.padding(.horizontal, 16 * scaleFactor)
						.padding(.vertical, 8 * scaleFactor)
						.background(Color(.systemGray5))
						.cornerRadius(8 * scaleFactor)
				}
			}
		}
		.padding(.vertical, 4 * scaleFactor)
		.onAppear {
			loadUser()
		}
		.navigationDestination(isPresented: $showProfile) {
			if let user = user {
				ViewerProfileView(userId: user.userId)
			}
		}
	}
	
	private func loadUser() {
		Task {
			do {
				// Check mutual blocking before loading user
				let areMutuallyBlocked = await CYServiceManager.shared.areUsersMutuallyBlocked(userId: request.fromUid)
				if areMutuallyBlocked {
					await MainActor.run {
						self.user = nil
						self.isLoading = false
					}
					return
				}
				
				let user = try await userService.getUser(userId: request.fromUid)
				await MainActor.run {
					self.user = user
					self.isLoading = false
				}
			} catch {
				print("Error loading user: \(error)")
				await MainActor.run {
					self.isLoading = false
				}
			}
		}
	}
	
	private func acceptRequest() {
		Task {
			do {
				try await friendService.acceptRequest(fromUid: request.fromUid)
				// Remove from incoming requests list and refresh user list
				await MainActor.run {
					NotificationCenter.default.post(name: NSNotification.Name("FriendRequestAccepted"), object: request.fromUid)
				}
			} catch {
				print("Error accepting request: \(error)")
			}
		}
	}
	
	private func denyRequest() {
		Task {
			do {
				try await friendService.denyRequest(fromUid: request.fromUid)
				// Remove from incoming requests list
				await MainActor.run {
					NotificationCenter.default.post(name: NSNotification.Name("FriendRequestDenied"), object: request.fromUid)
				}
			} catch {
				print("Error denying request: \(error)")
			}
		}
	}
}

struct UserSearchRow: View {
	let user: UserService.AppUser
	@Binding var outgoingRequestIds: Set<String>
	private let friendService = FriendService.shared
	@State private var requestStatus: RequestStatus = .none
	@State private var showProfile = false
	
	// Consistent sizing system (scaled for iPad)
	private var isIPad: Bool {
		UIDevice.current.userInterfaceIdiom == .pad
	}
	private var scaleFactor: CGFloat {
		isIPad ? 1.6 : 1.0
	}
	
	enum RequestStatus {
		case none, pending, friends
	}
	
	var body: some View {
		HStack(spacing: 12 * scaleFactor) {
			Button(action: {
				showProfile = true
			}) {
			CachedProfileImageView(url: user.profileImageURL ?? "", size: 50 * scaleFactor)
			}
			.buttonStyle(.plain)
			
			Button(action: {
				showProfile = true
			}) {
			VStack(alignment: .leading, spacing: 4 * scaleFactor) {
				Text(user.username)
					.font(.system(size: 16 * scaleFactor, weight: .semibold))
						.foregroundColor(.primary)
				Text(user.name)
					.font(.system(size: 14 * scaleFactor))
					.foregroundColor(.secondary)
			}
			}
			.buttonStyle(.plain)
			
			Spacer()
			
			if requestStatus == .pending || outgoingRequestIds.contains(user.userId) {
				Button(action: {
					Task {
						await undoRequest()
					}
				}) {
				Text("Pending")
					.font(.system(size: 14 * scaleFactor))
					.foregroundColor(.secondary)
					.padding(.horizontal, 12 * scaleFactor)
					.padding(.vertical, 6 * scaleFactor)
						.background(Color(.systemGray6))
					.cornerRadius(8)
				}
				.buttonStyle(.plain)
			} else if requestStatus == .friends {
				Text("Friends")
					.font(.system(size: 14 * scaleFactor))
					.foregroundColor(.secondary)
			} else {
				Button(action: {
					print("🔵 Add button tapped for user: \(user.userId)")
					Task {
						await sendRequest()
					}
				}) {
					Text("Add")
						.font(.system(size: 14 * scaleFactor, weight: .semibold))
						.foregroundColor(.blue)
						.padding(.horizontal, 16 * scaleFactor)
						.padding(.vertical, 8 * scaleFactor)
						.background(Color.blue.opacity(0.1))
						.cornerRadius(8 * scaleFactor)
				}
				.buttonStyle(.plain)
				.contentShape(Rectangle())
			}
		}
		.padding(.vertical, 4 * scaleFactor)
		.onAppear {
			checkStatus()
		}
		.navigationDestination(isPresented: $showProfile) {
			ViewerProfileView(userId: user.userId)
		}
	}
	
	private func checkStatus() {
		Task {
			let isFriend = await friendService.isFriend(userId: user.userId)
			await MainActor.run {
				if isFriend {
					requestStatus = .friends
				} else if outgoingRequestIds.contains(user.userId) {
					requestStatus = .pending
				}
			}
		}
	}
	
	private func sendRequest() async {
		print("📤 sendRequest() called for user: \(user.userId)")
		
			// Check if this is a one-way un-add scenario where we can restore friendship directly
			let canRestore = await friendService.canRestoreFriendship(userId: user.userId)
		print("🔄 canRestore: \(canRestore)")
			
			if canRestore {
				// One-way un-add: restore friendship immediately (no friend request needed)
				do {
				print("🔄 Attempting to restore friendship...")
					try await friendService.restoreFriendship(userId: user.userId)
					await MainActor.run {
					print("✅ Friendship restored successfully")
						requestStatus = .friends
						// Remove from outgoing requests if it was there
						outgoingRequestIds.remove(user.userId)
					}
				} catch {
				print("❌ Error restoring friendship: \(error.localizedDescription)")
				}
			} else {
				// Both-way un-add or new friend: send friend request
				do {
				print("📨 Attempting to send friend request...")
					try await friendService.sendFriendRequest(toUid: user.userId)
					await MainActor.run {
					print("✅ Friend request sent successfully")
						requestStatus = .pending
						outgoingRequestIds.insert(user.userId)
					}
				} catch {
				print("❌ Error sending request: \(error.localizedDescription)")
					// If it's a requestAlreadyExists error, check if we can restore instead
					// This handles edge cases where an old request exists but it's actually a one-way un-add
					if error.localizedDescription.contains("request already sent") || 
					   error.localizedDescription.contains("requestAlreadyExists") {
					print("🔄 Request already exists, checking if we can restore...")
							let canRestoreNow = await friendService.canRestoreFriendship(userId: user.userId)
							if canRestoreNow {
								do {
									try await friendService.restoreFriendship(userId: user.userId)
									await MainActor.run {
										requestStatus = .friends
										outgoingRequestIds.remove(user.userId)
									}
								} catch {
							print("❌ Error restoring friendship after request exists: \(error.localizedDescription)")
						}
					}
				}
			}
		}
	}
	
	private func undoRequest() async {
			do {
				// Cancel the outgoing friend request by deleting it
				guard let currentUid = Auth.auth().currentUser?.uid else { return }
				let requestId = "\(currentUid)_\(user.userId)"
				let db = Firestore.firestore()
				try await db.collection("friend_requests").document(requestId).delete()
				
				await MainActor.run {
					requestStatus = .none
					outgoingRequestIds.remove(user.userId)
				}
			} catch {
				print("Error undoing request: \(error)")
		}
	}
}

