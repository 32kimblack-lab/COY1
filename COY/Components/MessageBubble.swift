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
	var onReactionDetailsTap: ((String) -> Void)? = nil // (emoji) -> Void
	var onMediaTap: ((String, String) -> Void)? = nil // (mediaURL, mediaType)
	
	@Environment(\.colorScheme) var colorScheme
	
	private var repliedToPreviewText: String {
		guard let repliedTo = repliedToMessage else { return "" }
		if repliedTo.isDeleted {
			return repliedTo.type == "text" ? "This message was deleted" : "This media was deleted"
		}
		if repliedTo.type == "text" {
			return repliedTo.content
		}
		if repliedTo.type == "image" || repliedTo.type == "photo" {
			return "Photo"
		}
		if repliedTo.type == "video" {
			return "Video"
		}
		return repliedTo.content
	}
	
	var body: some View {
		HStack(alignment: .bottom, spacing: 8) {
			if !isMe {
				profileImageView
			}
			
			VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
				// Reply preview if this message is a reply
				replyPreviewView
				
				// Message content
				messageContentView
				
				// Reactions
				reactionsView
				
				// Timestamp
				HStack(spacing: 4) {
					Text(formatTime(message.timestamp))
						.font(.system(size: 11))
						.foregroundColor(.secondary)
					if message.isEdited {
						Text("(edited)")
							.font(.system(size: 11))
							.foregroundColor(.secondary)
					}
				}
				.padding(.horizontal, 4)
			}
			.frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
			
			if isMe {
				profileImageView
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 4)
		.contentShape(Rectangle())
		.onLongPressGesture {
			onLongPress()
		}
	}
	
	// MARK: - Subviews
	
	private var profileImageView: some View {
		Group {
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
			
	@ViewBuilder
	private var replyPreviewView: some View {
				if let repliedTo = repliedToMessage {
					HStack {
						if isMe { Spacer() }
						HStack(alignment: .center, spacing: 6) {
							// Show media thumbnail for photos/videos
							if !repliedTo.isDeleted {
								switch repliedTo.type {
								case "image", "photo":
									if let url = URL(string: repliedTo.content) {
										WebImage(url: url)
											.resizable()
											.indicator(.activity)
											.scaledToFill()
											.frame(width: 40, height: 40)
											.clipShape(RoundedRectangle(cornerRadius: 6))
											.clipped()
									}
								case "video":
									if let url = URL(string: repliedTo.content) {
										ZStack {
											VideoThumbnailView(videoURL: url)
												.frame(width: 40, height: 40)
												.clipShape(RoundedRectangle(cornerRadius: 6))
												.clipped()
											Image(systemName: "play.circle.fill")
												.font(.system(size: 16))
												.foregroundColor(.white)
										}
									}
								default:
									EmptyView()
								}
							}
							
						VStack(alignment: .leading, spacing: 2) {
							Text(repliedToSenderName ?? "User")
								.font(.system(size: 11, weight: .semibold))
									.foregroundColor(isMe ? .primary.opacity(0.8) : .blue)
								Text(repliedToPreviewText)
								.font(.system(size: 11))
									.foregroundColor(isMe ? .primary.opacity(0.7) : .secondary)
								.lineLimit(2)
							}
						}
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.background(isMe ? Color.clear : Color.gray.opacity(0.2))
						.cornerRadius(6)
						if !isMe { Spacer() }
					}
					.onTapGesture {
						onReplyTap()
					}
					}
				}
				
	@ViewBuilder
	private var messageContentView: some View {
				HStack(alignment: .bottom, spacing: 6) {
					if isMe { Spacer() }
					
			messageContentBody
				.background(messageBackground)
				.overlay(messageOutline)
			
			if !isMe { Spacer() }
		}
	}
	
	@ViewBuilder
	private var messageContentBody: some View {
		if message.isDeleted {
			deletedMessageView
		} else {
						switch message.type {
						case "text":
				textMessageView
			case "image":
				imageMessageView
			case "video":
				videoMessageView
			default:
				Text(message.content)
					.font(.system(size: 15))
					.foregroundColor(.primary)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.contentShape(Rectangle())
			}
		}
	}
	
	private var deletedMessageView: some View {
		HStack(spacing: 6) {
			Image(systemName: "trash")
				.font(.system(size: 12))
				.foregroundColor(.gray)
			Text(message.type == "text" ? "This message was deleted" : "This media was deleted")
				.font(.system(size: 15))
				.foregroundColor(.gray)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.contentShape(Rectangle())
	}
	
	private var textMessageView: some View {
		Text(message.content)
								.font(.system(size: 15))
			.foregroundColor(.primary)
								.padding(.horizontal, 12)
								.padding(.vertical, 8)
			.contentShape(Rectangle())
	}
	
	@ViewBuilder
	private var imageMessageView: some View {
							if !message.content.isEmpty, let url = URL(string: message.content) {
								WebImage(url: url)
									.resizable()
									.scaledToFill()
									.frame(maxWidth: 200, maxHeight: 200)
									.clipShape(RoundedRectangle(cornerRadius: 12))
				.contentShape(Rectangle())
				.highPriorityGesture(
					TapGesture()
						.onEnded {
							onMediaTap?(message.content, "image")
						}
				)
		}
	}
	
	@ViewBuilder
	private var videoMessageView: some View {
							if !message.content.isEmpty, let url = URL(string: message.content) {
								VideoThumbnailView(videoURL: url)
									.frame(maxWidth: 200, maxHeight: 200)
									.clipShape(RoundedRectangle(cornerRadius: 12))
				.contentShape(Rectangle())
				.highPriorityGesture(
					TapGesture()
						.onEnded {
							onMediaTap?(message.content, "video")
						}
				)
						}
					}
	
	private var messageBackground: some View {
						RoundedRectangle(cornerRadius: 16)
			.fill(isMe ? Color.clear : (colorScheme == .dark ? Color(.systemGray5) : Color(.systemGray6)))
	}
	
	private var messageOutline: some View {
						RoundedRectangle(cornerRadius: 16)
			.stroke(outlineColor, lineWidth: 1)
	}
	
	private var outlineColor: Color {
		let shouldShowOutline = message.type == "text" || message.isDeleted
		guard shouldShowOutline else { return Color.clear }
		
		if isMe {
			return colorScheme == .dark ? Color.white : Color.black
		} else {
			return Color.gray.opacity(0.2)
		}
				}
				
	@ViewBuilder
	private var reactionsView: some View {
		if !message.reactions.isEmpty {
			HStack(spacing: 4) {
				if isMe { Spacer() }
				ForEach(groupedReactions, id: \.emoji) { reactionGroup in
					HStack(spacing: 4) {
						Text(reactionGroup.emoji)
							.font(.system(size: 14))
						if reactionGroup.count > 1 {
							Text("\(reactionGroup.count)")
								.font(.system(size: 12, weight: .medium))
								.foregroundColor(.secondary)
						}
					}
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(Color.gray.opacity(0.2))
					.cornerRadius(12)
					.onTapGesture {
						if let onDetails = onReactionDetailsTap {
							onDetails(reactionGroup.emoji)
						} else {
							onReactionTap(reactionGroup.emoji)
						}
					}
				}
				if !isMe { Spacer() }
			}
		}
	}
	
	// Group reactions by emoji and count
	private var groupedReactions: [(emoji: String, count: Int)] {
		var grouped: [String: Int] = [:]
		for emoji in message.reactions.values {
			grouped[emoji, default: 0] += 1
		}
		return grouped.map { (emoji: $0.key, count: $0.value) }
			.sorted { $0.emoji < $1.emoji }
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

