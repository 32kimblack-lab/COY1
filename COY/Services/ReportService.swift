import Foundation
import FirebaseFirestore
import FirebaseAuth

class ReportService {
	static let shared = ReportService()
	private let db = Firestore.firestore()
	
	private init() {}
	
	/// Report a user
	/// - Parameters:
	///   - reportedUserId: The ID of the user being reported
	///   - reason: Optional reason for the report
	/// - Returns: Success status
	func reportUser(reportedUserId: String, reason: String? = nil) async throws {
		guard let reporterId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "ReportService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Prevent users from reporting themselves
		if reporterId == reportedUserId {
			throw NSError(domain: "ReportService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Cannot report yourself"])
		}
		
		// Create report document
		let reportData: [String: Any] = [
			"reporterId": reporterId,
			"reportedUserId": reportedUserId,
			"reason": reason ?? "No reason provided",
			"type": "user",
			"createdAt": Timestamp(),
			"status": "pending"
		]
		
		// Save to Firestore in a reports collection
		try await db.collection("reports").addDocument(data: reportData)
		
		print("✅ ReportService: User report submitted successfully")
	}
	
	/// Report a collection
	/// - Parameters:
	///   - collectionId: The ID of the collection being reported
	///   - reason: Optional reason for the report
	/// - Returns: Success status
	func reportCollection(collectionId: String, reason: String? = nil) async throws {
		guard let reporterId = Auth.auth().currentUser?.uid else {
			throw NSError(domain: "ReportService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
		}
		
		// Create report document
		let reportData: [String: Any] = [
			"reporterId": reporterId,
			"collectionId": collectionId,
			"reason": reason ?? "No reason provided",
			"type": "collection",
			"createdAt": Timestamp(),
			"status": "pending"
		]
		
		// Save to Firestore in a reports collection
		try await db.collection("reports").addDocument(data: reportData)
		
		print("✅ ReportService: Collection report submitted successfully")
	}
}

