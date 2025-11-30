import Foundation
import SwiftUI
import Combine
import AVFoundation

/// Manages video playback for grid views - ensures videos play when 70-80% visible
/// Videos automatically pause when scrolled out of frame and play when scrolled into frame
@MainActor
class GridVideoPlaybackManager: ObservableObject {
	static let shared = GridVideoPlaybackManager()
	
	// Store visibility info for all videos (keyed by playerId)
	struct VideoVisibility {
		let topY: CGFloat
		let frame: CGRect
		let visibility: Double // 0.0 to 1.0 (percentage visible)
	}
	
	private var videoVisibility: [String: VideoVisibility] = [:]
	
	// The video IDs currently playing (maximum of 2)
	@Published var activeVideoIDs: [String] = []
	
	// Visibility threshold: play videos when they're 70% or more visible
	private let visibilityThreshold: Double = 0.70
	
	private init() {}
	
	func updateVisibility(for id: String, topY: CGFloat) {
		// Legacy method - try to preserve existing visibility if available
		if let existing = videoVisibility[id] {
			videoVisibility[id] = VideoVisibility(
				topY: topY,
				frame: existing.frame,
				visibility: existing.visibility
			)
		}
	}
	
	/// Update video visibility using frame and computed visibility percentage
	func updateVideoVisibility(
		postId: String,
		videoURL: String,
		frame: CGRect,
		visibility: Double? = nil
	) {
		let playerId = "\(postId)_\(videoURL)"
		// Extract topY from frame (frame is in global coordinates)
		let topY = frame.minY
		
		// Calculate visibility if not provided
		let calculatedVisibility: Double
		if let providedVisibility = visibility {
			calculatedVisibility = providedVisibility
		} else {
			// Calculate visibility percentage from frame
			let screenHeight = UIScreen.main.bounds.height
			let safeAreaTop = UIApplication.shared.connectedScenes
				.compactMap { $0 as? UIWindowScene }
				.flatMap { $0.windows }
				.first { $0.isKeyWindow }?
				.safeAreaInsets.top ?? 0
			
			let safeAreaBottom = UIApplication.shared.connectedScenes
				.compactMap { $0 as? UIWindowScene }
				.flatMap { $0.windows }
				.first { $0.isKeyWindow }?
				.safeAreaInsets.bottom ?? 0
			
			let viewportTop = safeAreaTop
			let viewportBottom = screenHeight - safeAreaBottom
			
			let viewTop = frame.minY
			let viewBottom = frame.maxY
			let cardHeight = frame.height
			
			let visibleTop = max(viewportTop, viewTop)
			let visibleBottom = min(viewportBottom, viewBottom)
			let visibleHeight = max(0, visibleBottom - visibleTop)
			
			calculatedVisibility = cardHeight > 0 ? Double(visibleHeight / cardHeight) : 0.0
		}
		
		// Always track the visibility - let evaluatePlayback decide which ones to play
		videoVisibility[playerId] = VideoVisibility(
			topY: topY,
			frame: frame,
			visibility: calculatedVisibility
		)
		
		// Immediately evaluate playback when visibility updates
		evaluatePlayback()
	}
	
	func removeVideo(playerId: String) {
		videoVisibility.removeValue(forKey: playerId)
		// If this video was playing, pause it and remove from active list
		if let index = activeVideoIDs.firstIndex(of: playerId) {
			activeVideoIDs.remove(at: index)
			let manager = VideoPlayerManager.shared
			manager.pauseVideo(playerId: playerId)
		}
		// Re-evaluate playback after removal
		evaluatePlayback()
	}
	
	func clearAll() {
		let manager = VideoPlayerManager.shared
		// Pause all currently playing videos
		for id in activeVideoIDs {
			manager.pauseVideo(playerId: id)
		}
		videoVisibility.removeAll()
		activeVideoIDs = []
	}
	
	func evaluatePlayback() {
		// Filter videos that are at least 70% visible
		let eligibleVideos = videoVisibility
			.filter { (playerId, visibility) in
				visibility.visibility >= visibilityThreshold
			}
		
		// Maximum of 2 videos can play at once
		let maxPlayingVideos = 2
		
		// If no videos meet the 70% threshold, play the most visible one(s) up to max
		let videosToPlay: [String]
		if eligibleVideos.isEmpty {
			// No videos are 70%+ visible, so play the most visible one (up to max)
			let sortedAll = videoVisibility.sorted { first, second in
				// Sort by visibility (higher is better)
				if abs(first.value.visibility - second.value.visibility) > 0.01 {
					return first.value.visibility > second.value.visibility
				}
				// If visibility is similar, prefer the one higher on screen (lower topY)
				return first.value.topY < second.value.topY
			}
			videosToPlay = Array(sortedAll.prefix(maxPlayingVideos)).map { $0.key }
		} else {
			// Sort by visibility percentage (most visible first), then by position (topmost first)
			let sorted = eligibleVideos.sorted { first, second in
				// First sort by visibility (higher is better)
				if abs(first.value.visibility - second.value.visibility) > 0.01 {
					return first.value.visibility > second.value.visibility
				}
				// If visibility is similar, prefer the one higher on screen (lower topY)
				return first.value.topY < second.value.topY
			}
			
			// Only play the top 2 most visible videos (enforce limit)
			videosToPlay = Array(sorted.prefix(maxPlayingVideos)).map { $0.key }
		}
		
		// Update active videos if changed
		if videosToPlay != activeVideoIDs {
			activeVideoIDs = videosToPlay
			applyAutoplay(videosToPlay)
		}
	}
	
	private func applyAutoplay(_ ids: [String]) {
		let manager = VideoPlayerManager.shared
		
		// Pause all others
		for storedID in manager.activePlayerIds {
			if !ids.contains(storedID) {
				manager.pauseVideo(playerId: storedID)
			}
		}
		
		// Play only the top 2 most visible videos (enforced limit)
		for id in ids {
			if let videoURL = extractVideoURL(from: id) {
				_ = manager.player(for: videoURL, id: id)
				if let player = manager.findPlayer(by: id) {
					player.isMuted = true
				}
				manager.playVideo(playerId: id)
			}
		}
	}
	
	// Helper to extract videoURL from playerId format: "\(postId)_\(videoURL)"
	private func extractVideoURL(from playerId: String) -> String? {
		// PlayerId format is "postId_videoURL", so we need to extract the videoURL part
		// Find the first underscore and take everything after it
		if let underscoreIndex = playerId.firstIndex(of: "_") {
			let videoURL = String(playerId[playerId.index(after: underscoreIndex)...])
			return videoURL
		}
		return nil
	}
	
	// Legacy method for compatibility - converts to new system
	func forceVisibilityUpdate() {
		evaluatePlayback()
	}
}
