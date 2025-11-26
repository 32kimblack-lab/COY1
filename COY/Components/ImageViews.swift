import SwiftUI
import SDWebImageSwiftUI

struct CachedProfileImageView: View {
	let url: String
	let size: CGFloat
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		if !url.isEmpty, let imageURL = URL(string: url) {
			ZStack {
				DefaultProfileImageView(size: size)
				WebImage(url: imageURL)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.scaledToFill()
					.frame(width: size, height: size)
					.clipShape(Circle())
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
				Color.clear
					.frame(height: height)
				WebImage(url: imageURL)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.scaledToFill()
					.frame(height: height)
					.clipped()
			}
		} else {
			Color.clear
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

