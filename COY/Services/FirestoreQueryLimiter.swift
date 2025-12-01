import Foundation
import FirebaseFirestore

/// Enforces query limits and prevents unbounded reads (CRITICAL for cost control)
/// All Firestore queries should use this helper to ensure limits are always applied
@MainActor
final class FirestoreQueryLimiter {
	static let shared = FirestoreQueryLimiter()
	private init() {}
	
	// Maximum allowed query limits per query type
	private let maxPostsPerQuery = 50
	private let maxCollectionsPerQuery = 50
	private let maxUsersPerQuery = 50
	private let maxCommentsPerQuery = 100
	private let maxMessagesPerQuery = 50
	
	/// Apply limit to a query based on its collection type
	func applyLimit<T>(to query: Query, collectionType: CollectionType, requestedLimit: Int? = nil) -> Query {
		let maxLimit: Int
		let defaultLimit: Int
		
		switch collectionType {
		case .posts:
			maxLimit = maxPostsPerQuery
			defaultLimit = 25
		case .collections:
			maxLimit = maxCollectionsPerQuery
			defaultLimit = 25
		case .users:
			maxLimit = maxUsersPerQuery
			defaultLimit = 20
		case .comments:
			maxLimit = maxCommentsPerQuery
			defaultLimit = 50
		case .messages:
			maxLimit = maxMessagesPerQuery
			defaultLimit = 30
		case .other:
			maxLimit = 50
			defaultLimit = 25
		}
		
		// Use requested limit if provided and valid, otherwise use default
		let finalLimit = min(requestedLimit ?? defaultLimit, maxLimit)
		
		// CRITICAL: Always apply limit - never allow unbounded queries
		return query.limit(to: finalLimit)
	}
	
	enum CollectionType {
		case posts
		case collections
		case users
		case comments
		case messages
		case other
	}
}

/// Extension to make Query limiting easier
extension Query {
	/// Apply a safe limit to this query (prevents unbounded reads)
	func safeLimit(_ limit: Int, maxAllowed: Int = 50) -> Query {
		let safeLimit = min(limit, maxAllowed)
		return self.limit(to: safeLimit)
	}
}
