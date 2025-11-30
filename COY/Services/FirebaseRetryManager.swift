import Foundation
import FirebaseFirestore
import FirebaseStorage

/// Manages retry logic with exponential backoff for Firebase operations
/// Prevents app crashes from rate limits and temporary failures
@MainActor
class FirebaseRetryManager {
	static let shared = FirebaseRetryManager()
	private init() {}
	
	// Maximum number of retry attempts
	private let maxRetries = 3
	// Initial delay in seconds
	private let initialDelay: TimeInterval = 1.0
	// Maximum delay in seconds
	private let maxDelay: TimeInterval = 30.0
	
	/// Execute a Firebase operation with automatic retry and exponential backoff
	func executeWithRetry<T>(
		operation: @escaping () async throws -> T,
		operationName: String = "Firebase operation"
	) async throws -> T {
		var lastError: Error?
		var delay = initialDelay
		
		for attempt in 0...maxRetries {
			do {
				return try await operation()
			} catch {
				lastError = error
				
				// Check if error is retryable
				if !isRetryableError(error) {
					print("❌ \(operationName): Non-retryable error: \(error.localizedDescription)")
					throw error
				}
				
				// Don't retry on last attempt
				if attempt == maxRetries {
					print("❌ \(operationName): Failed after \(maxRetries + 1) attempts: \(error.localizedDescription)")
					throw error
				}
				
				// Calculate exponential backoff delay
				let backoffDelay = min(delay * pow(2.0, Double(attempt)), maxDelay)
				
				print("⚠️ \(operationName): Attempt \(attempt + 1) failed, retrying in \(String(format: "%.1f", backoffDelay))s...")
				print("   Error: \(error.localizedDescription)")
				
				// Wait before retrying
				try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
				delay = backoffDelay
			}
		}
		
		// Should never reach here, but just in case
		if let error = lastError {
			throw error
		}
		throw NSError(domain: "FirebaseRetryManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])
	}
	
	/// Check if an error is retryable (network issues, rate limits, temporary failures)
	private func isRetryableError(_ error: Error) -> Bool {
		let nsError = error as NSError
		
		// Firebase Firestore errors
		if nsError.domain.contains("FIRFirestoreErrorDomain") {
			// Rate limit errors (code 8)
			if nsError.code == 8 {
				return true
			}
			// Resource exhausted (code 8)
			if nsError.code == 8 {
				return true
			}
			// Unavailable (code 14)
			if nsError.code == 14 {
				return true
			}
			// Deadline exceeded (code 4)
			if nsError.code == 4 {
				return true
			}
		}
		
		// Firebase Storage errors
		if nsError.domain.contains("FIRStorageErrorDomain") {
			// Retry on network errors
			return true
		}
		
		// Network errors (URLError)
		if nsError.domain == NSURLErrorDomain {
			// Network connection errors
			if nsError.code == NSURLErrorNotConnectedToInternet ||
			   nsError.code == NSURLErrorTimedOut ||
			   nsError.code == NSURLErrorNetworkConnectionLost ||
			   nsError.code == NSURLErrorCannotConnectToHost {
				return true
			}
		}
		
		// Generic network errors
		let errorDescription = nsError.localizedDescription.lowercased()
		if errorDescription.contains("network") ||
		   errorDescription.contains("timeout") ||
		   errorDescription.contains("connection") ||
		   errorDescription.contains("quota") ||
		   errorDescription.contains("rate limit") ||
		   errorDescription.contains("resource exhausted") {
			return true
		}
		
		return false
	}
	
	/// Get user-friendly error message
	func getUserFriendlyErrorMessage(_ error: Error) -> String {
		let nsError = error as NSError
		
		// Firebase quota exceeded
		if nsError.localizedDescription.contains("quota") || nsError.localizedDescription.contains("rate limit") {
			return "The app is experiencing high traffic. Please try again in a moment."
		}
		
		// Network errors
		if nsError.domain == NSURLErrorDomain {
			if nsError.code == NSURLErrorNotConnectedToInternet {
				return "No internet connection. Please check your network and try again."
			}
			if nsError.code == NSURLErrorTimedOut {
				return "Request timed out. Please try again."
			}
		}
		
		// Generic error
		return "Something went wrong. Please try again."
	}
}

