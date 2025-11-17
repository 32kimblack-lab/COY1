import UIKit

class ImageCache {
	static let shared = ImageCache()
	private var cache: [String: UIImage] = [:]
	
	private init() {}
	
	func setImage(_ image: UIImage, for key: String) {
		cache[key] = image
	}
	
	func getImage(for key: String) -> UIImage? {
		return cache[key]
	}
	
	func removeImage(for key: String) {
		cache.removeValue(forKey: key)
	}
	
	func clear() {
		cache.removeAll()
	}
}

