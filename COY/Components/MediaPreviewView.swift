import SwiftUI
import AVFoundation

struct MediaPreviewView: View {
	let image: UIImage?
	let videoURL: URL?
	var onSend: () -> Void
	var onCancel: () -> Void
	
	@State private var videoThumbnail: UIImage?
	
	var body: some View {
		HStack(spacing: 12) {
			// Cancel button
			Button(action: onCancel) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 24))
					.foregroundColor(.red)
			}
			
			// Media preview
			Group {
				if let image = image {
					Image(uiImage: image)
						.resizable()
						.scaledToFill()
						.frame(width: 60, height: 60)
						.clipShape(RoundedRectangle(cornerRadius: 8))
				} else if videoURL != nil {
					ZStack {
						if let thumbnail = videoThumbnail {
							Image(uiImage: thumbnail)
								.resizable()
								.scaledToFill()
								.frame(width: 60, height: 60)
								.clipShape(RoundedRectangle(cornerRadius: 8))
						} else {
							RoundedRectangle(cornerRadius: 8)
								.fill(Color.gray.opacity(0.3))
								.frame(width: 60, height: 60)
								.overlay(
									ProgressView()
										.tint(.white)
								)
						}
						
						// Play icon overlay
						Image(systemName: "play.circle.fill")
							.font(.system(size: 24))
							.foregroundColor(.white)
					}
					.frame(width: 60, height: 60)
					.clipped()
				}
			}
			
			Spacer()
			
			// Send button
			Button(action: onSend) {
				Image(systemName: "arrow.up.circle.fill")
					.font(.system(size: 28))
					.foregroundColor(.blue)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(Color(.systemGray6))
		.cornerRadius(20)
		.onAppear {
			if let videoURL = videoURL {
				generateVideoThumbnail(url: videoURL)
			}
		}
	}
	
	private func generateVideoThumbnail(url: URL) {
		let asset = AVAsset(url: url)
		let imageGenerator = AVAssetImageGenerator(asset: asset)
		imageGenerator.appliesPreferredTrackTransform = true
		
		Task {
			do {
				let cgImage = try await imageGenerator.image(at: CMTime.zero).image
				await MainActor.run {
					videoThumbnail = UIImage(cgImage: cgImage)
				}
			} catch {
				print("Error generating video thumbnail: \(error)")
			}
		}
	}
	
}

