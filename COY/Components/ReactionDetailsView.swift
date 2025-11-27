import SwiftUI
import SDWebImageSwiftUI
import FirebaseAuth

struct ReactionDetailsView: View {
	let message: MessageModel
	let emoji: String
	var onRemoveReaction: (String) -> Void
	var onDismiss: () -> Void
	
	@State private var userInfo: [String: (username: String, profileImageURL: String?)] = [:]
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		ZStack {
			// Background overlay
			Color.black.opacity(0.3)
				.ignoresSafeArea()
				.onTapGesture {
					onDismiss()
				}
			
			// Popup content
			VStack(spacing: 0) {
				// Header
				HStack {
					Text(emoji)
						.font(.system(size: 24))
					Text("Reactions")
						.font(.system(size: 16, weight: .semibold))
					Spacer()
					Button(action: {
						onDismiss()
					}) {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 20))
							.foregroundColor(.gray)
					}
				}
				.padding()
				Divider()
				
				// Users who reacted
				ScrollView {
					VStack(spacing: 0) {
						ForEach(reactedUserIds, id: \.self) { userId in
							HStack(spacing: 12) {
								// Profile image
								if let userInfo = userInfo[userId] {
									if let profileURL = userInfo.profileImageURL, !profileURL.isEmpty, let url = URL(string: profileURL) {
										WebImage(url: url)
											.resizable()
											.scaledToFill()
											.frame(width: 40, height: 40)
											.clipShape(Circle())
									} else {
										Circle()
											.fill(Color.gray.opacity(0.3))
											.frame(width: 40, height: 40)
											.overlay(
												Image(systemName: "person.fill")
													.font(.system(size: 16))
													.foregroundColor(.secondary)
											)
									}
									
									// Username
									Text(userInfo.username.isEmpty ? "User" : userInfo.username)
										.font(.system(size: 15))
										.foregroundColor(.primary)
									
									Spacer()
									
									// Remove button (only for current user's reaction)
									if userId == Auth.auth().currentUser?.uid {
										Button(action: {
											onRemoveReaction(emoji)
											onDismiss()
										}) {
											Image(systemName: "xmark.circle.fill")
												.font(.system(size: 20))
												.foregroundColor(.red)
										}
									}
								} else {
									// Loading state
									Circle()
										.fill(Color.gray.opacity(0.3))
										.frame(width: 40, height: 40)
									Text("Loading...")
										.font(.system(size: 15))
										.foregroundColor(.secondary)
									Spacer()
								}
							}
							.padding(.horizontal)
							.padding(.vertical, 12)
							
							if userId != reactedUserIds.last {
								Divider()
									.padding(.leading, 52)
							}
						}
					}
				}
				.frame(maxHeight: 300)
			}
			.background(colorScheme == .dark ? Color(.systemGray6) : Color.white)
			.cornerRadius(12)
			.shadow(radius: 10)
			.frame(width: 300)
			.padding()
		}
		.onAppear {
			loadUserInfo()
		}
	}
	
	// Get user IDs who reacted with this emoji
	private var reactedUserIds: [String] {
		message.reactions.compactMap { userId, reactionEmoji in
			reactionEmoji == emoji ? userId : nil
		}
	}
	
	private func loadUserInfo() {
		Task {
			let userService = UserService.shared
			for userId in reactedUserIds {
				do {
					if let user = try await userService.getUser(userId: userId) {
						await MainActor.run {
							userInfo[userId] = (username: user.username.isEmpty ? user.name : user.username, profileImageURL: user.profileImageURL)
						}
					}
				} catch {
					print("Error loading user info for \(userId): \(error)")
					await MainActor.run {
						userInfo[userId] = (username: "User", profileImageURL: nil)
					}
				}
			}
		}
	}
}

