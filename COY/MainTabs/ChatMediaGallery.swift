import SwiftUI
import SDWebImageSwiftUI
import AVFoundation

struct ChatMediaGallery: View {
	let chatId: String
	private let chatService = ChatService.shared
	@State private var mediaMessages: [MessageModel] = []
	@State private var isLoading = true
	@State private var selectedImageURL: String?
	@State private var selectedVideoURL: String?
	@Environment(\.dismiss) var dismiss
	
	var body: some View {
		NavigationStack {
			if isLoading {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if mediaMessages.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "photo.on.rectangle")
						.font(.system(size: 50))
						.foregroundColor(.gray)
					Text("No media")
						.font(.headline)
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVGrid(columns: [
						GridItem(.flexible()),
						GridItem(.flexible()),
						GridItem(.flexible())
					], spacing: 2) {
						ForEach(mediaMessages) { message in
							if let url = URL(string: message.content) {
								if message.type == "image" {
									Button(action: {
										selectedImageURL = message.content
									}) {
										WebImage(url: url)
											.resizable()
											.scaledToFill()
											.frame(width: 120, height: 120)
											.clipped()
											.cornerRadius(4)
									}
									.buttonStyle(.plain)
								} else if message.type == "video" {
									Button(action: {
										selectedVideoURL = message.content
									}) {
										VideoThumbnailGalleryView(videoURL: url)
											.frame(width: 120, height: 120)
											.clipped()
											.cornerRadius(4)
									}
									.buttonStyle(.plain)
								}
							}
						}
					}
					.padding(2)
				}
			}
		}
		.navigationTitle("Photos & Videos")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .navigationBarTrailing) {
				Button("Done") {
					dismiss()
				}
			}
		}
		.onAppear {
			loadMediaMessages()
		}
		.fullScreenCover(isPresented: Binding(
			get: { selectedImageURL != nil },
			set: { if !$0 { selectedImageURL = nil } }
		)) {
			if let imageURL = selectedImageURL {
				FullScreenImageView(imageURL: imageURL)
			}
		}
		.fullScreenCover(isPresented: Binding(
			get: { selectedVideoURL != nil },
			set: { if !$0 { selectedVideoURL = nil } }
		)) {
			if let videoURL = selectedVideoURL {
				FullScreenVideoView(videoURL: videoURL)
			}
		}
	}
	
	private func loadMediaMessages() {
		Task {
			do {
				// Load all messages and filter for media
				for try await messageList in chatService.getMessages(chatId: chatId) {
					await MainActor.run {
						self.mediaMessages = messageList.filter { 
							$0.type == "image" || $0.type == "video" || $0.type == "live_photo"
						}
						self.isLoading = false
					}
				}
			} catch {
				print("Error loading media: \(error)")
				await MainActor.run {
					self.isLoading = false
				}
			}
		}
	}
}

struct VideoThumbnailGalleryView: View {
	let videoURL: URL
	@State private var thumbnail: UIImage?
	
	var body: some View {
		Group {
			if let thumbnail = thumbnail {
				ZStack {
					Image(uiImage: thumbnail)
						.resizable()
						.aspectRatio(contentMode: .fill)
					
					Image(systemName: "play.circle.fill")
						.font(.system(size: 30))
						.foregroundColor(.white)
						.shadow(radius: 2)
				}
			} else {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(Color(.systemGray5))
			}
		}
		.onAppear {
			generateThumbnail()
		}
	}
	
	private func generateThumbnail() {
		Task {
			let asset = AVURLAsset(url: videoURL)
			let imageGenerator = AVAssetImageGenerator(asset: asset)
			imageGenerator.appliesPreferredTrackTransform = true
			imageGenerator.maximumSize = CGSize(width: 200, height: 200)
			
			do {
				let time = CMTime(seconds: 0.1, preferredTimescale: 600)
				let cgImage = try await imageGenerator.image(at: time).image
				await MainActor.run {
					self.thumbnail = UIImage(cgImage: cgImage)
				}
			} catch {
				print("Error generating video thumbnail: \(error)")
			}
		}
	}
}

