import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI

struct DeletedCollectionsView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@EnvironmentObject var authService: AuthService
	
	@State private var deletedCollections: [(CollectionData, Date)] = []
	@State private var isLoading = false
	@State private var showRestoreAlert = false
	@State private var showDeleteAlert = false
	@State private var selectedCollection: CollectionData?
	@State private var isDeleting = false
	
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
					Text("Deleted Collections")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				// Refresh button
				Button(action: {
					loadDeletedCollections()
				}) {
					Image(systemName: "arrow.clockwise")
						.font(.title2)
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
			if isLoading {
				Spacer()
				ProgressView()
					.scaleEffect(1.2)
				Spacer()
			} else if deletedCollections.isEmpty {
				Spacer()
				VStack(spacing: 16) {
					Image(systemName: "trash")
						.resizable()
						.scaledToFit()
						.frame(width: 100, height: 100)
						.foregroundColor(.gray)
					Text("No Deleted Collections")
						.font(.headline)
						.foregroundColor(.gray)
					Text("Collections you delete will appear here for 15 days before permanent deletion.")
						.font(.subheadline)
						.foregroundColor(.gray)
						.multilineTextAlignment(.center)
						.padding(.horizontal)
				}
				Spacer()
			} else {
				ScrollView {
					LazyVStack(spacing: 16) {
						ForEach(deletedCollections, id: \.0.id) { item in
							DeletedCollectionRow(
								collection: item.0,
								deletedAt: item.1,
								onRestore: {
									selectedCollection = item.0
									showRestoreAlert = true
								},
								onDeletePermanently: {
									selectedCollection = item.0
									showDeleteAlert = true
								}
							)
							.padding(.horizontal)
						}
					}
					.padding(.vertical)
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
			}
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
		.onAppear {
			loadDeletedCollections()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionDeleted"))) { notification in
			if let userInfo = notification.userInfo, userInfo["permanent"] as? Bool == true {
				// Collection was permanently deleted, reload list
				loadDeletedCollections()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRestored"))) { _ in
			// Collection was restored, reload list
			loadDeletedCollections()
		}
		.alert("Restore Collection", isPresented: $showRestoreAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Restore") {
				if let collection = selectedCollection {
					restoreCollection(collection)
				}
			}
		} message: {
			Text("Are you sure you want to restore this collection? It will appear back in your profile.")
		}
		.alert("Delete Permanently", isPresented: $showDeleteAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Delete", role: .destructive) {
				if let collection = selectedCollection {
					deletePermanently(collection)
				}
			}
		} message: {
			Text("Are you sure you want to permanently delete this collection? This will delete all posts, comments, and media. This action cannot be undone.")
		}
	}
	
	private func loadDeletedCollections() {
		guard let userId = authService.user?.uid else { return }
		isLoading = true
		Task {
			do {
				let collections = try await CollectionService.shared.getDeletedCollections(ownerId: userId)
				await MainActor.run {
					deletedCollections = collections
					isLoading = false
				}
			} catch {
				print("Error loading deleted collections: \(error)")
				await MainActor.run {
					isLoading = false
				}
			}
		}
	}
	
	private func restoreCollection(_ collection: CollectionData) {
		Task {
			do {
				try await CollectionService.shared.recoverCollection(collectionId: collection.id, ownerId: collection.ownerId)
				loadDeletedCollections()
			} catch {
				print("Error restoring collection: \(error)")
			}
		}
	}
	
	private func deletePermanently(_ collection: CollectionData) {
		isDeleting = true
		Task {
			do {
				try await CollectionService.shared.permanentlyDeleteCollection(collectionId: collection.id, ownerId: collection.ownerId)
				await MainActor.run {
					isDeleting = false
					loadDeletedCollections()
				}
			} catch {
				print("Error permanently deleting collection: \(error)")
				await MainActor.run {
					isDeleting = false
				}
			}
		}
	}
}

