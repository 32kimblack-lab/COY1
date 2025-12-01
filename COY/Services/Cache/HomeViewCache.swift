import Foundation

/// Cache for CYHome view to prevent unnecessary reloads
/// Moved from CYHome.swift for better organization
final class HomeViewCache {
	static let shared = HomeViewCache()
	private init() {}
	
	private var hasLoadedDataOnce = false
	private var cachedFollowedCollections: [CollectionData] = []
	private var cachedPostsWithCollections: [(post: CollectionPost, collection: CollectionData)] = []
	private var cachedFollowedCollectionIds: Set<String> = []
	
	func hasDataLoaded() -> Bool {
		return hasLoadedDataOnce
	}
	
	func getCachedData() -> (collections: [CollectionData], postsWithCollections: [(post: CollectionPost, collection: CollectionData)], followedIds: Set<String>) {
		return (cachedFollowedCollections, cachedPostsWithCollections, cachedFollowedCollectionIds)
	}
	
	func setCachedData(collections: [CollectionData], postsWithCollections: [(post: CollectionPost, collection: CollectionData)], followedIds: Set<String>) {
		self.cachedFollowedCollections = collections
		self.cachedPostsWithCollections = postsWithCollections
		self.cachedFollowedCollectionIds = followedIds
		self.hasLoadedDataOnce = true
	}
	
	func clearCache() {
		hasLoadedDataOnce = false
		cachedFollowedCollections.removeAll()
		cachedPostsWithCollections.removeAll()
		cachedFollowedCollectionIds.removeAll()
	}
	
	func matchesCurrentFollowedIds(_ currentIds: Set<String>) -> Bool {
		return cachedFollowedCollectionIds == currentIds
	}
}
