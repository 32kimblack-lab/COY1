import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct HiddenCollectionsView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@EnvironmentObject var authService: AuthService
	
	@State private var hiddenCollections: [CollectionData] = []
	@State private var isLoading = false
	@State private var showUnhideAlert = false
	@State private var selectedCollection: CollectionData?
	@State private var userListener: ListenerRegistration?
	
	var body: some View {
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
									selectedCollection = collection
									showUnhideAlert = true
								}
							)
						}
					}
					.padding()
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
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
				// Remove from list immediately
				hiddenCollections.removeAll { $0.id == collectionId }
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("CurrentUserDidChange"))) { _ in
			// Reload when user data changes
			loadHiddenCollections()
		}
		.alert("Unhide Collection", isPresented: $showUnhideAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Unhide", role: .destructive) {
				if let collection = selectedCollection {
					unhideCollection(collection)
				}
			}
		} message: {
			Text("Are you sure you want to unhide this collection?")
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
	
	private func unhideCollection(_ collection: CollectionData) {
		Task {
			do {
				try await CYServiceManager.shared.unhideCollection(collectionId: collection.id)
				// Reload to ensure consistency
				loadHiddenCollections()
			} catch {
				print("Error unhiding collection: \(error)")
			}
		}
	}
}

// MARK: - Hidden Collection Row

struct HiddenCollectionRow: View {
	let collection: CollectionData
	let onUnhide: () -> Void
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		HStack(spacing: 12) {
			// Collection image
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				CachedProfileImageView(url: imageURL, size: 60)
					.clipShape(Circle())
			} else {
				Circle()
					.fill(Color.gray.opacity(0.3))
					.frame(width: 60, height: 60)
					.overlay(
						Image(systemName: "photo")
							.foregroundColor(.gray)
					)
			}
			
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
			Button(action: onUnhide) {
				Text("Unhide")
					.font(.subheadline)
					.fontWeight(.semibold)
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 8)
					.background(Color.blue)
					.cornerRadius(8)
			}
		}
		.padding()
		.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
		.cornerRadius(12)
	}
}

