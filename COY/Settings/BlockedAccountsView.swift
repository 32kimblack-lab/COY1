import SwiftUI
import Combine
import FirebaseFirestore

struct BlockedAccountsView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@StateObject private var viewModel = BlockedAccountsViewModel()
	
	var body: some View {
		PhoneSizeContainer {
			VStack(spacing: 0) {
			// Header
			HStack {
				Button(action: { presentationMode.wrappedValue.dismiss() }) {
					Image(systemName: "chevron.backward")
						.font(.title2)
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
				Spacer()
				Text("Blocked Accounts")
					.font(.title2)
					.fontWeight(.bold)
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Spacer()
				// Refresh button
				Button(action: {
					Task {
						await viewModel.loadBlockedUsers()
					}
				}) {
					Image(systemName: "arrow.clockwise")
						.font(.title2)
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
			}
			.padding(.top, 10)
			.padding(.horizontal)
			
			if viewModel.isLoading {
				Spacer()
				ProgressView("Loading blocked users...")
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Spacer()
			} else if viewModel.blockedUsers.isEmpty {
				Spacer()
				VStack(spacing: 16) {
					Image(systemName: "hand.raised.slash")
						.resizable()
						.scaledToFit()
						.frame(width: 100, height: 100)
						.foregroundColor(.gray)
					Text("No Blocked Users")
						.font(.headline)
						.foregroundColor(.gray)
					Text("Users you block will appear here.")
						.font(.subheadline)
						.foregroundColor(.gray)
						.multilineTextAlignment(.center)
				}
				Spacer()
			} else {
				List {
					ForEach(viewModel.blockedUsers, id: \.id) { user in
						BlockedUserRow(user: user) {
							Task {
								await viewModel.unblockUser(user)
							}
						}
						.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
						.listRowBackground(Color.clear)
						.listRowSeparator(.hidden)
					}
				}
				.listStyle(PlainListStyle())
			}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
		.onAppear {
			Task {
				await viewModel.loadBlockedUsers()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { _ in
			// Refresh blocked users list when a user is blocked
			print("🔄 BlockedAccountsView: User blocked, refreshing list")
			Task {
				await viewModel.loadBlockedUsers()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { _ in
			// Refresh blocked users list when a user is unblocked
			print("🔄 BlockedAccountsView: User unblocked, refreshing list")
			Task {
				await viewModel.loadBlockedUsers()
			}
		}
	}
}

// MARK: - Blocked User Row

struct BlockedUserRow: View {
	let user: CYUser
	let onUnblock: () -> Void
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		HStack(spacing: 12) {
			// User profile image
			if !user.profileImageURL.isEmpty {
				CachedProfileImageView(url: user.profileImageURL, size: 60)
					.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 60)
			}
			
			// User info
			VStack(alignment: .leading, spacing: 4) {
				Text("@\(user.username)")
					.font(.headline)
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Text(user.name)
					.font(.subheadline)
					.foregroundColor(.gray)
			}
			
			Spacer()
			
			// Unblock button
			Button(action: {
				print("🔘 Unblock button tapped for user: @\(user.username)")
				onUnblock()
			}) {
				Text("Unblock")
					.font(.subheadline)
					.fontWeight(.semibold)
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 8)
					.background(Color.blue)
					.cornerRadius(8)
			}
			.buttonStyle(PlainButtonStyle())
			.contentShape(Rectangle())
		}
		.padding()
		.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
		.cornerRadius(12)
	}
}

class BlockedAccountsViewModel: ObservableObject {
	@Published var blockedUsers: [CYUser] = []
	@Published var isLoading = false
	
	@MainActor
	func loadBlockedUsers() async {
		isLoading = true
		
		do {
			// Get the blocked users list from the already-loaded current user
			// Don't reload from Firestore to avoid stale data issues
			let blockedUserIds = CYServiceManager.shared.getBlockedUsers()
			print("📋 Found \(blockedUserIds.count) blocked user IDs: \(blockedUserIds)")
			
			// If no current user is loaded yet, load it once
			if blockedUserIds.isEmpty && CYServiceManager.shared.currentUser == nil {
				print("🔄 No current user loaded, loading from Firestore...")
				try await CYServiceManager.shared.loadCurrentUser()
				let newBlockedUserIds = CYServiceManager.shared.getBlockedUsers()
				print("📋 After loading current user, found \(newBlockedUserIds.count) blocked user IDs")
			}
			
			// Get the fresh list after potential reload
			let finalBlockedUserIds = CYServiceManager.shared.getBlockedUsers()
			var users: [CYUser] = []
			
			for userId in finalBlockedUserIds {
				do {
					// Fetch user data from Firestore
					let userDoc = try await Firestore.firestore().collection("users").document(userId).getDocument()
					if let userData = userDoc.data() {
						let user = CYUser(
							id: userId,
							name: userData["name"] as? String ?? "",
							username: userData["username"] as? String ?? "",
							profileImageURL: userData["profileImageURL"] as? String ?? ""
						)
						users.append(user)
						print("✅ Loaded blocked user: @\(user.username)")
					}
				} catch {
					print("❌ Failed to fetch blocked user \(userId): \(error)")
				}
			}
			
			self.blockedUsers = users
			print("✅ Total blocked users loaded: \(users.count)")
		} catch {
			print("❌ Error loading blocked users: \(error)")
		}
		
		isLoading = false
	}
	
	@MainActor
	func unblockUser(_ user: CYUser) async {
		let userId = user.id
		print("🔓 BlockedAccountsViewModel: Unblocking user @\(user.username) (ID: \(userId))")
		
		do {
			try await CYServiceManager.shared.unblockUser(userId: userId)
			print("✅ BlockedAccountsViewModel: Successfully unblocked user, removing from list")
			blockedUsers.removeAll { $0.id == userId }
			print("✅ BlockedAccountsViewModel: Blocked users count: \(blockedUsers.count)")
		} catch {
			print("❌ BlockedAccountsViewModel: Error unblocking user: \(error)")
		}
	}
}