// MARK: - Deleted Collection Row
struct DeletedCollectionRow: View {
	let collection: CollectionData
	let deletedAt: Date
	let onRestore: () -> Void
	let onDeletePermanently: () -> Void
	@Environment(\.colorScheme) var colorScheme
	@StateObject private var cyServiceManager = CYServiceManager.shared
	@State private var previewPosts: [CollectionPost] = []
	@State private var isLoadingPosts = false
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Header: Image + Name on left, Buttons on right (on top)
			HStack(alignment: .top, spacing: 12) {
				// Left side: Collection Image + Info
				HStack(spacing: 12) {
					// Collection Image (non-clickable, with fallback logic)
					if let imageURL = collection.imageURL, !imageURL.isEmpty {
						// Use collection's profile image if available
						CachedProfileImageView(url: imageURL, size: 50)
							.clipShape(Circle())
					} else {
						// Use user's own profile image as default
						if let userProfileImageURL = cyServiceManager.currentUser?.profileImageURL,
						   !userProfileImageURL.isEmpty {
							CachedProfileImageView(url: userProfileImageURL, size: 50)
								.clipShape(Circle())
						} else {
							// Fallback to default icon if user has no profile image
							DefaultProfileImageView(size: 50)
						}
					}
					
					// Name + Type/Members
					VStack(alignment: .leading, spacing: 4) {
						Text(collection.name)
							.font(.headline)
							.foregroundColor(.primary)
						
						Text(memberLabel)
							.font(.caption)
							.foregroundColor(.secondary)
						
						// Show deleted date
						Text("Deleted \(formatDate(deletedAt))")
							.font(.caption2)
							.foregroundColor(.secondary)
					}
				}
				
				Spacer()
				
				// Right side: Action Buttons (small, side by side, on top, more to the right)
				HStack(spacing: 6) {
					// Restore Button
					Button(action: onRestore) {
						Text("Restore")
							.font(.caption)
							.fontWeight(.medium)
							.foregroundColor(.white)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(Color.blue)
							.cornerRadius(6)
					}
					
					// Delete Permanently Button
					Button(action: onDeletePermanently) {
						Text("Delete")
							.font(.caption)
							.fontWeight(.medium)
							.foregroundColor(.white)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(Color.red)
							.cornerRadius(6)
					}
				}
				.padding(.trailing, 8)
			}
			.padding(.horizontal)
			.padding(.top, 12)
			
			// Description
			if !collection.description.isEmpty {
				Text(collection.description)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(2)
					.padding(.horizontal)
			}
			
			// Grid with actual post images
			HStack(spacing: 8) {
				ForEach(0..<4, id: \.self) { index in
					if index < previewPosts.count {
						// Show actual post image
						let post = previewPosts[index]
						let mediaItem = post.firstMediaItem ?? post.mediaItems.first
						
						if let mediaItem = mediaItem {
							// Show image or video thumbnail
							if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
								WebImage(url: url)
									.resizable()
									.indicator(.activity)
									.transition(.fade(duration: 0.2))
									.scaledToFill()
									.frame(width: 90, height: 130)
									.clipped()
									.cornerRadius(8)
							} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
								// Video thumbnail
								ZStack {
									WebImage(url: url)
										.resizable()
										.indicator(.activity)
										.transition(.fade(duration: 0.2))
										.scaledToFill()
										.frame(width: 90, height: 130)
										.clipped()
										.cornerRadius(8)
									
									// Video play icon overlay
									Image(systemName: "play.circle.fill")
										.font(.system(size: 24))
										.foregroundColor(.white)
										.shadow(radius: 2)
								}
							} else {
								// Fallback placeholder
								Rectangle()
									.fill(Color.gray.opacity(0.2))
									.frame(width: 90, height: 130)
									.cornerRadius(8)
							}
						} else {
							// No media item
							Rectangle()
								.fill(Color.gray.opacity(0.2))
								.frame(width: 90, height: 130)
								.cornerRadius(8)
						}
					} else {
						// Placeholder for missing posts
						Rectangle()
							.fill(Color.gray.opacity(0.2))
							.frame(width: 90, height: 130)
							.cornerRadius(8)
					}
				}
			}
			.padding(.horizontal)
			.padding(.bottom, 12)
		}
		.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
		.cornerRadius(12)
		.onAppear {
			loadPreviewPosts()
		}
	}
	
	private var memberLabel: String {
		if collection.type == "Individual" {
			return "Individual"
		} else {
			return "\(collection.memberCount) member\(collection.memberCount == 1 ? "" : "s")"
		}
	}
	
	// MARK: - Load Preview Posts
	private func loadPreviewPosts() {
		guard !isLoadingPosts else { return }
		isLoadingPosts = true
		
		Task {
			do {
				// Fetch posts from collection (prioritize pinned, then most recent)
				var allPosts = try await CollectionService.shared.getCollectionPostsFromFirebase(collectionId: collection.id)
				
				// Filter out posts from hidden collections and blocked users
				allPosts = await CollectionService.filterPosts(allPosts)
				
				// Sort: pinned first, then by date (newest first)
				let sortedPosts = allPosts.sorted { post1, post2 in
					if post1.isPinned != post2.isPinned {
						return post1.isPinned
					}
					return post1.createdAt > post2.createdAt
				}
				
				// Take first 4 posts
				await MainActor.run {
					previewPosts = Array(sortedPosts.prefix(4))
					isLoadingPosts = false
				}
			} catch {
				print("Error loading preview posts: \(error.localizedDescription)")
				await MainActor.run {
					previewPosts = []
					isLoadingPosts = false
				}
			}
		}
	}
	
	private func formatDate(_ date: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return formatter.localizedString(for: date, relativeTo: Date())
	}
}
