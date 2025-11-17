import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseCore
import Combine

@MainActor
class AuthViewModel: ObservableObject {
	static let shared = AuthViewModel()
	
	// MARK: - User Info
	@Published var email: String = ""
	@Published var name: String = ""
	@Published var username: String = ""
	@Published var birthMonth: String = "Month"
	@Published var birthDay: String = ""
	@Published var birthYear: String = ""
	@Published var password: String = ""
	@Published var confirmPassword: String = ""
	@Published var emailOrUsername: String = ""
	
	// MARK: - Images
	@Published var profileImage: UIImage?
	@Published var backgroundImage: UIImage?
	@Published var profileImageURL: String?
	@Published var backgroundImageURL: String?
	
	// MARK: - Errors
	@Published var errorMessage: String = ""
	@Published var emailError: String = ""
	@Published var usernameError: String = ""
	@Published var birthdayError: String = ""
	@Published var passwordError: String = ""
	
	// Inject AuthService
	var authService: AuthService?
	
	private func ensureFirebaseConfigured() {
		guard FirebaseApp.app() == nil else { return }
		// Look for any file whose name contains GoogleService-Info
		let plistPaths = Bundle.main.paths(forResourcesOfType: "plist", inDirectory: nil)
		if let matchedPath = plistPaths.first(where: { URL(fileURLWithPath: $0).lastPathComponent.contains("GoogleService-Info") }),
		   let options = FirebaseOptions(contentsOfFile: matchedPath) {
			FirebaseApp.configure(options: options)
			return
		}
		// Fallback
		FirebaseApp.configure()
	}
	
	// Lazily resolve Firestore to avoid accessing it before Firebase is configured
	private lazy var db: Firestore = {
		ensureFirebaseConfigured()
		return Firestore.firestore()
	}()
	
	private let validEmailDomains = ["gmail.com", "yahoo.com", "outlook.com", "aol.com", "mail.com", "icloud.com", "hotmail.com", "live.com"]
	private let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
	
	// MARK: - Check Email Exists
	private func checkEmailExists(_ email: String) async -> Bool {
		// Check in Firestore first
		do {
			let snapshot = try await db.collection("users")
				.whereField("email", isEqualTo: email.lowercased())
				.limit(to: 1)
				.getDocuments()
			
			if !snapshot.documents.isEmpty {
				print("✅ Email found in Firestore: \(email)")
				return true
			}
		} catch {
			print("❌ Error checking email in Firestore: \(error)")
		}
		
		// Note: fetchSignInMethods is deprecated. Email existence will be caught during registration.
		return false
	}
	
	// MARK: - Login
	func login() async throws {
		try validateLoginInputs(emailOrUsername: emailOrUsername, password: password)
		
		do {
			// Check if input is email or username
			if emailOrUsername.contains("@") {
				// It's an email, sign in directly
				try await Auth.auth().signIn(withEmail: emailOrUsername, password: password)
			} else {
				// It's a username, find the associated email first
				// Usernames are case-insensitive, so use lowercase
				let userService = UserService.shared
				
				// Try to get user by username
				do {
					guard let user = try await userService.getUserByUsername(emailOrUsername.lowercased()) else {
						throw AuthError.invalidCredentials("Email or password is incorrect")
					}
					
					// Check if user has an email (required for Firebase Auth)
					guard !user.email.isEmpty else {
						throw AuthError.invalidCredentials("User account has no email associated. Please contact support.")
					}
					
					// Sign in with the email associated with this username
					try await Auth.auth().signIn(withEmail: user.email, password: password)
				} catch {
					// If Firestore query fails (e.g., permissions), provide helpful error
					if let nsError = error as NSError?,
					   (nsError.domain == "FIRFirestoreErrorDomain" || 
						error.localizedDescription.contains("permission") ||
						error.localizedDescription.contains("Permission")) {
						print("⚠️ Firestore permissions error during username lookup: \(error.localizedDescription)")
						// Still throw generic error to user (don't expose internal errors)
						throw AuthError.invalidCredentials("Email or password is incorrect")
					} else {
						// Re-throw other errors (including AuthError)
						throw error
					}
				}
			}
		} catch {
			// Convert Firebase Auth errors to user-friendly messages
			if let nsError = error as NSError? {
				let errorCode = nsError.code
				// Firebase Auth error codes
				// 17008 = invalid-email, 17009 = wrong-password, 17011 = user-not-found
				if errorCode == 17008 || errorCode == 17009 || errorCode == 17011 || errorCode == 17010 {
					throw AuthError.invalidCredentials("Email or password is incorrect")
				} else if errorCode == 17020 {
					throw AuthError.invalidCredentials("Network error. Please check your connection.")
				} else {
					// For any other Firebase Auth error, show generic message
					throw AuthError.invalidCredentials("Email or password is incorrect")
				}
			} else {
				// If it's already an AuthError, rethrow it
				if let authError = error as? AuthError {
					throw authError
				}
				// Otherwise, convert to generic error
				throw AuthError.invalidCredentials("Email or password is incorrect")
			}
		}
	}
	
