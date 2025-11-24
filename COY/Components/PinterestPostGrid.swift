import SwiftUI
import SDWebImageSwiftUI
import SDWebImage
import AVKit
import FirebaseAuth

// MARK: - Pinterest Style Post Grid
struct PinterestPostGrid: View {
	let posts: [CollectionPost]
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	
	@State private var postHeights: [String: CGFloat] = [:]
	
	private let columns = 2
	private let spacing: CGFloat = 8
	private let padding: CGFloat = 12
	
	var body: some View {
		ScrollView {
			LazyVStack(spacing: spacing) {
				// Create two columns using HStack
				ForEach(0..<(posts.count + 1) / 2, id: \.self) { rowIndex in
					HStack(alignment: .top, spacing: spacing) {
						// Left column
						if rowIndex * 2 < posts.count {
							PinterestPostCard(
								post: posts[rowIndex * 2],
								collection: collection,
								isIndividualCollection: isIndividualCollection,
								currentUserId: currentUserId,
								width: (UIScreen.main.bounds.width - (padding * 2) - spacing) / CGFloat(columns)
							)
						}
						
						// Right column
						if rowIndex * 2 + 1 < posts.count {
							PinterestPostCard(
								post: posts[rowIndex * 2 + 1],
								collection: collection,
								isIndividualCollection: isIndividualCollection,
								currentUserId: currentUserId,
								width: (UIScreen.main.bounds.width - (padding * 2) - spacing) / CGFloat(columns)
							)
						} else {
							// Empty space to maintain alignment
							Spacer()
								.frame(width: (UIScreen.main.bounds.width - (padding * 2) - spacing) / CGFloat(columns))
						}
					}
					.padding(.horizontal, padding)
				}
			}
			.padding(.vertical, padding)
		}
	}
}

// MARK: - Pinterest Post Card
struct PinterestPostCard: View {
	let post: CollectionPost
	let collection: CollectionData?
	let isIndividualCollection: Bool
	let currentUserId: String?
	let width: CGFloat
	
	@State private var imageHeight: CGFloat = 200
	@State private var showStar: Bool = false
	@State private var showPostDetail: Bool = false
	@State private var imageAspectRatios: [String: CGFloat] = [:]
	@Environment(\.colorScheme) var colorScheme
	
	// Calculate the tallest height from all media items
	private var calculatedHeight: CGFloat {
		if post.mediaItems.isEmpty {
			return 200 // Default height
		}
		
		// For multiple media items, find the tallest one
		var maxHeight: CGFloat = 200
		
		for mediaItem in post.mediaItems {
			let height: CGFloat
			
			if mediaItem.isVideo {
				// For videos, use a default aspect ratio (16:9)
				height = width * (9.0 / 16.0)
			} else if let imageURL = mediaItem.imageURL,
					  let aspectRatio = imageAspectRatios[imageURL] {
				// Use calculated aspect ratio
				height = width / aspectRatio
			} else {
				// Default aspect ratio for images (4:3)
				height = width * (3.0 / 4.0)
			}
			
			maxHeight = max(maxHeight, height)
		}
		
		return maxHeight
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Media Content with blur background
			ZStack {
				// Blur background
				blurBackgroundView
					.frame(width: width, height: calculatedHeight)
					.clipped()
				
				// Media content on top
				mediaContentView
					.frame(width: width, height: calculatedHeight)
					.clipped()
			}
			.cornerRadius(12)
			.onTapGesture {
				showPostDetail = true
			}
			
			// Post Info - under the media
			VStack(alignment: .leading, spacing: 4) {
				// Username and Star in same row
				HStack(alignment: .center, spacing: 6) {
					// Username
					if !post.authorName.isEmpty {
						Text("@\(post.authorName)")
							.font(.caption)
							.fontWeight(.medium)
							.foregroundColor(.primary)
							.lineLimit(1)
					}
					
					Spacer()
					
					// Star Icon (only for members if individual collection)
					if shouldShowStar {
						Image(systemName: "star.fill")
							.font(.caption2)
							.foregroundColor(.yellow)
					}
				}
				
				// Caption
				if !post.title.isEmpty {
					Text(post.title)
						.font(.caption)
						.foregroundColor(.secondary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}
			}
			.padding(.horizontal, 0)
		}
		.onAppear {
			checkStarVisibility()
			calculateImageAspectRatios()
		}
		.fullScreenCover(isPresented: $showPostDetail) {
			CYPostDetailView(post: post, collection: collection)
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
					.frame(width: width, height: calculatedHeight)
					.blur(radius: 20)
					.opacity(0.6)
			} else if let thumbnailURL = firstMedia.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.aspectRatio(contentMode: .fill)
					.frame(width: width, height: calculatedHeight)
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
	
	// MARK: - Media Content View
	@ViewBuilder
	private var mediaContentView: some View {
		if post.mediaItems.count > 1 {
			// Multiple media items - show swipeable carousel
			TabView {
				ForEach(0..<post.mediaItems.count, id: \.self) { index in
					Group {
						if post.mediaItems[index].isVideo {
							videoPlayerView(mediaItem: post.mediaItems[index])
						} else {
							imageView(mediaItem: post.mediaItems[index])
						}
					}
				}
			}
			.tabViewStyle(.page)
			.frame(height: calculatedHeight)
		} else if let mediaItem = post.firstMediaItem ?? post.mediaItems.first {
			// Single media item
			if mediaItem.isVideo {
				// Video Player
				videoPlayerView(mediaItem: mediaItem)
			} else {
				// Image or Live Photo
				imageView(mediaItem: mediaItem)
			}
		} else {
			// Placeholder
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: calculatedHeight)
				.overlay(
					Image(systemName: "photo")
						.foregroundColor(.gray)
				)
		}
	}
	
