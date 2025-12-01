import Foundation
import GoogleMobileAds
import SwiftUI
import Combine

/// Centralized ad manager for all ad types
@MainActor
class AdManager: NSObject, ObservableObject {
	static let shared = AdManager()
	
	// Ad Unit IDs - Real AdMob ad unit IDs for COY app
	private let homeAdUnitID = "ca-app-pub-1522482018148796/2756986850"
	private let insideCollectionAdUnitID = "ca-app-pub-1522482018148796/4149959577"
	private let discoverPostAdUnitID = "ca-app-pub-1522482018148796/4778297925"
	private let commentAdUnitID = "ca-app-pub-1522482018148796/8721412363"
	private let collectionAdUnitID = "ca-app-pub-1522482018148796/9530989204"
	private let postDetailAdUnitID = "ca-app-pub-1522482018148796/2836877902"
	private let interstitialAdUnitID = "ca-app-pub-1522482018148796/2836877902" // Interstitial ad unit ID
	
	// Test Ad Unit IDs (for development - always work)
	private let testNativeAdUnitID = "ca-app-pub-3940256099942544/3986624511"
	private let testBannerAdUnitID = "ca-app-pub-3940256099942544/2934735716"
	private let testInterstitialAdUnitID = "ca-app-pub-3940256099942544/4411468910"
	
	// Default/fallback (using home for backward compatibility)
	private var defaultNativeAdUnitID: String {
		#if DEBUG
		return testNativeAdUnitID
		#else
		return homeAdUnitID
		#endif
	}
	
	// Cache for native ads
	private var nativeAdCache: [String: GADNativeAd] = [:]
	private var nativeAdLoaders: [String: GADAdLoader] = [:]
	// Store completion handlers for ad loading
	private var adCompletionHandlers: [String: [(GADNativeAd?) -> Void]] = [:]
	// Cache for carousel/multi-card ads (multiple ads for collection row design)
	private var carouselAdCache: [String: [GADNativeAd]] = [:]
	private var carouselAdLoaders: [String: GADAdLoader] = [:]
	private var carouselAdCompletionHandlers: [String: [([GADNativeAd]) -> Void]] = [:]
	// Track loaded ads for each carousel request
	private var carouselLoadedAds: [String: [GADNativeAd]] = [:]
	
	// Interstitial ad
	private var interstitialAd: GADInterstitialAd?
	
	// Rewarded ad
	private var rewardedAd: GADRewardedAd?
	
	private override init() {
		super.init()
		// Test mode is automatically enabled for simulators in newer SDK versions
		// We use test ad unit IDs in DEBUG mode to ensure test ads are shown
		#if DEBUG
		print("✅ AdManager: Test mode enabled for development")
		print("✅ AdManager: Using TEST ad unit IDs - test ads will be shown")
		print("   - Test Native: \(testNativeAdUnitID)")
		print("   - Test Banner: \(testBannerAdUnitID)")
		print("   - Test Interstitial: \(testInterstitialAdUnitID)")
		#endif
	}
	
	// MARK: - Native Ads (for Pinterest grid)
	
	/// Get ad unit ID based on location
	private func getAdUnitID(for location: AdLocation) -> String {
		#if DEBUG
		// Use test ad unit IDs in debug mode (always work, show test ads)
		return testNativeAdUnitID
		#else
		// Use real ad unit IDs in release mode
		switch location {
		case .home:
			return homeAdUnitID
		case .insideCollection:
			return insideCollectionAdUnitID
		case .discoverPost:
			return discoverPostAdUnitID
		case .collection:
			return collectionAdUnitID
		case .postDetail:
			return postDetailAdUnitID
		case .comment:
			return commentAdUnitID
		}
		#endif
	}
	
	/// Get banner ad unit ID (for comments)
	private func getBannerAdUnitID() -> String {
		#if DEBUG
		return testBannerAdUnitID
		#else
		return commentAdUnitID
		#endif
	}
	
	/// Get interstitial ad unit ID
	private func getInterstitialAdUnitID() -> String {
		#if DEBUG
		return testInterstitialAdUnitID
		#else
		return interstitialAdUnitID
		#endif
	}
	
	/// Ad location enum for different placements
	public enum AdLocation {
		case home
		case insideCollection
		case discoverPost
		case collection
		case postDetail
		case comment
	}
	
	/// Load a native ad for use in grid
	func loadNativeAd(adKey: String = "default", location: AdLocation = .home, completion: @escaping (GADNativeAd?) -> Void) {
		// Return cached ad if available
		if let cachedAd = nativeAdCache[adKey] {
			completion(cachedAd)
			return
		}
		
		// Store completion handler
		if adCompletionHandlers[adKey] == nil {
			adCompletionHandlers[adKey] = []
		}
		adCompletionHandlers[adKey]?.append(completion)
		
		// If already loading, just add to completion handlers
		if nativeAdLoaders[adKey] != nil {
			return
		}
		
		// Create ad loader
		guard let rootViewController = UIApplication.shared.connectedScenes
			.compactMap({ $0 as? UIWindowScene })
			.flatMap({ $0.windows })
			.first(where: { $0.isKeyWindow })?
			.rootViewController else {
			completion(nil)
			return
		}
		
		let adUnitID = getAdUnitID(for: location)
		let adLoader = GADAdLoader(
			adUnitID: adUnitID,
			rootViewController: rootViewController,
			adTypes: [.native],
			options: nil
		)
		adLoader.delegate = self
		nativeAdLoaders[adKey] = adLoader
		
		// Load ad request (test mode is automatic for simulators, and we use test ad unit IDs in DEBUG)
		let request = GADRequest()
		// Reduced logging to improve performance
		adLoader.load(request)
	}
	
