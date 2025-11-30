import SwiftUI
import GoogleMobileAds
import SDWebImageSwiftUI

/// Collection-style ad card for Discover/Search (matches CollectionRowDesign style exactly)
/// Uses carousel/multi-card ads - shows multiple ad images in the 4 grid slots
struct CollectionStyleAdCard: View {
	let carouselAds: [GADNativeAd] // Multiple ads for carousel/multi-card
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	
	// iPad detection
	private var isIPad: Bool {
		horizontalSizeClass == .regular
	}
	
	var body: some View {
		// Use wrapper for proper ad click tracking
		CollectionStyleAdCardWrapper(carouselAds: carouselAds, isIPad: isIPad, colorScheme: colorScheme)
	}
}

/// Internal view that matches CollectionRowDesign layout
private struct CollectionStyleAdCardContent: View {
	let carouselAds: [GADNativeAd] // Multiple ads for carousel
	let isIPad: Bool
	let colorScheme: ColorScheme
	
	// Get the first ad for header info (advertiser name, etc.)
	private var primaryAd: GADNativeAd? {
		carouselAds.first
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: isIPad ? 16 : 12) {
			// Header: Image + Name + Sponsored Label (matching CollectionRowDesign exactly)
			HStack(spacing: isIPad ? 16 : 12) {
				// Ad Icon/Image Placeholder (matching profile image size)
				adIconView
				
				// Name + Sponsored Label (matching CollectionRowDesign header exactly)
				VStack(alignment: .leading, spacing: isIPad ? 6 : 4) {
					HStack {
						// Show advertiser name or headline as "collection name" from first ad
						Text(primaryAd?.advertiser ?? primaryAd?.headline ?? "Sponsored")
							.font(isIPad ? .title3 : .headline)
							.fontWeight(isIPad ? .semibold : .regular)
							.foregroundColor(.primary)
					}
					
					// "Sponsored" label (matching member label position exactly)
					Text("Sponsored")
						.font(isIPad ? .subheadline : .caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
				
				// No action button for ads (matching CollectionRowDesign when no button is shown)
			}
			.padding(.horizontal, isIPad ? 20 : 16)
			
			// Ad Media Grid (matching post grid layout) - shows different ad images in each slot
			adMediaGrid
		}
	}
	
	// MARK: - Ad Icon View
	private var adIconView: some View {
		let imageSize: CGFloat = isIPad ? 56 : 44
		return ZStack {
			Circle()
				.fill(Color.blue.opacity(0.1))
				.frame(width: imageSize, height: imageSize)
			
			Image(systemName: "megaphone.fill")
				.font(.system(size: isIPad ? 28 : 22))
				.foregroundColor(.blue)
		}
	}
	
	// MARK: - Ad Media Grid (matching CollectionRowDesign post grid exactly)
	private var adMediaGrid: some View {
		// Always show 4 slots with DIFFERENT ad images from carousel (matching CollectionRowDesign)
		let thumbnailWidth: CGFloat = isIPad ? 180 : 90
		let thumbnailHeight: CGFloat = isIPad ? 260 : 130
		let spacing: CGFloat = isIPad ? 18 : 8
		
		return HStack(spacing: spacing) {
			// Show DIFFERENT ad media in each slot (carousel/multi-card ads)
			ForEach(0..<4, id: \.self) { idx in
				if idx < carouselAds.count {
					// Show actual ad media from carousel
					NativeAdMediaView(nativeAd: carouselAds[idx])
						.frame(width: thumbnailWidth, height: thumbnailHeight)
						.clipped()
						.cornerRadius(0)
				} else {
					// Show placeholder if we don't have enough ads
					Rectangle()
						.fill(colorScheme == .dark ? Color.white.opacity(0.3) : Color.gray.opacity(0.3))
						.frame(width: thumbnailWidth, height: thumbnailHeight)
						.clipped()
				}
			}
		}
		.padding(.horizontal, isIPad ? 20 : 16)
		.padding(.bottom, isIPad ? 24 : 20)
	}
}

/// UIViewRepresentable wrapper that properly registers ad views for click tracking
struct CollectionStyleAdCardWrapper: UIViewRepresentable {
	let carouselAds: [GADNativeAd] // Multiple ads for carousel
	let isIPad: Bool
	let colorScheme: ColorScheme
	
	func makeUIView(context: Context) -> UIView {
		// Create container view
		let containerView = UIView()
		containerView.backgroundColor = .clear
		
		// Create SwiftUI content as UIHostingController
		let contentView = CollectionStyleAdCardContent(
			carouselAds: carouselAds,
			isIPad: isIPad,
			colorScheme: colorScheme
		)
		let hostingController = UIHostingController(rootView: contentView)
		hostingController.view.backgroundColor = .clear
		hostingController.view.translatesAutoresizingMaskIntoConstraints = false
		
		// For carousel ads, we need to register each ad's media view
		// Create GADNativeAdView for each ad in the carousel for proper click tracking
		var adViews: [GADNativeAdView] = []
		for nativeAd in carouselAds {
			let adView = GADNativeAdView()
			adView.nativeAd = nativeAd
			adView.translatesAutoresizingMaskIntoConstraints = false
			adView.isHidden = true // Hide the actual ad view, we'll use SwiftUI for display
			adViews.append(adView)
			containerView.addSubview(adView)
		}
		
		// Add hosting controller's view
		containerView.addSubview(hostingController.view)
		
		// Set up constraints
		NSLayoutConstraint.activate([
			// Hosting controller view fills container
			hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
			hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
			hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
			hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
		])
		
		// Register media views for click tracking (required by AdMob)
		// Find and register media views after layout
		DispatchQueue.main.async {
			var allMediaViews: [GADMediaView] = []
			self.findAllMediaViews(in: hostingController.view, results: &allMediaViews)
			
			// Register each media view with its corresponding ad view
			for (index, adView) in adViews.enumerated() {
				if index < allMediaViews.count {
					adView.mediaView = allMediaViews[index]
				} else if let firstMediaView = allMediaViews.first {
					// Fallback to first media view if we don't have enough
					adView.mediaView = firstMediaView
				}
				// Make each ad view clickable
				adView.callToActionView = adView
			}
		}
		
		// Store hosting controller and ad views to prevent deallocation
		objc_setAssociatedObject(containerView, "hostingController", hostingController, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		objc_setAssociatedObject(containerView, "adViews", adViews, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		
		return containerView
	}
	
	func updateUIView(_ uiView: UIView, context: Context) {
		// Update if needed
	}
	
	// Helper to find all GADMediaViews in view hierarchy
	private func findAllMediaViews(in view: UIView, results: inout [GADMediaView]) {
		if let mediaView = view as? GADMediaView {
			results.append(mediaView)
		}
		for subview in view.subviews {
			findAllMediaViews(in: subview, results: &results)
		}
	}
}

/// UIViewRepresentable for native ad media view
struct NativeAdMediaView: UIViewRepresentable {
	let nativeAd: GADNativeAd
	
	func makeUIView(context: Context) -> GADMediaView {
		let mediaView = GADMediaView()
		mediaView.mediaContent = nativeAd.mediaContent
		return mediaView
	}
	
	func updateUIView(_ uiView: GADMediaView, context: Context) {
		uiView.mediaContent = nativeAd.mediaContent
	}
}
