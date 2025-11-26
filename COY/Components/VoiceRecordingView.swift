import SwiftUI
import AVFoundation

struct VoiceRecordingView: View {
	@ObservedObject var recorder: AudioRecorderManager
	var onStopRecording: () -> Void
	
	@State private var waveformPhase: Double = 0
	@State private var waveformTimer: Timer?
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		HStack(spacing: 12) {
			// Down button to stop recording
			Button(action: {
				recorder.stopRecording()
				onStopRecording()
			}) {
				Image(systemName: "chevron.down.circle.fill")
					.font(.system(size: 24))
					.foregroundColor(.gray)
			}
			
			// Animated waveform
			HStack(spacing: 2) {
				ForEach(0..<20, id: \.self) { index in
					RoundedRectangle(cornerRadius: 1.5)
						.fill(Color.red)
						.frame(width: 3, height: waveformHeight(for: index))
				}
			}
			.frame(height: 30)
			
			// Duration display
			Text(recorder.formattedDuration(recorder.recordingDuration))
				.font(.system(size: 13, weight: .medium, design: .monospaced))
				.foregroundColor(.secondary)
			
			Spacer()
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5))
		.cornerRadius(20)
		.onAppear {
			startWaveformAnimation()
		}
		.onDisappear {
			stopWaveformAnimation()
		}
	}
	
	private func waveformHeight(for index: Int) -> CGFloat {
		let baseHeight: CGFloat = 4
		let maxHeight: CGFloat = 24
		
		let phase1 = waveformPhase + Double(index) * 0.3
		let phase2 = waveformPhase * 1.5 + Double(index) * 0.5
		
		let amplitude = (sin(phase1) + sin(phase2 * 0.7)) / 2
		let normalized = (amplitude + 1) / 2
		
		return baseHeight + normalized * (maxHeight - baseHeight)
	}
	
	private func startWaveformAnimation() {
		waveformTimer?.invalidate()
		waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
			waveformPhase += 0.2
			if waveformPhase > Double.pi * 2 {
				waveformPhase = 0
			}
		}
	}
	
	private func stopWaveformAnimation() {
		waveformTimer?.invalidate()
		waveformTimer = nil
	}
}

