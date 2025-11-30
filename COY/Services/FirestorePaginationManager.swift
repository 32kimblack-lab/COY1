import Foundation
import FirebaseFirestore
import Combine

/// Generic pagination manager for Firestore queries
/// Works with any collection and document type
@MainActor
class FirestorePaginationManager<T: Identifiable>: ObservableObject {
	@Published var items: [T] = []
	@Published var isLoading = false
	@Published var isLoadingMore = false
	@Published var hasMore = true
	@Published var error: Error?
	
	private var lastDocument: DocumentSnapshot?
	private var query: Query?
	private let pageSize: Int
	private let initialPageSize: Int
	private let parser: (QueryDocumentSnapshot) throws -> T
	private var isLoadingInitial = false
	
	/// Initialize pagination manager
	/// - Parameters:
	///   - query: Base Firestore query (should NOT include limit)
	///   - initialPageSize: Number of items to load initially
	///   - pageSize: Number of items to load per subsequent page
	///   - parser: Closure to convert Firestore document to your model type
	init(
		query: Query,
		initialPageSize: Int = 20,
		pageSize: Int = 15,
		parser: @escaping (QueryDocumentSnapshot) throws -> T
	) {
		self.query = query
		self.initialPageSize = initialPageSize
		self.pageSize = pageSize
		self.parser = parser
	}
	
	/// Load initial page of items
	func loadInitial() async throws {
		guard !isLoadingInitial else { return }
		guard let query = query else { return }
		
		isLoadingInitial = true
		isLoading = true
		error = nil
		
		do {
			let paginatedQuery = query
				.limit(to: initialPageSize)
			
			let snapshot = try await paginatedQuery.getDocuments()
			
			var loadedItems: [T] = []
			for document in snapshot.documents {
				do {
					let item = try parser(document)
					loadedItems.append(item)
				} catch {
					print("⚠️ FirestorePaginationManager: Error parsing document \(document.documentID): \(error)")
					// Continue with other documents
				}
			}
			
			items = loadedItems
			lastDocument = snapshot.documents.last
			hasMore = snapshot.documents.count == initialPageSize
			
			print("✅ FirestorePaginationManager: Loaded \(loadedItems.count) initial items, hasMore: \(hasMore)")
		} catch {
			self.error = error
			print("❌ FirestorePaginationManager: Error loading initial page: \(error)")
			throw error
		}
		
		isLoading = false
		isLoadingInitial = false
	}
	
	/// Load next page of items
	func loadMore() async throws {
		guard !isLoadingMore && !isLoading else { return }
		guard hasMore else { return }
		guard let query = query else { return }
		guard let lastDoc = lastDocument else {
			// If no last document, try loading initial
			try await loadInitial()
			return
		}
		
		isLoadingMore = true
		error = nil
		
		do {
			let paginatedQuery = query
				.start(afterDocument: lastDoc)
				.limit(to: pageSize)
			
			let snapshot = try await paginatedQuery.getDocuments()
			
			var newItems: [T] = []
			for document in snapshot.documents {
				do {
					let item = try parser(document)
					newItems.append(item)
				} catch {
					print("⚠️ FirestorePaginationManager: Error parsing document \(document.documentID): \(error)")
					// Continue with other documents
				}
			}
			
			items.append(contentsOf: newItems)
			lastDocument = snapshot.documents.last
			hasMore = snapshot.documents.count == pageSize
			
			print("✅ FirestorePaginationManager: Loaded \(newItems.count) more items, total: \(items.count), hasMore: \(hasMore)")
		} catch {
			self.error = error
			print("❌ FirestorePaginationManager: Error loading more items: \(error)")
			throw error
		}
		
		isLoadingMore = false
	}
	
	/// Reset pagination state
	func reset() {
		items.removeAll()
		lastDocument = nil
		hasMore = true
		isLoading = false
		isLoadingMore = false
		isLoadingInitial = false
		error = nil
	}
	
	/// Refresh data (reload from beginning)
	func refresh() async throws {
		reset()
		try await loadInitial()
	}
	
	/// Update the base query (useful for filters/search)
	func updateQuery(_ newQuery: Query) {
		reset()
		query = newQuery
	}
}
