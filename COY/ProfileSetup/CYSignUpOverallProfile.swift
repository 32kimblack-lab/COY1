import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CYSignUpOverallProfile: View {

	@EnvironmentObject var authService: AuthService
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) var colorScheme
	
	@StateObject private var userService = UserService.shared
	@StateObject private var authViewModel = AuthViewModel.shared
	
	// User data properties
	var name: String
	var username: String
	var email: String
	var birthday: String
	
	// Image properties
	var profileImage: UIImage?
	var backgroundImage: UIImage?
	
	@State private var navigateToHome = false
	@State private var navigateToInvite = false
	@State private var isLoading = false
	@State private var errorMessage: String?
	
	var body: some View {
		ZStack(alignment: .top) {
			(colorScheme == .dark ? Color.black : Color.white)
				.edgesIgnoringSafeArea(.all)
			
			VStack(spacing: 0) {
				ScrollView {
					VStack(spacing: 0) {
						headerView()
							.padding(.top, 20)
						
						backgroundAndProfileImageView()
							.padding(.bottom, 60)
						
						userDetailsCardView()
							.padding(.horizontal)
							.padding(.bottom, 50)
						
						Spacer()
					}
				}
				
				completeProfileButton()
					.padding(.horizontal, 20)
					.padding(.bottom, 30)
					.padding(.top, 10)
				
				// Error Message
				if let error = errorMessage {
					Text(error)
						.foregroundColor(.red)
						.font(.caption)
						.padding(.horizontal, 20)
						.padding(.bottom, 10)
				}
			}
		}
		.fullScreenCover(isPresented: $navigateToHome) {
			NavigationStack {
				CYHome()
					.environmentObject(authService)
			}
			.interactiveDismissDisabled()
		}
		.fullScreenCover(isPresented: $navigateToInvite) {
			InviteShareView(
				name: name,
				username: username,
				email: email,
				birthday: birthday,
				profileImage: profileImage,
				backgroundImage: backgroundImage
			)
			.environmentObject(authService)
			.interactiveDismissDisabled()
		}
		.navigationBarBackButtonHidden(true)
		.toolbar {
			ToolbarItem(placement: .navigationBarLeading) {
				Button("Back") {
					// If user goes back, clear pending sign-up data so they can start fresh
					UserDefaults.standard.removeObject(forKey: "pendingSignupData")
					print("🧹 Cleared pending sign-up data - user exited profile setup")
					dismiss()
				}
			}
		}
	}
	
	// MARK: - Header
	@ViewBuilder
	private func headerView() -> some View {
		HStack {
			Spacer()
			Text("My Profile")
				.font(.title2)
				.fontWeight(.semibold)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Spacer()
		}
	}
	
	// MARK: - Background + Profile Image
	@ViewBuilder
	private func backgroundAndProfileImageView() -> some View {
		ZStack(alignment: .bottom) {
			// Only show background if it exists - no placeholder
			if let backgroundImage {
				Image(uiImage: backgroundImage)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(height: 105)
					.clipped()
					.cornerRadius(1)
			}
			
			if let profileImage {
				Image(uiImage: profileImage)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 70, height: 70)
					.clipShape(Circle())
					.offset(y: backgroundImage != nil ? 35 : 0)
			} else {
				// Default profile icon - white, not translucent
				Image(systemName: "person.crop.circle.fill")
					.resizable()
					.scaledToFill()
					.frame(width: 70, height: 70)
					.foregroundColor(.white)
					.offset(y: backgroundImage != nil ? 35 : 0)
			}
		}
		.frame(height: backgroundImage != nil ? 170 : 100)
	}
	
	// MARK: - Details Card
	@ViewBuilder
	private func userDetailsCardView() -> some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Personal Information")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
				.padding(.top, 10)

			VStack(spacing: 0) {
				userDetailsRow(label: "Name", value: name)
				userDetailsRow(label: "Username", value: "@\(username)")
				userDetailsRow(label: "Birthday", value: birthday)
				userDetailsRow(label: "Email", value: email)
			}
			.padding(.vertical, 10)
		}
		.padding()
		.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
		.cornerRadius(10)
	}
	
	@ViewBuilder
	private func userDetailsRow(label: String, value: String) -> some View {
		HStack {
			Text(label)
				.foregroundColor(.gray)
			Spacer()
			Text(value)
				.foregroundColor(colorScheme == .dark ? .white : .black)
		}
		.padding(.vertical, 8)
	}
	
	// MARK: - Complete Profile Button
	@ViewBuilder
	private func completeProfileButton() -> some View {
		TKButton("Complete profile") {
			Task {
				await completeProfile()
			}
		}
		.disabled(isLoading)
		.padding(.horizontal, 20)
	}
	
	// MARK: - Complete Profile Function
	private func completeProfile() async {
		isLoading = true
		errorMessage = nil
		
		do {
			// Check if there's pending email sign-up data
			if let pendingData = UserDefaults.standard.dictionary(forKey: "pendingSignupData"),
			   let email = pendingData["email"] as? String,
			   let password = pendingData["password"] as? String {
				
				// IMPORTANT: Set flags BEFORE creating auth account to prevent premature cleanup
				// This ensures checkProfileSetupStatus knows profile save is in progress and user is in sign-up flow
				UserDefaults.standard.set(true, forKey: "profileSaveInProgress")
				authService.setInSignUpFlow(true)
				print("📝 Set profileSaveInProgress and isInSignUpFlow flags BEFORE creating auth account")
				
				print("🔐 Creating Firebase Auth account now that profile is complete...")
				
				// Create Firebase Auth account
				let authResult: AuthDataResult
				do {
					authResult = try await Auth.auth().createUser(withEmail: email, password: password)
					print("✅ Firebase Auth account created: \(authResult.user.uid)")
				} catch {
					// Clear progress flag on error
					UserDefaults.standard.removeObject(forKey: "profileSaveInProgress")
					
					// If email is already taken (edge case: someone registered it between sign-up and completion)
					if let nsError = error as NSError?,
					   nsError.domain == "FIRAuthErrorDomain",
					   nsError.code == 17007 { // email-already-in-use
						// Clear pending data and show error
						UserDefaults.standard.removeObject(forKey: "pendingSignupData")
						print("❌ Email was taken between sign-up and profile completion")
						throw UserError.emailTaken
					}
					throw error
				}
				
				// Verify current user is available (critical check)
				guard Auth.auth().currentUser != nil else {
					throw UserError.userNotFound
				}
				
				// Check username availability before proceeding
				let isUsernameAvailable = try await userService.isUsernameAvailable(username)
				if !isUsernameAvailable {
					// Clear progress flag on error
					UserDefaults.standard.removeObject(forKey: "profileSaveInProgress")
					throw UserError.usernameTaken
				}
				
				// Extract birthday components (prefer authViewModel, fall back to pendingData, then parse birthday string)
				var birthMonth = authViewModel.birthMonth.isEmpty ? (pendingData["birthMonth"] as? String ?? "") : authViewModel.birthMonth
				var birthDay = authViewModel.birthDay.isEmpty ? (pendingData["birthDay"] as? String ?? "") : authViewModel.birthDay
				var birthYear = authViewModel.birthYear.isEmpty ? (pendingData["birthYear"] as? String ?? "") : authViewModel.birthYear
				
				// If still empty, parse from birthday string
				if birthMonth.isEmpty && !birthday.isEmpty {
					let parsed = parseBirthday(birthday)
					birthMonth = parsed.month
					birthDay = parsed.day
					birthYear = parsed.year
				}
				
				// Save user profile data (this now handles image uploads too)
				_ = try await userService.completeProfileSetup(
					name: name,
					username: username,
					email: email,
					birthMonth: birthMonth,
					birthDay: birthDay,
					birthYear: birthYear,
					profileImage: profileImage,
					backgroundImage: backgroundImage
				)
				
				print("✅ Email sign-up: Profile data and images saved to Firestore")
				
				// NOW clear pending sign-up data (after successful save) and clear progress flag
				UserDefaults.standard.removeObject(forKey: "pendingSignupData")
				UserDefaults.standard.removeObject(forKey: "profileSaveInProgress")
				print("🧹 Cleared pending email sign-up data")
			} else {
				// Existing auth user completing profile - verify authentication first
				guard let currentUser = Auth.auth().currentUser else {
					throw UserError.userNotFound
				}
				
				// For existing users, check if they already have this username
				// (they might be updating their profile with the same username)
				var shouldCheckUsername = true
				if let existingUser = try? await userService.getUser(userId: currentUser.uid),
				   existingUser.username.lowercased() == username.lowercased() {
					// User already has this username, no need to check availability
					shouldCheckUsername = false
					print("ℹ️ User already has this username, skipping availability check")
				}
				
				// Check username availability only if user is changing username
				if shouldCheckUsername {
					let isUsernameAvailable = try await userService.isUsernameAvailable(username)
					if !isUsernameAvailable {
						throw UserError.usernameTaken
					}
				}
				
				// Parse birthday from string
				let birthComponents = parseBirthday(birthday)
				
				_ = try await userService.completeProfileSetup(
					name: name,
					username: username,
					email: email,
					birthMonth: birthComponents.month.isEmpty ? authViewModel.birthMonth : birthComponents.month,
					birthDay: birthComponents.day.isEmpty ? authViewModel.birthDay : birthComponents.day,
					birthYear: birthComponents.year.isEmpty ? authViewModel.birthYear : birthComponents.year,
					profileImage: profileImage,
					backgroundImage: backgroundImage
				)
				print("✅ Existing user: Profile data and images saved to Firestore")
			}
			
			// Mark profile setup as complete
			authService.markProfileSetupComplete()
			
			// IMPORTANT: Keep isInSignUpFlow = true while showing invite screen
			// The invite screen will clear this flag when user clicks "Skip"
			// This prevents COYApp from immediately switching to MainTabView
			print("✅ Profile complete - navigating to invite screen")
			
			// Navigate to invite screen (user can skip if they want)
			// Heavy operations (user reload) will happen in background
			await MainActor.run {
				self.isLoading = false
				self.navigateToInvite = true
			}
			
			// Run heavy operations in background (don't block navigation)
			if let currentUser = Auth.auth().currentUser {
				let userId = currentUser.uid
				
				Task.detached {
					// Clear cache
					await MainActor.run {
						UserService.shared.clearUserCache(userId: userId)
					}
					
					// Reload user data
					await withTaskGroup(of: Void.self) { group in
						// Add user reload task (throwing)
						group.addTask {
							try? await CYServiceManager.shared.loadCurrentUser()
						}
					}
					
					print("✅ User reload completed")
					
					// Post notification to refresh profile views with latest data
					await MainActor.run {
						if let updatedUser = CYServiceManager.shared.currentUser {
							NotificationCenter.default.post(
								name: NSNotification.Name("ProfileUpdated"),
								object: nil,
								userInfo: ["updatedData": [
									"profileImageURL": updatedUser.profileImageURL,
									"backgroundImageURL": updatedUser.backgroundImageURL,
									"name": updatedUser.name,
									"username": updatedUser.username
								]]
							)
						}
					}
				}
			}
			
		} catch {
			// Handle specific errors
			print("❌ Failed to complete profile: \(error)")
			print("❌ Error details: \(error.localizedDescription)")
			if let nsError = error as NSError? {
				print("❌ Error domain: \(nsError.domain), code: \(nsError.code)")
				print("❌ Error userInfo: \(nsError.userInfo)")
			}
			
			// Clear progress flag on error
			UserDefaults.standard.removeObject(forKey: "profileSaveInProgress")
			
			await MainActor.run {
				self.isLoading = false
				if let userError = error as? UserError {
					switch userError {
					case .emailTaken:
						self.errorMessage = "This email was already registered. Please use a different email or try logging in."
					case .usernameTaken:
						self.errorMessage = "This username is already taken. Please choose a different username."
					case .userNotFound:
						self.errorMessage = "Authentication error. Please try logging in again."
					}
				} else {
					// Show more detailed error message
					let detailedError = error.localizedDescription.isEmpty ? "Please try again." : error.localizedDescription
					self.errorMessage = "Failed to complete profile: \(detailedError)"
				}
			}
		}
	}
	
	// Helper to parse birthday string like "January 1, 2000"
	private func parseBirthday(_ birthday: String) -> (month: String, day: String, year: String) {
		let components = birthday.components(separatedBy: " ")
		if components.count >= 3 {
			let month = components[0]
			let day = components[1].trimmingCharacters(in: CharacterSet(charactersIn: ","))
			let year = components[2]
			return (month: month, day: day, year: year)
		}
		return (month: "", day: "", year: "")
	}
}