	// MARK: - Image View
	@ViewBuilder
	private func imageView(mediaItem: MediaItem) -> some View {
		if let imageURL = mediaItem.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
			WebImage(url: url)
				.resizable()
				.indicator(.activity)
				.transition(.fade(duration: 0.2))
				.aspectRatio(contentMode: .fit)
				.frame(width: width, height: calculatedHeight)
				.clipped()
				.onSuccess { image, data, cacheType in
					// Calculate and store aspect ratio when image loads
					if let image = image {
						let aspectRatio = image.size.width / image.size.height
						DispatchQueue.main.async {
							imageAspectRatios[imageURL] = aspectRatio
						}
					}
				}
		} else {
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: calculatedHeight)
				.overlay(
					Image(systemName: "photo")
						.foregroundColor(.gray)
				)
		}
	}
	
	// MARK: - Video Player View
	@ViewBuilder
	private func videoPlayerView(mediaItem: MediaItem) -> some View {
		ZStack {
			// Thumbnail
			if let thumbnailURL = mediaItem.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.transition(.fade(duration: 0.2))
					.aspectRatio(contentMode: .fit)
					.frame(width: width, height: calculatedHeight)
					.clipped()
					.onSuccess { image, data, cacheType in
						// Calculate and store aspect ratio when thumbnail loads
						if let image = image, let thumbnailURL = mediaItem.thumbnailURL {
							let aspectRatio = image.size.width / image.size.height
							DispatchQueue.main.async {
								imageAspectRatios[thumbnailURL] = aspectRatio
							}
						}
					}
			} else {
				Rectangle()
					.fill(Color.black)
					.frame(height: calculatedHeight)
			}
			
			// Play Button Overlay
			Image(systemName: "play.circle.fill")
				.font(.system(size: 50))
				.foregroundColor(.white.opacity(0.9))
			
			// Duration Badge
			if let duration = mediaItem.videoDuration {
				VStack {
					Spacer()
					HStack {
						Spacer()
						Text(formatDuration(duration))
							.font(.caption2)
							.fontWeight(.semibold)
							.foregroundColor(.white)
							.padding(.horizontal, 6)
							.padding(.vertical, 3)
							.background(Color.black.opacity(0.7))
							.cornerRadius(4)
							.padding(8)
					}
				}
			}
		}
		.frame(height: calculatedHeight)
		.onTapGesture {
			// Handle video tap - could open full screen player
			playVideo(mediaItem: mediaItem)
		}
	}
	
	// MARK: - Helper Methods
	private var shouldShowStar: Bool {
		if isIndividualCollection {
			// Only show star if user is a member
			guard let currentUserId = currentUserId,
				  let collection = collection else {
				return false
			}
			return collection.members.contains(currentUserId) || collection.ownerId == currentUserId
		} else {
			// Show star for all posts in non-individual collections
			return true
		}
	}
	
	private func checkStarVisibility() {
		showStar = shouldShowStar
	}
	
	private func formatDuration(_ seconds: Double) -> String {
		let minutes = Int(seconds) / 60
		let secs = Int(seconds) % 60
		return String(format: "%d:%02d", minutes, secs)
	}
	
	private func playVideo(mediaItem: MediaItem) {
		// TODO: Implement full screen video player
		// This could open a sheet with AVPlayerViewController
		if let videoURL = mediaItem.videoURL, !videoURL.isEmpty {
			print("Playing video: \(videoURL)")
		}
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
						) { image, data, error, cacheType, finished, imageURL in
							if let image = image, finished, let imageURL = imageURL {
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

// MARK: - Preview
#Preview {
	PinterestPostGrid(
		posts: [
			CollectionPost(
				id: "1",
				title: "Beautiful sunset at the beach",
				collectionId: "col1",
				authorId: "user1",
				authorName: "john_doe",
				createdAt: Date(),
				firstMediaItem: MediaItem(
					imageURL: "https://example.com/image1.jpg",
					thumbnailURL: nil,
					videoURL: nil,
					videoDuration: nil,
					isVideo: false
				),
				mediaItems: [
					MediaItem(
						imageURL: "https://example.com/image1.jpg",
						thumbnailURL: nil,
						videoURL: nil,
						videoDuration: nil,
						isVideo: false
					)
				]
			),
			CollectionPost(
				id: "2",
				title: "Amazing city lights",
				collectionId: "col1",
				authorId: "user2",
				authorName: "jane_smith",
				createdAt: Date(),
				firstMediaItem: MediaItem(
					imageURL: "https://example.com/image2.jpg",
					thumbnailURL: nil,
					videoURL: nil,
					videoDuration: nil,
					isVideo: false
				),
				mediaItems: [
					MediaItem(
						imageURL: "https://example.com/image2.jpg",
						thumbnailURL: nil,
						videoURL: nil,
						videoDuration: nil,
						isVideo: false
					)
				]
			)
		],
		collection: nil,
		isIndividualCollection: false,
		currentUserId: "user1"
	)
}

