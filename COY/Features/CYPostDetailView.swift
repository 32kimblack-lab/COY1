import SwiftUI
import SDWebImageSwiftUI
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
	
	private let maxHeight: CGFloat = UIScreen.main.bounds.height * 0.6
	
	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					// Media Carousel
					if !post.mediaItems.isEmpty {
						TabView(selection: $currentMediaIndex) {
							ForEach(0..<post.mediaItems.count, id: \.self) { index in
								mediaView(mediaItem: post.mediaItems[index])
									.tag(index)
							}
						}
						.tabViewStyle(.page)
						.frame(height: maxHeight)
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
				.frame(maxHeight: maxHeight)
				.clipped()
		} else {
			Rectangle()
				.fill(Color.gray.opacity(0.3))
				.frame(height: maxHeight)
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
					.frame(maxHeight: maxHeight)
					.clipped()
			} else {
				Rectangle()
					.fill(Color.black)
					.frame(height: maxHeight)
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
}

