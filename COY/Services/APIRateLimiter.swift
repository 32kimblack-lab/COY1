import Foundation

/// Rate limiter for API calls to prevent overwhelming backend
@MainActor
final class APIRateLimiter {
	static let shared = APIRateLimiter()
	private init() {}
	
	// Rate limiting configuration
	private let maxRequestsPerMinute = 30 // Limit to 30 requests per minute per user
	private let maxConcurrentRequests = 5 // Limit concurrent requests
	
	// Use nonisolated storage for thread-safe access from DispatchQueue
	nonisolated private final class TimestampStorage {
		var timestamps: [Date] = []
		private let lock = NSLock()
		
		func removeAll(where predicate: (Date) -> Bool) {
			lock.lock()
			defer { lock.unlock() }
			timestamps.removeAll(where: predicate)
		}
		
		func append(_ date: Date) {
			lock.lock()
			defer { lock.unlock() }
			timestamps.append(date)
		}
		
		var count: Int {
			lock.lock()
			defer { lock.unlock() }
			return timestamps.count
		}
	}
	
	nonisolated private let timestampStorage = TimestampStorage()
	private var activeRequestCount = 0
	private let queue = DispatchQueue(label: "com.coy.apiratelimiter")
	
	/// Execute an API request with rate limiting
	func execute<T>(_ operation: @escaping () async throws -> T) async throws -> T {
		// Wait for available slot
		await waitForAvailableSlot()
		
		// Record request timestamp
		recordRequest()
		
		// Execute request
		defer {
			activeRequestCount -= 1
		}
		activeRequestCount += 1
		
		return try await operation()
	}
	
	private func waitForAvailableSlot() async {
		// Wait for concurrent request slot
		while activeRequestCount >= maxConcurrentRequests {
			try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
		}
		
		// Wait for rate limit (requests per minute)
		while true {
			let now = Date()
			let oneMinuteAgo = now.addingTimeInterval(-60)
			
			let canProceed = await withCheckedContinuation { continuation in
				queue.async {
					// Remove old timestamps
					self.timestampStorage.removeAll { $0 < oneMinuteAgo }
					
					// Check if we're under the limit
					let canProceed = self.timestampStorage.count < self.maxRequestsPerMinute
					continuation.resume(returning: canProceed)
				}
			}
			
			if canProceed {
				break
			}
			
			// Wait a bit before checking again
			try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
		}
	}
	
	private func recordRequest() {
		queue.async {
			self.timestampStorage.append(Date())
		}
	}
}
