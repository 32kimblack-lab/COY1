import Foundation
import UIKit

// MARK: - API Client Protocol
protocol APIClientProtocol {
	func verifyToken(
		uid: String,
		email: String?,
		name: String?,
		username: String?,
		profileImageURL: String?,
		backgroundImageURL: String?
	) async throws -> UserResponse
}

// MARK: - Config
struct Config {
	static var isBackendEnabled: Bool {
		// Check if backend URL is configured
		// For now, default to true if API client is available
		return true
	}
}

// MARK: - Active Instance Extension
extension APIClient {
	static var activeInstance: APIClient {
		return APIClient.shared
	}
}

// Make APIClient conform to APIClientProtocol
extension APIClient: APIClientProtocol {
	func verifyToken(
		uid: String,
		email: String?,
		name: String?,
		username: String?,
		profileImageURL: String?,
		backgroundImageURL: String?
	) async throws -> UserResponse {
		// Create or update user with the provided data
		return try await createOrUpdateUser(
			userId: uid,
			name: name ?? "",
			username: username ?? "",
			email: email ?? "",
			birthMonth: "",
			birthDay: "",
			birthYear: "",
			profileImage: nil,
			backgroundImage: nil
		)
	}
}

