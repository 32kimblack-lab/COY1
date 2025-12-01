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
	
	// Maximum number of players to keep in memory
	private let maxPlayers = 20
	
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
	/// CRITICAL: Uses video caching to prevent repeated downloads (67.6GB for 18MB stored)
	func player(for url: String, id: String) -> AVPlayer {
		if let existing = players[id] {
			// If player exists but its currentItem is different, ensure looping target is updated
			setupVideoLooping(for: existing, playerId: id)
			ensureElapsedPublisherExists(for: id, player: existing)
			return existing
		}
		
		// Clean up old players if we're at the limit (keep active players)
		// Defer to avoid publishing changes during view updates
		if players.count >= maxPlayers {
			Task { @MainActor in
				cleanupInactivePlayers()
			}
		}
		
		guard let videoURL = URL(string: url) else {
			// Don't create empty player - return nil would be better but we need AVPlayer
			// Create a player but mark it as invalid
			let empty = AVPlayer()
			players[id] = empty
			ensureElapsedPublisherExists(for: id, player: empty)
			return empty
		}
		
		// CRITICAL FIX: Check for cached video first, then download if needed
		// This prevents the 67.6GB bandwidth issue by caching videos locally
		let cacheKey = VideoCacheManager.shared.generateCacheKeySync(from: url)
		let cachedFileURL = VideoCacheManager.shared.getCacheDirectory().appendingPathComponent(cacheKey)
		
		// Use cached file if it exists and is valid, otherwise use remote URL
		// Cache download will happen in background for next time
		let finalURL: URL
		if FileManager.default.fileExists(atPath: cachedFileURL.path) {
			// Use cached file - this prevents re-downloading!
			finalURL = cachedFileURL
			// Start background download to refresh cache if needed
			Task { @MainActor in
				_ = await VideoCacheManager.shared.getCachedVideoURL(for: url)
			}
		} else {
			// Not cached yet - use remote URL and start caching in background
			finalURL = videoURL
			// Start caching in background for next time
			Task { @MainActor in
				_ = await VideoCacheManager.shared.getCachedVideoURL(for: url)
			}
		}
		
		let playerItem = AVPlayerItem(url: finalURL)
		let player = AVPlayer(playerItem: playerItem)
		player.isMuted = true
		player.automaticallyWaitsToMinimizeStalling = false // Faster playback start
		players[id] = player
		
		// Observe player item status to handle loading/errors
		observePlayerItemStatus(playerItem: playerItem, playerId: id, player: player)
		
		// Ensure looping and time observers
		setupVideoLooping(for: player, playerId: id)
		ensureElapsedPublisherExists(for: id, player: player)
		
		return player
	}
	
	// Clean up inactive players when we hit the limit
	private func cleanupInactivePlayers() {
		// Keep active players and remove oldest inactive ones
		let inactivePlayers = players.keys.filter { !activePlayerIds.contains($0) }
		
		// Remove oldest inactive players (keep at least 10 for quick access)
		if inactivePlayers.count > 10 {
			let toRemove = inactivePlayers.prefix(inactivePlayers.count - 10)
			// Defer cleanup to avoid publishing changes during view updates
			Task { @MainActor in
				for playerId in toRemove {
					cleanupPlayer(playerId: playerId)
				}
			}
		}
	}
	
	// Track player item status observers
	private var statusObservers: [String: NSKeyValueObservation] = [:]
	
	private func observePlayerItemStatus(playerItem: AVPlayerItem, playerId: String, player: AVPlayer) {
		// Remove existing observer if any
		statusObservers[playerId]?.invalidate()
		
		// Observe status changes - KVO observer runs on background thread
		// Capture playerId to avoid capturing self
		let capturedPlayerId = playerId
		let observer = playerItem.observe(\.status, options: [.new]) { item, _ in
			Task { @MainActor in
				// Access shared instance on MainActor to avoid capturing self
				let manager = VideoPlayerManager.shared
				
				// Get the actual player instance from manager
				guard let actualPlayer = manager.findPlayer(by: capturedPlayerId) else {
					return
				}
				
				switch item.status {
				case .readyToPlay:
					// Video is ready - if it's supposed to be active, play it immediately
					if manager.activePlayerIds.contains(capturedPlayerId) {
						// Video is in active set and ready - play it
						actualPlayer.isMuted = true
						if actualPlayer.rate == 0 {
							actualPlayer.play()
						}
					}
				case .failed:
					// Video failed to load - clean up
					// Remove from active players
					manager.activePlayerIds.remove(capturedPlayerId)
					if manager.activePlayerId == capturedPlayerId {
						manager.activePlayerId = manager.activePlayerIds.first
					}
				case .unknown:
					// Still loading
					break
				@unknown default:
					break
				}
			}
		}
		
		statusObservers[playerId] = observer
	}
	
	/// Return player for playerId if it exists
	func findPlayer(by playerId: String) -> AVPlayer? {
		return players[playerId]
	}
	
	// MARK: - Playback controls
	func playVideo(playerId: String) {
		// Early return if already playing to prevent duplicate calls
		if activePlayerIds.contains(playerId), let player = players[playerId], player.rate > 0 {
			return
		}
		
		// If >2 players active, pause oldest (but GridVideoPlaybackManager already enforces top-2)
		if activePlayerIds.count >= 2 && !activePlayerIds.contains(playerId) {
			if let oldest = activePlayerIds.first {
				pauseVideo(playerId: oldest)
			}
		}
		
		guard let player = players[playerId] else {
			return
		}
		
		// Add to active set first
		activePlayerIds.insert(playerId)
		activePlayerId = playerId
		player.isMuted = true
		
		// Check if player item is ready before playing
		if let playerItem = player.currentItem {
			// Only play if ready or unknown (will play when ready)
			if playerItem.status == .failed {
				// Don't try to play failed videos
				activePlayerIds.remove(playerId)
				return
			}
			
			// If ready, play immediately
			if playerItem.status == .readyToPlay {
				if player.rate == 0 {
					player.play()
				}
			}
			// Status is unknown - observer will play when ready (no logging to reduce noise)
		} else {
			// No player item - remove from active and return
			activePlayerIds.remove(playerId)
			return
		}
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
		
		// Remove status observer
		statusObservers[playerId]?.invalidate()
		statusObservers.removeValue(forKey: playerId)
		
		// Remove elapsed publisher
		elapsedTimePublishers.removeValue(forKey: playerId)
		
		// Pause and remove player
		if let player = players[playerId] {
			player.pause()
			player.replaceCurrentItem(with: nil) // Release player item
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
