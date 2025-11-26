import SwiftUI
import PhotosUI
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth

struct EditCollectionView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	
	@State private var collection: CollectionData
	var onSave: (() -> Void)? = nil
	
	@State private var showImagePicker = false
	@State private var profileImage: UIImage?
	@State private var name = ""
	@State private var description = ""
	@State private var isPublic = true
	@State private var isLoading = false
	@State private var errorMessage: String?
	@State private var showErrorAlert = false
	
	init(collection: CollectionData, onSave: (() -> Void)? = nil) {
		_collection = State(initialValue: collection)
		self.onSave = onSave
	}
	
	var body: some View {
		PhoneSizeContainer {
			ZStack {
				(colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea()
			VStack(spacing: 0) {
				// Header
				HStack {
					Button(action: {
						dismiss()
					}) {
						Image(systemName: "chevron.left")
							.font(.title2)
							.foregroundColor(colorScheme == .dark ? .white : .black)
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					}
					Spacer()
					Text("Edit Collection")
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
					Button(action: {
						Task {
							await saveCollection()
						}
					}) {
						Text("Done")
							.fontWeight(.semibold)
							.foregroundColor(isLoading ? .gray : .blue)
					}
					.disabled(isLoading)
					.frame(minWidth: 50, minHeight: 44)
					.contentShape(Rectangle())
				}
				.padding(.horizontal)
				.padding(.top, 20)
				.background(colorScheme == .dark ? Color.black : Color.white)
				.zIndex(1)
				
				ScrollView {
					VStack(spacing: 24) {
						// Profile Image Section
						VStack(spacing: 12) {
							// Show selected image first, then collection image, then default
							if let image = profileImage {
								Image(uiImage: image)
									.resizable()
									.aspectRatio(contentMode: .fill)
									.frame(width: 120, height: 120)
									.clipShape(Circle())
									.overlay(
										Circle()
											.stroke(Color.gray.opacity(0.3), lineWidth: 1)
									)
							} else {
								// Always show collection image if it exists, not default
								if let imageURL = collection.imageURL, !imageURL.isEmpty {
									CachedProfileImageView(url: imageURL, size: 120)
										.clipShape(Circle())
										.overlay(
											Circle()
												.stroke(Color.gray.opacity(0.3), lineWidth: 1)
										)
								} else {
									// Only show default if collection has no image
									DefaultProfileImageView(size: 120)
										.overlay(
											Circle()
												.stroke(Color.gray.opacity(0.3), lineWidth: 1)
										)
								}
							}
							
							Button(action: {
								showImagePicker = true
							}) {
								Text("Change Profile Image")
									.font(.subheadline)
									.foregroundColor(.blue)
							}
						}
						.padding(.top, 20)
						
						// Collection Name
						VStack(alignment: .leading, spacing: 8) {
							Text("Collection Name")
								.font(.subheadline)
								.foregroundColor(.secondary)
							TextField("Collection Name", text: $name)
								.textFieldStyle(.plain)
								.padding()
								.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
								.cornerRadius(8)
						}
						.padding(.horizontal)
						
						// Description
						VStack(alignment: .leading, spacing: 8) {
							Text("Description")
								.font(.subheadline)
								.foregroundColor(.secondary)
							TextEditor(text: $description)
								.frame(minHeight: 100)
								.padding(8)
								.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
								.cornerRadius(8)
								.overlay(
									RoundedRectangle(cornerRadius: 8)
										.stroke(Color.gray.opacity(0.2), lineWidth: 1)
								)
						}
						.padding(.horizontal)
						
						// Collection Type (Read-only)
						VStack(alignment: .leading, spacing: 8) {
							Text("Collection Type")
								.font(.subheadline)
								.foregroundColor(.secondary)
							HStack {
								Text(collection.type)
									.foregroundColor(.primary)
								Spacer()
								Image(systemName: "lock.fill")
									.foregroundColor(.gray)
									.font(.caption)
							}
							.padding()
							.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
							.cornerRadius(8)
							.opacity(0.6)
						}
						.padding(.horizontal)
						
						// Privacy Setting (only if not Request type)
						if collection.type != "Request" {
							VStack(alignment: .leading, spacing: 8) {
								Text("Privacy")
									.font(.subheadline)
									.foregroundColor(.secondary)
								Toggle(isOn: $isPublic) {
									Text(isPublic ? "Public" : "Private")
										.foregroundColor(.primary)
								}
								.padding()
								.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
								.cornerRadius(8)
							}
							.padding(.horizontal)
						} else {
							// Request collections must be public (read-only)
							VStack(alignment: .leading, spacing: 8) {
								Text("Privacy")
									.font(.subheadline)
									.foregroundColor(.secondary)
								HStack {
									Text("Public")
										.foregroundColor(.primary)
									Spacer()
									Image(systemName: "lock.fill")
										.foregroundColor(.gray)
										.font(.caption)
								}
								.padding()
								.background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
								.cornerRadius(8)
								.opacity(0.6)
							}
							.padding(.horizontal)
						}
					}
					.padding(.bottom, 40)
				}
			}
		}
		.onAppear {
			loadCollectionData()
		}
		.sheet(isPresented: $showImagePicker) {
			EditCollectionImagePicker(image: $profileImage)
				.presentationCompactAdaptation(.none)
		}
			}
		.alert("Error", isPresented: $showErrorAlert) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(errorMessage ?? "An error occurred")
		}
	}
	
	private func loadCollectionData() {
		Task {
			// Reload collection to get latest data including imageURL
			do {
				if let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) {
					await MainActor.run {
						// Update the collection with latest data
						collection = updatedCollection
						// Load form fields from updated collection
						name = collection.name
						description = collection.description
						isPublic = collection.isPublic
					}
				}
			} catch {
				// If reload fails, use existing collection data
				await MainActor.run {
					name = collection.name
					description = collection.description
					isPublic = collection.isPublic
				}
			}
		}
	}
	
	private func saveCollection() async {
		isLoading = true
		defer { isLoading = false }
		
		do {
			let db = Firestore.firestore()
			let collectionRef = db.collection("collections").document(collection.id)
			
			// Store old image URL before updating
			let oldImageURL = collection.imageURL
			
			var updateData: [String: Any] = [
				"name": name,
				"description": description,
				"isPublic": isPublic
			]
			
			var newImageURL: String? = nil
			
			// Upload profile image if changed
			if let image = profileImage {
				newImageURL = try await uploadProfileImage(image)
				updateData["imageURL"] = newImageURL
			}
			
			// Use setData with merge instead of updateData to handle cases where document doesn't exist
			// This will create the document if it doesn't exist, or update it if it does
			try await collectionRef.setData(updateData, merge: true)
			
			// Clear old image cache if image changed
			if let oldURL = oldImageURL, !oldURL.isEmpty, oldURL != newImageURL {
				ImageCache.shared.removeImage(for: oldURL)
				print("🗑️ Removed old collection image from cache: \(oldURL)")
			}
			
			// Pre-cache new image if changed
			if let image = profileImage, let imageURL = newImageURL, !imageURL.isEmpty {
				ImageCache.shared.setImage(image, for: imageURL)
				print("💾 Pre-cached new collection image: \(imageURL)")
			}
			
			// Reload collection data to verify update
			print("🔍 Verifying collection update was saved...")
			if let updatedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id) {
				print("✅ Verified update - Name: \(updatedCollection.name), Image URL: \(updatedCollection.imageURL ?? "nil")")
				
				// Post notifications to update all views
				await MainActor.run {
					// Post CollectionUpdated notification
					NotificationCenter.default.post(
						name: NSNotification.Name("CollectionUpdated"),
						object: collection.id,
						userInfo: ["collection": updatedCollection]
					)
					
					// Post CollectionImageUpdated notification if image changed
					if oldImageURL != newImageURL {
						NotificationCenter.default.post(
							name: NSNotification.Name("CollectionImageUpdated"),
							object: collection.id
						)
						print("📢 Posted CollectionImageUpdated notification")
					}
					
					print("📢 Posted CollectionUpdated notification")
				}
			}
			
			// Wait a moment for notifications to propagate
			try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
			
			await MainActor.run {
				dismiss()
				onSave?()
			}
		} catch {
			await MainActor.run {
				errorMessage = error.localizedDescription
				showErrorAlert = true
			}
		}
	}
	
	private func uploadProfileImage(_ image: UIImage) async throws -> String {
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			throw NSError(domain: "EditCollectionView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
		}
		
		let storage = Storage.storage()
		let storageRef = storage.reference()
		let imageRef = storageRef.child("collections/\(collection.id)/profile.jpg")
		
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		_ = try await imageRef.putDataAsync(imageData, metadata: metadata)
		let downloadURL = try await imageRef.downloadURL()
		
		return downloadURL.absoluteString
	}
}

// MARK: - Image Picker (renamed to avoid conflict with CYEditCollectionView)
struct EditCollectionImagePicker: UIViewControllerRepresentable {
	@Binding var image: UIImage?
	@Environment(\.dismiss) var dismiss
	
	func makeUIViewController(context: Context) -> UIImagePickerController {
		let picker = UIImagePickerController()
		picker.delegate = context.coordinator
		picker.sourceType = .photoLibrary
		picker.allowsEditing = true
		return picker
	}
	
	func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}
	
	class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
		let parent: EditCollectionImagePicker
		
		init(_ parent: EditCollectionImagePicker) {
			self.parent = parent
		}
		
		func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
			if let editedImage = info[.editedImage] as? UIImage {
				parent.image = editedImage
			} else if let originalImage = info[.originalImage] as? UIImage {
				parent.image = originalImage
			}
			parent.dismiss()
		}
		
		func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
			parent.dismiss()
		}
	}
}

