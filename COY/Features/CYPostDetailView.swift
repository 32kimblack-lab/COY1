import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import AVKit
import FirebaseAuth

struct CYPostDetailView: View {
	let post: CollectionPost
	let collection: CollectionData?
	
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@State private var currentMediaIndex: Int = 0
	@State private var isStarred: Bool = false
	@State private var showFullCaption: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	
	private let screenWidth: CGFloat = UIScreen.main.bounds.width
	private let maxHeight: CGFloat = UIScreen.main.bounds.height * 0.6
	
	// Calculate the tallest height from all media items
	private var calculatedHeight: CGFloat {
		if post.mediaItems.isEmpty {
			return maxHeight // Default max height
		}
		
		// For multiple media items, find the tallest one
		var maxCalculatedHeight: CGFloat = 0
		
		for mediaItem in post.mediaItems {
			let height: CGFloat
			
			if mediaItem.isVideo {
				// For videos, use a default aspect ratio (16:9) or from thumbnail
				if let thumbnailURL = mediaItem.thumbnailURL,
				   let aspectRatio = imageAspectRatios[thumbnailURL] {
					height = screenWidth / aspectRatio
				} else {
					height = screenWidth * (9.0 / 16.0) // Default 16:9
				}
			} else if let imageURL = mediaItem.imageURL,
					  let aspectRatio = imageAspectRatios[imageURL] {
				// Use calculated aspect ratio
				height = screenWidth / aspectRatio
			} else {
				// Default aspect ratio for images (4:3)
				height = screenWidth * (3.0 / 4.0)
			}
			
			maxCalculatedHeight = max(maxCalculatedHeight, height)
		}
		
		// Cap at maxHeight to prevent overly tall images
		return min(maxCalculatedHeight, maxHeight)
	}
	
	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					// Media Carousel with blur background
					if !post.mediaItems.isEmpty {
						ZStack {
							// Blur background
							blurBackgroundView
								.frame(width: screenWidth, height: calculatedHeight)
								.clipped()
							
							// Media carousel on top
							TabView(selection: $currentMediaIndex) {
								ForEach(0..<post.mediaItems.count, id: \.self) { index in
									mediaView(mediaItem: post.mediaItems[index])
										.tag(index)
								}
							}
							.tabViewStyle(.page)
							.frame(height: calculatedHeight)
							.overlay(
								// Page indicator dots
								VStack {
									Spacer()
									if post.mediaItems.count > 1 {
										HStack(spacing: 6) {
											ForEach(0..<post.mediaItems.count, id: \.self) { index in
												Circle()
													.fill(index == currentMediaIndex ? Color.white : Color.white.opacity(0.4))
													.frame(width: 6, height: 6)
											}
										}
										.padding(.bottom, 12)
									}
								}
							)
						}
					}
					
