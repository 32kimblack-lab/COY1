import Foundation
import FirebaseFirestore

/// CRITICAL: Manages Firestore listeners with automatic cleanup to prevent memory leaks
/// Limits concurrent listeners to prevent battery drain and performance issues
@MainActor
final class FirestoreListenerManager {
	static let shared = FirestoreListenerManager()
	private init() {}
	
	// Track all active listeners by view/screen identifier
	private var listeners: [String: [ListenerRegistration]] = [:]
	
	// CRITICAL: Maximum concurrent listeners per screen (prevents battery drain)
	private let maxListenersPerScreen = 5
	private let maxTotalListeners = 25 // Global limit across all screens
	
	/// Register a listener for a specific screen/view
	/// - Parameters:
	///   - screenId: Unique identifier for the screen (e.g., "CYHome", "ProfileView")
	///   - listenerId: Unique identifier for this specific listener
	///   - registration: The Firestore listener registration
	func registerListener(screenId: String, listenerId: String, registration: ListenerRegistration) {
		// Check global limit
		let totalCount = listeners.values.reduce(0) { $0 + $1.count }
		if totalCount >= maxTotalListeners {
			#if DEBUG
			print("⚠️ FirestoreListenerManager: Max total listeners (\(maxTotalListeners)) reached, removing oldest")
			#endif
			// Remove oldest listeners from first screen
			if let firstScreen = listeners.keys.first, var firstScreenListeners = listeners[firstScreen] {
				firstScreenListeners.first?.remove()
				firstScreenListeners.removeFirst()
				if firstScreenListeners.isEmpty {
					listeners.removeValue(forKey: firstScreen)
				} else {
					listeners[firstScreen] = firstScreenListeners
				}
			}
		}
		
		// Check per-screen limit
		var screenListeners = listeners[screenId] ?? []
		if screenListeners.count >= maxListenersPerScreen {
			#if DEBUG
			print("⚠️ FirestoreListenerManager: Max listeners for \(screenId) reached, removing oldest")
			#endif
			// Remove oldest listener for this screen
			screenListeners.first?.remove()
			screenListeners.removeFirst()
		}
		
		// Add new listener
		screenListeners.append(registration)
		listeners[screenId] = screenListeners
		
		#if DEBUG
		print("✅ FirestoreListenerManager: Registered listener '\(listenerId)' for '\(screenId)' (total: \(totalCount + 1))")
		#endif
	}
	
	/// Remove a specific listener
	func removeListener(screenId: String, listenerId: String) {
		guard var screenListeners = listeners[screenId] else { return }
		
		// Find and remove the listener
		if let index = screenListeners.firstIndex(where: { $0 === screenListeners.first }) {
			screenListeners[index].remove()
			screenListeners.remove(at: index)
		}
		
		if screenListeners.isEmpty {
			listeners.removeValue(forKey: screenId)
		} else {
			listeners[screenId] = screenListeners
		}
	}
	
	/// Remove all listeners for a specific screen (call in onDisappear)
	func removeAllListeners(for screenId: String) {
		guard let screenListeners = listeners[screenId] else { return }
		
		for listener in screenListeners {
			listener.remove()
		}
		
		listeners.removeValue(forKey: screenId)
		
		#if DEBUG
		print("✅ FirestoreListenerManager: Removed all listeners for '\(screenId)'")
		#endif
	}
	
	/// Remove all listeners (use when app goes to background)
	func removeAllListeners() {
		for (screenId, screenListeners) in listeners {
			for listener in screenListeners {
				listener.remove()
			}
		}
		listeners.removeAll()
		
		#if DEBUG
		print("✅ FirestoreListenerManager: Removed all listeners")
		#endif
	}
	
	/// Get count of active listeners (for debugging)
	func getActiveListenerCount() -> Int {
		return listeners.values.reduce(0) { $0 + $1.count }
	}
	
	/// Get count of listeners for a specific screen
	func getListenerCount(for screenId: String) -> Int {
		return listeners[screenId]?.count ?? 0
	}
}
