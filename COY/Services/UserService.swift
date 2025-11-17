import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

@MainActor
final class UserService: ObservableObject {
	static let shared = UserService()
	private init() {}

	struct AppUser: Identifiable {
		var id: String { userId }
		var userId: String
		var name: String
		var username: String
		var profileImageURL: String?
		var backgroundImageURL: String?
		var birthMonth: String
		var birthDay: String
		var birthYear: String
		var email: String
		
		init(userId: String, name: String = "", username: String = "", profileImageURL: String? = nil, backgroundImageURL: String? = nil, birthMonth: String = "", birthDay: String = "", birthYear: String = "", email: String = "") {
			self.userId = userId
			self.name = name
			self.username = username
			self.profileImageURL = profileImageURL
			self.backgroundImageURL = backgroundImageURL
			self.birthMonth = birthMonth
			self.birthDay = birthDay
			self.birthYear = birthYear
			self.email = email
		}
	}

	private var cache: [String: AppUser] = [:]

	func clearUserCache(userId: String) {
		cache[userId] = nil
	}

	func isUsernameAvailable(_ username: String) async throws -> Bool {
		let db = Firestore.firestore()
		// Usernames are stored in lowercase, so check lowercase
		let lowercaseUsername = username.lowercased()
		
		let snapshot = try await db.collection("users")
			.whereField("username", isEqualTo: lowercaseUsername)
			.limit(to: 1)
			.getDocuments()
		
		return snapshot.documents.isEmpty
	}
	
	func getUserByUsername(_ username: String) async throws -> AppUser? {
		let db = Firestore.firestore()
		// Usernames are stored in lowercase, so search lowercase
		let lowercaseUsername = username.lowercased()
		
		let snapshot = try await db.collection("users")
			.whereField("username", isEqualTo: lowercaseUsername)
			.limit(to: 1)
			.getDocuments()
		
		guard let doc = snapshot.documents.first else { return nil }
		
		let data = doc.data()
		return AppUser(
			userId: doc.documentID,
			name: data["name"] as? String ?? "",
			username: data["username"] as? String ?? "",
			profileImageURL: data["profileImageURL"] as? String,
			backgroundImageURL: data["backgroundImageURL"] as? String,
			birthMonth: data["birthMonth"] as? String ?? "",
			birthDay: data["birthDay"] as? String ?? "",
			birthYear: data["birthYear"] as? String ?? "",
			email: data["email"] as? String ?? ""
		)
	}

	func getUser(userId: String) async throws -> AppUser? {
		if let cached = cache[userId] { return cached }
		
		let db = Firestore.firestore()
		let doc = try await db.collection("users").document(userId).getDocument()
		
		guard let data = doc.data() else { return nil }
		
		let user = AppUser(
			userId: userId,
			name: data["name"] as? String ?? "",
			username: data["username"] as? String ?? "",
			profileImageURL: data["profileImageURL"] as? String,
			backgroundImageURL: data["backgroundImageURL"] as? String,
			birthMonth: data["birthMonth"] as? String ?? "",
			birthDay: data["birthDay"] as? String ?? "",
			birthYear: data["birthYear"] as? String ?? "",
			email: data["email"] as? String ?? ""
		)
		
		cache[userId] = user
		return user
	}
	
	func getAllUsers() async throws -> [User] {
		let db = Firestore.firestore()
		let snapshot = try await db.collection("users").getDocuments()
		
		return snapshot.documents.compactMap { doc in
			let data = doc.data()
			return AppUser(
				userId: doc.documentID,
				name: data["name"] as? String ?? "",
				username: data["username"] as? String ?? "",
				profileImageURL: data["profileImageURL"] as? String,
				backgroundImageURL: data["backgroundImageURL"] as? String,
				birthMonth: data["birthMonth"] as? String ?? "",
				birthDay: data["birthDay"] as? String ?? "",
				birthYear: data["birthYear"] as? String ?? "",
				email: data["email"] as? String ?? ""
			)
		}
	}
	
	func updateUserProfile(userId: String, name: String, username: String, profileImage: UIImage?, backgroundImage: UIImage?) async throws -> AppUser {
		let db = Firestore.firestore()
		var updateData: [String: Any] = [
			"name": name,
			"username": username
		]
		
		// Upload images if provided
		if let profileImage = profileImage {
			let profileURL = try await uploadImage(profileImage, path: "profile_images/\(userId).jpg")
			updateData["profileImageURL"] = profileURL
		}
		
		if let backgroundImage = backgroundImage {
			let backgroundURL = try await uploadImage(backgroundImage, path: "background_images/\(userId).jpg")
			updateData["backgroundImageURL"] = backgroundURL
		}
		
		try await db.collection("users").document(userId).updateData(updateData)
		
		// Return updated user
		return try await getUser(userId: userId) ?? AppUser(userId: userId, name: name, username: username)
	}
	
	private func uploadImage(_ image: UIImage, path: String) async throws -> String {
		// Verify user is authenticated before uploading
		guard Auth.auth().currentUser != nil else {
			throw NSError(domain: "UserService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User must be authenticated to upload images"])
		}
		
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			throw NSError(domain: "UserService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image"])
		}
		
		let storage = Storage.storage()
		let ref = storage.reference().child(path)
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		do {
			_ = try await ref.putDataAsync(imageData, metadata: metadata)
			let url = try await ref.downloadURL()
			return url.absoluteString
		} catch {
			// Provide more detailed error information
			print("❌ Storage upload error for path: \(path)")
			print("   Error: \(error.localizedDescription)")
			if let nsError = error as NSError? {
				print("   Domain: \(nsError.domain), Code: \(nsError.code)")
				print("   UserInfo: \(nsError.userInfo)")
			}
			// Re-throw with more context
			throw NSError(domain: "UserService", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Failed to upload image: \(error.localizedDescription)",
				NSUnderlyingErrorKey: error
			])
		}
	}

	func completeProfileSetup(name: String,
							  username: String,
							  email: String,
							  birthMonth: String,
							  birthDay: String,
							  birthYear: String,
							  profileImage: UIImage?,
							  backgroundImage: UIImage?) async throws -> Bool {
		guard let userId = Auth.auth().currentUser?.uid else {
			throw UserError.userNotFound
		}
		
		let db = Firestore.firestore()
		var userData: [String: Any] = [
			"name": name,
			"username": username,
			"email": email,
			"birthMonth": birthMonth,
			"birthDay": birthDay,
			"birthYear": birthYear,
			"createdAt": Timestamp(date: Date())
		]
		
		// Upload profile image if provided
		if let profileImage = profileImage {
			let profileURL = try await uploadImage(profileImage, path: "profile_images/\(userId).jpg")
			userData["profileImageURL"] = profileURL
			print("✅ Profile image uploaded: \(profileURL)")
		} else {
			userData["profileImageURL"] = ""
		}
		
		// Upload background image if provided
		if let backgroundImage = backgroundImage {
			let backgroundURL = try await uploadImage(backgroundImage, path: "background_images/\(userId).jpg")
			userData["backgroundImageURL"] = backgroundURL
			print("✅ Background image uploaded: \(backgroundURL)")
		} else {
			userData["backgroundImageURL"] = ""
		}
		
		// Save to Firestore
		try await db.collection("users").document(userId).setData(userData, merge: true)
		print("✅ User profile saved to Firestore for user: \(userId)")
		
		// Clear cache to force fresh load
		cache[userId] = nil
		
		return true
	}
}

enum UserError: Error {
	case emailTaken
	case usernameTaken
	case userNotFound
}

// Global type alias for User (AppUser)
typealias User = UserService.AppUser