					// Post Info Section
					VStack(alignment: .leading, spacing: 12) {
						// Username and Star Row
						HStack(alignment: .center, spacing: 12) {
							// Username
							if !post.authorName.isEmpty {
								Text("@\(post.authorName)")
									.font(.headline)
									.fontWeight(.semibold)
									.foregroundColor(.primary)
							}
							
							Spacer()
							
							// Star Button
							Button(action: {
								toggleStar()
							}) {
								Image(systemName: isStarred ? "star.fill" : "star")
									.font(.title3)
									.foregroundColor(isStarred ? .yellow : .gray)
							}
						}
						.padding(.horizontal, 16)
						.padding(.top, 12)
						
						// Caption
						if !post.title.isEmpty {
							VStack(alignment: .leading, spacing: 4) {
								Text(post.title)
									.font(.body)
									.foregroundColor(.primary)
									.lineLimit(showFullCaption ? nil : 3)
									.multilineTextAlignment(.leading)
								
								if post.title.count > 100 {
									Button(action: {
										showFullCaption.toggle()
									}) {
										Text(showFullCaption ? "Show less" : "Show more")
											.font(.caption)
											.foregroundColor(.blue)
									}
								}
							}
							.padding(.horizontal, 16)
						}
						
						// Post Metadata
						HStack {
							Text(timeAgoString(from: post.createdAt))
								.font(.caption)
								.foregroundColor(.secondary)
							
							Spacer()
						}
						.padding(.horizontal, 16)
						.padding(.top, 4)
					}
					.padding(.bottom, 20)
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(action: {
						dismiss()
					}) {
						Image(systemName: "xmark")
							.foregroundColor(.primary)
					}
				}
			}
		}
		.onAppear {
			loadStarStatus()
			calculateImageAspectRatios()
		}
	}
	
	// MARK: - Blur Background View
	@ViewBuilder
	private var blurBackgroundView: some View {
		// Use the first media item for blur background
		if let firstMedia = post.firstMediaItem ?? post.mediaItems.first {
			if let imageURL = firstMedia.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: screenWidth, height: calculatedHeight)
					.blur(radius: 20)
					.opacity(0.6)
			} else if let thumbnailURL = firstMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: screenWidth, height: calculatedHeight)
					.blur(radius: 20)
					.opacity(0.6)
			} else {
				// Fallback gradient
				LinearGradient(
					colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
					startPoint: .top,
					endPoint: .bottom
				)
			}
		} else {
			// Fallback gradient
			LinearGradient(
				colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
				startPoint: .top,
				endPoint: .bottom
			)
		}
	}
	
	// MARK: - Media View
	@ViewBuilder
	private func mediaView(mediaItem: MediaItem) -> some View {
		if mediaItem.isVideo {
			videoView(mediaItem: mediaItem)
		} else {
			imageView(mediaItem: mediaItem)
		}
	}
	
	@ViewBuilder
	private func imageView(mediaItem: MediaItem) -> some View {
		if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.transition(.fade(duration: 0.2))
				.aspectRatio(contentMode: .fit)
				.frame(width: screenWidth, height: calculatedHeight)
				.clipped()
		} else {
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: calculatedHeight)
				.overlay(
					Image(systemName: "photo")
						.foregroundColor(.gray)
						.font(.largeTitle)
				)
		}
	}
	
	@ViewBuilder
	private func videoView(mediaItem: MediaItem) -> some View {
		ZStack {
			// Thumbnail
			if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.aspectRatio(contentMode: .fit)
					.frame(width: screenWidth, height: calculatedHeight)
					.clipped()
			} else {
				Rectangle()
					.fill(Color.black)
					.frame(height: calculatedHeight)
			}
			
			// Play Button Overlay
			if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
				Button(action: {
					// TODO: Play video in full screen
				}) {
					Image(systemName: "play.circle.fill")
						.font(.system(size: 60))
						.foregroundColor(.white.opacity(0.9))
				}
			}
			
			// Duration Badge
			if let duration = mediaItem.videoDuration {
				VStack {
					Spacer()
					HStack {
						Spacer()
						Text(formatDuration(duration))
							.font(.caption)
							.fontWeight(.semibold)
							.foregroundColor(.white)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(Color.black.opacity(0.6))
							.cornerRadius(4)
							.padding(.trailing, 12)
							.padding(.bottom, 12)
					}
				}
			}
		}
	}
	
	// MARK: - Helper Functions
	private func toggleStar() {
		// TODO: Implement star/unstar functionality
		isStarred.toggle()
	}
	
	private func loadStarStatus() {
		// TODO: Load star status from Firebase
		// Check if current user has starred this post
		// For now, default to false
		isStarred = false
	}
	
	private func timeAgoString(from date: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return formatter.localizedString(for: date, relativeTo: Date())
	}
	
	private func formatDuration(_ seconds: Double) -> String {
		let minutes = Int(seconds) / 60
		let remainingSeconds = Int(seconds) % 60
		return String(format: "%d:%02d", minutes, remainingSeconds)
	}
	
	// MARK: - Calculate Image Aspect Ratios
	private func calculateImageAspectRatios() {
		// Pre-calculate aspect ratios for all media items using SDWebImage
		for mediaItem in post.mediaItems {
			if !mediaItem.isVideo {
				if let imageURL = mediaItem.imageURL, !imageURL.isEmpty {
					// Load image to get dimensions
					Task {
						if let url = URL(string: imageURL) {
							// Use SDWebImage to load and get dimensions
							SDWebImageManager.shared.loadImage(
								with: url,
								options: [],
								progress: nil
							) { image, data, error, cacheType, finished, imageURL in
								if let image = image, finished, let imageURL = imageURL {
									let aspectRatio = image.size.width / image.size.height
									DispatchQueue.main.async {
										imageAspectRatios[imageURL.absoluteString] = aspectRatio
									}
								}
							}
						}
					}
				}
			} else if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty {
				// For videos, load thumbnail to get aspect ratio
				Task {
					if let url = URL(string: thumbnailURL) {
						SDWebImageManager.shared.loadImage(
							with: url,
							options: [],
							progress: nil
						) { image, data, error, cacheType, finished, _ in
							if let image = image, finished {
								let aspectRatio = image.size.width / image.size.height
								DispatchQueue.main.async {
									imageAspectRatios[thumbnailURL] = aspectRatio
								}
							}
						}
					}
				}
			}
		}
	}
}

