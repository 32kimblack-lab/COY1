import Foundation
import AVKit
@preconcurrency import Combine

@MainActor
class VideoPlayerManager: ObservableObject {
	static let shared = VideoPlayerManager()
	
	// Legacy single active id (kept for compatibility)
	@Published var activePlayerId: String?
	// Set of active playerIds (we expect Grid manager to restrict to 2)
	@Published var activePlayerIds: Set<String> = []
	
	// Players keyed by playerId (stable format "<postId>_<videoURL>")
	private var players: [String: AVPlayer] = [:]
	
	// Periodic time observers keyed by playerId (need to remove when cleaning up)
	private var timeObservers: [String: Any] = [:]
	
	// Elapsed time publishers (CurrentValueSubject) per playerId
	private var elapsedTimePublishers: [String: CurrentValueSubject<Double, Never>] = [:]
	
	// End-of-play observers per playerId (NotificationCenter tokens)
	private var endTimeObservers: [String: NSObjectProtocol] = [:]
	
	private init() {}
	
	// MARK: - Player creation / lookup
	/// Returns an AVPlayer for the given url and stable playerId; reuses existing if present
	func player(for url: String, id: String) -> AVPlayer {
		if let existing = players[id] {
			// If player exists but its currentItem is different, ensure looping target is updated
			setupVideoLooping(for: existing, playerId: id)
			ensureElapsedPublisherExists(for: id, player: existing)
			return existing
		}
		
		guard let videoURL = URL(string: url) else {
			let empty = AVPlayer()
			players[id] = empty
			ensureElapsedPublisherExists(for: id, player: empty)
			return empty
		}
		
		let playerItem = AVPlayerItem(url: videoURL)
		let player = AVPlayer(playerItem: playerItem)
		player.isMuted = true
		players[id] = player
		
		// Ensure looping and time observers
		setupVideoLooping(for: player, playerId: id)
		ensureElapsedPublisherExists(for: id, player: player)
		
		return player
	}
	
	/// Return player for playerId if it exists
	func findPlayer(by playerId: String) -> AVPlayer? {
		return players[playerId]
	}
	
	// MARK: - Playback controls
	func playVideo(playerId: String) {
		// If >2 players active, pause oldest (but GridVideoPlaybackManager already enforces top-2)
		if activePlayerIds.count >= 2 && !activePlayerIds.contains(playerId) {
			if let oldest = activePlayerIds.first {
				pauseVideo(playerId: oldest)
			}
		}
		
		guard let player = players[playerId] else {
			return
		}
		
		// Ensure muted for autoplay
		player.isMuted = true
		
		// Attempt to play
		player.play()
		
		// Register as active
		activePlayerIds.insert(playerId)
		activePlayerId = playerId
	}
	
	func pauseVideo(playerId: String) {
		guard let player = players[playerId] else { return }
		player.pause()
		player.isMuted = true
		
		// Remove active tracking
		activePlayerIds.remove(playerId)
		if activePlayerId == playerId {
			activePlayerId = activePlayerIds.first
		}
	}
	
	func pauseAll() {
		for (playerId, _) in players {
			pauseVideo(playerId: playerId)
		}
		activePlayerIds.removeAll()
		activePlayerId = nil
	}
	
	// MARK: - Elapsed time / publishers
	private func ensureElapsedPublisherExists(for playerId: String, player: AVPlayer) {
		if elapsedTimePublishers[playerId] != nil { return }
		
		let subject = CurrentValueSubject<Double, Never>(0.0)
		elapsedTimePublishers[playerId] = subject
		
		// Add periodic time observer at 0.1s intervals on main queue
		let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
		let timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
			subject.send(time.seconds)
		}
		timeObservers[playerId] = timeObserver
	}
	
	func getElapsedTime(for playerId: String) -> Double {
		return elapsedTimePublishers[playerId]?.value ?? 0.0
	}
	
	func getElapsedTimePublisher(for playerId: String) -> AnyPublisher<Double, Never>? {
		return elapsedTimePublishers[playerId]?.eraseToAnyPublisher()
	}
	
	func observeElapsedTime(for playerId: String, callback: @escaping (Double) -> Void) -> AnyCancellable? {
		if let publisher = elapsedTimePublishers[playerId] {
			return publisher.sink { time in callback(time) }
		}
		return nil
	}
	
	// MARK: - Looping and cleanup
	private func setupVideoLooping(for player: AVPlayer, playerId: String) {
		// Remove previous end-time observer for this playerId (if any)
		if let token = endTimeObservers[playerId] {
			NotificationCenter.default.removeObserver(token)
			endTimeObservers.removeValue(forKey: playerId)
		}
		
		guard let item = player.currentItem else {
			// If no current item yet, try to observe when it becomes available by adding a boundary
			return
		}
		
		// Ensure player does not pause at end automatically
		player.actionAtItemEnd = .none
		
		// Add observer: when item ends, seek to zero and play
		let token = NotificationCenter.default.addObserver(
			forName: .AVPlayerItemDidPlayToEndTime,
			object: item,
			queue: .main
		) { [weak self] notification in
			guard let self = self else { return }
			// Confirm the item matches currentItem
			guard let finishedItem = notification.object as? AVPlayerItem, finishedItem == player.currentItem else { return }
			player.seek(to: .zero) { _ in
				// restart
				player.play()
				// Reset elapsed time publisher if present
				Task { @MainActor in
					self.elapsedTimePublishers[playerId]?.send(0.0)
				}
			}
		}
		
		endTimeObservers[playerId] = token
	}
	
	func cleanupPlayer(playerId: String) {
		// Remove time observer
		if let obs = timeObservers[playerId], let player = players[playerId] {
			player.removeTimeObserver(obs)
			timeObservers.removeValue(forKey: playerId)
		}
		
		// Remove end observer
		if let token = endTimeObservers[playerId] {
			NotificationCenter.default.removeObserver(token)
			endTimeObservers.removeValue(forKey: playerId)
		}
		
		// Remove elapsed publisher
		elapsedTimePublishers.removeValue(forKey: playerId)
		
		// Pause and remove player
		if let player = players[playerId] {
			player.pause()
			// Optionally set actionAtItemEnd default
			player.actionAtItemEnd = .pause
		}
		players.removeValue(forKey: playerId)
		
		// Remove from active sets
		activePlayerIds.remove(playerId)
		if activePlayerId == playerId {
			activePlayerId = activePlayerIds.first
		}
	}
	
	// Legacy method for backward compatibility
	func getOrCreatePlayer(for videoURL: String, postId: String) -> AVPlayer {
		let playerId = "\(postId)_\(videoURL)"
		return player(for: videoURL, id: playerId)
	}
}
