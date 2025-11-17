import SwiftUI
import SDWebImageSwiftUI
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
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Media Content
			mediaContentView
				.frame(width: width)
				.clipped()
				.cornerRadius(12)
			
			// Post Info
			VStack(alignment: .leading, spacing: 6) {
				// Username
				if !post.authorName.isEmpty {
					Text("@\(post.authorName)")
						.font(.caption)
						.fontWeight(.medium)
						.foregroundColor(.primary)
						.lineLimit(1)
				}
				
				// Caption
				if !post.title.isEmpty {
					Text(post.title)
						.font(.caption)
						.foregroundColor(.secondary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}
				
				// Star Icon (only for members if individual collection)
				if shouldShowStar {
					HStack {
						Spacer()
						Image(systemName: "star.fill")
							.font(.caption)
							.foregroundColor(.yellow)
					}
				}
			}
			.padding(.horizontal, 4)
			.padding(.bottom, 4)
		}
		.background(colorScheme == .dark ? Color(white: 0.1) : Color.white)
		.cornerRadius(12)
		.shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
		.onAppear {
			checkStarVisibility()
		}
	}
	
	// MARK: - Media Content View
	@ViewBuilder
	private var mediaContentView: some View {
		if post.mediaItems.count > 1 {
			// Multiple media items - show swipeable carousel
			TabView {
				ForEach(Array(post.mediaItems.enumerated()), id: \.offset) { index, mediaItem in
					if mediaItem.isVideo {
						videoPlayerView(mediaItem: mediaItem)
					} else {
						imageView(mediaItem: mediaItem)
					}
				}
			}
			.tabViewStyle(.page)
			.frame(height: imageHeight)
			.overlay(
				// Page indicator dots
				VStack {
					Spacer()
					HStack(spacing: 4) {
						ForEach(0..<post.mediaItems.count, id: \.self) { index in
							Circle()
								.fill(Color.white.opacity(0.6))
								.frame(width: 6, height: 6)
						}
					}
					.padding(.bottom, 8)
				}
			)
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
				.frame(height: 200)
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
				.aspectRatio(contentMode: .fill)
				.frame(width: width, height: imageHeight)
				.clipped()
				.onAppear {
					// Use default aspect ratio for Pinterest-style grid
					// Images will be displayed with natural proportions
					// Default height will be adjusted based on content
					if imageHeight == 200 {
						// Set a reasonable default height for grid layout
						imageHeight = width * 1.2 // 1.2:1 aspect ratio (slightly taller)
					}
				}
		} else {
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: 200)
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
					.aspectRatio(contentMode: .fill)
					.frame(height: imageHeight)
					.clipped()
			} else {
				Rectangle()
					.fill(Color.black)
					.frame(height: imageHeight)
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
		.frame(height: imageHeight)
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
				)
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
				)
			)
		],
		collection: nil,
		isIndividualCollection: false,
		currentUserId: "user1"
	)
}

