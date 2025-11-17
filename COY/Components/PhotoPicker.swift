import SwiftUI
import UIKit
import AVFoundation

struct PhotoPicker: UIViewControllerRepresentable {
	@Binding var selectedImage: UIImage?
	var mediaTypes: [String] = ["public.image"] // Default to images only
	@Binding var selectedVideo: URL?
	var allowsEditing: Bool = true // Enable cropping by default
	
	init(selectedImage: Binding<UIImage?>, mediaTypes: [String] = ["public.image"], selectedVideo: Binding<URL?>? = nil, allowsEditing: Bool = true) {
		self._selectedImage = selectedImage
		self.mediaTypes = mediaTypes
		self.allowsEditing = allowsEditing
		if let selectedVideo = selectedVideo {
			self._selectedVideo = selectedVideo
		} else {
			self._selectedVideo = .constant(nil)
		}
	}
	
	func makeUIViewController(context: Context) -> UIImagePickerController {
		let picker = UIImagePickerController()
		picker.delegate = context.coordinator
		picker.allowsEditing = allowsEditing
		picker.mediaTypes = mediaTypes
		picker.sourceType = .photoLibrary
		return picker
	}
	
	func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		return Coordinator(self)
	}
	
	class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
		let parent: PhotoPicker
		
		init(_ parent: PhotoPicker) {
			self.parent = parent
		}
		
		func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
			if let mediaType = info[.mediaType] as? String, mediaType == "public.movie" {
				if let videoURL = info[.mediaURL] as? URL {
					let asset = AVURLAsset(url: videoURL)
					Task {
						do {
							let duration = try await asset.load(.duration)
							let durationSeconds = CMTimeGetSeconds(duration)
							await MainActor.run {
								if durationSeconds > 120.0 {
									let alert = UIAlertController(
										title: "Video Too Long",
										message: "Please select a video that is 2:00 or shorter.",
										preferredStyle: .alert
									)
									alert.addAction(UIAlertAction(title: "OK", style: .default))
									picker.present(alert, animated: true)
								} else {
									parent.selectedVideo = videoURL
									parent.selectedImage = nil
									picker.dismiss(animated: true)
								}
							}
						} catch {
							await MainActor.run { picker.dismiss(animated: true) }
						}
					}
					return
				}
			} else {
				if let editedImage = info[.editedImage] as? UIImage {
					parent.selectedImage = editedImage
					parent.selectedVideo = nil
					picker.dismiss(animated: true)
				} else if let originalImage = info[.originalImage] as? UIImage {
					parent.selectedImage = originalImage
					parent.selectedVideo = nil
					picker.dismiss(animated: true)
				}
			}
		}
		
		func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
			picker.dismiss(animated: true)
		}
	}
}

