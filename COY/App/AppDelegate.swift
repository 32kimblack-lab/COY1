import UIKit
import FirebaseCore
import FirebaseMessaging
import GoogleMobileAds
import UserNotifications
import SDWebImage

// AppDelegate to fix Firebase Analytics warning
@objc class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
		// Firebase is already configured in COYApp.init()
		
		// Initialize connection state monitoring (for offline/online detection)
		Task { @MainActor in
			_ = ConnectionStateManager.shared // Initialize connection monitoring
			#if DEBUG
			print("✅ ConnectionStateManager initialized")
			#endif
		}
		
		// Verify AdMob Application ID is in Info.plist
		if let appID = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String {
			#if DEBUG
			print("✅ AdMob App ID found in Info.plist: \(appID)")
			#endif
		} else {
			#if DEBUG
			print("⚠️ WARNING: GADApplicationIdentifier not found in Info.plist!")
			#endif
		}
		
		// Configure SDWebImage for optimal performance
		configureSDWebImage()
		
		// Initialize Google Mobile Ads SDK
		// The SDK will automatically read GADApplicationIdentifier from Info.plist
		GADMobileAds.sharedInstance().start(completionHandler: { status in
			#if DEBUG
			print("✅ Google Mobile Ads SDK initialized")
			#endif
			// Preload interstitial ad for post detail view
			Task { @MainActor in
				AdManager.shared.loadInterstitialAd()
			}
		})
		
		// Set up push notifications
		setupPushNotifications(application: application)
		
		return true
	}
	
	// MARK: - SDWebImage Configuration
	private func configureSDWebImage() {
		// Configure SDWebImage cache and performance settings for optimal performance
		// This reduces memory usage and improves loading performance
		let cache = SDImageCache.shared
		
		// Set memory cache limit (50MB) - prevents memory pressure
		cache.config.maxMemoryCost = 50 * 1024 * 1024
		
		// Set disk cache limit (200MB, 7 days retention)
		cache.config.maxDiskAge = 60 * 60 * 24 * 7 // 7 days
		cache.config.maxDiskSize = 200 * 1024 * 1024 // 200MB
		
		// Configure downloader for better performance
		let downloader = SDWebImageDownloader.shared
		downloader.config.maxConcurrentDownloads = 6 // Limit concurrent downloads to prevent overload
		downloader.config.downloadTimeout = 15.0 // 15 second timeout
		
		#if DEBUG
		print("✅ SDWebImage configured: Memory=50MB, Disk=200MB, MaxConcurrent=6")
		#endif
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
		#if DEBUG
		print("✅ AppDelegate: APNs token registered")
		#endif
		Messaging.messaging().apnsToken = deviceToken
	}
	
	func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
		#if DEBUG
		print("❌ AppDelegate: Failed to register for remote notifications: \(error)")
		#endif
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
		#if DEBUG
		print("📱 AppDelegate: Notification tapped: \(userInfo)")
		#endif
		
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
		#if DEBUG
		print("🔗 AppDelegate: Handling universal link: \(userActivity.activityType)")
		#endif
		
		// Handle universal links (applinks)
		if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
		   let url = userActivity.webpageURL {
			#if DEBUG
			print("🔗 AppDelegate: Universal link URL: \(url.absoluteString)")
			#endif
			DeepLinkManager.shared.handleUniversalLink(url)
			return true
		}
		
		return false
	}
	
	// MARK: - Custom URL Scheme
	func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
		#if DEBUG
		print("🔗 AppDelegate: Handling custom URL: \(url.absoluteString)")
		#endif
		DeepLinkManager.shared.handleCustomURL(url)
		return true
	}
}

// MARK: - MessagingDelegate
extension AppDelegate: MessagingDelegate {
	func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
		#if DEBUG
		print("📱 AppDelegate: Received FCM token: \(fcmToken ?? "nil")")
		#endif
		
		// Sync token to Firestore
		Task {
			await PushNotificationManager.shared.syncTokenForCurrentUser()
		}
	}
}

