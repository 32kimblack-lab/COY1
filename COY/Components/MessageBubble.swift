import SwiftUI
import SDWebImageSwiftUI
import FirebaseAuth
import AVFoundation

struct MessageBubble: View {
	let message: MessageModel
	let isMe: Bool
	let senderProfileImageURL: String?
	let repliedToMessage: MessageModel?
	let repliedToSenderName: String?
	var onLongPress: () -> Void
	var onReplyTap: () -> Void
	var onReactionTap: (String) -> Void
	
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		HStack(alignment: .bottom, spacing: 8) {
			if !isMe {
				// Profile image for received messages
				if let profileURL = senderProfileImageURL, !profileURL.isEmpty, let url = URL(string: profileURL) {
					WebImage(url: url)
						.resizable()
						.scaledToFill()
						.frame(width: 32, height: 32)
						.clipShape(Circle())
				} else {
					Circle()
						.fill(Color.gray.opacity(0.3))
						.frame(width: 32, height: 32)
						.overlay(
							Image(systemName: "person.fill")
								.font(.system(size: 14))
								.foregroundColor(.secondary)
						)
				}
			}
			
			VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
				// Reply preview if this message is a reply
				if let repliedTo = repliedToMessage {
					HStack {
						if isMe { Spacer() }
						VStack(alignment: .leading, spacing: 2) {
							Text(repliedToSenderName ?? "User")
								.font(.system(size: 11, weight: .semibold))
								.foregroundColor(isMe ? .white.opacity(0.8) : .blue)
							Text(repliedTo.isDeleted ? "This message was deleted" : repliedTo.content)
								.font(.system(size: 11))
								.foregroundColor(isMe ? .white.opacity(0.7) : .secondary)
								.lineLimit(2)
						}
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.background(isMe ? Color.white.opacity(0.2) : Color.gray.opacity(0.2))
						.cornerRadius(6)
						if !isMe { Spacer() }
					}
					.onTapGesture {
						onReplyTap()
					}
				}
				
				// Message content
				HStack(alignment: .bottom, spacing: 6) {
					if isMe { Spacer() }
					
					Group {
						switch message.type {
						case "text":
							Text(message.isDeleted ? "This message was deleted" : message.content)
								.font(.system(size: 15))
								.foregroundColor(isMe ? .white : .primary)
								.padding(.horizontal, 12)
								.padding(.vertical, 8)
						case "image":
							if !message.content.isEmpty, let url = URL(string: message.content) {
								WebImage(url: url)
									.resizable()
									.scaledToFill()
									.frame(maxWidth: 200, maxHeight: 200)
									.clipShape(RoundedRectangle(cornerRadius: 12))
							}
						case "video":
							if !message.content.isEmpty, let url = URL(string: message.content) {
								VideoThumbnailView(videoURL: url)
									.frame(maxWidth: 200, maxHeight: 200)
									.clipShape(RoundedRectangle(cornerRadius: 12))
							}
						case "voice":
							if !message.content.isEmpty, let url = URL(string: message.content) {
								VoiceMessagePlayerView(audioURL: url, isMe: isMe)
							}
						default:
							Text(message.content)
								.font(.system(size: 15))
								.foregroundColor(isMe ? .white : .primary)
								.padding(.horizontal, 12)
								.padding(.vertical, 8)
						}
					}
					.background(
						RoundedRectangle(cornerRadius: 16)
							.fill(isMe ? Color.blue : (colorScheme == .dark ? Color(.systemGray5) : Color(.systemGray6)))
					)
					.overlay(
						RoundedRectangle(cornerRadius: 16)
							.stroke(isMe ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
					)
					
					if !isMe { Spacer() }
				}
				
				// Reactions
				if !message.reactions.isEmpty {
					HStack(spacing: 4) {
						if isMe { Spacer() }
						ForEach(Array(message.reactions.values), id: \.self) { emoji in
							Text(emoji)
								.font(.system(size: 14))
								.padding(.horizontal, 6)
								.padding(.vertical, 2)
								.background(Color.gray.opacity(0.2))
								.cornerRadius(12)
								.onTapGesture {
									onReactionTap(emoji)
								}
						}
						if !isMe { Spacer() }
					}
				}
				
				// Timestamp
				Text(formatTime(message.timestamp))
					.font(.system(size: 11))
					.foregroundColor(.secondary)
					.padding(.horizontal, 4)
			}
			.frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
			
			if isMe {
				// Profile image for sent messages
				if let profileURL = senderProfileImageURL, !profileURL.isEmpty, let url = URL(string: profileURL) {
					WebImage(url: url)
						.resizable()
						.scaledToFill()
						.frame(width: 32, height: 32)
						.clipShape(Circle())
				} else {
					Circle()
						.fill(Color.gray.opacity(0.3))
						.frame(width: 32, height: 32)
						.overlay(
							Image(systemName: "person.fill")
								.font(.system(size: 14))
								.foregroundColor(.secondary)
						)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 4)
		.onLongPressGesture {
			onLongPress()
		}
	}
	
	private func formatTime(_ date: Date) -> String {
		let formatter = DateFormatter()
		formatter.timeStyle = .short
		return formatter.string(from: date)
	}
}

// MARK: - Video Thumbnail View
struct VideoThumbnailView: View {
	let videoURL: URL
	@State private var thumbnail: UIImage?
	
	var body: some View {
		ZStack {
			if let thumbnail = thumbnail {
				Image(uiImage: thumbnail)
					.resizable()
					.scaledToFill()
			} else {
				Color.gray.opacity(0.3)
			}
			
			Image(systemName: "play.circle.fill")
				.font(.system(size: 40))
				.foregroundColor(.white)
		}
		.onAppear {
			generateThumbnail()
		}
	}
	
	private func generateThumbnail() {
		let asset = AVAsset(url: videoURL)
		let imageGenerator = AVAssetImageGenerator(asset: asset)
		imageGenerator.appliesPreferredTrackTransform = true
		
		Task {
			do {
				let cgImage = try await imageGenerator.image(at: CMTime.zero).image
				await MainActor.run {
					thumbnail = UIImage(cgImage: cgImage)
				}
			} catch {
				print("Error generating thumbnail: \(error)")
			}
		}
	}
}

