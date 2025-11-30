import Foundation
import FirebaseStorage

extension StorageReference {
	func putDataAsync(_ data: Data, metadata: StorageMetadata? = nil) async throws -> StorageMetadata {
		return try await withCheckedThrowingContinuation { continuation in
			self.putData(data, metadata: metadata) { metadata, error in
				if let error = error {
					continuation.resume(throwing: error)
				} else if let metadata = metadata {
					continuation.resume(returning: metadata)
				} else {
					continuation.resume(throwing: NSError(domain: "Storage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
				}
			}
		}
	}
	
	/// Upload file from URL without loading entire file into memory (memory efficient)
	func putFileAsync(from fileURL: URL, metadata: StorageMetadata? = nil) async throws -> StorageMetadata {
		return try await withCheckedThrowingContinuation { continuation in
			self.putFile(from: fileURL, metadata: metadata) { metadata, error in
				if let error = error {
					continuation.resume(throwing: error)
				} else if let metadata = metadata {
					continuation.resume(returning: metadata)
				} else {
					continuation.resume(throwing: NSError(domain: "Storage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
				}
			}
		}
	}
	
	func downloadURL() async throws -> URL {
		return try await withCheckedThrowingContinuation { continuation in
			self.downloadURL { url, error in
				if let error = error {
					continuation.resume(throwing: error)
				} else if let url = url {
					continuation.resume(returning: url)
				} else {
					continuation.resume(throwing: NSError(domain: "Storage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
				}
			}
		}
	}
}

