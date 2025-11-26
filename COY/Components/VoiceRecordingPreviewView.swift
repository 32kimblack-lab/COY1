import SwiftUI
import AVFoundation

struct VoiceRecordingPreviewView: View {
	@ObservedObject var recorder: AudioRecorderManager
	var onSend: () -> Void
	var onCancel: () -> Void
	
	@State private var waveformData: [CGFloat] = []
	@State private var animationPhase: Double = 0
	
	var body: some View {
		HStack(spacing: 12) {
			// Cancel button
			Button(action: onCancel) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 24))
					.foregroundColor(.red)
			}
			
			// Waveform visualization
			HStack(spacing: 2) {
				ForEach(0..<20, id: \.self) { index in
					RoundedRectangle(cornerRadius: 2)
						.fill(Color.blue)
						.frame(width: 3, height: waveformHeight(for: index))
						.animation(
							Animation.easeInOut(duration: 0.5)
								.repeatForever(autoreverses: true)
								.delay(Double(index) * 0.05),
							value: animationPhase
						)
				}
			}
			.frame(height: 40)
			.onAppear {
				startWaveformAnimation()
			}
			
			// Duration display
			Text(recorder.formattedDuration(recorder.recordingDuration))
				.font(.system(size: 14, weight: .medium, design: .monospaced))
				.foregroundColor(.primary)
				.frame(minWidth: 50, alignment: .leading)
			
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
			startWaveformAnimation()
		}
	}
	
	private func waveformHeight(for index: Int) -> CGFloat {
		// Generate random-looking waveform pattern
		let baseHeight: CGFloat = 4
		let maxHeight: CGFloat = 32
		
		// Use sin wave with multiple frequencies for more natural look
		let phase1 = animationPhase + Double(index) * 0.3
		let phase2 = animationPhase * 1.5 + Double(index) * 0.5
		
		let amplitude = (sin(phase1) + sin(phase2 * 0.7)) / 2
		let normalized = (amplitude + 1) / 2 // Normalize from -1...1 to 0...1
		
		return baseHeight + normalized * (maxHeight - baseHeight)
	}
	
	private func startWaveformAnimation() {
		// Animate waveform continuously
		Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
			withAnimation(.linear(duration: 0.1)) {
				animationPhase += 0.2
				if animationPhase > Double.pi * 2 {
					animationPhase = 0
				}
			}
		}
	}
}

