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
		Image(systemName: "person.crop.circle.fill")
			.resizable()
			.scaledToFill()
			.frame(width: size, height: size)
			.foregroundColor(.white)
	}
}

