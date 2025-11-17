import Foundation
import UIKit
import FirebaseAuth

// MARK: - API Client for Backend Integration
@MainActor
final class APIClient {
	static let shared = APIClient()
	private init() {}
	
	// Vercel API URL - Update this if your deployment URL changes
	private let baseURL = "https://backend-delta-two-66.vercel.app/api"
	
	// MARK: - User Profile Endpoints
	
	/// Create or update user profile
	func createOrUpdateUser(
		userId: String,
		name: String,
		username: String,
		email: String,
		birthMonth: String,
		birthDay: String,
		birthYear: String,
		profileImage: UIImage?,
		backgroundImage: UIImage?
	) async throws -> UserResponse {
		var request = try await createRequest(endpoint: "/users/\(userId)", method: "PUT")
		
		// Create multipart form data
		var formData = [
			"name": name,
			"username": username,
			"email": email,
			"birthMonth": birthMonth,
			"birthDay": birthDay,
			"birthYear": birthYear
		]
		
		// Add images if provided
		var imageDataDict: [String: Data] = [:]
		if let profileImage = profileImage,
		   let profileData = profileImage.jpegData(compressionQuality: 0.8) {
			formData["profileImage"] = "profileImage"
			imageDataDict["profileImage"] = profileData
		}
		
		if let backgroundImage = backgroundImage,
		   let bgData = backgroundImage.jpegData(compressionQuality: 0.8) {
			formData["backgroundImage"] = "backgroundImage"
			imageDataDict["backgroundImage"] = bgData
		}
		
		request.httpBody = try createMultipartBody(formData: formData, images: imageDataDict)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(UserResponse.self, from: data)
	}
	
	/// Get user profile
	func getUser(userId: String) async throws -> UserResponse {
		let request = try await createRequest(endpoint: "/users/\(userId)", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(UserResponse.self, from: data)
	}
	
	// MARK: - Collection Endpoints
	
	/// Create a new collection
	func createCollection(
		name: String,
		description: String,
		type: String,
		isPublic: Bool,
		ownerId: String,
		ownerName: String,
		image: UIImage?,
		invitedUsers: [String]
	) async throws -> CollectionResponse {
		var request = try await createRequest(endpoint: "/collections", method: "POST")
		
		var formData: [String: String] = [
			"name": name,
			"description": description,
			"type": type,
			"isPublic": String(isPublic),
			"ownerId": ownerId,
			"ownerName": ownerName,
			"invitedUsers": invitedUsers.joined(separator: ",")
		]
		
		var imageDataDict: [String: Data] = [:]
		if let image = image,
		   let imgData = image.jpegData(compressionQuality: 0.8) {
			formData["image"] = "image"
			imageDataDict["image"] = imgData
		}
		
		request.httpBody = try createMultipartBody(formData: formData, images: imageDataDict)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(CollectionResponse.self, from: data)
	}
	
	/// Get user's collections
	func getUserCollections(userId: String) async throws -> [CollectionResponse] {
		let request = try await createRequest(endpoint: "/users/\(userId)/collections", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode([CollectionResponse].self, from: data)
	}
	
	/// Get visible collections (for home/search feeds)
	func getVisibleCollections() async throws -> [CollectionResponse] {
		let request = try await createRequest(endpoint: "/collections/visible", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode([CollectionResponse].self, from: data)
	}
	
	/// Get a specific collection
	func getCollection(collectionId: String) async throws -> CollectionResponse {
		let request = try await createRequest(endpoint: "/collections/\(collectionId)", method: "GET")
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(CollectionResponse.self, from: data)
	}
	
	/// Update user preferences
	func updateUser(
		userId: String,
		collectionSortPreference: String? = nil,
		customCollectionOrder: [String]? = nil
	) async throws -> UserResponse {
		var request = try await createRequest(endpoint: "/users/\(userId)", method: "PATCH")
		
		var body: [String: Any] = [:]
		if let sortPreference = collectionSortPreference {
			body["collectionSortPreference"] = sortPreference
		}
		if let customOrder = customCollectionOrder {
			body["customCollectionOrder"] = customOrder
		}
		
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		try validateResponse(response)
		return try JSONDecoder().decode(UserResponse.self, from: data)
	}
	
	// MARK: - Helper Methods
	
	private func createRequest(endpoint: String, method: String) async throws -> URLRequest {
		guard let url = URL(string: "\(baseURL)\(endpoint)") else {
			throw APIError.invalidURL
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = method
		
		// Add Firebase Auth token for authentication
		if let idToken = try await getFirebaseAuthToken() {
			request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
		}
		
		return request
	}
	
	/// Get Firebase Auth ID token for backend authentication
	private func getFirebaseAuthToken() async throws -> String? {
		guard let user = Auth.auth().currentUser else {
			return nil
		}
		return try await user.getIDToken()
	}
	
	private func validateResponse(_ response: URLResponse) throws {
		guard let httpResponse = response as? HTTPURLResponse else {
			throw APIError.invalidResponse
		}
		
		guard (200...299).contains(httpResponse.statusCode) else {
			throw APIError.httpError(statusCode: httpResponse.statusCode, message: "Request failed")
		}
	}
	
	private let boundary = "Boundary-\(UUID().uuidString)"
	
	private func createMultipartBody(formData: [String: String], images: [String: Data]) throws -> Data {
		var body = Data()
		
		// Add form fields
		for (key, value) in formData {
			body.append("--\(boundary)\r\n".data(using: .utf8)!)
			body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
			body.append("\(value)\r\n".data(using: .utf8)!)
		}
		
		// Add image files
		for (key, data) in images {
			body.append("--\(boundary)\r\n".data(using: .utf8)!)
			body.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(key).jpg\"\r\n".data(using: .utf8)!)
			body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
			body.append(data)
			body.append("\r\n".data(using: .utf8)!)
		}
		
		body.append("--\(boundary)--\r\n".data(using: .utf8)!)
		return body
	}
}

// MARK: - Response Models

struct UserResponse: Codable {
	let userId: String
	let name: String
	let username: String
	let email: String
	let profileImageURL: String?
	let backgroundImageURL: String?
	let birthMonth: String?
	let birthDay: String?
	let birthYear: String?
	let blockedUsers: [String]?
	let blockedCollectionIds: [String]?
	let hiddenPostIds: [String]?
	let starredPostIds: [String]?
	let collectionSortPreference: String?
	let customCollectionOrder: [String]?
}

struct CollectionResponse: Codable {
	let id: String
	let name: String
	let description: String
	let type: String
	let isPublic: Bool
	let ownerId: String
	let ownerName: String
	let imageURL: String?
	let members: [String]
	let memberCount: Int
	let createdAt: String
}

// MARK: - API Errors

enum APIError: Error, LocalizedError {
	case invalidURL
	case invalidResponse
	case httpError(statusCode: Int, message: String)
	case encodingError
	case decodingError(Error)
	
	var errorDescription: String? {
		switch self {
		case .invalidURL:
			return "Invalid API URL"
		case .invalidResponse:
			return "Invalid response from server"
		case .httpError(let code, let message):
			return "HTTP \(code): \(message)"
		case .encodingError:
			return "Failed to encode request"
		case .decodingError(let error):
			return "Failed to decode response: \(error.localizedDescription)"
		}
	}
}

