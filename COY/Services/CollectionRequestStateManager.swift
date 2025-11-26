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
	}
	
	func hasPendingRequest(for collectionId: String) -> Bool {
		return pendingRequests.contains(collectionId)
	}
	
	func initializeState() async {
		guard let currentUserId = Auth.auth().currentUser?.uid else { return }
		
		do {
			let notifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
			await MainActor.run {
				for notification in notifications {
					if notification.type == "collection_request",
					   let collectionId = notification.collectionId,
					   notification.status == "pending" {
						pendingRequests.insert(collectionId)
						print("✅ CollectionRequestStateManager: Initialized request state for collection \(collectionId)")
					}
				}
			}
		} catch {
			print("Error initializing request state: \(error)")
		}
	}
}

