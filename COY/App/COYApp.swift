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
			RootView()
				.environmentObject(authService)
				.onOpenURL { url in
					print("🔗 COYApp: onOpenURL called with: \(url.absoluteString)")
					DeepLinkManager.shared.handleCustomURL(url)
				}
		}
	}
}

struct RootView: View {
	@EnvironmentObject var authService: AuthService
	@State private var showSplash = true
	
	var body: some View {
		ZStack {
			Group {
				if authService.isLoading {
					Color(.systemBackground).ignoresSafeArea() // prevent flash while determining auth
				} else if let _ = authService.user, !authService.isInSignUpFlow {
					NavigationStack {
						MainTabView()
					}
				} else {
					CYWelcome()
						.dismissKeyboardOnTap()
				}
			}
			
			// Show splash screen on app launch
			if showSplash {
				SplashScreenView()
					.transition(.opacity)
					.onAppear {
						DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
							withAnimation(.easeOut(duration: 0.3)) {
								showSplash = false
							}
						}
					}
			}
		}
		.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
			print("🔗 RootView: Handling universal link activity")
			if let url = userActivity.webpageURL {
				print("🔗 RootView: Universal link URL: \(url.absoluteString)")
				DeepLinkManager.shared.handleUniversalLink(url)
			}
		}
	}
}

