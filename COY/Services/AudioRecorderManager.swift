import Foundation
import AVFoundation
import Combine

@MainActor
class AudioRecorderManager: NSObject, ObservableObject {
	static let shared = AudioRecorderManager()
	
	@Published var isRecording = false
	@Published var recordingDuration: TimeInterval = 0
	@Published var recordingURL: URL?
	@Published var error: Error?
	
	private var audioRecorder: AVAudioRecorder?
	private var recordingTimer: Timer?
	private var audioSession: AVAudioSession = AVAudioSession.sharedInstance()
	
	private override init() {
		super.init()
		setupAudioSession()
	}
	
	private func setupAudioSession() {
		do {
			try audioSession.setCategory(.playAndRecord, mode: .default)
			try audioSession.setActive(true)
		} catch {
			print("Failed to setup audio session: \(error)")
		}
	}
	
	func startRecording() async throws {
		// Stop any existing recording
		if isRecording {
			stopRecording()
		}
		
		// Request microphone permission
		let permissionGranted = await requestMicrophonePermission()
		guard permissionGranted else {
			throw AudioRecorderError.permissionDenied
		}
		
		// Create recording URL
		let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let audioFilename = documentsPath.appendingPathComponent("voice_recording_\(UUID().uuidString).m4a")
		
		// Setup audio recorder settings
		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
			AVSampleRateKey: 44100.0,
			AVNumberOfChannelsKey: 1,
			AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
		]
		
		// Create recorder
		audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
		audioRecorder?.delegate = self
		audioRecorder?.prepareToRecord()
		
		// Start recording
		let success = audioRecorder?.record() ?? false
		guard success else {
			throw AudioRecorderError.recordingFailed
		}
		
		isRecording = true
		recordingDuration = 0
		recordingURL = audioFilename
		error = nil
		
		// Start timer to update duration
		recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
			guard let self = self else { return }
			Task { @MainActor in
				self.recordingDuration = self.audioRecorder?.currentTime ?? 0
			}
		}
	}
	
	func stopRecording() {
		audioRecorder?.stop()
		recordingTimer?.invalidate()
		recordingTimer = nil
		isRecording = false
	}
	
	func cancelRecording() {
		stopRecording()
		
		// Delete the recording file
		if let url = recordingURL {
			try? FileManager.default.removeItem(at: url)
		}
		
		recordingURL = nil
		recordingDuration = 0
	}
	
	private func requestMicrophonePermission() async -> Bool {
		if #available(iOS 17.0, *) {
			switch await AVAudioApplication.shared.recordPermission {
			case .granted:
				return true
			case .denied:
				return false
			case .undetermined:
				return await AVAudioApplication.requestRecordPermission()
			@unknown default:
				return false
			}
		} else {
			switch AVAudioSession.sharedInstance().recordPermission {
			case .granted:
				return true
			case .denied:
				return false
			case .undetermined:
				return await withCheckedContinuation { continuation in
					AVAudioSession.sharedInstance().requestRecordPermission { granted in
						continuation.resume(returning: granted)
					}
				}
			@unknown default:
				return false
			}
		}
	}
	
	func formattedDuration(_ duration: TimeInterval) -> String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorderManager: AVAudioRecorderDelegate {
	nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		Task { @MainActor in
			if !flag {
				error = AudioRecorderError.recordingFailed
				cancelRecording()
			}
		}
	}
	
	nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
		Task { @MainActor in
			self.error = error ?? AudioRecorderError.unknown
			stopRecording()
		}
	}
}

enum AudioRecorderError: LocalizedError {
	case permissionDenied
	case recordingFailed
	case unknown
	
	var errorDescription: String? {
		switch self {
		case .permissionDenied:
			return "Microphone permission is required to record voice messages"
		case .recordingFailed:
			return "Failed to record audio"
		case .unknown:
			return "An unknown error occurred"
		}
	}
}

