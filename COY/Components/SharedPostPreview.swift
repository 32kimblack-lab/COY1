import SwiftUI
import SDWebImageSwiftUI
import FirebaseFirestore
import FirebaseAuth
import AVFoundation

struct SharedPostPreview: View {
	let messageContent: String
	let onTap: () -> Void
	
	@State private var postData: [String: Any]?
	@State private var post: CollectionPost?
	@State private var collection: CollectionData?
	@State private var author: UserService.AppUser?
	@State private var ownerProfileImageURL: String?
	@State private var isLoading = true
	@State private var hasAccess = true // Default to true, will be checked
	
	@Environment(\.colorScheme) var colorScheme
	
	private var currentUserId: String? {
		Auth.auth().currentUser?.uid
	}
	
	var body: some View {
		Button(action: onTap) {
			if hasAccess {
				// Show full preview if user has access
				VStack(alignment: .leading, spacing: 0) {
					// Post preview image/video - use actual post data if available
					if let post = post, let firstMedia = post.firstMediaItem ?? post.mediaItems.first {
						if firstMedia.isVideo {
							// Video - use thumbnail if available, otherwise placeholder
							if let thumbnailURL = firstMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
								WebImage(url: url)
									.resizable()
									.scaledToFill()
									.frame(height: 200)
									.clipped()
									.overlay(
										Image(systemName: "play.circle.fill")
											.font(.system(size: 40))
											.foregroundColor(.white.opacity(0.8))
									)
							} else if let videoURL = firstMedia.videoURL, !videoURL.isEmpty, let url = URL(string: videoURL) {
								// Fallback to video URL if no thumbnail
								VideoThumbnailView(videoURL: url)
									.frame(height: 200)
									.clipped()
							} else {
								// Placeholder for video
								Rectangle()
									.fill(Color.gray.opacity(0.3))
									.frame(height: 200)
									.overlay(
										Image(systemName: "play.circle.fill")
											.font(.system(size: 40))
											.foregroundColor(.gray)
									)
							}
						} else {
							// Image
							if let imageURL = firstMedia.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
								WebImage(url: url)
									.resizable()
									.scaledToFill()
									.frame(height: 200)
									.clipped()
							} else {
								// Placeholder
								Rectangle()
									.fill(Color.gray.opacity(0.3))
									.frame(height: 200)
									.overlay(
										Image(systemName: "photo")
											.font(.system(size: 40))
											.foregroundColor(.gray)
									)
							}
						}
					} else if let firstMediaURL = postData?["firstMediaURL"] as? String,
							  !firstMediaURL.isEmpty,
							  let url = URL(string: firstMediaURL) {
						// Fallback to JSON data if post not loaded yet
						let mediaType = postData?["firstMediaType"] as? String ?? ""
						if mediaType == "video" {
							VideoThumbnailView(videoURL: url)
								.frame(height: 200)
								.clipped()
						} else {
							WebImage(url: url)
								.resizable()
								.scaledToFill()
								.frame(height: 200)
								.clipped()
						}
					} else {
						// Placeholder
						Rectangle()
							.fill(Color.gray.opacity(0.3))
							.frame(height: 200)
							.overlay(
								Image(systemName: "photo")
									.font(.system(size: 40))
									.foregroundColor(.gray)
							)
					}
					
					// Gray info bar
					HStack(spacing: 8) {
						// Collection profile image - use collection imageURL or fall back to owner's profile image
						Group {
							if let collection = collection {
								if let collectionImageURL = collection.imageURL, !collectionImageURL.isEmpty, let url = URL(string: collectionImageURL) {
									// Use collection's profile image if available
									WebImage(url: url)
										.resizable()
										.scaledToFill()
										.frame(width: 24, height: 24)
										.clipShape(Circle())
								} else if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty, let url = URL(string: ownerImageURL) {
									// Use owner's profile image as fallback
									WebImage(url: url)
										.resizable()
										.scaledToFill()
										.frame(width: 24, height: 24)
										.clipShape(Circle())
								} else {
									// Default icon if no image available
									Circle()
										.fill(Color.gray.opacity(0.3))
										.frame(width: 24, height: 24)
										.overlay(
											Image(systemName: "folder.fill")
												.font(.system(size: 12))
												.foregroundColor(.gray)
										)
								}
							} else {
								// Default icon while loading
								Circle()
									.fill(Color.gray.opacity(0.3))
									.frame(width: 24, height: 24)
									.overlay(
										Image(systemName: "folder.fill")
											.font(.system(size: 12))
											.foregroundColor(.gray)
									)
							}
						}
						
						// Collection name and username
						HStack(spacing: 4) {
							if let collectionName = collection?.name, !collectionName.isEmpty {
								Text(collectionName)
									.font(.system(size: 13, weight: .semibold))
									.foregroundColor(.primary)
							}
							
							if let username = author?.username, !username.isEmpty {
								Text("@\(username)")
									.font(.system(size: 13))
									.foregroundColor(.secondary)
							}
						}
						
						Spacer()
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 10)
					.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5))
				}
				.cornerRadius(12)
				.overlay(
					RoundedRectangle(cornerRadius: 12)
						.stroke(Color.gray.opacity(0.2), lineWidth: 1)
				)
			} else {
				// Show "This post is private" message if user doesn't have access
				VStack(spacing: 12) {
					Image(systemName: "lock.fill")
						.font(.system(size: 32))
						.foregroundColor(.secondary)
					Text("This post is private")
						.font(.system(size: 15, weight: .medium))
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity)
				.frame(height: 200)
				.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5))
				.cornerRadius(12)
				.overlay(
					RoundedRectangle(cornerRadius: 12)
						.stroke(Color.gray.opacity(0.2), lineWidth: 1)
				)
			}
		}
		.buttonStyle(.plain)
		.disabled(!hasAccess) // Disable tap if no access
		.task {
			await loadPostData()
		}
	}
	
	private func loadPostData() async {
		guard let data = messageContent.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			isLoading = false
			return
		}
		
		postData = json
		
		// Load collection first
		if let collectionId = json["collectionId"] as? String, !collectionId.isEmpty {
			do {
				collection = try await CollectionService.shared.getCollection(collectionId: collectionId)
				
				// Check if user has access to private collection
				if let loadedCollection = collection {
					hasAccess = checkAccessToCollection(loadedCollection)
					
					// Load owner's profile image if collection has no imageURL (for fallback)
					if loadedCollection.imageURL?.isEmpty != false {
						do {
							let owner = try await UserService.shared.getUser(userId: loadedCollection.ownerId)
							await MainActor.run {
								ownerProfileImageURL = owner?.profileImageURL
							}
						} catch {
							print("Error loading owner profile image: \(error)")
						}
					}
				}
			} catch {
				print("Error loading collection: \(error)")
				// If we can't load the collection, assume no access (it might be private)
				hasAccess = false
			}
		}
		
		// Only load post and author if user has access (privacy protection)
		if hasAccess {
			// Load the actual post to get correct media preview
			if let postId = json["postId"] as? String, !postId.isEmpty {
				do {
					post = try await CollectionService.shared.getPostById(postId: postId)
				} catch {
					print("Error loading post: \(error)")
				}
			}
			
			// Load author
			if let authorId = json["authorId"] as? String, !authorId.isEmpty {
				do {
					author = try await UserService.shared.getUser(userId: authorId)
				} catch {
					print("Error loading author: \(error)")
				}
			}
		}
		
		isLoading = false
	}
	
	private func checkAccessToCollection(_ collection: CollectionData) -> Bool {
		guard let userId = currentUserId else {
			return false
		}
		
		// If collection is public, everyone has access
		if collection.isPublic {
			return true
		}
		
		// If collection is private, check if user has access:
		// 1. User is the owner
		if collection.ownerId == userId {
			return true
		}
		
		// 2. User is in members list
		if collection.members.contains(userId) {
			return true
		}
		
		// 3. User is in allowedUsers list
		if collection.allowedUsers.contains(userId) {
			return true
		}
		
		// User doesn't have access
		return false
	}
}

