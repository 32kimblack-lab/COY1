import Foundation
import UIKit

// Local MediaItem for create post (before upload to Firebase)
struct CreatePostMediaItem: Identifiable {
	let id = UUID()
	var image: UIImage?
	var videoURL: URL?
	var videoDuration: Double?
	var videoThumbnail: UIImage?
}

