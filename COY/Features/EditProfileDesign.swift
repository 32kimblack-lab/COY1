import SwiftUI
import PhotosUI
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth

// Cache for profile images
class EditProfileCache {
	static let shared = EditProfileCache()
	var profileImage: UIImage?
	var backgroundImage: UIImage?
	var name: String = ""
	var username: String = ""
	var userData: [String: Any]?
	var lastLoadedUserId: String?
	
	func clear() {
		profileImage = nil
		backgroundImage = nil
		name = ""
		username = ""
		userData = nil
		lastLoadedUserId = nil
	}
}

struct EditProfileDesign: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	var onSave: (() -> Void)? = nil
	@State private var showProfilePicker = false
	@State private var showBackgroundPicker = false
	@State private var profileImage: UIImage?
	@State private var backgroundImage: UIImage?
	@State private var name = ""
	@State private var username = ""
	@State private var website = ""
	@State private var about = ""
	@State private var pronouns = ""
	@State private var userData: [String: Any]?
	@State private var isLoading = false
	@State private var errorMessage: String?
	@State private var showErrorAlert = false
	@State private var originalUsername = ""
	@State private var originalName = ""
	@State private var usernameError = ""
	@State private var isCheckingUsername = false
	
	// UserService for backend sync
	private let userService = UserService.shared
	
	var body: some View {
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
					Text("Edit Profile")
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
					Button(action: {
						print("Done button tapped")
						Task {
							await saveProfile()
						}
					}) {
						Text("Done")
							.fontWeight(.semibold)
							.foregroundColor((isLoading || !usernameError.isEmpty || isCheckingUsername) ? .gray : .blue)
					}
					.disabled(isLoading || !usernameError.isEmpty || isCheckingUsername)
					.frame(minWidth: 50, minHeight: 44)
					.contentShape(Rectangle())
				}
				.padding(.horizontal)
				.padding(.top, 20)
				.background(colorScheme == .dark ? Color.black : Color.white)
				.zIndex(1)
				
				// Background + Profile
				ZStack(alignment: .topLeading) {
					// Background Image - Fixed height of 105
					ZStack(alignment: .bottomTrailing) {
						if let image = backgroundImage {
							Image(uiImage: image)
								.resizable()
								.aspectRatio(contentMode: .fill)
								.frame(height: 105)
								.frame(maxWidth: .infinity)
								.clipped()
						} else {
							// No background image - show nothing (transparent)
							Color.clear
								.frame(height: 105)
								.frame(maxWidth: .infinity)
						}
						
						Button("Edit background") {
							showBackgroundPicker = true
						}
						.font(.caption)
						.foregroundColor(.black)
						.padding(.horizontal, 12)
						.padding(.vertical, 4)
						.background(Color(white: 0.8))
						.cornerRadius(8)
						.padding(8)
					}
					
					// Profile Image - Half on background, half below (centered at bottom edge)
					// Background height is 105, profile image is 70, so center at 105 (half of image = 35 above, 35 below)
					ZStack {
						if let image = profileImage {
							Image(uiImage: image)
								.resizable()
								.aspectRatio(contentMode: .fill)
								.frame(width: 70, height: 70)
								.clipShape(Circle())
						} else {
							// Default profile icon - white, not translucent
							Image(systemName: "person.crop.circle.fill")
								.resizable()
								.scaledToFill()
								.frame(width: 70, height: 70)
								.foregroundColor(.white)
						}
						
						// Edit Profile Image Button overlay
						Button(action: {
							showProfilePicker = true
						}) {
							Circle()
								.fill(Color.black.opacity(0.6))
								.frame(width: 24, height: 24)
								.overlay(
									Image(systemName: "camera.fill")
										.font(.system(size: 10))
										.foregroundColor(.white)
								)
						}
						.offset(x: 25, y: 25)
					}
					.offset(y: 105 - 35) // Center at bottom edge of background (105) - half image height (35) = 70
					.frame(maxWidth: .infinity, alignment: .center)
				}
				.frame(height: 105 + 35 + 8) // Background (105) + half profile image (35) + spacing (8)
				.padding(.top, 24)
				.padding(.bottom, 16)
				
				// Form fields
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						Text("You can only change your name and username. Birthday and email cannot be edited.")
							.font(.subheadline)
							.foregroundColor(.gray)
							.multilineTextAlignment(.center)
							.padding(.horizontal)
							.padding(.bottom, 8)
						Group {
							field(title: "Name", placeholder: "Enter your name", text: $name)
							usernameFieldWithValidation(title: "Username", placeholder: "Enter your username", text: $username)
							field(title: "Birthday", placeholder: formatBirthday(), text: .constant(""), editable: false)
							field(title: "Email", placeholder: userData?["email"] as? String ?? "example@email.com", text: .constant(""), editable: false)
						}
					}
					.padding(.horizontal)
					.padding(.bottom, 40)
				}
			}
		}
		.sheet(isPresented: $showProfilePicker) {
			PhotoPicker(selectedImage: $profileImage)
		}
		.sheet(isPresented: $showBackgroundPicker) {
			PhotoPicker(selectedImage: $backgroundImage)
		}
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .tabBar)
		.alert("Error", isPresented: $showErrorAlert) {
			Button("OK") { }
		} message: {
			Text(errorMessage ?? "An error occurred")
		}
		.overlay {
			if isLoading {
				ZStack {
					Color.black.opacity(0.4)
						.ignoresSafeArea()
					VStack(spacing: 16) {
						ProgressView()
							.scaleEffect(1.5)
							.tint(.white)
						Text("Uploading images...")
							.font(.headline)
							.foregroundColor(.white)
						Text("Please wait")
							.font(.subheadline)
							.foregroundColor(.white.opacity(0.8))
					}
					.padding(30)
					.background(
						RoundedRectangle(cornerRadius: 16)
							.fill(Color.black.opacity(0.8))
					)
				}
			}
		}
		.onAppear {
			loadUserData()
		}
	}
	
	// MARK: - Reusable Input Field
	private func field(title: String, placeholder: String, text: Binding<String>, editable: Bool = true) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.subheadline)
				.foregroundColor(.gray)
			TextField(placeholder, text: text)
				.disabled(!editable)
				.padding()
				.background(Color.gray.opacity(0.1))
				.cornerRadius(10)
		}
	}
	
	// MARK: - Username Field with Validation
	private func usernameFieldWithValidation(title: String, placeholder: String, text: Binding<String>) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.subheadline)
				.foregroundColor(.gray)
			TextField(placeholder, text: text)
				.padding()
				.background(Color.gray.opacity(0.1))
				.cornerRadius(10)
				.onChange(of: text.wrappedValue) { _, newValue in
					// Filter out emojis
					let filtered = newValue.filter { !$0.isEmoji }
					if filtered != newValue {
						text.wrappedValue = filtered
						return
					}
					
					// Validate username in real-time
					validateUsername(newValue)
				}
			
			// Show error message
			if !usernameError.isEmpty {
				Text(usernameError)
					.foregroundColor(.red)
					.font(.caption)
					.padding(.horizontal, 5)
			}
			
			// Show loading indicator
			if isCheckingUsername {
				HStack {
					ProgressView()
						.scaleEffect(0.8)
					Text("Checking availability...")
						.font(.caption)
						.foregroundColor(.gray)
				}
				.padding(.horizontal, 5)
			}
		}
	}
	
	// MARK: - Username Validation
	private func validateUsername(_ username: String) {
		let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		
		// Clear error immediately
		usernameError = ""
		
		if trimmedUsername.isEmpty {
			return
		}
		
		// Basic format validation (like AuthViewModel)
		if trimmedUsername.count > 30 {
			usernameError = "Username must be 30 characters or less"
			return
		}
		
		let allowedCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
		if trimmedUsername.rangeOfCharacter(from: allowedCharacterSet.inverted) != nil {
			usernameError = "Username cannot contain emojis or symbols"
			return
		}
		
		// If username hasn't changed, no need to check availability
		if trimmedUsername == originalUsername.lowercased() {
			return
		}
		
		// Check availability asynchronously
		Task {
			await MainActor.run {
				isCheckingUsername = true
			}
			
			do {
				let userService = UserService.shared
				let isAvailable = try await userService.isUsernameAvailable(trimmedUsername)
				
				await MainActor.run {
					isCheckingUsername = false
					if !isAvailable {
						usernameError = "This username is already registered."
					}
				}
			} catch {
				await MainActor.run {
					isCheckingUsername = false
					print("Error checking username: \(error)")
					// Don't show error for network issues, just continue
				}
			}
		}
	}
	
	private func loadUserData() {
		guard let user = authService.user else { return }
		
		// Load from Firebase (source of truth) - not backend
		print("🔄 EditProfile: Loading fresh data from Firebase (source of truth)")
		
		// Clear caches to force fresh load
		UserService.shared.clearUserCache(userId: user.uid)
		
		Task {
			do {
				// Get user data from Firebase (source of truth)
				let firebaseUser = try await userService.getUser(userId: user.uid)
				guard let firebaseUser = firebaseUser else {
					print("❌ EditProfile: User not found in Firebase")
					return
				}
				
				print("✅ EditProfile: Got user from Firebase - Name: \(firebaseUser.name), Username: \(firebaseUser.username)")
				print("   - Profile URL: \(firebaseUser.profileImageURL ?? "nil")")
				print("   - Background URL: \(firebaseUser.backgroundImageURL ?? "nil")")
				
				// Extract URLs from Firebase (source of truth)
				let profileImageURL = firebaseUser.profileImageURL
				let backgroundImageURL = firebaseUser.backgroundImageURL
				
				// Get additional data from Firestore (birthday, email, etc.)
				let db = Firestore.firestore()
				let document = try await db.collection("users").document(user.uid).getDocument()
				let firestoreData = document.data() ?? [:]
				
				// Load both images in parallel
				async let profileImageTask: UIImage? = loadImageAsync(from: profileImageURL)
				async let backgroundImageTask: UIImage? = loadImageAsync(from: backgroundImageURL)
				
				let (loadedProfileImage, loadedBackgroundImage) = await (profileImageTask, backgroundImageTask)
				
				// Combine Firebase data
				var combinedData = firestoreData
				combinedData["name"] = firebaseUser.name
				combinedData["username"] = firebaseUser.username
				combinedData["profileImageURL"] = profileImageURL ?? ""
				combinedData["backgroundImageURL"] = backgroundImageURL ?? ""
				
				// Update cache with fresh data
				let cache = EditProfileCache.shared
				cache.userData = combinedData
				cache.name = firebaseUser.name
				cache.username = firebaseUser.username
				cache.profileImage = loadedProfileImage
				cache.backgroundImage = loadedBackgroundImage
				cache.lastLoadedUserId = user.uid
				
				// Update UI
				await MainActor.run {
					self.userData = combinedData
					self.name = firebaseUser.name
					self.username = firebaseUser.username
					self.originalName = firebaseUser.name
					self.originalUsername = firebaseUser.username
					self.profileImage = loadedProfileImage
					self.backgroundImage = loadedBackgroundImage
					print("✅ EditProfile: Data loaded and cached from Firebase")
					print("   - Loaded profile image: \(loadedProfileImage != nil ? "yes" : "no")")
					print("   - Loaded background image: \(loadedBackgroundImage != nil ? "yes" : "no")")
				}
			} catch {
				print("❌ EditProfile: Error loading user data: \(error)")
			}
		}
	}
	
	private func loadImageAsync(from urlString: String?) async -> UIImage? {
		guard let urlString = urlString,
			  !urlString.isEmpty,
			  let url = URL(string: urlString) else {
			return nil
		}
		
		do {
			let (data, _) = try await URLSession.shared.data(from: url)
			return UIImage(data: data)
		} catch {
			print("❌ Failed to load image from \(urlString): \(error)")
			return nil
		}
	}
	
	private func loadImage(from urlString: String, completion: @escaping (UIImage?) -> Void) {
		guard let url = URL(string: urlString) else {
			completion(nil)
			return
		}
		
		URLSession.shared.dataTask(with: url) { data, response, error in
			guard let data = data, error == nil else {
				completion(nil)
				return
			}
			
			DispatchQueue.main.async {
				completion(UIImage(data: data))
			}
		}.resume()
	}
	
	// MARK: - Save Profile Function
	private func saveProfile() async {
		isLoading = true
		errorMessage = nil
		
		// Check if there are validation errors
		if !usernameError.isEmpty {
			await MainActor.run {
				self.errorMessage = usernameError
				self.showErrorAlert = true
				self.isLoading = false
			}
			return
		}
		
		// Capture values for upload
		guard let user = authService.user else {
			await MainActor.run {
				self.errorMessage = "User not authenticated"
				self.showErrorAlert = true
				self.isLoading = false
			}
			return
		}
		
		let nameToSave = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
		let usernameToSave = self.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let profileImageToSave = self.profileImage
		let backgroundImageToSave = self.backgroundImage
		
		// Validate inputs
		guard !nameToSave.isEmpty, !usernameToSave.isEmpty else {
			await MainActor.run {
				self.errorMessage = "Name and username cannot be empty"
				self.showErrorAlert = true
				self.isLoading = false
			}
			return
		}
		
		do {
			// Save to Firebase FIRST (source of truth), then sync to backend
			print("🔄 Saving profile to Firebase (source of truth)...")
			
			// Clear UserService cache BEFORE update to ensure fresh data
			UserService.shared.clearUserCache(userId: user.uid)
			
			// Use UserService to update profile (saves to Firebase, then syncs to backend)
			let updatedUser = try await userService.updateUserProfile(
				userId: user.uid,
				name: nameToSave,
				username: usernameToSave,
				profileImage: profileImageToSave,
				backgroundImage: backgroundImageToSave
			)
			print("✅ User profile saved to Firebase and synced to backend")
			
			// Get the URLs returned from backend
			let profileImageURL = updatedUser.profileImageURL
			let backgroundImageURL = updatedUser.backgroundImageURL
			
			// Clear ALL caches to ensure fresh data
			UserService.shared.clearUserCache(userId: user.uid)
			EditProfileCache.shared.clear()
			
			// Remove old images from ImageCache
			let cache = EditProfileCache.shared
			if let oldProfileURL = cache.userData?["profileImageURL"] as? String, !oldProfileURL.isEmpty {
				ImageCache.shared.removeImage(for: oldProfileURL)
				print("🗑️ Removed old profile image from cache: \(oldProfileURL)")
			}
			if let oldBackgroundURL = cache.userData?["backgroundImageURL"] as? String, !oldBackgroundURL.isEmpty {
				ImageCache.shared.removeImage(for: oldBackgroundURL)
				print("🗑️ Removed old background image from cache: \(oldBackgroundURL)")
			}
			
			// Pre-cache the NEW images with their URLs so they load instantly
			if let profileImage = profileImageToSave, let profileImageURL = profileImageURL, !profileImageURL.isEmpty {
				ImageCache.shared.setImage(profileImage, for: profileImageURL)
				print("💾 Pre-cached new profile image: \(profileImageURL)")
			}
			if let backgroundImage = backgroundImageToSave, let backgroundImageURL = backgroundImageURL, !backgroundImageURL.isEmpty {
				ImageCache.shared.setImage(backgroundImage, for: backgroundImageURL)
				print("💾 Pre-cached new background image: \(backgroundImageURL)")
			}
			
			// CRITICAL: Force reload CYServiceManager with fresh data from backend
			// This ensures currentUser is updated with the latest URLs
			print("🔄 Reloading CYServiceManager with fresh data...")
			try await CYServiceManager.shared.loadCurrentUser()
			
			// Verify the update was saved by fetching fresh data from backend again
			print("🔍 Verifying update was saved...")
			let verifiedUser = try await UserService.shared.getUser(userId: user.uid)
			guard let verifiedUser = verifiedUser else {
				throw NSError(domain: "ProfileUpdateError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to verify profile update"])
			}
			
			print("✅ Verified update - Profile URL: \(verifiedUser.profileImageURL ?? "nil"), Background URL: \(verifiedUser.backgroundImageURL ?? "nil")")
			
			// Prepare notification data with verified URLs from backend
			var immediateUpdateData: [String: Any] = [
				"name": verifiedUser.name,
				"username": verifiedUser.username
			]
			
			// Use verified URLs from backend (these are the actual saved URLs)
			if let profileImageURL = verifiedUser.profileImageURL, !profileImageURL.isEmpty {
				immediateUpdateData["profileImageURL"] = profileImageURL
			}
			if let backgroundImageURL = verifiedUser.backgroundImageURL, !backgroundImageURL.isEmpty {
				immediateUpdateData["backgroundImageURL"] = backgroundImageURL
			}
			
			// Post notification with verified data
			await MainActor.run {
				NotificationCenter.default.post(
					name: NSNotification.Name("ProfileUpdated"),
					object: nil,
					userInfo: ["updatedData": immediateUpdateData]
				)
				print("📢 Posted profile update notification with verified URLs from backend")
				print("   - Name: \(immediateUpdateData["name"] as? String ?? "nil")")
				print("   - Username: \(immediateUpdateData["username"] as? String ?? "nil")")
				print("   - Profile URL: \(immediateUpdateData["profileImageURL"] as? String ?? "nil")")
				print("   - Background URL: \(immediateUpdateData["backgroundImageURL"] as? String ?? "nil")")
			}
			
			// Wait a moment for notification to propagate
			try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
			
			// Dismiss - everything is now complete
			await MainActor.run {
				self.isLoading = false
				self.dismiss()
				print("✅ Dismissed - all updates complete and verified")
			}
			
		} catch {
			await MainActor.run {
				// Better error handling
				var errorMsg = "Failed to save profile: \(error.localizedDescription)"
				if let apiError = error as? APIError {
					switch apiError {
					case .httpError(let statusCode, let message):
						if statusCode == 404 {
							errorMsg = "User account not found. Please try signing out and back in, or contact support."
						} else {
							errorMsg = "Failed to save profile: \(message)"
						}
					default:
						errorMsg = "Failed to save profile: \(error.localizedDescription)"
					}
				}
				self.errorMessage = errorMsg
				self.showErrorAlert = true
				self.isLoading = false
			}
			return
		}
	}
	
	// MARK: - Format Birthday
	private func formatBirthday() -> String {
		// Try to get birthday from userData (from Firestore)
		if let userData = userData,
		   let birthMonth = userData["birthMonth"] as? String,
		   let birthDay = userData["birthDay"] as? String,
		   let birthYear = userData["birthYear"] as? String,
		   !birthMonth.isEmpty, !birthDay.isEmpty, !birthYear.isEmpty {
			return "\(birthMonth) \(birthDay), \(birthYear)"
		}
		// Fallback: try to get from combined userData if available
		if let userData = userData, let birthday = userData["birthday"] as? String, !birthday.isEmpty {
			return birthday
		}
		// Last resort: return empty string instead of placeholder
		return ""
	}
	
	// MARK: - Upload Image Function
	private func uploadImage(_ image: UIImage, path: String) async throws -> String {
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			throw NSError(domain: "ImageConversionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
		}
		
		let storage = Storage.storage()
		let storageRef = storage.reference().child(path)
		
		let metadata = StorageMetadata()
		metadata.contentType = "image/jpeg"
		
		let _ = try await storageRef.putDataAsync(imageData, metadata: metadata)
		let downloadURL = try await storageRef.downloadURL()
		
		return downloadURL.absoluteString
	}
}

// MARK: - Character Extension for Emoji Detection
extension Character {
	var isEmoji: Bool {
		guard let scalar = unicodeScalars.first else { return false }
		return scalar.properties.isEmoji && (scalar.value > 0x238C || unicodeScalars.count > 1)
	}
}

