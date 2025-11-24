import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseCore
import Combine

@MainActor
class AuthService: ObservableObject {
	@Published var user: FirebaseAuth.User?
	@Published var isLoading = true  // Start as true to show loading while checking auth
	@Published var errorMessage: String?
	@Published var isProfileSetupComplete = false
	@Published var isInSignUpFlow = false  // Track if user is currently in sign-up flow
	
	private var authStateHandle: AuthStateDidChangeListenerHandle?
	private var _db: Firestore?
	
	// Safe Firebase Auth access - only returns if Firebase is configured
	private var firebaseAuth: Auth? {
		guard FirebaseApp.app() != nil else {
			return nil
		}
		return Auth.auth()
	}
	
	// Lazy Firestore access - only initializes if Firebase is configured
	private var db: Firestore? {
		if let existing = _db {
			return existing
		}
		// Check if Firebase is configured before accessing Firestore
		guard FirebaseApp.app() != nil else {
			print(" ERROR: Firebase is not configured. Firestore operations will fail.")
			print(" Please add GoogleService-Info.plist to your project.")
			return nil
		}
		let firestore = Firestore.firestore()
		_db = firestore
		return firestore
	}
	
	init() {
		// Only setup auth listener if Firebase is configured
		if FirebaseApp.app() != nil {
			setupAuthStateListener()
		} else {
			print(" Firebase not configured - AuthService will not work properly")
			isLoading = false
		}
	}
	
	// Backend sync removed - using Firebase only
	
	deinit {
		// Check Firebase directly in deinit (not main actor isolated)
		if let handle = authStateHandle, FirebaseApp.app() != nil {
			Auth.auth().removeStateDidChangeListener(handle)
		}
	}
	
	private func setupAuthStateListener() {
		// Check if Firebase Auth is available
		guard let auth = firebaseAuth else {
			print("⚠️ Firebase not configured - cannot setup auth state listener")
			return
		}
		authStateHandle = auth.addStateDidChangeListener { [weak self] _, user in
			self?.user = user
			// Check if user has completed profile setup
			if let user = user {
				Task {
					await PushNotificationManager.shared.syncTokenForCurrentUser()
				}
				Task {
					await self?.checkProfileSetupStatus(user: user)
					await MainActor.run {
						self?.isLoading = false
					}
				}
			} else {
				self?.isProfileSetupComplete = false
				self?.isLoading = false
			}
		}
	}
	
	// Backend sync removed - using Firebase only
	
	func checkProfileSetupStatus(user: FirebaseAuth.User) async {
		guard let db = self.db else {
			print("⚠️ Firestore not available - cannot check profile setup status")
			await MainActor.run {
				self.isProfileSetupComplete = false
				self.isLoading = false
			}
			return
		}
		do {
			let data = try await Task.detached {
				let document = try await db.collection("users").document(user.uid).getDocument()
				return document.data()
			}.value
			
			await MainActor.run {
				// Check if user has completed the full profile setup
				if let data = data,
				   let name = data["name"] as? String,
				   let username = data["username"] as? String,
				   !name.isEmpty,
				   !username.isEmpty {
					// User has complete profile data, they're good to go
					self.isProfileSetupComplete = true
					// If profile is complete, clear sign-up flow flag (user might have exited app during invite screen)
					self.isInSignUpFlow = false
				} else {
					// User doesn't have complete profile data
					self.isProfileSetupComplete = false
					
					// Check if there's pending sign-up data, profile save in progress, or if user is in sign-up flow
					let hasPendingEmailSignup = UserDefaults.standard.dictionary(forKey: "pendingSignupData") != nil
					let hasPendingPhoneSignup = UserDefaults.standard.dictionary(forKey: "pendingPhoneSignupData") != nil
					let isProfileSaveInProgress = UserDefaults.standard.bool(forKey: "profileSaveInProgress")
					let inSignUpFlow = self.isInSignUpFlow // Check if user is actively in sign-up flow (e.g., on invite screen)
					
					// Also check if account was just created (within last 5 minutes) - give it time to save profile
					let accountCreationTime = user.metadata.creationDate
					let timeSinceCreation = accountCreationTime.map { Date().timeIntervalSince($0) } ?? 0
					let isRecentlyCreated = timeSinceCreation < 300.0 // Account created within last 5 minutes (increased from 30 seconds)
					
					// CRITICAL: Only delete accounts if:
					// 1. Account is very new (less than 5 minutes old)
					// 2. No pending sign-up data
					// 3. Not in sign-up flow
					// 4. Profile save is not in progress
					// This prevents deleting legitimate users who just have Firestore permission issues
					if isRecentlyCreated && !hasPendingEmailSignup && !hasPendingPhoneSignup && !isProfileSaveInProgress && !inSignUpFlow {
						// Very new account with no profile data and no sign-up in progress
						// This means user exited before completing profile during initial signup
						print("⚠️ Incomplete sign-up detected - user authenticated but profile incomplete (account age: \(String(format: "%.1f", timeSinceCreation))s)")
						print("🧹 Signing out and cleaning up incomplete sign-up...")
						
						Task { @MainActor [weak self] in
							guard let self = self else { return }
							do {
								// Delete the Firebase Auth account
								try await user.delete()
								print("✅ Deleted incomplete Firebase Auth account")
							} catch {
								print("⚠️ Could not delete auth account: \(error)")
								// Still sign out even if deletion fails
							}
							
							// Sign out
							if let auth = self.firebaseAuth {
								try? auth.signOut()
							}
							self.user = nil
							self.isProfileSetupComplete = false
							print("✅ Signed out incomplete user - they can now start over")
						}
					} else {
						// Account is older than 5 minutes OR has pending data OR is in sign-up flow
						// Don't delete - this is likely a legitimate user or a permissions issue
						if !isRecentlyCreated {
							print("📝 Account is older than 5 minutes - treating as legitimate user (may have Firestore permission issues)")
						} else if inSignUpFlow {
							print("📝 User is in sign-up flow - allowing completion")
						} else if isProfileSaveInProgress {
							print("📝 Profile save in progress - allowing completion")
						} else {
							print("📝 User has pending sign-up data - allowing profile completion")
						}
					}
				}
			}
		} catch {
			// If Firestore query fails (e.g., permissions error), don't delete the account
			// This is likely a configuration issue, not a user issue
			let errorDomain = (error as NSError).domain
			
			await MainActor.run {
				// Check if it's a permissions error
				if errorDomain == "FIRFirestoreErrorDomain" || error.localizedDescription.contains("permission") || error.localizedDescription.contains("Permission") {
					print("⚠️ Firestore permissions error - cannot check profile. Allowing user to stay logged in.")
					print("⚠️ Error: \(error.localizedDescription)")
					// Don't delete account - this is a configuration issue
					// Assume profile might be complete but we just can't verify it
					self.isProfileSetupComplete = true // Allow access, user can complete profile if needed
					self.isInSignUpFlow = false
				} else {
					// Other errors - be conservative, don't delete account
					print("⚠️ Error checking profile setup: \(error.localizedDescription)")
					self.isProfileSetupComplete = false
				}
			}
		}
	}
	
