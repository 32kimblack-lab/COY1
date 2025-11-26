import SwiftUI

struct VoiceRecordingButton: View {
	@ObservedObject var recorder: AudioRecorderManager
	var onRecordingEnded: (Bool) -> Void
	
	@State private var isPressed = false
	@State private var shouldCancel = false
	
	var body: some View {
		Button(action: {}) {
			Image(systemName: "mic.fill")
				.font(.system(size: 20))
				.foregroundColor(recorder.isRecording ? .red : .blue)
		}
		.simultaneousGesture(
			DragGesture(minimumDistance: 0)
				.onChanged { value in
					if !isPressed && !recorder.isRecording {
						// Start recording on press
						isPressed = true
						shouldCancel = false
						Task {
							do {
								try await recorder.startRecording()
							} catch {
								print("Failed to start recording: \(error)")
								isPressed = false
							}
						}
					}
					
					// Check if user dragged up to cancel (like iMessage)
					if value.translation.height < -50 {
						shouldCancel = true
					} else {
						shouldCancel = false
					}
				}
				.onEnded { _ in
					if recorder.isRecording {
						// Stop recording when released
						recorder.stopRecording()
						
						// If dragged up, cancel; otherwise show preview
						if shouldCancel {
							recorder.cancelRecording()
							onRecordingEnded(false)
						} else {
							// Show preview (don't auto-send)
							onRecordingEnded(false)
						}
					}
					isPressed = false
					shouldCancel = false
				}
		)
	}
}

