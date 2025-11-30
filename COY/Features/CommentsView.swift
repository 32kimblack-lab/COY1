import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI
import GoogleMobileAds

struct CommentsView: View {
	let post: CollectionPost
	
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	@StateObject private var viewModel = CommentsViewModel()
	
	// Consistent sizing system (scaled for iPad)
	private var isIPad: Bool {
		UIDevice.current.userInterfaceIdiom == .pad
	}
	private var scaleFactor: CGFloat {
		isIPad ? 1.6 : 1.0
	}
	private var iconSize: CGFloat { 48 * scaleFactor }
	private var horizontalPadding: CGFloat { 16 * scaleFactor }
	private var verticalPadding: CGFloat { 12 * scaleFactor }
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				ZStack {
				// Background
				Color(colorScheme == .dark ? .black : .white)
					.ignoresSafeArea()
				
				if post.allowReplies {
					VStack(spacing: 0) {
						// Banner Ad at top (like Reddit)
						BannerAdView(adUnitID: {
							#if DEBUG
							return "ca-app-pub-3940256099942544/2934735716" // Test banner ad unit ID
							#else
							return "ca-app-pub-1522482018148796/8721412363" // Real comment ad unit
							#endif
						}())
							.frame(height: 50)
							.frame(maxWidth: .infinity)
							.background(Color(colorScheme == .dark ? .black : .white))
							.padding(.top, 8)
							.onAppear {
								print("✅ CommentsView: Banner ad view appeared")
							}
						
						// Comments List
						if viewModel.comments.isEmpty && !viewModel.isLoading {
							VStack(spacing: 16 * scaleFactor) {
								Image(systemName: "bubble.right")
									.font(.system(size: iconSize))
									.foregroundColor(.secondary)
								Text("No comments yet")
									.font(.headline)
									.foregroundColor(.secondary)
								Text("Be the first to comment!")
									.font(.subheadline)
									.foregroundColor(.secondary)
							}
							.frame(maxWidth: .infinity, maxHeight: .infinity)
						} else {
							ScrollView {
								LazyVStack(spacing: 0) {
									ForEach(viewModel.topLevelComments) { comment in
										CommentRow(
											comment: comment,
											post: post,
											onReplyTapped: {
												viewModel.selectedCommentForReply = comment
												viewModel.showReplyField = true
											},
											onDeleteTapped: {
												Task {
													await viewModel.deleteComment(commentId: comment.id, parentCommentId: comment.parentCommentId)
												}
											}
										)
										.padding(.horizontal, horizontalPadding)
										.padding(.vertical, verticalPadding)
										
										// Show replies if expanded
										if viewModel.expandedComments.contains(comment.id) {
											ForEach(viewModel.replies[comment.id] ?? []) { reply in
												CommentRow(
													comment: reply,
													post: post,
													isReply: true,
													onReplyTapped: {
														viewModel.selectedCommentForReply = comment
														viewModel.showReplyField = true
													},
													onDeleteTapped: {
														Task {
															await viewModel.deleteComment(commentId: reply.id, parentCommentId: reply.parentCommentId)
														}
													}
												)
												.padding(.leading, 32 * scaleFactor)
												.padding(.horizontal, horizontalPadding)
												.padding(.vertical, 8 * scaleFactor)
											}
											
											// Load more replies button
											if let replyCount = viewModel.commentReplyCounts[comment.id],
											   replyCount > (viewModel.replies[comment.id]?.count ?? 0) {
												Button(action: {
													Task {
														await viewModel.loadMoreReplies(parentCommentId: comment.id)
													}
												}) {
													Text("View \(replyCount - (viewModel.replies[comment.id]?.count ?? 0)) more comments")
														.font(.subheadline)
														.foregroundColor(.blue)
														.padding(.leading, 32)
														.padding(.top, 8)
												}
											}
										}
									}
								}
								.padding(.bottom, 100)
							}
						}
						
						// Input Field
						if let selectedComment = viewModel.selectedCommentForReply, viewModel.showReplyField {
							// Reply input
							ReplyInputView(
								replyingTo: selectedComment,
								onSend: { text in
									Task {
										await viewModel.addReply(text: text, parentCommentId: selectedComment.id)
									}
								},
								onCancel: {
									viewModel.showReplyField = false
									viewModel.selectedCommentForReply = nil
								}
							)
						} else {
							// Main comment input
							CommentInputView(
								onSend: { text in
									Task {
										await viewModel.addComment(text: text)
									}
								}
							)
						}
					}
				} else {
					VStack(spacing: 16) {
						Image(systemName: "bubble.right.slash")
							.font(.system(size: 48))
							.foregroundColor(.secondary)
						Text("Comments are disabled")
							.font(.headline)
							.foregroundColor(.secondary)
						Text("The post owner has disabled comments on this post.")
							.font(.subheadline)
							.foregroundColor(.secondary)
							.multilineTextAlignment(.center)
							.padding(.horizontal)
					}
				}
			}
				}
			.navigationTitle("Comments")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Done") {
						dismiss()
					}
					.foregroundColor(.primary)
				}
			}
			.onAppear {
				viewModel.postId = post.id
				Task {
					await viewModel.loadComments(postId: post.id)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentAdded"))) { notification in
				if let postId = notification.object as? String, postId == post.id {
					Task {
						await viewModel.loadComments(postId: post.id)
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommentDeleted"))) { notification in
				if let postId = notification.object as? String, postId == post.id {
					Task {
						await viewModel.loadComments(postId: post.id)
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserBlocked"))) { notification in
				// Immediately filter out comments from blocked user
				if let blockedUserId = notification.userInfo?["blockedUserId"] as? String {
					Task {
						await MainActor.run {
							// Remove comments from blocked user immediately
							viewModel.comments.removeAll { $0.userId == blockedUserId }
							// Also remove from replies
							for key in viewModel.replies.keys {
								viewModel.replies[key]?.removeAll { $0.userId == blockedUserId }
							}
							print("🚫 CommentsView: Removed comments from blocked user '\(blockedUserId)'")
						}
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("UserUnblocked"))) { notification in
				// Reload comments when user is unblocked to show their comments again
				if let unblockedUserId = notification.userInfo?["unblockedUserId"] as? String {
					print("✅ CommentsView: User '\(unblockedUserId)' was unblocked, reloading comments")
					Task {
						await viewModel.loadComments(postId: post.id)
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
				// Update comments when user profiles are updated
				if let userId = notification.object as? String,
				   let userInfo = notification.userInfo,
				   let _ = userInfo["updatedData"] as? [String: Any] {
					// Check if any comment author matches the updated user
					let hasMatchingAuthor = viewModel.comments.contains { $0.userId == userId }
					if hasMatchingAuthor {
						print("🔄 CommentsView: User profile updated, reloading comments to show updated author info")
						// Clear user cache to force fresh load
						UserService.shared.clearUserCache(userId: userId)
						// Reload comments to get updated author info
						Task {
							await viewModel.loadComments(postId: post.id)
						}
					}
				}
			}
		}
	}
}

// MARK: - Comments ViewModel

@MainActor
class CommentsViewModel: ObservableObject {
	@Published var comments: [Comment] = []
	@Published var replies: [String: [Comment]] = [:]
	@Published var expandedComments: Set<String> = []
	@Published var commentReplyCounts: [String: Int] = [:]
	@Published var isLoading = false
	@Published var showReplyField = false
	@Published var selectedCommentForReply: Comment?
	
	var postId: String = ""
	private var commentsListener: ListenerRegistration?
	
	var topLevelComments: [Comment] {
		comments.filter { $0.parentCommentId == nil }
	}
	
	/// Filter out comments from blocked users or where commenter has blocked current user (mutual blocking)
	private func filterBlockedUsersComments(_ comments: [Comment]) async -> [Comment] {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			return comments
		}
		
		do {
			try await CYServiceManager.shared.loadCurrentUser()
			let blockedUserIds = Set(CYServiceManager.shared.getBlockedUsers())
			
			// Get unique commenter IDs to check
			let commenterIds = Set(comments.map { $0.userId })
			
			// Batch fetch commenter data to check if they've blocked current user
			var commentersWhoBlockedCurrentUser: Set<String> = []
			await withTaskGroup(of: (String, Bool).self) { group in
				for commenterId in commenterIds {
					group.addTask {
						do {
							let db = Firestore.firestore()
							let commenterDoc = try await db.collection("users").document(commenterId).getDocument()
							if let data = commenterDoc.data(),
							   let commenterBlockedUsers = data["blockedUsers"] as? [String],
							   commenterBlockedUsers.contains(currentUserId) {
								return (commenterId, true)
							}
						} catch {
							print("Error checking if commenter blocked current user: \(error.localizedDescription)")
						}
						return (commenterId, false)
					}
				}
				
				for await (commenterId, isBlocked) in group {
					if isBlocked {
						commentersWhoBlockedCurrentUser.insert(commenterId)
					}
				}
			}
			
			return comments.filter { comment in
				// Exclude if current user has blocked the commenter
				if blockedUserIds.contains(comment.userId) {
					return false
				}
				// Exclude if commenter has blocked current user (mutual blocking)
				if commentersWhoBlockedCurrentUser.contains(comment.userId) {
					return false
				}
				return true
			}
		} catch {
			print("Error loading blocked users: \(error.localizedDescription)")
			return comments
		}
	}
	
	func loadComments(postId: String) async {
		isLoading = true
		do {
			// Setup real-time listener BEFORE loading to catch new comments immediately
			setupCommentsListener(postId: postId)
			
			var loadedComments = try await CommentService.shared.loadComments(postId: postId)
			// Filter out comments from blocked users
			loadedComments = await filterBlockedUsersComments(loadedComments)
			self.comments = loadedComments
			
			// Organize comments and replies
			replies.removeAll()
			commentReplyCounts.removeAll()
			
			for comment in loadedComments {
				if let parentId = comment.parentCommentId {
					if replies[parentId] == nil {
						replies[parentId] = []
					}
					replies[parentId]?.append(comment)
				} else {
					commentReplyCounts[comment.id] = comment.replyCount
				}
			}
			
			// Auto-expand comments with replies
			for comment in topLevelComments {
				if comment.replyCount > 0 {
					expandedComments.insert(comment.id)
					// Load initial replies
					await loadReplies(parentCommentId: comment.id)
				}
			}
		} catch {
			print("❌ Error loading comments: \(error)")
		}
		isLoading = false
	}
	
	// MARK: - Real-time Comments Listener
	private func setupCommentsListener(postId: String) {
		let db = Firestore.firestore()
		
		// Remove existing listener
		commentsListener?.remove()
		
		// Listen to comments for this post - listen to ALL comments (not just top-level)
		commentsListener = db.collection("posts").document(postId)
			.collection("comments")
			.addSnapshotListener { [weak self] snapshot, error in
				guard let self = self else { return }
				
				if let error = error {
					print("❌ CommentsViewModel: Comments listener error: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot else { return }
				
				// Handle document changes
				for change in snapshot.documentChanges {
					let doc = change.document
					let data = doc.data()
					
					if change.type == .removed {
						// Comment was deleted
						let deletedCommentId = doc.documentID
						Task { @MainActor in
							self.comments.removeAll { $0.id == deletedCommentId }
							// Also remove from replies
							for (parentId, replyList) in self.replies {
								if replyList.contains(where: { $0.id == deletedCommentId }) {
									self.replies[parentId] = replyList.filter { $0.id != deletedCommentId }
								}
							}
							print("🗑️ CommentsViewModel: Removed deleted comment \(deletedCommentId)")
						}
					} else if change.type == .added || change.type == .modified {
						// New or updated comment
						let commentId = doc.documentID
						let text = data["text"] as? String ?? ""
						let userId = data["authorId"] as? String ?? data["userId"] as? String ?? ""
						let username = data["username"] as? String ?? data["authorName"] as? String ?? ""
						let name = data["name"] as? String ?? data["authorName"] as? String ?? ""
						let profileImageURL = data["authorImageURL"] as? String ?? data["profileImageURL"] as? String
						let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
						let parentCommentId = data["parentCommentId"] as? String
						let replyCount = data["replyCount"] as? Int ?? 0
						
						// Skip deleted comments
						if text == "[deleted]" || (data["isDeleted"] as? Bool == true) {
							continue
						}
						
						let comment = Comment(
							id: commentId,
							postId: postId,
							userId: userId,
							username: username,
							name: name,
							profileImageURL: profileImageURL,
							text: text,
							createdAt: createdAt,
							parentCommentId: parentCommentId,
							replyCount: replyCount
						)
						
						Task { @MainActor in
							// Check if comment author is blocked (mutual blocking check)
							guard let currentUserId = Auth.auth().currentUser?.uid else { return }
							
							let blockedUserIds = Set(CYServiceManager.shared.getBlockedUsers())
							if blockedUserIds.contains(comment.userId) {
								// Don't add comments from blocked users
								print("🚫 CommentsViewModel: Skipping comment from blocked user \(comment.userId)")
								return
							}
							
							// Check if commenter has blocked current user (mutual blocking)
							do {
								let db = Firestore.firestore()
								let commenterDoc = try await db.collection("users").document(comment.userId).getDocument()
								if let data = commenterDoc.data(),
								   let commenterBlockedUsers = data["blockedUsers"] as? [String],
								   commenterBlockedUsers.contains(currentUserId) {
									// Don't add comments from users who blocked current user
									print("🚫 CommentsViewModel: Skipping comment from user who blocked current user \(comment.userId)")
									return
								}
							} catch {
								print("Error checking if commenter blocked current user: \(error.localizedDescription)")
							}
							
							if change.type == .added {
								// New comment - add if not already present
								if !self.comments.contains(where: { $0.id == comment.id }) {
									self.comments.append(comment)
									
									// Organize into replies if needed
									if let parentId = comment.parentCommentId {
										if self.replies[parentId] == nil {
											self.replies[parentId] = []
										}
										if !self.replies[parentId]!.contains(where: { $0.id == comment.id }) {
											self.replies[parentId]!.append(comment)
										}
										// Auto-expand parent comment if it has replies
										if !self.expandedComments.contains(parentId) {
											self.expandedComments.insert(parentId)
										}
									} else {
										// Top-level comment
										self.commentReplyCounts[comment.id] = comment.replyCount
									}
									
									print("✅ CommentsViewModel: Added new comment \(comment.id) - parentCommentId: \(parentCommentId ?? "nil")")
								} else {
									print("⚠️ CommentsViewModel: Comment \(comment.id) already exists, skipping")
								}
							} else if change.type == .modified {
								// Updated comment - replace existing
								if let index = self.comments.firstIndex(where: { $0.id == comment.id }) {
									self.comments[index] = comment
									
									// Update in replies if needed
									if let parentId = comment.parentCommentId,
									   let replyIndex = self.replies[parentId]?.firstIndex(where: { $0.id == comment.id }) {
										self.replies[parentId]?[replyIndex] = comment
									} else if comment.parentCommentId == nil {
										self.commentReplyCounts[comment.id] = comment.replyCount
									}
									
									print("🔄 CommentsViewModel: Updated comment \(comment.id)")
								}
							}
						}
					}
				}
			}
	}
	
	deinit {
		commentsListener?.remove()
	}
	
	func loadReplies(parentCommentId: String) async {
		do {
			var loadedReplies = try await CommentService.shared.loadReplies(postId: postId, parentCommentId: parentCommentId)
			// Filter out replies from blocked users
			loadedReplies = await filterBlockedUsersComments(loadedReplies)
			replies[parentCommentId] = loadedReplies
		} catch {
			print("❌ Error loading replies: \(error)")
		}
	}
	
	func loadMoreReplies(parentCommentId: String) async {
		await loadReplies(parentCommentId: parentCommentId)
	}
	
	func addComment(text: String) async {
		// Use postId from CommentsView
		do {
			try await CommentService.shared.addComment(postId: postId, text: text)
			// Post notification to trigger refresh
			NotificationCenter.default.post(
				name: NSNotification.Name("CommentAdded"),
				object: postId
			)
			// Wait a brief moment for Firestore to index the new comment, then reload
			// The real-time listener should also catch it, but this ensures it appears
			try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
			await loadComments(postId: postId)
		} catch {
			print("❌ Error adding comment: \(error)")
		}
	}
	
	func addReply(text: String, parentCommentId: String) async {
		// Use postId from CommentsView
		do {
			try await CommentService.shared.addComment(postId: postId, text: text, parentCommentId: parentCommentId)
			showReplyField = false
			selectedCommentForReply = nil
			// Post notification to trigger refresh
			NotificationCenter.default.post(
				name: NSNotification.Name("CommentAdded"),
				object: postId
			)
			// Wait a brief moment for Firestore to index the new reply, then reload
			// The real-time listener should also catch it, but this ensures it appears
			try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
			await loadComments(postId: postId)
			// Auto-expand parent comment
			expandedComments.insert(parentCommentId)
		} catch {
			print("❌ Error adding reply: \(error)")
		}
	}
	
	func deleteComment(commentId: String, parentCommentId: String?) async {
		// Use postId from CommentsView
		do {
			try await CommentService.shared.deleteComment(postId: postId, commentId: commentId, parentCommentId: parentCommentId)
			await loadComments(postId: postId)
		} catch {
			print("❌ Error deleting comment: \(error)")
		}
	}
	
}

// MARK: - Comment Row

struct CommentRow: View {
	let comment: Comment
	let post: CollectionPost
	var isReply: Bool = false
	let onReplyTapped: () -> Void
	let onDeleteTapped: () -> Void
	
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	@State private var showDeleteAlert = false
	
	// Consistent sizing system (scaled for iPad)
	private var isIPad: Bool {
		UIDevice.current.userInterfaceIdiom == .pad
	}
	private var scaleFactor: CGFloat {
		isIPad ? 1.6 : 1.0
	}
	private var profileImageSize: CGFloat { (isReply ? 32 : 40) * scaleFactor }
	private var nameFontSize: CGFloat { (isReply ? 14 : 15) * scaleFactor }
	private var textFontSize: CGFloat { (isReply ? 14 : 15) * scaleFactor }
	private var smallFontSize: CGFloat { (isReply ? 13 : 14) * scaleFactor }
	private var commentSpacing: CGFloat { 12 * scaleFactor }
	private var commentPadding: CGFloat { 4 * scaleFactor }
	
	private var canDelete: Bool {
		guard let currentUserId = authService.user?.uid else { return false }
		return comment.userId == currentUserId
	}
	
	var body: some View {
		HStack(alignment: .top, spacing: commentSpacing) {
			// Profile Image
			NavigationLink(destination: ViewerProfileView(userId: comment.userId).environmentObject(authService)) {
				if let imageURL = comment.profileImageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
					WebImage(url: url)
						.resizable()
						.scaledToFill()
						.frame(width: profileImageSize, height: profileImageSize)
						.clipShape(Circle())
				} else {
					DefaultProfileImageView(size: profileImageSize)
				}
			}
			.buttonStyle(.plain)
			
			// Comment Content
			VStack(alignment: .leading, spacing: commentPadding) {
				HStack(spacing: 4 * scaleFactor) {
					Text(comment.name)
						.font(.system(size: nameFontSize, weight: .semibold))
						.foregroundColor(.primary)
					Text("@\(comment.username)")
						.font(.system(size: smallFontSize))
						.foregroundColor(.secondary)
					Text("•")
						.font(.system(size: smallFontSize))
						.foregroundColor(.secondary)
					Text(formatTimeAgo(comment.createdAt))
						.font(.system(size: smallFontSize))
						.foregroundColor(.secondary)
				}
				
				Text(comment.text)
					.font(.system(size: textFontSize))
					.foregroundColor(.primary)
					.fixedSize(horizontal: false, vertical: true)
				
				// Reply and Delete buttons
				HStack(spacing: 16 * scaleFactor) {
					if !isReply {
						Button(action: onReplyTapped) {
							Text("Reply")
								.font(.system(size: 13 * scaleFactor, weight: .medium))
								.foregroundColor(.secondary)
						}
					}
					
					if canDelete {
						Button(action: {
							showDeleteAlert = true
						}) {
							Text("Delete")
								.font(.system(size: 13, weight: .medium))
								.foregroundColor(.red)
						}
					}
				}
				.padding(.top, 2)
			}
			
			Spacer()
		}
		.alert("Delete Comment", isPresented: $showDeleteAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Delete", role: .destructive) {
				onDeleteTapped()
			}
		} message: {
			Text("Are you sure you want to delete this comment? This action cannot be undone.")
		}
	}
	
	private func formatTimeAgo(_ date: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return formatter.localizedString(for: date, relativeTo: Date())
	}
}

// MARK: - Comment Input View

struct CommentInputView: View {
	let onSend: (String) -> Void
	
	@State private var commentText = ""
	@FocusState private var isFocused: Bool
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		VStack(spacing: 0) {
			Divider()
			
			HStack(spacing: 12) {
				TextField("Add a comment...", text: $commentText, axis: .vertical)
					.textFieldStyle(.plain)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.95))
					.cornerRadius(20)
					.focused($isFocused)
				
				Button(action: {
					if !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						onSend(commentText.trimmingCharacters(in: .whitespacesAndNewlines))
						commentText = ""
						isFocused = false
					}
				}) {
					Text("Post")
						.font(.system(size: 15, weight: .semibold))
						.foregroundColor(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .blue)
				}
				.disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
		}
		.background(Color(colorScheme == .dark ? .black : .white))
	}
}

// MARK: - Reply Input View

struct ReplyInputView: View {
	let replyingTo: Comment
	let onSend: (String) -> Void
	let onCancel: () -> Void
	
	@State private var replyText = ""
	@FocusState private var isFocused: Bool
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		VStack(spacing: 0) {
			Divider()
			
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text("Replying to @\(replyingTo.username)")
						.font(.system(size: 13, weight: .medium))
						.foregroundColor(.secondary)
					Spacer()
					Button(action: onCancel) {
						Text("Cancel")
							.font(.system(size: 13, weight: .medium))
							.foregroundColor(.secondary)
					}
				}
				
				HStack(spacing: 12) {
					TextField("Add a reply...", text: $replyText, axis: .vertical)
						.textFieldStyle(.plain)
						.padding(.horizontal, 12)
						.padding(.vertical, 8)
						.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.95))
						.cornerRadius(20)
						.focused($isFocused)
					
					Button(action: {
						if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
							onSend(replyText.trimmingCharacters(in: .whitespacesAndNewlines))
							replyText = ""
							isFocused = false
						}
					}) {
						Text("Reply")
							.font(.system(size: 15, weight: .semibold))
							.foregroundColor(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .blue)
					}
					.disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
		}
		.background(Color(colorScheme == .dark ? .black : .white))
		.onAppear {
			isFocused = true
		}
	}
}

