import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct HiddenCollectionsView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@EnvironmentObject var authService: AuthService
	
	@State private var hiddenCollections: [CollectionData] = []
	@State private var isLoading = false
	@State private var userListener: ListenerRegistration?
	
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
				Text("Hidden Collections")
					.font(.title2)
					.fontWeight(.bold)
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Spacer()
				// Refresh button
				Button(action: {
					loadHiddenCollections()
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
			} else if hiddenCollections.isEmpty {
				Spacer()
				VStack(spacing: 16) {
					Image(systemName: "eye.slash")
						.resizable()
						.scaledToFit()
						.frame(width: 100, height: 100)
						.foregroundColor(.gray)
					Text("No Hidden Collections")
						.font(.headline)
						.foregroundColor(.gray)
					Text("Collections you hide will appear here.")
						.font(.subheadline)
						.foregroundColor(.gray)
						.multilineTextAlignment(.center)
				}
				Spacer()
			} else {
				ScrollView {
					LazyVStack(spacing: 16) {
						ForEach(hiddenCollections) { collection in
							HiddenCollectionRow(
								collection: collection,
								onUnhide: {
									unhideCollection(collection)
								}
							)
						}
					}
					.padding()
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
			}
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
		.onAppear {
			loadHiddenCollections()
			setupLiveListener()
		}
		.onDisappear {
			userListener?.remove()
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CollectionUnhidden"))) { notification in
			if let collectionId = notification.object as? String {
				// Remove from list immediately with animation (if not already removed)
				withAnimation(.easeOut(duration: 0.3)) {
				hiddenCollections.removeAll { $0.id == collectionId }
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CurrentUserDidChange"))) { _ in
			// Reload when user data changes
			loadHiddenCollections()
		}
	}
	
	private func setupLiveListener() {
		guard let userId = authService.user?.uid else { return }
		
		// Listen to user document changes to detect when collections are hidden/unhidden
		let db = Firestore.firestore()
		userListener = db.collection("users").document(userId)
			.addSnapshotListener { snapshot, error in
				guard let data = snapshot?.data(),
					  let _ = data["blockedCollectionIds"] as? [String] else {
					return
				}
				
				// Reload collections when blockedCollectionIds changes
				loadHiddenCollections()
			}
	}
	
	private func loadHiddenCollections() {
		isLoading = true
		Task {
			do {
				// Load current user data to get blocked collection IDs
				try await CYServiceManager.shared.loadCurrentUser()
				
				guard let blockedIds = CYServiceManager.shared.currentUser?.blockedCollectionIds,
					  !blockedIds.isEmpty else {
					await MainActor.run {
						hiddenCollections = []
						isLoading = false
					}
					return
				}
				
				// Fetch collection data for each blocked ID using CollectionService
				// FIX-008: Load owner info properly for each collection
				var collections: [CollectionData] = []
				for collectionId in blockedIds {
					if let collection = try? await CollectionService.shared.getCollection(collectionId: collectionId) {
						// If ownerName is empty or "Unknown", try to fetch owner info
						var updatedCollection = collection
						if collection.ownerName.isEmpty || collection.ownerName == "Unknown" {
							// Fetch owner user data to get real username
							if let ownerUser = try? await UserService.shared.getUser(userId: collection.ownerId) {
								// Create updated collection with real owner name
								updatedCollection = CollectionData(
									id: collection.id,
									name: collection.name,
									description: collection.description,
									type: collection.type,
									isPublic: collection.isPublic,
									ownerId: collection.ownerId,
									ownerName: ownerUser.username, // Use real username
									owners: collection.owners,
									imageURL: collection.imageURL,
									invitedUsers: collection.invitedUsers,
									members: collection.members,
									memberCount: collection.memberCount,
									followers: collection.followers,
									followerCount: collection.followerCount,
									allowedUsers: collection.allowedUsers,
									deniedUsers: collection.deniedUsers,
									createdAt: collection.createdAt
								)
							} else {
								print("⚠️ Could not fetch owner info for collection \(collectionId)")
							}
						}
						collections.append(updatedCollection)
					}
				}
				
				await MainActor.run {
					hiddenCollections = collections
					isLoading = false
				}
			} catch {
				print("Error loading hidden collections: \(error)")
				await MainActor.run {
					isLoading = false
				}
			}
		}
	}
	
	@MainActor
	private func unhideCollection(_ collection: CollectionData) {
		let collectionId = collection.id
		
		// Immediately remove from list for smooth UI (optimistic update)
		withAnimation(.easeOut(duration: 0.3)) {
			hiddenCollections.removeAll { $0.id == collectionId }
		}
		
		// Then perform the actual unhide operation
		Task {
			do {
				try await CYServiceManager.shared.unhideCollection(collectionId: collectionId)
				// The notification listener will handle the removal, but we already did it optimistically
				// No need to reload - the list is already updated
				print("✅ Successfully unhid collection: \(collection.name)")
			} catch {
				print("❌ Error unhiding collection: \(error)")
				// If error, reload to restore the collection in case it failed
				await MainActor.run {
					loadHiddenCollections()
				}
			}
		}
	}
}

// MARK: - Hidden Collection Row

struct HiddenCollectionRow: View {
	let collection: CollectionData
	let onUnhide: () -> Void
	@Environment(\.colorScheme) var colorScheme
	@State private var ownerProfileImageURL: String?
	
	var body: some View {
		HStack(spacing: 12) {
			// Collection image with fallback to owner's profile image
			collectionImageView
			
			// Collection info
			VStack(alignment: .leading, spacing: 4) {
				Text(collection.name)
					.font(.headline)
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Text(collection.type == "Individual" ? "Individual" : "\(collection.memberCount) member\(collection.memberCount == 1 ? "" : "s")")
					.font(.caption)
					.foregroundColor(.gray)
				
				// Show owner name
				if !collection.ownerName.isEmpty {
					Text("by @\(collection.ownerName)")
						.font(.caption)
						.foregroundColor(.gray)
				}
				
				if !collection.description.isEmpty {
					Text(collection.description)
						.font(.caption)
						.foregroundColor(.gray)
						.lineLimit(1)
				}
			}
			
			Spacer()
			
			// Unhide button
			Button(action: {
				print("🔘 Unhide button tapped for collection: \(collection.name)")
				onUnhide()
			}) {
				Text("Unhide")
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
		.onAppear {
			// Load owner's profile image if collection has no imageURL
			if collection.imageURL?.isEmpty != false {
				loadOwnerProfileImage()
			}
		}
	}
	
	// MARK: - Collection Image View
	private var collectionImageView: some View {
		Group {
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				// Use collection's profile image if available
				CachedProfileImageView(url: imageURL, size: 60)
					.clipShape(Circle())
			} else if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty {
				// Use owner's profile image as fallback
				CachedProfileImageView(url: ownerImageURL, size: 60)
					.clipShape(Circle())
			} else {
				// Fallback to default icon
				DefaultProfileImageView(size: 60)
			}
		}
	}
	
	// MARK: - Load Owner Profile Image
	private func loadOwnerProfileImage() {
		// Skip if already loaded
		if ownerProfileImageURL != nil {
			return
		}
		
		Task {
			do {
				let owner = try await UserService.shared.getUser(userId: collection.ownerId)
				await MainActor.run {
					ownerProfileImageURL = owner?.profileImageURL
				}
			} catch {
				print("⚠️ HiddenCollectionRow: Could not load owner profile image: \(error)")
			}
		}
	}
}

