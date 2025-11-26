import SwiftUI
import FirebaseAuth

struct SearchMessagesScreen: View {
	let chatId: String
	private let chatService = ChatService.shared
	private let userService = UserService.shared
	@State private var searchText = ""
	@State private var searchResults: [MessageModel] = []
	@State private var isLoading = false
	@State private var userCache: [String: UserService.AppUser] = [:]
	@State private var navigateToMessage: MessageModel?
	@Environment(\.dismiss) var dismiss
	
	var body: some View {
		NavigationStack {
			VStack {
				// Search Bar
				HStack {
					Image(systemName: "magnifyingglass")
						.foregroundColor(.gray)
					TextField("Search messages...", text: $searchText)
						.onChange(of: searchText) { _, newValue in
							if !newValue.isEmpty {
								searchMessages()
							} else {
								searchResults = []
							}
						}
						.onSubmit {
							searchMessages()
						}
				}
				.padding()
				.background(Color(.systemGray6))
				.cornerRadius(12)
				.padding()
				
				// Results
				if isLoading {
					VStack(spacing: 12) {
						ProgressView()
						Text("Searching...")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if searchText.isEmpty {
					VStack(spacing: 12) {
						Image(systemName: "magnifyingglass")
							.font(.system(size: 40))
							.foregroundColor(.gray)
						Text("Start typing to search messages")
							.font(.headline)
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if searchResults.isEmpty {
					VStack(spacing: 12) {
						Image(systemName: "message")
							.font(.system(size: 40))
							.foregroundColor(.gray)
						Text("No messages found")
							.font(.headline)
							.foregroundColor(.secondary)
						Text("Try a different search term")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					List(searchResults) { message in
						MessageSearchResultRow(
							message: message,
							user: userCache[message.senderUid]
						)
						.onTapGesture {
							navigateToMessage = message
						}
					}
				}
			}
			.navigationTitle("Search Messages")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
		}
		.onChange(of: navigateToMessage) { _, message in
			if let message = message {
				// Navigate back to chat and scroll to message
				dismiss()
				// Post notification to scroll to message
				NotificationCenter.default.post(
					name: NSNotification.Name("ScrollToMessage"),
					object: message.messageId
				)
			}
		}
	}
	
	private func searchMessages() {
		let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedQuery.isEmpty else {
			searchResults = []
			isLoading = false
			return
		}
		
		isLoading = true
		Task {
			do {
				let results = try await chatService.searchMessages(chatId: chatId, query: trimmedQuery)
				
				// Load user info for each unique sender
				let uniqueSenderIds = Set(results.map { $0.senderUid })
				for senderId in uniqueSenderIds {
					if userCache[senderId] == nil {
						do {
							let user = try await userService.getUser(userId: senderId)
							await MainActor.run {
								userCache[senderId] = user
							}
						} catch {
							print("Error loading user \(senderId): \(error)")
						}
					}
				}
				
				await MainActor.run {
					self.searchResults = results
					self.isLoading = false
					print("✅ Search completed: Found \(results.count) messages for query '\(trimmedQuery)'")
				}
			} catch {
				print("❌ Error searching messages: \(error)")
				await MainActor.run {
					self.isLoading = false
					self.searchResults = []
				}
			}
		}
	}
}

struct MessageSearchResultRow: View {
	let message: MessageModel
	let user: UserService.AppUser?
	
	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			// Profile Image
			if let user = user, let profileImageURL = user.profileImageURL, !profileImageURL.isEmpty {
				CachedProfileImageView(url: profileImageURL, size: 40)
					.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 40)
			}
			
			VStack(alignment: .leading, spacing: 4) {
				// Username
				Text(user?.username ?? "Unknown")
					.font(.system(size: 15, weight: .semibold))
					.foregroundColor(.primary)
				
				// Message Content
				Text(message.content)
					.font(.system(size: 14))
					.foregroundColor(.primary)
					.lineLimit(2)
				
				// Date
				Text(message.timestamp, style: .date)
					.font(.system(size: 12))
					.foregroundColor(.secondary)
			}
			
			Spacer()
		}
		.padding(.vertical, 8)
	}
}

