import SwiftUI
import PhotosUI
import FirebaseAuth

struct ChatInputBar: View {
	@Binding var messageText: String
	@Binding var replyToMessage: MessageModel?
	var onSend: () -> Void
	var onSendMedia: (UIImage?, URL?) -> Void
	var canMessage: Bool
	var friendshipStatus: ChatInputBar.FriendshipStatus
	var onAddFriend: () -> Void
	
	@State private var showImagePicker = false
	@State private var showVideoPicker = false
	@State private var selectedImage: UIImage?
	@State private var selectedVideoURL: URL?
	@State private var previewImage: UIImage?
	@State private var previewVideoURL: URL?
	@Environment(\.colorScheme) var colorScheme
	
	enum FriendshipStatus {
		case friends
		case pending
		case unadded
		case blocked
		case bothUnadded
		case theyUnadded
		case iUnadded
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// Reply preview removed - handled in ChatScreen
			
			// Media preview (shows when photo/video is selected but not yet sent)
			if previewImage != nil || previewVideoURL != nil {
				MediaPreviewView(
					image: previewImage,
					videoURL: previewVideoURL,
					onSend: {
						onSendMedia(previewImage, previewVideoURL)
						previewImage = nil
						previewVideoURL = nil
					},
					onCancel: {
						previewImage = nil
						previewVideoURL = nil
					}
				)
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
			}
			
			// Main input bar
			HStack(spacing: 12) {
				// Media picker button (only show if no preview is active)
				if canMessage && previewImage == nil && previewVideoURL == nil {
					Button(action: {
						showImagePicker = true
					}) {
						Image(systemName: "photo")
							.font(.system(size: 20))
							.foregroundColor(.blue)
					}
				}
				
				// Text input (only show if no preview is active)
				if canMessage && previewImage == nil && previewVideoURL == nil {
					TextField("Message", text: $messageText, axis: .vertical)
						.textFieldStyle(.plain)
						.padding(.horizontal, 12)
						.padding(.vertical, 8)
						.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5))
						.cornerRadius(20)
						.lineLimit(1...5)
						.onSubmit {
							if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
								onSend()
							}
						}
				} else {
					// Show appropriate message based on friendship status
					HStack {
						switch friendshipStatus {
						case .pending:
							Text("Friend request pending")
								.font(.subheadline)
								.foregroundColor(.secondary)
						case .unadded:
							// Normal Add System: User has never been friends
							Button(action: onAddFriend) {
								Text("Add Friend")
									.font(.subheadline)
									.fontWeight(.medium)
									.foregroundColor(.white)
									.padding(.horizontal, 16)
									.padding(.vertical, 8)
									.background(Color.blue)
									.cornerRadius(20)
							}
						case .blocked:
							Text("You cannot message this user")
								.font(.subheadline)
								.foregroundColor(.secondary)
						case .bothUnadded:
							// Two-Way Unadd: Both unadded each other
							// Message: "You have unadded this user." with Add button
							VStack(alignment: .leading, spacing: 8) {
								Text("You have unadded this user.")
									.font(.subheadline)
									.foregroundColor(.secondary)
							Button(action: onAddFriend) {
									Text("Add")
									.font(.subheadline)
									.fontWeight(.medium)
									.foregroundColor(.white)
									.padding(.horizontal, 16)
									.padding(.vertical, 8)
									.background(Color.blue)
									.cornerRadius(20)
								}
							}
						case .theyUnadded:
							// One-Way Unadd: They unadded me, I haven't unadded them
							// Message: "You have been unadded by this user." with NO Add button
							Text("You have been unadded by this user.")
								.font(.subheadline)
								.foregroundColor(.secondary)
						case .iUnadded:
							// One-Way Unadd: I unadded them, they haven't unadded me
							// Message: "You have unadded this user." with Add button
							VStack(alignment: .leading, spacing: 8) {
								Text("You have unadded this user.")
									.font(.subheadline)
									.foregroundColor(.secondary)
							Button(action: onAddFriend) {
									Text("Add")
									.font(.subheadline)
									.fontWeight(.medium)
									.foregroundColor(.white)
									.padding(.horizontal, 16)
									.padding(.vertical, 8)
									.background(Color.blue)
									.cornerRadius(20)
								}
							}
						case .friends:
							Text("Unable to send message")
								.font(.subheadline)
								.foregroundColor(.secondary)
						}
						Spacer()
					}
					.padding(.horizontal, 12)
				}
				
				// Send button
				if canMessage && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					Button(action: onSend) {
						Image(systemName: "arrow.up.circle.fill")
							.font(.system(size: 28))
							.foregroundColor(.blue)
					}
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.background(colorScheme == .dark ? Color.black : Color.white)
		}
		.sheet(isPresented: $showImagePicker) {
			ChatMediaPicker(
				selectedImage: $selectedImage,
				selectedVideoURL: $selectedVideoURL,
				sourceType: .photoLibrary,
				mediaTypes: ["public.image", "public.movie"],
				onSelection: { image, videoURL in
					// Store in preview instead of immediately sending
					previewImage = image
					previewVideoURL = videoURL
					// Clear the picker selections
					selectedImage = nil
					selectedVideoURL = nil
				}
			)
		}
	}
}

// MARK: - Chat Media Picker Helper
struct ChatMediaPicker: UIViewControllerRepresentable {
	@Binding var selectedImage: UIImage?
	@Binding var selectedVideoURL: URL?
	var sourceType: UIImagePickerController.SourceType
	var mediaTypes: [String]
	var onSelection: (UIImage?, URL?) -> Void
	@Environment(\.dismiss) var dismiss
	
	func makeUIViewController(context: Context) -> UIImagePickerController {
		let picker = UIImagePickerController()
		picker.delegate = context.coordinator
		picker.sourceType = sourceType
		picker.mediaTypes = mediaTypes
		picker.allowsEditing = false
		return picker
	}
	
	func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}
	
	class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
		let parent: ChatMediaPicker
		
		init(_ parent: ChatMediaPicker) {
			self.parent = parent
		}
		
		func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
			if let mediaType = info[.mediaType] as? String {
				if mediaType == "public.movie" {
					if let videoURL = info[.mediaURL] as? URL {
						parent.selectedVideoURL = videoURL
						parent.onSelection(nil, videoURL)
					}
				} else if mediaType == "public.image" {
					if let image = info[.originalImage] as? UIImage {
						parent.selectedImage = image
						parent.onSelection(image, nil)
					}
				}
			}
			parent.dismiss()
		}
		
		func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
			parent.dismiss()
		}
	}
}