	private func validateLoginInputs(emailOrUsername: String, password: String) throws {
		guard !emailOrUsername.trimmingCharacters(in: .whitespaces).isEmpty else {
			throw AuthError.invalidCredentials("Email or username cannot be empty")
		}
		guard !password.trimmingCharacters(in: .whitespaces).isEmpty else {
			throw AuthError.invalidCredentials("Password cannot be empty")
		}
	}
	
	// MARK: - Validation Methods
	func validateEmail() {
		let email = self.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		
		if email.isEmpty {
			emailError = ""
			return
		}
		
		// Check basic email format
		guard email.contains("@") else {
			emailError = "Invalid email format"
			return
		}
		
		// Check domain
		guard let emailDomain = email.split(separator: "@").last else {
			emailError = "Invalid email format"
			return
		}
		
		let hasValidDomain = validEmailDomains.contains(String(emailDomain))
		if !hasValidDomain {
			emailError = "Email does not exist"
			return
		}
		
		// Email format is valid, now check if it's already registered
		Task {
			let isTaken = await checkEmailExists(email)
			await MainActor.run {
				if isTaken {
					emailError = "This email is already registered"
				} else {
					emailError = ""
				}
			}
		}
	}
	
	// Async version for when we need to wait for validation to complete
	func validateEmailAsync() async {
		let email = self.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Do format validation synchronously
		if email.isEmpty {
			await MainActor.run {
				emailError = ""
			}
			return
		}
		
		// Check basic email format
		guard email.contains("@") else {
			await MainActor.run {
				emailError = "Invalid email format"
			}
			return
		}
		
		// Check domain
		guard let emailDomain = email.split(separator: "@").last else {
			await MainActor.run {
				emailError = "Invalid email format"
			}
			return
		}
		
		let hasValidDomain = validEmailDomains.contains(String(emailDomain))
		if !hasValidDomain {
			await MainActor.run {
				emailError = "Email does not exist"
			}
			return
		}
		
		// Email format is valid, clear error temporarily while checking
		await MainActor.run {
			emailError = ""
		}
		
		// Check if it's already registered (this runs off main actor for async work)
		let isTaken = await checkEmailExists(email)
		
		// Update error on main actor
		await MainActor.run {
			if isTaken {
				emailError = "This email is already registered"
				print("✅ Set emailError: 'This email is already registered'")
			} else {
				emailError = ""
			}
		}
	}
	
	func validateUsername() {
		let username = self.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		
		if username.isEmpty {
			usernameError = ""
			return
		}
		
		// Check length
		if username.count > 30 {
			usernameError = "Username must be 30 characters or less"
			return
		}
		
		// Check for emojis and symbols
		let allowedCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
		if username.rangeOfCharacter(from: allowedCharacterSet.inverted) != nil {
			usernameError = "Username cannot contain emojis or symbols"
			return
		}
		
		// Username format is valid, now check if it's already taken
		Task {
			do {
				let userService = UserService.shared
				let isAvailable = try await userService.isUsernameAvailable(username)
				await MainActor.run {
					if !isAvailable {
						usernameError = "This username is already registered"
					} else {
						usernameError = ""
					}
				}
			} catch {
				await MainActor.run {
					print("Error checking username availability: \(error)")
					// Don't show error for network issues, just continue
				}
			}
		}
	}
	
	// Async version for when we need to wait for validation to complete
	func validateUsernameAsync() async {
		let username = self.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		
		// Do format validation synchronously
		if username.isEmpty {
			await MainActor.run {
				usernameError = ""
			}
			return
		}
		
		// Check length
		if username.count > 30 {
			await MainActor.run {
				usernameError = "Username must be 30 characters or less"
			}
			return
		}
		
		// Check for emojis and symbols
		let allowedCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
		if username.rangeOfCharacter(from: allowedCharacterSet.inverted) != nil {
			await MainActor.run {
				usernameError = "Username cannot contain emojis or symbols"
			}
			return
		}
		
		// Username format is valid, clear error temporarily while checking
		await MainActor.run {
			usernameError = ""
		}
		
		// Check if it's already taken (this runs off main actor for async work)
		do {
			let userService = UserService.shared
			print("🔍 Checking username availability for: '\(username)'")
			let isAvailable = try await userService.isUsernameAvailable(username)
			
			// Update error on main actor
			await MainActor.run {
				if !isAvailable {
					usernameError = "This username is already registered"
					print("✅✅✅ Set usernameError: '\(usernameError)' for username: '\(username)'")
				} else {
					usernameError = ""
					print("✅ Username is available: '\(username)'")
				}
			}
		} catch {
			await MainActor.run {
				print("⚠️ Error checking username availability: \(error)")
				// On error, we'll assume it's available to not block users due to network issues
				// But we could also show a different message
				usernameError = ""
			}
		}
	}
	
