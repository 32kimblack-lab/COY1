import Foundation
import FirebaseFirestore
import FirebaseAuth
import FirebaseFunctions

// MARK: - Message Notification Service
@MainActor
class MessageNotificationService {
	static let shared = MessageNotificationService()
	private let db = Firestore.firestore()
	private let functions = Functions.functions()
	
	private init() {}
	
	// MARK: - Send Push Notification for Message
	func sendMessageNotification(
		chatId: String,
		messageType: String,
		messageContent: String,
		senderUid: String,
		senderName: String,
		senderProfileImageURL: String?,
		receiverUid: String
	) async {
		// Don't send notification if user is sending to themselves
		guard senderUid != receiverUid else {
			return
		}
		
		// Get receiver's FCM token
		guard let receiverToken = await PushNotificationManager.shared.getFCMToken(for: receiverUid) else {
			print("⚠️ MessageNotificationService: No FCM token for receiver: \(receiverUid)")
			return
		}
		
		// Get receiver's user data for app profile image
		let receiverUser = try? await UserService.shared.getUser(userId: receiverUid)
		let appProfileImageURL = receiverUser?.profileImageURL
		
		// Format notification body based on message type
		let notificationBody: String
		switch messageType {
		case "voice":
			notificationBody = "Voice message"
		case "image", "photo":
			notificationBody = "Sent photo"
		case "video":
			notificationBody = "Sent video"
		case "text":
			notificationBody = messageContent
		default:
			notificationBody = "New message"
		}
		
		// Prepare notification data
		let notificationData: [String: Any] = [
			"token": receiverToken,
			"notification": [
				"title": senderName,
				"body": notificationBody
			],
			"data": [
				"type": "message",
				"chatId": chatId,
				"senderUid": senderUid,
				"messageType": messageType,
				"userProfileImageURL": senderProfileImageURL ?? "",
				"appProfileImageURL": appProfileImageURL ?? ""
			],
			"apns": [
				"payload": [
					"aps": [
						"alert": [
							"title": senderName,
							"body": notificationBody
						],
						"sound": "default",
						"badge": 1
					],
					"userProfileImageURL": senderProfileImageURL ?? "",
					"appProfileImageURL": appProfileImageURL ?? ""
				]
			]
		]
		
		// Call Cloud Function to send notification
		do {
			let sendNotification = functions.httpsCallable("sendMessageNotification")
			_ = try await sendNotification.call(notificationData)
			print("✅ MessageNotificationService: Notification sent successfully")
		} catch {
			print("❌ MessageNotificationService: Error sending notification: \(error)")
			// Fallback: Try direct HTTP request if Cloud Function fails
			await sendNotificationDirectly(data: notificationData)
		}
	}
	
	// MARK: - Direct HTTP Request (Fallback)
	private func sendNotificationDirectly(data: [String: Any]) async {
		// This is a fallback method
		// In production, you should use Firebase Cloud Functions
		print("⚠️ MessageNotificationService: Using fallback notification method")
		
		// Store notification request in Firestore for Cloud Function to process
		// This is a workaround if Cloud Functions aren't set up yet
		do {
			let notificationRequestRef = db.collection("notification_requests").document()
			try await notificationRequestRef.setData([
				"data": data,
				"createdAt": Timestamp(date: Date()),
				"status": "pending"
			])
			print("✅ MessageNotificationService: Notification request stored in Firestore")
		} catch {
			print("❌ MessageNotificationService: Error storing notification request: \(error)")
		}
	}
}