	/// Preload multiple native ads for a specific location (throttled to prevent overload)
	func preloadNativeAds(count: Int = 3, location: AdLocation = .home) {
		// Throttle ad loading to prevent overwhelming the system
		Task { @MainActor in
		for i in 0..<count {
				// Add delay between ad loads to prevent simultaneous requests
				if i > 0 {
					try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
				}
			loadNativeAd(adKey: "preload_\(i)", location: location) { _ in }
			}
		}
	}
	
	// MARK: - Carousel/Multi-Card Ads (for Collection Row Design)
	
	/// Load carousel/multi-card ads for collection row design (4 ads for 4 grid slots)
	func loadCarouselAds(adKey: String = "collection_carousel", location: AdLocation = .collection, completion: @escaping ([GADNativeAd]) -> Void) {
		// Return cached ads if available
		if let cachedAds = carouselAdCache[adKey], cachedAds.count >= 4 {
			completion(Array(cachedAds.prefix(4)))
			return
		}
		
		// Store completion handler
		if carouselAdCompletionHandlers[adKey] == nil {
			carouselAdCompletionHandlers[adKey] = []
		}
		carouselAdCompletionHandlers[adKey]?.append(completion)
		
		// If already loading, just add to completion handlers
		if carouselAdLoaders[adKey] != nil {
			return
		}
		
		// Create ad loader with multiple ads option
		guard let rootViewController = UIApplication.shared.connectedScenes
			.compactMap({ $0 as? UIWindowScene })
			.flatMap({ $0.windows })
			.first(where: { $0.isKeyWindow })?
			.rootViewController else {
			completion([])
			return
		}
		
		let adUnitID = getAdUnitID(for: location)
		
		// Configure for multiple ads (carousel/multi-card)
		let multipleAdsOptions = GADMultipleAdsAdLoaderOptions()
		multipleAdsOptions.numberOfAds = 4 // Request 4 ads for 4 grid slots
		
		let adLoader = GADAdLoader(
			adUnitID: adUnitID,
			rootViewController: rootViewController,
			adTypes: [.native],
			options: [multipleAdsOptions]
		)
		adLoader.delegate = self
		carouselAdLoaders[adKey] = adLoader
		
		// Initialize tracking for this carousel request
		carouselLoadedAds[adKey] = []
		
		let request = GADRequest()
		
		adLoader.load(request)
	}
	
	// MARK: - Banner Ads (for comments)
	
	/// Create a banner ad view
	func createBannerAdView() -> GADBannerView {
		let banner = GADBannerView(adSize: GADAdSizeBanner)
		banner.adUnitID = getBannerAdUnitID() // Use test ID in debug, real ID in release
		banner.rootViewController = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap { $0.windows }
			.first(where: { $0.isKeyWindow })?
			.rootViewController
		// Test mode is automatic for simulators, and we use test ad unit IDs in DEBUG
		banner.load(GADRequest())
		return banner
	}
	
	// MARK: - Interstitial Ads (for post detail swiping)
	
	/// Load interstitial ad for post detail
	func loadInterstitialAd() {
		let request = GADRequest()
		let adUnitID = getInterstitialAdUnitID() // Use proper interstitial ad unit ID
		GADInterstitialAd.load(withAdUnitID: adUnitID, request: request) { [weak self] ad, error in
			guard let self = self else { return }
			if let error = error {
				print("❌ Failed to load interstitial ad: \(error.localizedDescription)")
				return
			}
			Task { @MainActor in
				self.interstitialAd = ad
				self.interstitialAd?.fullScreenContentDelegate = self
				print("✅ Interstitial ad loaded")
			}
		}
	}
	
	/// Show interstitial ad if available
	func showInterstitialAd(completion: (() -> Void)? = nil) {
		guard let ad = interstitialAd,
			  let rootViewController = UIApplication.shared.connectedScenes
			.compactMap({ $0 as? UIWindowScene })
			.flatMap({ $0.windows })
			.first(where: { $0.isKeyWindow })?
			.rootViewController else {
			completion?()
			// Load new ad for next time
			loadInterstitialAd()
			return
		}
		
		ad.present(fromRootViewController: rootViewController)
		completion?()
		
		// Clear ad after showing
		interstitialAd = nil
	}
	
	// MARK: - Rewarded Ads
	
	/// Load rewarded ad (not currently used, but kept for future use)
	func loadRewardedAd() {
		// Rewarded ads not implemented yet - placeholder
		print("⚠️ Rewarded ads not configured")
	}
	
