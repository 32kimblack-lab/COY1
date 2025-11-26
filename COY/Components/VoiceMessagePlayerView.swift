import SwiftUI
import AVFoundation
import Combine

struct VoiceMessagePlayerView: View {
	let audioURL: URL
	let isMe: Bool
	
	@StateObject private var player = AudioPlayerManager()
	@State private var isPlaying = false
	@State private var currentTime: TimeInterval = 0
	@State private var duration: TimeInterval = 0
	
	var body: some View {
		HStack(spacing: 12) {
			if !isMe {
				// Play/Pause button for received messages (on left)
				Button(action: togglePlayback) {
					Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
						.font(.system(size: 32))
						.foregroundColor(isMe ? .white : .blue)
				}
			}
			
			// Waveform visualization
			if duration > 0 {
				GeometryReader { geometry in
					ZStack(alignment: .leading) {
						// Background waveform
						WaveformView(
							isActive: false,
							progress: 1.0,
							width: geometry.size.width,
							height: 30
						)
						.opacity(0.3)
						
						// Active waveform (shows progress)
						WaveformView(
							isActive: true,
							progress: currentTime / duration,
							width: geometry.size.width,
							height: 30
						)
					}
				}
				.frame(height: 30)
			} else {
				// Loading waveform
				WaveformView(
					isActive: false,
					progress: 0.5,
					width: 200,
					height: 30
				)
				.opacity(0.3)
				.frame(width: 200, height: 30)
			}
			
			// Duration display
			Text(formatTime(isPlaying ? currentTime : duration))
				.font(.system(size: 13, weight: .medium, design: .monospaced))
				.foregroundColor(isMe ? .white.opacity(0.9) : .primary)
				.frame(minWidth: 45, alignment: .trailing)
			
			if isMe {
				// Play/Pause button for sent messages (on right)
				Button(action: togglePlayback) {
					Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
						.font(.system(size: 32))
						.foregroundColor(.white)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.frame(minWidth: 150, maxWidth: 250)
		.onAppear {
			loadAudio()
		}
		.onDisappear {
			player.stop()
		}
		.onReceive(player.$isPlaying) { playing in
			isPlaying = playing
		}
		.onReceive(player.$currentTime) { time in
			currentTime = time
		}
		.onReceive(player.$duration) { dur in
			duration = dur
		}
	}
	
	private func loadAudio() {
		Task {
			await player.loadAudio(url: audioURL)
		}
	}
	
	private func togglePlayback() {
		if isPlaying {
			player.pause()
		} else {
			player.play()
		}
	}
	
	private func formatTime(_ time: TimeInterval) -> String {
		let minutes = Int(time) / 60
		let seconds = Int(time) % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}

// MARK: - Waveform View
struct WaveformView: View {
	let isActive: Bool
	let progress: Double
	let width: CGFloat
	let height: CGFloat
	
	var body: some View {
		HStack(spacing: 2) {
			ForEach(0..<Int(width / 5), id: \.self) { index in
				let normalizedIndex = Double(index) / Double(Int(width / 5))
				let isInProgress = normalizedIndex <= progress
				
				RoundedRectangle(cornerRadius: 1.5)
					.fill(isActive && isInProgress ? Color.blue : Color.gray)
					.frame(width: 3, height: waveformHeight(for: index))
			}
		}
		.frame(width: width, height: height)
		.clipped()
	}
	
	private func waveformHeight(for index: Int) -> CGFloat {
		// Generate static waveform pattern based on index
		let baseHeight: CGFloat = 4
		let maxHeight: CGFloat = height - 4
		
		// Use sine wave with different frequencies for natural look
		let phase = Double(index) * 0.3
		let amplitude = (sin(phase) + sin(phase * 1.5) * 0.5) / 1.5
		let normalized = (amplitude + 1) / 2 // Normalize to 0...1
		
		return baseHeight + normalized * (maxHeight - baseHeight)
	}
}

// MARK: - Audio Player Manager
@MainActor
class AudioPlayerManager: NSObject, ObservableObject {
	@Published var isPlaying = false
	@Published var currentTime: TimeInterval = 0
	@Published var duration: TimeInterval = 0
	
	private var audioPlayer: AVAudioPlayer?
	private var timer: Timer?
	
	func loadAudio(url: URL) async {
		do {
			let (data, _) = try await URLSession.shared.data(from: url)
			audioPlayer = try AVAudioPlayer(data: data)
			audioPlayer?.delegate = self
			audioPlayer?.prepareToPlay()
			duration = audioPlayer?.duration ?? 0
		} catch {
			print("Error loading audio: \(error)")
		}
	}
	
	func play() {
		audioPlayer?.play()
		isPlaying = true
		startTimer()
	}
	
	func pause() {
		audioPlayer?.pause()
		isPlaying = false
		stopTimer()
	}
	
	func stop() {
		audioPlayer?.stop()
		audioPlayer?.currentTime = 0
		isPlaying = false
		currentTime = 0
		stopTimer()
	}
	
	private func startTimer() {
		timer?.invalidate()
		timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
			guard let self = self else { return }
			Task { @MainActor in
				let currentTime = self.audioPlayer?.currentTime ?? 0
				let duration = self.duration
				self.currentTime = currentTime
				if currentTime >= duration {
					self.stop()
				}
			}
		}
	}
	
	private func stopTimer() {
		timer?.invalidate()
		timer = nil
	}
}

extension AudioPlayerManager: AVAudioPlayerDelegate {
	nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		Task { @MainActor in
			stop()
		}
	}
	
	nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
		Task { @MainActor in
			stop()
			print("Audio playback error: \(error?.localizedDescription ?? "Unknown")")
		}
	}
}

