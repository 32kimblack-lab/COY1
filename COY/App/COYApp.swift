import SwiftUI
import FirebaseCore

@main
struct COYApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject private var authService = AuthService()

	init() {
		FirebaseApp.configure()
		
		// Request push notification permission on app launch
		Task {
			_ = await PushNotificationManager.shared.requestPermission()
			// Sync token after permission is granted
			await PushNotificationManager.shared.syncTokenForCurrentUser()
		}
	}

	var body: some Scene {
		WindowGroup {
			Group {
				if authService.isLoading {
					Color(.systemBackground).ignoresSafeArea() // prevent flash while determining auth
				} else if let _ = authService.user, !authService.isInSignUpFlow {
					MainTabView()
				} else {
					CYWelcome()
				}
			}
			.environmentObject(authService)
		}
	}
}

