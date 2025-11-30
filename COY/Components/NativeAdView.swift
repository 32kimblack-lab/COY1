import SwiftUI
import GoogleMobileAds
import SDWebImageSwiftUI

/// Native ad view that matches Pinterest grid style
struct NativeAdView: UIViewRepresentable {
	let nativeAd: GADNativeAd
	let width: CGFloat
	
	func makeUIView(context: Context) -> GADNativeAdView {
		let adView = GADNativeAdView()
		adView.nativeAd = nativeAd
		adView.translatesAutoresizingMaskIntoConstraints = false
		
		// Ad content
		let stackView = UIStackView()
		stackView.axis = .vertical
		stackView.spacing = 8
		stackView.translatesAutoresizingMaskIntoConstraints = false
		
		// Media view (image/video) - must be at least 120x120 to avoid demonetization
		let mediaView = GADMediaView()
		mediaView.translatesAutoresizingMaskIntoConstraints = false
		let mediaHeight = max(width * 1.2, 120) // Ensure minimum 120px height
		mediaView.heightAnchor.constraint(equalToConstant: mediaHeight).isActive = true
		adView.mediaView = mediaView
		stackView.addArrangedSubview(mediaView)
		
		// Ad label
		let adLabel = UILabel()
		adLabel.text = "Ad"
		adLabel.font = .systemFont(ofSize: 10, weight: .medium)
		adLabel.textColor = .systemGray
		stackView.addArrangedSubview(adLabel)
		
		// Headline
		if let headline = nativeAd.headline {
			let headlineLabel = UILabel()
			headlineLabel.text = headline
			headlineLabel.font = .systemFont(ofSize: 14, weight: .semibold)
			headlineLabel.numberOfLines = 2
			stackView.addArrangedSubview(headlineLabel)
			adView.headlineView = headlineLabel
		}
		
		// Body
		if let body = nativeAd.body {
			let bodyLabel = UILabel()
			bodyLabel.text = body
			bodyLabel.font = .systemFont(ofSize: 12)
			bodyLabel.textColor = .secondaryLabel
			bodyLabel.numberOfLines = 2
			stackView.addArrangedSubview(bodyLabel)
			adView.bodyView = bodyLabel
		}
		
		// Advertiser
		if let advertiser = nativeAd.advertiser {
			let advertiserLabel = UILabel()
			advertiserLabel.text = advertiser
			advertiserLabel.font = .systemFont(ofSize: 11, weight: .medium)
			advertiserLabel.textColor = .systemBlue
			stackView.addArrangedSubview(advertiserLabel)
			adView.advertiserView = advertiserLabel
		}
		
		adView.addSubview(stackView)
		
		NSLayoutConstraint.activate([
			stackView.topAnchor.constraint(equalTo: adView.topAnchor, constant: 8),
			stackView.leadingAnchor.constraint(equalTo: adView.leadingAnchor, constant: 8),
			stackView.trailingAnchor.constraint(equalTo: adView.trailingAnchor, constant: -8),
			stackView.bottomAnchor.constraint(equalTo: adView.bottomAnchor, constant: -8)
		])
		
		// Ensure adView has proper width constraint (activate separately)
		let widthConstraint = adView.widthAnchor.constraint(equalToConstant: width)
		widthConstraint.isActive = true
		
		return adView
	}
	
	func updateUIView(_ uiView: GADNativeAdView, context: Context) {
		// Update if needed
	}
}

/// SwiftUI wrapper for native ad in grid
struct GridNativeAdCard: View {
	let nativeAd: GADNativeAd
	let width: CGFloat
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		NativeAdView(nativeAd: nativeAd, width: width)
			.frame(width: width)
			.background(colorScheme == .dark ? Color(.systemGray6) : Color.white)
			.cornerRadius(12)
			.shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
	}
}

/// Banner ad view for comments
struct BannerAdView: UIViewRepresentable {
	let adUnitID: String
	
	func makeUIView(context: Context) -> GADBannerView {
		let banner = GADBannerView(adSize: GADAdSizeBanner)
		banner.adUnitID = adUnitID
		
		// Get root view controller more reliably
		if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
		   let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
			banner.rootViewController = rootViewController
		} else {
			// Fallback: try to get root view controller from any window scene
			for scene in UIApplication.shared.connectedScenes {
				if let windowScene = scene as? UIWindowScene,
				   let rootViewController = windowScene.windows.first?.rootViewController {
					banner.rootViewController = rootViewController
					break
				}
			}
		}
		
		// Set delegate to handle ad loading
		banner.delegate = context.coordinator
		
		// Load the ad request
		// Test mode is automatic for simulators, and we use test ad unit IDs in DEBUG
		let request = GADRequest()
		banner.load(request)
		
		print("✅ BannerAdView: Loading banner ad with unit ID: \(adUnitID)")
		
		return banner
	}
	
	func updateUIView(_ uiView: GADBannerView, context: Context) {
		// Ensure root view controller is set on update
		if uiView.rootViewController == nil {
			if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
			   let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
				uiView.rootViewController = rootViewController
				// Reload if we just set the root view controller
				uiView.load(GADRequest())
			}
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator()
	}
	
	class Coordinator: NSObject, GADBannerViewDelegate {
		func bannerViewDidReceiveAd(_ bannerView: GADBannerView) {
			print("✅ BannerAdView: Ad loaded successfully")
		}
		
		func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
			print("❌ BannerAdView: Failed to load ad: \(error.localizedDescription)")
		}
		
		func bannerViewDidRecordImpression(_ bannerView: GADBannerView) {
			print("✅ BannerAdView: Ad impression recorded")
		}
	}
}
