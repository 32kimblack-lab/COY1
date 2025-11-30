import Foundation
@preconcurrency import FirebaseFirestore

/// Manages Firestore listener lifecycle to prevent memory leaks
@MainActor
final class ListenerCleanupManager {
	static let shared = ListenerCleanupManager()
	private init() {}
	
	// Track active listeners
	nonisolated(unsafe) private var activeListeners: [String: ListenerRegistration] = [:]
	private let queue = DispatchQueue(label: "com.coy.listenercleanup")
	
	/// Register a listener with automatic cleanup tracking
	func registerListener(id: String, registration: ListenerRegistration) {
		queue.async {
			// Remove old listener if exists
			self.activeListeners[id]?.remove()
			// Add new listener
			self.activeListeners[id] = registration
		}
	}
	
	/// Remove a specific listener
	func removeListener(id: String) {
		queue.async {
			self.activeListeners[id]?.remove()
			self.activeListeners.removeValue(forKey: id)
		}
	}
	
	/// Remove all listeners (use when view disappears)
	func removeAllListeners() {
		queue.async {
			for (_, listener) in self.activeListeners {
				listener.remove()
			}
			self.activeListeners.removeAll()
		}
	}
	
	/// Get count of active listeners (for debugging)
	func getActiveListenerCount() -> Int {
		return queue.sync {
			return activeListeners.count
		}
	}
}
