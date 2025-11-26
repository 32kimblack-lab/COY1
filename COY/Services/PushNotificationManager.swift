import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import UserNotifications

// MARK: - Push Notification Manager
@MainActor
class PushNotificationManager: NSObject {
	static let shared = PushNotificationManager()
	private let db = Firestore.firestore()
	
	private override init() {
		super.init()
	}
	
	// MARK: - Request Permission
	func requestPermission() async -> Bool {
		do {
			let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
			let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: authOptions)
			
			if granted {
				await MainActor.run {
					UIApplication.shared.registerForRemoteNotifications()
				}
				Messaging.messaging().delegate = self
				print("✅ PushNotificationManager: Permission granted")
			} else {
				print("❌ PushNotificationManager: Permission denied")
			}
			
			return granted
		} catch {
			print("❌ PushNotificationManager: Error requesting permission: \(error)")
			return false
		}
	}
	
	// MARK: - Token Management
	func syncTokenForCurrentUser() async {
		guard let currentUid = Auth.auth().currentUser?.uid else {
			print("⚠️ PushNotificationManager: No current user")
			return
		}
		
		do {
			// Get FCM token
			let token = try await Messaging.messaging().token()
			print("✅ PushNotificationManager: FCM Token: \(token)")
			
			// Store token in Firestore under user's document
			try await db.collection("users").document(currentUid).updateData([
				"fcmToken": token,
				"fcmTokenUpdatedAt": Timestamp(date: Date())
			])
			
			print("✅ PushNotificationManager: Token synced for user: \(currentUid)")
		} catch {
			print("❌ PushNotificationManager: Error syncing token: \(error)")
		}
	}
	
	func removeToken(for userId: String) async {
		do {
			try await db.collection("users").document(userId).updateData([
				"fcmToken": FieldValue.delete()
			])
			print("✅ PushNotificationManager: Token removed for user: \(userId)")
		} catch {
			print("❌ PushNotificationManager: Error removing token: \(error)")
		}
	}
	
	// MARK: - Get FCM Token for User
	func getFCMToken(for userId: String) async -> String? {
		do {
			let userDoc = try await db.collection("users").document(userId).getDocument()
			return userDoc.data()?["fcmToken"] as? String
		} catch {
			print("❌ PushNotificationManager: Error getting token: \(error)")
			return nil
		}
	}
}

// MARK: - MessagingDelegate
extension PushNotificationManager: MessagingDelegate {
	func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
		print("📱 PushNotificationManager: Received FCM token: \(fcmToken ?? "nil")")
		
		// Sync token when it's received/refreshed
		Task {
			await syncTokenForCurrentUser()
		}
	}
}

