import UIKit
import FirebaseCore
import FirebaseMessaging
import GoogleMobileAds
import UserNotifications

// AppDelegate to fix Firebase Analytics warning
@objc class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
		// Firebase is already configured in COYApp.init()
		
		// Verify AdMob Application ID is in Info.plist
		if let appID = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String {
			print("✅ AdMob App ID found in Info.plist: \(appID)")
		} else {
			print("⚠️ WARNING: GADApplicationIdentifier not found in Info.plist!")
		}
		
		// Initialize Google Mobile Ads SDK
		// The SDK will automatically read GADApplicationIdentifier from Info.plist
		GADMobileAds.sharedInstance().start(completionHandler: { status in
			print("✅ Google Mobile Ads SDK initialized")
		})
		
		// Set up push notifications
		setupPushNotifications(application: application)
		
		return true
	}
	
	// MARK: - Push Notification Setup
	private func setupPushNotifications(application: UIApplication) {
		// Set UNUserNotificationCenter delegate
		UNUserNotificationCenter.current().delegate = self
		
		// Set Messaging delegate
		Messaging.messaging().delegate = self
		
		// Request notification permission
		Task {
			await PushNotificationManager.shared.requestPermission()
		}
	}
	
	// MARK: - APNs Token Registration
	func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
		print("✅ AppDelegate: APNs token registered")
		Messaging.messaging().apnsToken = deviceToken
	}
	
	func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
		print("❌ AppDelegate: Failed to register for remote notifications: \(error)")
	}
	
	// MARK: - UNUserNotificationCenterDelegate
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
		// Show notification even when app is in foreground
		if #available(iOS 14.0, *) {
			completionHandler([.banner, .badge, .sound])
		} else {
			completionHandler([.alert, .badge, .sound])
		}
	}
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		// Handle notification tap
		let userInfo = response.notification.request.content.userInfo
		print("📱 AppDelegate: Notification tapped: \(userInfo)")
		
		// Handle deep linking to chat if needed
		if let chatId = userInfo["chatId"] as? String {
			NotificationCenter.default.post(
				name: NSNotification.Name("OpenChatFromNotification"),
				object: chatId
			)
		}
		
		completionHandler()
	}
	
	// MARK: - Universal Links
	func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
		print("🔗 AppDelegate: Handling universal link: \(userActivity.activityType)")
		
		// Handle universal links (applinks)
		if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
		   let url = userActivity.webpageURL {
			print("🔗 AppDelegate: Universal link URL: \(url.absoluteString)")
			DeepLinkManager.shared.handleUniversalLink(url)
			return true
		}
		
		return false
	}
	
	// MARK: - Custom URL Scheme
	func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
		print("🔗 AppDelegate: Handling custom URL: \(url.absoluteString)")
		DeepLinkManager.shared.handleCustomURL(url)
		return true
	}
}

// MARK: - MessagingDelegate
extension AppDelegate: MessagingDelegate {
	func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
		print("📱 AppDelegate: Received FCM token: \(fcmToken ?? "nil")")
		
		// Sync token to Firestore
		Task {
			await PushNotificationManager.shared.syncTokenForCurrentUser()
		}
	}
}

