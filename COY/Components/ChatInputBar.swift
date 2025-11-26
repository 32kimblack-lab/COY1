import SwiftUI
import PhotosUI
import FirebaseAuth

struct ChatInputBar: View {
	@Binding var messageText: String
	@Binding var replyToMessage: MessageModel?
	var onSend: () -> Void
	var onSendMedia: (UIImage?, URL?) -> Void
	var onSendVoice: (URL) -> Void
	var canMessage: Bool
	var friendshipStatus: ChatInputBar.FriendshipStatus
	var onAddFriend: () -> Void
	
	@StateObject private var recorder = AudioRecorderManager.shared
	@State private var showImagePicker = false
	@State private var showVideoPicker = false
	@State private var selectedImage: UIImage?
	@State private var selectedVideoURL: URL?
	@State private var waveformPhase: Double = 0
	@State private var waveformTimer: Timer?
	@Environment(\.colorScheme) var colorScheme
	
	private func waveformHeight(for index: Int) -> CGFloat {
		let baseHeight: CGFloat = 4
		let maxHeight: CGFloat = 24
		
		let phase1 = waveformPhase + Double(index) * 0.3
		let phase2 = waveformPhase * 1.5 + Double(index) * 0.5
		
		let amplitude = (sin(phase1) + sin(phase2 * 0.7)) / 2
		let normalized = (amplitude + 1) / 2
		
		return baseHeight + normalized * (maxHeight - baseHeight)
	}
	
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
			// Reply preview if replying to a message
			if let replyMessage = replyToMessage {
				HStack {
					VStack(alignment: .leading, spacing: 4) {
						Text("Replying to \(replyMessage.senderUid == Auth.auth().currentUser?.uid ? "yourself" : "message")")
							.font(.caption)
							.foregroundColor(.secondary)
						Text(replyMessage.content)
							.font(.subheadline)
							.lineLimit(2)
							.foregroundColor(.primary)
					}
					Spacer()
					Button(action: {
						replyToMessage = nil
					}) {
						Image(systemName: "xmark.circle.fill")
							.foregroundColor(.secondary)
					}
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5))
			}
			
			// Voice recording preview (shows when recording is stopped but not yet sent)
			if !recorder.isRecording && recorder.recordingURL != nil {
				VoiceRecordingPreviewView(
					recorder: recorder,
					onSend: {
						if let url = recorder.recordingURL {
							onSendVoice(url)
							// Clean up after a brief delay to allow upload to start
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
								recorder.cancelRecording()
							}
						}
					},
					onCancel: {
						recorder.cancelRecording()
					}
				)
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
			}
			
			// Main input bar
			HStack(spacing: 12) {
				// Voice recording button (press and hold to record)
				if canMessage && !recorder.isRecording && recorder.recordingURL == nil {
					VoiceRecordingButton(
						recorder: recorder,
						onRecordingEnded: { shouldSend in
							if shouldSend, let url = recorder.recordingURL, recorder.recordingDuration > 0.3 {
								// Auto-send after recording ends
								onSendVoice(url)
								DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
									recorder.cancelRecording()
								}
							} else {
								// Show preview for user to confirm or cancel
								recorder.stopRecording()
							}
						}
					)
				}
				
				// Media picker button
				if canMessage && !recorder.isRecording && recorder.recordingURL == nil {
					Button(action: {
						showImagePicker = true
					}) {
						Image(systemName: "photo")
							.font(.system(size: 20))
							.foregroundColor(.blue)
					}
				}
				
				// Text input
				if canMessage && !recorder.isRecording && recorder.recordingURL == nil {
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
				} else if recorder.isRecording {
					// Show recording waveform while recording
					HStack(spacing: 8) {
						// Animated waveform
						HStack(spacing: 2) {
							ForEach(0..<15, id: \.self) { index in
								RoundedRectangle(cornerRadius: 1.5)
									.fill(Color.blue)
									.frame(width: 3, height: waveformHeight(for: index))
							}
						}
						.frame(height: 30)
						.onAppear {
							startWaveformAnimation()
						}
						
						Text(recorder.formattedDuration(recorder.recordingDuration))
							.font(.system(size: 13, weight: .medium, design: .monospaced))
							.foregroundColor(.secondary)
						
						Spacer()
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5))
					.cornerRadius(20)
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
					if let image = image {
						onSendMedia(image, nil)
					} else if let videoURL = videoURL {
						onSendMedia(nil, videoURL)
					}
				}
			)
		}
		.onChange(of: recorder.isRecording) { oldValue, newValue in
			if newValue {
				startWaveformAnimation()
			} else {
				stopWaveformAnimation()
			}
		}
		.onDisappear {
			stopWaveformAnimation()
		}
	}
	
	private func startWaveformAnimation() {
		waveformTimer?.invalidate()
		let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
			Task { @MainActor in
				guard recorder.isRecording else {
					timer.invalidate()
					return
				}
				waveformPhase += 0.2
				if waveformPhase > Double.pi * 2 {
					waveformPhase = 0
				}
			}
		}
		waveformTimer = timer
	}
	
	private func stopWaveformAnimation() {
		waveformTimer?.invalidate()
		waveformTimer = nil
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

