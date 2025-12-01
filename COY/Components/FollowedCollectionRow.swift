import SwiftUI
import FirebaseFirestore

/// Row view for followed collections in side menu
/// Moved from CYHome.swift for better organization
struct FollowedCollectionRow: View {
	let collection: CollectionData
	let onUnfollow: () -> Void
	@State private var ownerProfileImageURL: String?
	@State private var ownerUsername: String?
	@State private var ownerProfileListener: ListenerRegistration?
	@Environment(\.colorScheme) var colorScheme
	
	// Computed property for username and type text
	private var usernameAndTypeText: String {
		var text = ""
		if let username = ownerUsername {
			text = "@\(username) • "
		}
		text += collection.type == "Individual" ? "Individual" : "\(collection.memberCount) members"
		return text
	}
	
	var body: some View {
		HStack(spacing: 12) {
			// Collection profile image (matching NotificationRow size: 50)
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				CachedProfileImageView(url: imageURL, size: 50)
					.clipShape(Circle())
			} else {
				if let ownerImageURL = ownerProfileImageURL, !ownerImageURL.isEmpty {
					CachedProfileImageView(url: ownerImageURL, size: 50)
						.clipShape(Circle())
				} else {
					DefaultProfileImageView(size: 50)
				}
			}
			
			// Collection info (matching NotificationRow text styling)
			VStack(alignment: .leading, spacing: 4) {
				// Collection name (matching NotificationRow message font: .subheadline)
				Text(collection.name)
					.font(.subheadline)
					.foregroundColor(.primary)
					.lineLimit(2)
					.multilineTextAlignment(.leading)
					.fixedSize(horizontal: false, vertical: true)
				
				// Username • Type (matching NotificationRow time font: .caption)
				Text(usernameAndTypeText)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(2)
					.multilineTextAlignment(.leading)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			
			Spacer()
			
			// Unfollow button (matching Accept/Deny button sizing)
			Button(action: onUnfollow) {
				Text("Unfollow")
					.font(.system(size: 12, weight: .semibold))
					.foregroundColor(.white)
					.frame(minWidth: 60, maxWidth: 60)
					.padding(.vertical, 6)
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
		.task {
			await loadOwnerInfo()
			setupOwnerProfileListener()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProfileUpdated"))) { notification in
			// Reload owner info when profile is updated
			if let userId = notification.userInfo?["userId"] as? String,
			   userId == collection.ownerId {
				Task {
					await loadOwnerInfo()
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("OwnerProfileImageUpdated"))) { notification in
			// Update owner info when real-time listener detects changes
			if let collectionId = notification.object as? String,
			   collectionId == collection.id,
			   let ownerId = notification.userInfo?["ownerId"] as? String,
			   ownerId == collection.ownerId {
				if let newProfileImageURL = notification.userInfo?["profileImageURL"] as? String {
					ownerProfileImageURL = newProfileImageURL
				}
				if let newUsername = notification.userInfo?["username"] as? String {
					ownerUsername = newUsername
				}
			}
		}
		.onDisappear {
			// CRITICAL: Clean up listener when view disappears
			ownerProfileListener?.remove()
			ownerProfileListener = nil
			FirestoreListenerManager.shared.removeAllListeners(for: "FollowedCollectionRow")
		}
	}
	
	// MARK: - Helper Functions
	private func loadOwnerInfo() async {
		if let owner = try? await UserService.shared.getUser(userId: collection.ownerId) {
			await MainActor.run {
				ownerProfileImageURL = owner.profileImageURL
				ownerUsername = owner.username
			}
		}
	}
	
	// MARK: - Real-time Listener for Owner's Profile
	private func setupOwnerProfileListener() {
		// Remove existing listener if any
		ownerProfileListener?.remove()
		
		// Set up real-time Firestore listener for the owner's profile
		let db = Firestore.firestore()
		let collectionId = collection.id
		let ownerId = collection.ownerId
		
		ownerProfileListener = db.collection("users").document(ownerId).addSnapshotListener { snapshot, error in
			Task { @MainActor in
				if let error = error {
					print("❌ FollowedCollectionRow: Error listening to owner profile updates: \(error.localizedDescription)")
					return
				}
				
				guard let snapshot = snapshot, let data = snapshot.data() else {
					return
				}
				
				// Immediately update owner info from Firestore (real-time)
				let newProfileImageURL = data["profileImageURL"] as? String
				let newUsername = data["username"] as? String ?? ""
				NotificationCenter.default.post(
					name: Notification.Name("OwnerProfileImageUpdated"),
					object: collectionId,
					userInfo: ["ownerId": ownerId, "profileImageURL": newProfileImageURL as Any, "username": newUsername]
				)
				print("🔄 FollowedCollectionRow: Owner profile updated in real-time from Firestore")
			}
		}
		
		// Register with FirestoreListenerManager
		if let listener = ownerProfileListener {
			FirestoreListenerManager.shared.registerListener(
				screenId: "FollowedCollectionRow",
				listenerId: "\(collectionId)_owner",
				registration: listener
			)
		}
	}
}