	// MARK: - Email Authentication
	
	func signInWithEmail(email: String, password: String) async -> Bool {
		guard let auth = firebaseAuth else {
			errorMessage = "Firebase is not configured. Please add GoogleService-Info.plist to your project."
			isLoading = false
			return false
		}
		isLoading = true
		errorMessage = nil
		
		do {
			let result = try await auth.signIn(withEmail: email, password: password)
			user = result.user
			
			// Sync to backend
			isLoading = false
			return true
		} catch {
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	func signUpWithEmail(email: String, password: String, name: String, username: String, birthday: String) async -> Bool {
		guard let auth = firebaseAuth else {
			errorMessage = "Firebase is not configured. Please add GoogleService-Info.plist to your project."
			isLoading = false
			return false
		}
		isLoading = true
		errorMessage = nil
		
		do {
			let result = try await auth.createUser(withEmail: email, password: password)
			let user = result.user
			
			// Create user document in Firestore
			if let db = self.db {
				let userData: [String: Any] = [
					"uid": user.uid,
					"email": email,
					"name": name,
					"username": username,
					"birthday": birthday,
					"createdAt": Timestamp(date: Date()),
					"profileImageURL": "",
					"backgroundImageURL": ""
				]
				
				_ = try await Task.detached {
					try await db.collection("users").document(user.uid).setData(userData)
				}.value
			} else {
				print("⚠️ Firestore not available - user document not created in Firestore")
				// Continue anyway - backend will have the user data
			}
			
			self.user = user
			isLoading = false
			return true
		} catch {
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	// MARK: - Phone Authentication
	
	func sendPhoneVerification(phoneNumber: String) async -> Bool {
		guard firebaseAuth != nil else {
			errorMessage = "Firebase is not configured. Please add GoogleService-Info.plist to your project."
			isLoading = false
			return false
		}
		isLoading = true
		errorMessage = nil
		
		do {
			let verificationID = try await PhoneAuthProvider.provider().verifyPhoneNumber(phoneNumber, uiDelegate: nil)
			UserDefaults.standard.set(verificationID, forKey: "authVerificationID")
			isLoading = false
			return true
		} catch {
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	func verifyPhoneCode(code: String) async -> Bool {
		isLoading = true
		errorMessage = nil
		
		guard let verificationID = UserDefaults.standard.string(forKey: "authVerificationID") else {
			errorMessage = "Verification ID not found"
			isLoading = false
			return false
		}
		
		guard let auth = firebaseAuth else {
			errorMessage = "Firebase is not configured. Please add GoogleService-Info.plist to your project."
			isLoading = false
			return false
		}
		do {
			let credential = PhoneAuthProvider.provider().credential(withVerificationID: verificationID, verificationCode: code)
			let result = try await auth.signIn(with: credential)
			user = result.user
			
			// Sync to backend
			isLoading = false
			return true
		} catch {
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	func signUpWithPhone(phoneNumber: String, name: String, username: String, birthday: String) async -> Bool {
		isLoading = true
		errorMessage = nil
		
		do {
			// Get current user (should exist after phone verification)
			guard let auth = firebaseAuth, let currentUser = auth.currentUser else {
				errorMessage = "No authenticated user found"
				isLoading = false
				return false
			}
			
			// Create user document in Firestore
			guard let db = self.db else {
				print("⚠️ Firestore not available - user document not created in Firestore")
				isLoading = false
				return true // Continue anyway - backend will have the user data
			}
			
			let userData: [String: Any] = [
				"phoneNumber": phoneNumber,
				"name": name,
				"username": username,
				"birthday": birthday,
				"createdAt": Timestamp(date: Date()),
				"profileImageURL": "",
				"backgroundImageURL": ""
			]
			
			_ = try await Task.detached {
				try await db.collection("users").document(currentUser.uid).setData(userData)
			}.value
			isLoading = false
			return true
		} catch {
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	// MARK: - Password Reset
	
	func sendPasswordReset(email: String) async -> Bool {
		guard let auth = firebaseAuth else {
			errorMessage = "Firebase is not configured. Please add GoogleService-Info.plist to your project."
			isLoading = false
			return false
		}
		print("🔄 Sending password reset email to: \(email)")
		isLoading = true
		errorMessage = nil
		
		do {
			// Use Firebase default handler without custom settings
			// This uses Firebase's hosted page and sends email immediately
			print("📧 Calling Firebase sendPasswordReset (default handler)")
			try await auth.sendPasswordReset(withEmail: email)
			print("✅ Password reset email sent successfully")
			isLoading = false
			return true
		} catch {
			print("❌ Password reset email FAILED: \(error.localizedDescription)")
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	// MARK: - Profile Management
	
	func updateProfileImage(image: UIImage) async -> Bool {
		guard let user = user else { return false }
		
		isLoading = true
		errorMessage = nil
		
		do {
			// Upload image to Firebase Storage
			let imageURL = try await uploadImage(image: image, path: "profile_images/\(user.uid).jpg")
			
			// Update user document
			guard let db = self.db else {
				print("⚠️ Firestore not available - profile image not updated in Firestore")
				isLoading = false
				return false
			}
			_ = try await Task.detached {
				try await db.collection("users").document(user.uid).updateData([
					"profileImageURL": imageURL
				])
			}.value
			
			isLoading = false
			return true
		} catch {
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	func updateBackgroundImage(image: UIImage) async -> Bool {
		guard let user = user else { return false }
		
		isLoading = true
		errorMessage = nil
		
		do {
			// Upload image to Firebase Storage
			let imageURL = try await uploadImage(image: image, path: "background_images/\(user.uid).jpg")
			
			// Update user document
			guard let db = self.db else {
				print("⚠️ Firestore not available - background image not updated in Firestore")
				isLoading = false
				return false
			}
			_ = try await Task.detached {
				try await db.collection("users").document(user.uid).updateData([
					"backgroundImageURL": imageURL
				])
			}.value
			
			isLoading = false
			return true
		} catch {
			errorMessage = error.localizedDescription
			isLoading = false
			return false
		}
	}
	
	private func uploadImage(image: UIImage, path: String) async throws -> String {
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			throw NSError(domain: "ImageError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
		}
		
		let storageRef = Storage.storage().reference().child(path)
		let _ = try await storageRef.putDataAsync(imageData)
		let downloadURL = try await storageRef.downloadURL()
		
		return downloadURL.absoluteString
	}
	
	// MARK: - Sign Out
	
	func signOut() {
		guard let auth = firebaseAuth else {
			print("⚠️ Firebase not configured - cannot sign out")
			user = nil
			isProfileSetupComplete = false
			return
		}
		do {
			if let userId = user?.uid {
				Task {
					await PushNotificationManager.shared.removeToken(for: userId)
				}
			}
			try auth.signOut()
			user = nil
			isProfileSetupComplete = false
		} catch {
			errorMessage = error.localizedDescription
		}
	}
	
	func markProfileSetupComplete() {
		isProfileSetupComplete = true
		// Don't auto-clear sign-up flow flag - let user explicitly skip or exit app
		// The flag will be cleared when user clicks Skip or when app relaunches (in checkProfileSetupStatus)
	}
	
	func setInSignUpFlow(_ inFlow: Bool) {
		isInSignUpFlow = inFlow
	}
	
	// MARK: - User Data
	
	func getUserData() async -> [String: Any]? {
		guard let user = user else { return nil }
		guard let db = self.db else {
			print("⚠️ Firestore not available - cannot get user data")
			return nil
		}
		
		do {
			let data = try await Task.detached {
				let document = try await db.collection("users").document(user.uid).getDocument()
				return document.data()
			}.value
			return await MainActor.run { data }
		} catch {
			await MainActor.run {
				errorMessage = error.localizedDescription
			}
			return nil
		}
	}
}

#if DEBUG
extension AuthService {
	// Backend sync removed - using Firebase only
}
#endif
