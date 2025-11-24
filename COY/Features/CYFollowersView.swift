import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI

struct CYFollowersView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	let collection: CollectionData
	@State private var followers: [FollowerInfo] = []
	@State private var isLoading = false
	@State private var showError = false
	@State private var errorMessage = ""
	
	// Check if current user is owner or admin
	private var canRemoveFollowers: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return collection.ownerId == currentUserId || collection.owners.contains(currentUserId)
	}
	
	var body: some View {
		ZStack {
			(colorScheme == .dark ? Color.black : Color.white)
				.ignoresSafeArea()
			
			VStack(spacing: 0) {
				// Header
				HStack {
					Button(action: { dismiss() }) {
						Image(systemName: "chevron.left")
							.font(.system(size: 18, weight: .medium))
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					.frame(width: 44, height: 44)
					
					Spacer()
					
					Text("Followers")
						.font(.system(size: 18, weight: .bold))
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					Spacer()
					
					Color.clear
						.frame(width: 44, height: 44)
				}
				.padding(.horizontal, 16)
				.padding(.top, 20)
				.padding(.bottom, 10)
				
				if isLoading {
					ProgressView()
						.scaleEffect(1.2)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if followers.isEmpty {
					VStack(spacing: 12) {
						Image(systemName: "person.2")
							.font(.system(size: 42))
							.foregroundColor(.secondary)
						Text("No followers yet")
							.font(.headline)
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					ScrollView {
						LazyVStack(spacing: 0) {
							ForEach(followers) { follower in
								followerRow(follower: follower)
							}
						}
					}
				}
			}
		}
		.navigationBarHidden(true)
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .navigationBar)
		.onAppear {
			loadFollowers()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUnfollowed"))) { notification in
			// Reload followers when someone unfollows (including if removed by owner)
			if let collectionId = notification.object as? String, collectionId == collection.id {
				loadFollowers()
			}
		}
		.alert("Error", isPresented: $showError) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage)
		}
	}
	
	// MARK: - Follower Row
	private func followerRow(follower: FollowerInfo) -> some View {
		HStack(spacing: 12) {
			// Profile Image
			NavigationLink(destination: ViewerProfileView(userId: follower.userId).environmentObject(authService)) {
				if let imageURL = follower.profileImageURL, !imageURL.isEmpty {
					CachedProfileImageView(url: imageURL, size: 50)
				} else {
					DefaultProfileImageView(size: 50)
				}
			}
			.buttonStyle(.plain)
			
			// User Info
			VStack(alignment: .leading, spacing: 2) {
				Text(follower.username)
					.font(.system(size: 16, weight: .bold))
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Text(follower.name)
					.font(.system(size: 14))
					.foregroundColor(.gray)
			}
			
			Spacer()
			
			// Remove button (only for owner/admin)
			if canRemoveFollowers {
				Button(action: {
					Task {
						await removeFollower(userId: follower.userId)
					}
				}) {
					Text("Remove")
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(.red)
						.padding(.horizontal, 16)
						.padding(.vertical, 8)
						.background(Color.red.opacity(0.1))
						.cornerRadius(8)
						.overlay(
							RoundedRectangle(cornerRadius: 8)
								.stroke(Color.red, lineWidth: 1)
						)
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(
			RoundedRectangle(cornerRadius: 12)
				.fill(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
		)
		.padding(.horizontal, 16)
		.padding(.vertical, 4)
	}
	
	// MARK: - Helper Functions
	private func loadFollowers() {
		isLoading = true
		Task {
			do {
				// Get follower IDs from collection directly from Firebase
				let db = Firestore.firestore()
				let collectionDoc = try await db.collection("collections").document(collection.id).getDocument()
				let followerIds = (collectionDoc.data()?["followers"] as? [String]) ?? []
				
				// Load current user's blocked users
				await CYServiceManager.shared.loadCurrentUser()
				let currentUserBlocked = CYServiceManager.shared.getBlockedUsers()
				
				// Load user info for each follower
				var loadedFollowers: [FollowerInfo] = []
				
				for userId in followerIds {
					// Check if user is blocked (mutual block check for full invisibility)
					let isBlocked = await areUsersMutuallyBlocked(userId1: authService.user?.uid ?? "", userId2: userId)
					
					// Filter out blocked users
					if isBlocked {
						continue
					}
					
					do {
						if let user = try await UserService.shared.getUser(userId: userId) {
							loadedFollowers.append(FollowerInfo(
								userId: userId,
								username: user.username,
								name: user.name,
								profileImageURL: user.profileImageURL
							))
						}
					} catch {
						print("⚠️ Failed to load user \(userId): \(error)")
					}
				}
				
				// Sort alphabetically by username
				loadedFollowers.sort { $0.username < $1.username }
				
				await MainActor.run {
					self.followers = loadedFollowers
					self.isLoading = false
				}
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
					showError = true
					isLoading = false
				}
			}
		}
	}
	
	private func removeFollower(userId: String) async {
		guard let currentUserId = authService.user?.uid else { return }
		
		do {
			print("👤 CYFollowersView: Removing follower \(userId) from collection \(collection.id)")
			
			// Remove follower directly from Firebase
			let db = Firestore.firestore()
			let collectionRef = db.collection("collections").document(collection.id)
			
			// Remove from followers array and decrement followerCount
			try await collectionRef.updateData([
				"followers": FieldValue.arrayRemove([userId]),
				"followerCount": FieldValue.increment(Int64(-1))
			])
			
			print("✅ CYFollowersView: Follower removed successfully")
			
			// Reload followers to update the list
			loadFollowers()
		} catch {
			print("❌ CYFollowersView: Error removing follower: \(error)")
			await MainActor.run {
				errorMessage = error.localizedDescription
				showError = true
			}
		}
	}
	
	// MARK: - Helper Functions
	private func areUsersMutuallyBlocked(userId1: String, userId2: String) async -> Bool {
		// Load both users' blocked lists
		let db = Firestore.firestore()
		
		do {
			let user1Doc = try await db.collection("users").document(userId1).getDocument()
			let user2Doc = try await db.collection("users").document(userId2).getDocument()
			
			let user1Blocked = (user1Doc.data()?["blockedUsers"] as? [String]) ?? []
			let user2Blocked = (user2Doc.data()?["blockedUsers"] as? [String]) ?? []
			
			// Check if either user has blocked the other
			return user1Blocked.contains(userId2) || user2Blocked.contains(userId1)
		} catch {
			print("⚠️ Error checking mutual block status: \(error)")
			return false
		}
	}
}

// MARK: - Follower Info
struct FollowerInfo: Identifiable {
	var id: String { userId }
	let userId: String
	let username: String
	let name: String
	let profileImageURL: String?
}

