import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct JoinedUser: Identifiable {
	let id: String
	let userId: String
	let username: String
	let name: String
	let profileImageURL: String?
}

struct JoinedUsersView: View {
	let notification: NotificationService.AppNotification
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var authService: AuthService
	
	@State private var joinedUsers: [JoinedUser] = []
	@State private var isLoading = true
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				Group {
				if isLoading {
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if joinedUsers.isEmpty {
					VStack(spacing: 12) {
						Image(systemName: "person.2")
							.font(.system(size: 48))
							.foregroundColor(.secondary)
						Text("No users found")
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					ScrollView {
						LazyVStack(spacing: 12) {
							ForEach(joinedUsers) { user in
								HStack(spacing: 12) {
									// Profile Image
									if let profileImageURL = user.profileImageURL, !profileImageURL.isEmpty {
										CachedProfileImageView(url: profileImageURL, size: 50)
											.clipShape(Circle())
									} else {
										DefaultProfileImageView(size: 50)
									}
									
									// User Info
									VStack(alignment: .leading, spacing: 4) {
										Text(user.name)
											.font(.subheadline)
											.fontWeight(.semibold)
											.foregroundColor(.primary)
										Text("@\(user.username)")
											.font(.caption)
											.foregroundColor(.secondary)
									}
									
									Spacer()
									
									// Remove Button
									Button(action: {
										removeUser(userId: user.userId)
									}) {
										Text("Remove")
											.font(.system(size: 14, weight: .semibold))
											.foregroundColor(.white)
											.padding(.horizontal, 16)
											.padding(.vertical, 8)
											.background(Color.red)
											.cornerRadius(8)
									}
									.buttonStyle(.plain)
								}
								.padding(.horizontal, 16)
								.padding(.vertical, 12)
								.background(Color(.systemBackground))
								.cornerRadius(12)
								.shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
							}
						}
						.padding(.vertical, 8)
					}
				}
			}
				}
			.navigationTitle(notification.collectionName ?? "Joined Users")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
			.onAppear {
				loadUsers()
			}
		}
	}
	
	private func loadUsers() {
		guard let joinedUsersData = notification.joinedUsers else {
			isLoading = false
			return
		}
		
		var users: [JoinedUser] = []
		for userData in joinedUsersData {
			guard let userId = userData["userId"] as? String ?? userData["uid"] as? String,
				  let username = userData["username"] as? String else {
				continue
			}
			
			let name = userData["name"] as? String ?? username
			let profileImageURL = userData["profileImageURL"] as? String
			
			users.append(JoinedUser(
				id: userId,
				userId: userId,
				username: username,
				name: name,
				profileImageURL: profileImageURL
			))
		}
		
		joinedUsers = users
		isLoading = false
	}
	
	private func removeUser(userId: String) {
		guard let collectionId = notification.collectionId else {
			return
		}
		
		Task {
			do {
				try await CollectionService.shared.removeUserFromCollection(
					collectionId: collectionId,
					userIdToRemove: userId
				)
				
				// Remove from local list
				joinedUsers.removeAll { $0.userId == userId }
				
				// If no users left, dismiss
				if joinedUsers.isEmpty {
					dismiss()
				}
			} catch {
				print("Error removing user: \(error)")
			}
		}
	}
}
