import Foundation
import AVKit
import Combine

// MARK: - Video Player Manager
@MainActor
class VideoPlayerManager: ObservableObject {
	static let shared = VideoPlayerManager()
	
	@Published var activePlayerId: String?
	private var players: [String: AVPlayer] = [:]
	private var timeObservers: [String: Any] = [:]
	private var elapsedTimePublishers: [String: CurrentValueSubject<Double, Never>] = [:]
	
	private init() {}
	
	// MARK: - Player Management
	func getOrCreatePlayer(for videoURL: String, postId: String) -> AVPlayer {
		let playerId = "\(postId)_\(videoURL)"
		
		if let existingPlayer = players[playerId] {
			return existingPlayer
		}
		
		guard let url = URL(string: videoURL) else {
			return AVPlayer()
		}
		
		let player = AVPlayer(url: url)
		players[playerId] = player
		
		// Set up elapsed time tracking
		let elapsedTimeSubject = CurrentValueSubject<Double, Never>(0.0)
		elapsedTimePublishers[playerId] = elapsedTimeSubject
		
		// Observe time updates
		let timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)), queue: .main) { [weak self] time in
			let elapsed = time.seconds
			elapsedTimeSubject.send(elapsed)
		}
		timeObservers[playerId] = timeObserver
		
		return player
	}
	
	func playVideo(playerId: String) {
		// Pause currently active player
		if let activeId = activePlayerId, activeId != playerId {
			pauseVideo(playerId: activeId)
		}
		
		// Find player by ID
		if let player = findPlayer(by: playerId) {
			player.play()
			activePlayerId = playerId
		}
	}
	
	func pauseVideo(playerId: String) {
		if let player = findPlayer(by: playerId) {
			player.pause()
			if activePlayerId == playerId {
				activePlayerId = nil
			}
		}
	}
	
	func getElapsedTime(for playerId: String) -> Double {
		return elapsedTimePublishers[playerId]?.value ?? 0.0
	}
	
	func getElapsedTimePublisher(for playerId: String) -> AnyPublisher<Double, Never>? {
		return elapsedTimePublishers[playerId]?.eraseToAnyPublisher()
	}
	
	func observeElapsedTime(for playerId: String, callback: @escaping (Double) -> Void) -> AnyCancellable? {
		if let publisher = elapsedTimePublishers[playerId] {
			return publisher.sink { time in
				callback(time)
			}
		}
		return nil
	}
	
	private func findPlayer(by playerId: String) -> AVPlayer? {
		// Try direct lookup first
		if let player = players[playerId] {
			return player
		}
		
		// Try to find by matching postId or videoURL
		for (id, player) in players {
			if id.contains(playerId) {
				return player
			}
		}
		
		return nil
	}
	
	func cleanupPlayer(playerId: String) {
		if let observer = timeObservers[playerId] {
			if let player = findPlayer(by: playerId) {
				player.removeTimeObserver(observer)
			}
			timeObservers.removeValue(forKey: playerId)
		}
		
		players.removeValue(forKey: playerId)
		elapsedTimePublishers.removeValue(forKey: playerId)
		
		if activePlayerId == playerId {
			activePlayerId = nil
		}
	}
	
	func pauseAll() {
		for (playerId, _) in players {
			pauseVideo(playerId: playerId)
		}
	}
}