	/// Show rewarded ad if available
	func showRewardedAd(completion: @escaping (Bool) -> Void) {
		guard let ad = rewardedAd,
			  let rootViewController = UIApplication.shared.connectedScenes
			.compactMap({ $0 as? UIWindowScene })
			.flatMap({ $0.windows })
			.first(where: { $0.isKeyWindow })?
			.rootViewController else {
			completion(false)
			loadRewardedAd()
			return
		}
		
		ad.present(fromRootViewController: rootViewController) {
			// User earned reward
			completion(true)
		}
		
		// Clear ad after showing
		rewardedAd = nil
	}
	
	// MARK: - Helper Methods
	
	/// Check if user is viewing their own profile (hide ads)
	func shouldShowAds(currentUserId: String?, profileUserId: String?) -> Bool {
		guard let currentUserId = currentUserId,
			  let profileUserId = profileUserId else {
			return true // Show ads if we can't determine
		}
		return currentUserId != profileUserId
	}
}

// MARK: - GADAdLoaderDelegate
extension AdManager: GADAdLoaderDelegate {
	func adLoader(_ adLoader: GADAdLoader, didFailToReceiveAdWithError error: Error) {
		// Check if this is a carousel ad loader
		if let carouselKey = carouselAdLoaders.first(where: { $0.value == adLoader })?.key {
			print("❌ Failed to load carousel ads for key '\(carouselKey)': \(error.localizedDescription)")
			// Call all completion handlers with empty array
			if let handlers = carouselAdCompletionHandlers[carouselKey] {
				for handler in handlers {
					handler([])
				}
				carouselAdCompletionHandlers[carouselKey] = nil
			}
			carouselAdLoaders[carouselKey] = nil
			carouselLoadedAds[carouselKey] = nil
		} else if let key = nativeAdLoaders.first(where: { $0.value == adLoader })?.key {
			// Single native ad
			print("❌ Failed to load native ad for key '\(key)': \(error.localizedDescription)")
			// Call all completion handlers with nil
			if let handlers = adCompletionHandlers[key] {
				for handler in handlers {
					handler(nil)
				}
				adCompletionHandlers[key] = nil
			}
			nativeAdLoaders[key] = nil
		} else {
			print("❌ Failed to load ad: \(error.localizedDescription)")
		}
	}
}

// MARK: - GADNativeAdLoaderDelegate
extension AdManager: GADNativeAdLoaderDelegate {
	func adLoader(_ adLoader: GADAdLoader, didReceive nativeAd: GADNativeAd) {
		
		// Check if this is a carousel ad loader (multiple ads)
		if let carouselKey = carouselAdLoaders.first(where: { $0.value == adLoader })?.key {
			// Add to loaded ads for this carousel
			if carouselLoadedAds[carouselKey] == nil {
				carouselLoadedAds[carouselKey] = []
			}
			carouselLoadedAds[carouselKey]?.append(nativeAd)
			
			// Don't call completion yet - wait for adLoaderDidFinishLoading
		} else if let key = nativeAdLoaders.first(where: { $0.value == adLoader })?.key {
			// Single native ad
			nativeAdCache[key] = nativeAd
			
			// Call all completion handlers
			if let handlers = adCompletionHandlers[key] {
				for handler in handlers {
					handler(nativeAd)
				}
				adCompletionHandlers[key] = nil
			}
			
			// Clean up loader
			nativeAdLoaders[key] = nil
		}
	}
	
	func adLoaderDidFinishLoading(_ adLoader: GADAdLoader) {
		// Check if this is a carousel ad loader
		if let carouselKey = carouselAdLoaders.first(where: { $0.value == adLoader })?.key {
			// Get all loaded ads for this carousel
			let loadedAds = carouselLoadedAds[carouselKey] ?? []
			print("✅ AdManager: Carousel ad loading finished for key: \(carouselKey) - \(loadedAds.count) ads loaded")
			
			// Cache the ads (take up to 4)
			let adsToCache = Array(loadedAds.prefix(4))
			carouselAdCache[carouselKey] = adsToCache
			
			// Call all completion handlers with the loaded ads
			if let handlers = carouselAdCompletionHandlers[carouselKey] {
				for handler in handlers {
					handler(adsToCache)
				}
				carouselAdCompletionHandlers[carouselKey] = nil
			}
			
			// Clean up
			carouselAdLoaders[carouselKey] = nil
			carouselLoadedAds[carouselKey] = nil
		}
	}
}

// MARK: - GADFullScreenContentDelegate
extension AdManager: GADFullScreenContentDelegate {
	func adWillPresentFullScreenContent(_ ad: any GADFullScreenPresentingAd) {
		print("✅ Ad will present full screen content")
	}
	
	func ad(_ ad: any GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
		print("❌ Ad failed to present: \(error.localizedDescription)")
	}
	
	func adDidDismissFullScreenContent(_ ad: any GADFullScreenPresentingAd) {
		print("✅ Ad dismissed")
		// Load new ads for next time
		loadInterstitialAd()
		// Note: Rewarded ads not implemented yet
	}
}
