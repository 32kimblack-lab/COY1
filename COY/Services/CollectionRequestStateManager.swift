import Foundation
import Combine
import FirebaseAuth

/// Shared state manager for collection request status
/// This ensures request state persists across view recreations and is synchronized everywhere
@MainActor
class CollectionRequestStateManager: ObservableObject {
	static let shared = CollectionRequestStateManager()
	
	@Published private var pendingRequests: Set<String> = []
	private var cancellables = Set<AnyCancellable>()
	private var isInitialized = false
	
	private init() {
		// Listen to notifications to keep state in sync
		NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestSent"))
			.sink { [weak self] notification in
				Task { @MainActor in
					if let collectionId = notification.object as? String ?? notification.userInfo?["collectionId"] as? String,
					   let requesterId = notification.userInfo?["requesterId"] as? String,
					   requesterId == Auth.auth().currentUser?.uid {
						self?.pendingRequests.insert(collectionId)
						print("✅ CollectionRequestStateManager: Added request for collection \(collectionId)")
					}
				}
			}
			.store(in: &cancellables)
		
		NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestCancelled"))
			.sink { [weak self] notification in
				Task { @MainActor in
					if let collectionId = notification.object as? String ?? notification.userInfo?["collectionId"] as? String,
					   let requesterId = notification.userInfo?["requesterId"] as? String,
					   requesterId == Auth.auth().currentUser?.uid {
						self?.pendingRequests.remove(collectionId)
						print("✅ CollectionRequestStateManager: Removed request for collection \(collectionId)")
					}
				}
			}
			.store(in: &cancellables)
		
		// Clear request state when a request is accepted (user becomes a member)
		NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestAccepted"))
			.sink { [weak self] notification in
				Task { @MainActor in
					if let collectionId = notification.object as? String ?? notification.userInfo?["collectionId"] as? String,
					   let requesterId = notification.userInfo?["requesterId"] as? String,
					   requesterId == Auth.auth().currentUser?.uid {
						// Request was accepted, user is now a member - clear request state
						self?.pendingRequests.remove(collectionId)
						print("✅ CollectionRequestStateManager: Cleared request state (request accepted) for collection \(collectionId)")
					}
				}
			}
			.store(in: &cancellables)
		
		// Clear request state when user is removed from or leaves a collection
		NotificationCenter.default.publisher(for: NSNotification.Name("CollectionUpdated"))
			.sink { [weak self] notification in
				Task { @MainActor in
					if let collectionId = notification.object as? String,
					   let userInfo = notification.userInfo,
					   let userId = userInfo["userId"] as? String,
					   userId == Auth.auth().currentUser?.uid,
					   let action = userInfo["action"] as? String,
					   (action == "memberRemoved" || action == "memberLeft") {
						// User was removed or left - clear request state
						self?.pendingRequests.remove(collectionId)
						print("✅ CollectionRequestStateManager: Cleared request state (user removed/left) for collection \(collectionId)")
					}
				}
			}
			.store(in: &cancellables)
	}
	
	func hasPendingRequest(for collectionId: String) -> Bool {
		return pendingRequests.contains(collectionId)
	}
	
	func initializeState() async {
		// Prevent repeated initialization
		guard !isInitialized else { return }
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		do {
			let notifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
			await MainActor.run {
				for notification in notifications {
					if notification.type == "collection_request",
					   let collectionId = notification.collectionId,
					   notification.status == "pending" {
						pendingRequests.insert(collectionId)
					}
				}
				isInitialized = true
				print("✅ CollectionRequestStateManager: Initialized with \(pendingRequests.count) pending requests")
			}
		} catch {
			print("Error initializing request state: \(error)")
		}
	}
}

