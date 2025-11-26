import SwiftUI
import Combine
import GoogleMobileAds

struct SplashAdView: View {
	@Binding var showMainApp: Bool
	@ObservedObject private var appOpenAdManager = AppOpenAdManager.shared
	
	var body: some View {
		// App branding/splash screen
		VStack(spacing: 20) {
			Image(systemName: "photo.on.rectangle.angled")
				.font(.system(size: 80))
				.foregroundColor(.blue)
			
			Text("COY")
				.font(.system(size: 48, weight: .bold))
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(.systemBackground))
		.onAppear {
			// Load and show App Open ad
			appOpenAdManager.loadAd(adUnitID: "ca-app-pub-1522482018148796/9361660327")
			
			// Show app branding for 2 seconds, then try to show ad
			DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
				appOpenAdManager.showAdIfAvailable {
					print("✅ App Open ad dismissed - proceeding to main app")
					showMainApp = true
				}
			}
			
			// Auto-proceed after 5 seconds regardless of ad
			DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
				if !showMainApp {
					print("✅ Auto-proceeding to main app after 5 seconds")
					showMainApp = true
				}
			}
		}
	}
}

// MARK: - App Open Ad Manager
class AppOpenAdManager: NSObject, ObservableObject {
	static let shared = AppOpenAdManager()
	
	private var appOpenAd: GADAppOpenAd?
	private var loadTime: Date?
	@Published var isLoading = false
	@Published var isShowing = false
	
	private override init() {
		super.init()
		// Ensure ObservableObject is properly initialized
	}
	
	func loadAd(adUnitID: String) {
		guard !isLoading, appOpenAd == nil else {
			return
		}
		
		isLoading = true
		print("📢 Loading App Open ad: \(adUnitID)")
		
		GADAppOpenAd.load(withAdUnitID: adUnitID, request: GADRequest()) { [weak self] (ad: GADAppOpenAd?, error: Error?) in
			guard let self = self else { return }
			self.isLoading = false
			
			if let error = error {
				print("❌ Failed to load App Open ad: \(error.localizedDescription)")
				return
			}
			
			guard let ad = ad else {
				print("⚠️ App Open ad is nil")
				return
			}
			
			Task { @MainActor in
				self.appOpenAd = ad
				self.appOpenAd?.fullScreenContentDelegate = self
				self.loadTime = Date()
				print("✅ App Open ad loaded successfully")
			}
		}
	}
	
	func showAdIfAvailable(completion: @escaping () -> Void) {
		guard let ad = appOpenAd,
			  let rootViewController = UIApplication.shared.connectedScenes
			.compactMap({ $0 as? UIWindowScene })
			.flatMap({ $0.windows })
			.first(where: { $0.isKeyWindow })?
			.rootViewController else {
			print("⚠️ App Open ad not ready, proceeding without ad")
			completion()
			return
		}
		
		// Check if ad is still fresh (within 4 hours)
		if let loadTime = loadTime, Date().timeIntervalSince(loadTime) > 14400 {
			print("⚠️ App Open ad expired, loading new one")
			appOpenAd = nil
			completion()
			return
		}
		
		isShowing = true
		ad.present(fromRootViewController: rootViewController)
		print("✅ Showing App Open ad")
		
		// Store completion handler to call after ad dismisses
		completion()
		
		// Clear ad after showing
		appOpenAd = nil
		loadTime = nil
	}
}

extension AppOpenAdManager: GADFullScreenContentDelegate {
	func adWillPresentFullScreenContent(_ ad: any GADFullScreenPresentingAd) {
		print("✅ App Open ad will present")
		DispatchQueue.main.async {
			self.isShowing = true
		}
	}
	
	func ad(_ ad: any GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
		print("❌ App Open ad failed to present: \(error.localizedDescription)")
		DispatchQueue.main.async {
			self.isShowing = false
		}
		appOpenAd = nil
		loadTime = nil
	}
	
	func adDidDismissFullScreenContent(_ ad: any GADFullScreenPresentingAd) {
		print("✅ App Open ad dismissed")
		DispatchQueue.main.async {
			self.isShowing = false
		}
		appOpenAd = nil
		loadTime = nil
	}
}

