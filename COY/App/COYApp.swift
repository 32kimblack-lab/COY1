import SwiftUI
import FirebaseCore

@main
struct COYApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject private var authService = AuthService()

	init() {
		FirebaseApp.configure()
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