	func validateBirthday() {
		guard let birthYear = Int(self.birthYear),
			  let birthDay = Int(self.birthDay),
			  let birthMonthIndex = months.firstIndex(of: self.birthMonth),
			  birthYear > 1900,
			  birthDay > 0,
			  birthDay <= 31 else {
			birthdayError = ""
			return
		}
		
		let calendar = Calendar.current
		let today = Date()
		let birthDateComponents = DateComponents(year: birthYear, month: birthMonthIndex + 1, day: birthDay)
		
		if let birthDate = calendar.date(from: birthDateComponents) {
			let age = calendar.dateComponents([.year], from: birthDate, to: today).year ?? 0
			if age < 13 {
				birthdayError = "You must be at least 13 years old"
			} else {
				birthdayError = ""
			}
		} else {
			birthdayError = "Invalid date"
		}
	}
	
	func validatePassword() {
		if password.isEmpty && confirmPassword.isEmpty {
			passwordError = ""
			return
		}
		
		if password.count < 8 {
			passwordError = "Password must be at least 8 characters"
			return
		}
		
		if password != confirmPassword {
			passwordError = "Passwords do not match"
			return
		}
		
		passwordError = ""
	}
	
	func clearAllErrors() {
		emailError = ""
		usernameError = ""
		birthdayError = ""
		passwordError = ""
		errorMessage = ""
	}
	
	func clearAllFields() {
		email = ""
		name = ""
		username = ""
		birthMonth = "Month"
		birthDay = ""
		birthYear = ""
		password = ""
		confirmPassword = ""
		emailOrUsername = ""
		clearAllErrors()
	}
	
	// MARK: - Signup
	func register() async -> Bool {
		do {
			guard password == confirmPassword else {
				self.errorMessage = "Passwords do not match"
				return false
			}
			
			// Create user in Firebase Auth first (this gives us authentication)
			let authResult = try await Auth.auth().createUser(withEmail: email, password: password)
			
			// Now that we're authenticated, check username availability properly
			let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if !trimmedUsername.isEmpty {
				do {
					let userService = UserService.shared
					print("🔍 Checking username availability after auth for: '\(trimmedUsername)'")
					let isAvailable = try await userService.isUsernameAvailable(trimmedUsername)
					
					if !isAvailable {
						// Username is taken - delete the Firebase Auth user we just created
						try? await authResult.user.delete()
						
						await MainActor.run {
							self.usernameError = "This username is already registered"
							self.errorMessage = "This username is already registered"
						}
						print("🚫 Username already registered, deleted auth user: \(trimmedUsername)")
						return false
					}
					print("✅ Username is available: \(trimmedUsername)")
				} catch {
					print("⚠️ Error checking username after registration: \(error)")
					// Even if check fails, we'll continue - duplicate will be caught during profile save
				}
			}
			
			// Don't save to Firestore here - let profile completion handle it
			await MainActor.run {
				self.errorMessage = ""
			}
			return true
		} catch {
			// Handle specific Firebase Auth errors
			let errorDesc = error.localizedDescription
			print("🚫 Registration error: \(errorDesc)")
			
			await MainActor.run {
				if errorDesc.contains("email-already-in-use") || 
				   errorDesc.contains("EMAIL_EXISTS") ||
				   errorDesc.contains("The email address is already in use") {
					self.emailError = "This email is already registered"
					self.errorMessage = "This email is already registered"
					print("✅ Set emailError to: '\(self.emailError)'")
				} else if errorDesc.contains("weak-password") {
					self.passwordError = "Password is too weak"
					self.errorMessage = "Password is too weak"
				} else if errorDesc.contains("invalid-email") {
					self.emailError = "Invalid email format"
					self.errorMessage = "Invalid email format"
				} else {
					self.errorMessage = "Unable to create account. Please try again."
				}
			}
			return false
		}
	}
}

// MARK: - Errors
enum AuthError: LocalizedError {
	case invalidCredentials(String)
	
	var errorDescription: String? {
		switch self {
		case .invalidCredentials(let message):
			return message
		}
	}
}
