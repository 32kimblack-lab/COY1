import SwiftUI
import AVKit

struct FullScreenVideoView: View {
	let videoURL: String
	@Environment(\.dismiss) var dismiss
	@State private var player: AVPlayer?
	
	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()
			
			if URL(string: videoURL) != nil {
				if let player = player {
					CustomVideoPlayer(player: player)
						.ignoresSafeArea()
				} else {
					ProgressView()
						.tint(.white)
				}
			}
			
			VStack {
				HStack {
					Spacer()
					Button(action: {
						player?.pause()
						dismiss()
					}) {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 30))
							.foregroundColor(.white)
							.padding()
					}
				}
				Spacer()
			}
		}
		.onAppear {
			if let url = URL(string: videoURL) {
				player = AVPlayer(url: url)
				player?.play()
			}
		}
		.onDisappear {
			player?.pause()
			player = nil
		}
	}
}

struct CustomVideoPlayer: UIViewControllerRepresentable {
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

