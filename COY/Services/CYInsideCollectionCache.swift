import Foundation

@MainActor
final class CYInsideCollectionCache {
	static let shared = CYInsideCollectionCache()
	private init() {}
	
	private var cache: [String: Any] = [:]
	
	func clearCache(for collectionId: String) {
		cache.removeValue(forKey: collectionId)
		print("🗑️ CYInsideCollectionCache: Cleared cache for collection \(collectionId)")
	}
	
	func clearAll() {
		cache.removeAll()
		print("🗑️ CYInsideCollectionCache: Cleared all cache")
	}
}

