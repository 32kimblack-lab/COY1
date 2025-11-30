import SwiftUI
import GoogleMobileAds

/// Native ad view for post detail view (full screen like a post)
struct PostDetailAdView: View {
	let adKey: String
	@Binding var nativeAds: [String: GADNativeAd]
	let adManager: AdManager
	
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		ZStack {
			// Background
			Color(colorScheme == .dark ? .black : .white)
				.ignoresSafeArea()
			
			if let nativeAd = nativeAds[adKey] {
				// Show native ad
				VStack(spacing: 0) {
					Spacer()
					
					NativeAdView(nativeAd: nativeAd, width: UIScreen.main.bounds.width - 32)
						.frame(maxWidth: .infinity)
						.padding(.horizontal, 16)
					
					Spacer()
					
					// Ad label
					Text("Sponsored")
						.font(.caption)
						.foregroundColor(.secondary)
						.padding(.bottom, 20)
				}
			} else {
				// Loading placeholder
				VStack(spacing: 16) {
					Spacer()
					
					ProgressView()
						.scaleEffect(1.5)
					
					Text("Loading ad...")
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					Spacer()
				}
				.onAppear {
					// Load ad when placeholder appears
					adManager.loadNativeAd(adKey: adKey, location: .postDetail) { ad in
						if let ad = ad {
							Task { @MainActor in
								nativeAds[adKey] = ad
								print("✅ PostDetailAdView: Native ad loaded for key: \(adKey)")
							}
						} else {
							print("⚠️ PostDetailAdView: Failed to load ad for key: \(adKey)")
						}
					}
				}
			}
		}
	}
}
