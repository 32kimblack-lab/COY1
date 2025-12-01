import SwiftUI
import AVKit
import AVFoundation
import SDWebImageSwiftUI

/// Video player view with thumbnail and play button
/// Moved from CYHome.swift for better organization
struct VideoPlayerView: View {
	let videoURL: String
	let thumbnailURL: String?
	@ObservedObject var videoPlayerManager: VideoPlayerManager
	@State private var isPlaying = false
	@State private var showControls = true
	
	var body: some View {
		ZStack {
			// Thumbnail
			if let thumbnailURL = thumbnailURL, let url = URL(string: thumbnailURL) {
				WebImage(url: url)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(maxWidth: .infinity)
					.opacity(isPlaying ? 0 : 1)
			} else {
				Color.black
			}
			
			// Video player (when playing)
			if isPlaying {
				if URL(string: videoURL) != nil {
					VideoPlayerViewController(player: videoPlayerManager.getOrCreatePlayer(for: videoURL, postId: ""))
						.frame(maxWidth: .infinity)
				}
			}
			
			// Play button overlay
			if !isPlaying {
				Button(action: {
					let playerId = "\(videoURL)"
					videoPlayerManager.playVideo(playerId: playerId)
					isPlaying = true
				}) {
					Image(systemName: "play.circle.fill")
						.font(.system(size: 60))
						.foregroundColor(.white.opacity(0.9))
				}
			}
		}
		.onAppear {
			_ = videoPlayerManager.getOrCreatePlayer(for: videoURL, postId: "")
		}
		.onDisappear {
			let playerId = "\(videoURL)"
			videoPlayerManager.pauseVideo(playerId: playerId)
		}
	}
}

/// Video player view controller wrapper
/// Moved from CYHome.swift for better organization
struct VideoPlayerViewController: UIViewControllerRepresentable {
	let player: AVPlayer
	
	func makeUIViewController(context: Context) -> AVPlayerViewController {
		let controller = AVPlayerViewController()
		controller.player = player
		controller.showsPlaybackControls = false
		return controller
	}
	
	func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
		uiViewController.player = player
	}
}
