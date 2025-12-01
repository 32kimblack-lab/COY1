import SwiftUI
import SDWebImageSwiftUI

struct CachedProfileImageView: View {
	let url: String
	let size: CGFloat
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		if !url.isEmpty, let imageURL = URL(string: url) {
			ZStack {
				// Placeholder shown immediately
				DefaultProfileImageView(size: size)
				// Full image loads lazily with fade transition
				WebImage(url: imageURL)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.scaledToFill()
					.frame(width: size, height: size)
					.clipShape(Circle())
					// Placeholder remains visible on failure automatically
			}
		} else {
			DefaultProfileImageView(size: size)
		}
	}
}

struct CachedBackgroundImageView: View {
	let url: String
	let height: CGFloat
	
	var body: some View {
		if !url.isEmpty, let imageURL = URL(string: url) {
			ZStack {
				// Placeholder shown immediately
				Color.gray.opacity(0.1)
					.frame(height: height)
				// Full image loads lazily
				WebImage(url: imageURL)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.3))
					.scaledToFill()
					.frame(height: height)
					.clipped()
					// Placeholder remains visible on failure automatically
			}
		} else {
			Color.gray.opacity(0.1)
				.frame(height: height)
		}
	}
}

struct DefaultProfileImageView: View {
	let size: CGFloat
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		ZStack {
			// Light gray background circle
			Circle()
				.fill(Color(red: 0.85, green: 0.85, blue: 0.85)) // Light gray
				.frame(width: size, height: size)
			
			// White solid person silhouette (not transparent)
			Image(systemName: "person.fill")
			.resizable()
				.scaledToFit()
				.frame(width: size * 0.5, height: size * 0.5)
				.foregroundColor(.white)
		}
			.frame(width: size, height: size)
	}
}

