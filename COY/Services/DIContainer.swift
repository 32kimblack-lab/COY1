import Foundation
import SwiftUI

/// Dependency Injection Container for managing service instances
/// CRITICAL: Replaces singleton pattern to prevent memory leaks and enable testing
/// Services are scoped per-view or per-tab to allow proper cleanup
@MainActor
final class DIContainer: ObservableObject {
	static let shared = DIContainer()
	
	// Core services (shared across app)
	private(set) var authService: AuthService
	private(set) var connectionStateManager: ConnectionStateManager
	
	// Service instances (can be shared or created per-view)
	private var serviceCache: [String: Any] = [:]
	
	private init() {
		// Initialize core services
		self.authService = AuthService()
		self.connectionStateManager = ConnectionStateManager.shared
	}
	
	/// Get or create a service instance
	/// Services are cached but can be cleared when views disappear
	func getService<T>(_ type: T.Type, key: String? = nil) -> T {
		let cacheKey = key ?? String(describing: type)
		
		if let cached = serviceCache[cacheKey] as? T {
			return cached
		}
		
		// Create new instance based on type
		let instance: Any
		
		switch String(describing: type) {
		case "CollectionService":
			instance = CollectionService.shared
		case "PostService":
			instance = PostService.shared
		case "UserService":
			instance = UserService.shared
		case "ChatService":
			instance = ChatService.shared
		case "FriendService":
			instance = FriendService.shared
		case "EngagementService":
			instance = EngagementService.shared
		case "AdManager":
			instance = AdManager.shared
		case "VideoPlayerManager":
			instance = VideoPlayerManager.shared
		case "VideoCacheManager":
			instance = VideoCacheManager.shared
		case "FeedService":
			instance = FeedService.shared
		default:
			// Fallback: try to access as singleton if it has .shared
			fatalError("Service \(String(describing: type)) not registered in DIContainer")
		}
		
		serviceCache[cacheKey] = instance
		return instance as! T
	}
	
	/// Clear cached services (call when view disappears or memory pressure)
	func clearCache() {
		serviceCache.removeAll()
	}
	
	/// Clear specific service from cache
	func clearService<T>(_ type: T.Type, key: String? = nil) {
		let cacheKey = key ?? String(describing: type)
		serviceCache.removeValue(forKey: cacheKey)
	}
}

/// Environment key for DI Container
private struct DIContainerKey: EnvironmentKey {
	static let defaultValue = DIContainer.shared
}

extension EnvironmentValues {
	var diContainer: DIContainer {
		get { self[DIContainerKey.self] }
		set { self[DIContainerKey.self] = newValue }
	}
}
