import AuthenticationServices
import SwiftUI
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import ObjectiveC

struct CYWelcome: View {

	@EnvironmentObject var authService: AuthService
	@StateObject private var authViewModel = AuthViewModel.shared
	@State private var currentNonce: String?
	
	init() {
		// Inject AuthService into AuthViewModel
		AuthViewModel.shared.authService = nil // Will be set in onAppear
	}
	@State private var showEmailSignUp = false
	@State private var navigateToResetPassword = false
	@State private var navigateToPrivacyPolicy = false
	@State private var navigateToTermsOfService = false
	@State private var errorMessage: String? = nil
	@State private var showAppleProfileSetup = false
	@State private var appleSignupName: String = ""
	@State private var appleSignupEmail: String = ""

	var body: some View {

		NavigationStack {

			ScrollView {

				VStack(spacing: 30) {

					

					// Logo

					CombinedIconView()

						.frame(maxWidth: .infinity, alignment: .center)

						.frame(height: 120)

						.padding(.top, 40)

					

					

					// Login Fields

					VStack(spacing: 20) {

						Text("Login")

							.font(.system(size: 25, weight: .semibold))

							.frame(maxWidth: .infinity, alignment: .leading)

							.foregroundColor(.primary)

						if !authViewModel.errorMessage.isEmpty {

							Text(authViewModel.errorMessage)

								.foregroundColor(.red)

								.lineLimit(2)

						}

						TKTextField(text: $authViewModel.emailOrUsername, placeholder: "Username/Email", image: "envelope")

							.foregroundColor(.primary)

							.textInputAutocapitalization(.never)

							.autocorrectionDisabled()

							.onChange(of: authViewModel.emailOrUsername) { oldValue, newValue in
								// Clear error when user starts typing
								errorMessage = nil
								authViewModel.errorMessage = ""
							}

						TKTextField(text: $authViewModel.password, placeholder: "Password", image: "lock", isSecure: true)

							.foregroundColor(.primary)

							.onChange(of: authViewModel.password) { oldValue, newValue in
								// Clear error when user starts typing
								errorMessage = nil
								authViewModel.errorMessage = ""
							}

						if let error = errorMessage {

							Text(error)

								.foregroundStyle(.red)

								.font(.caption)

						}

						HStack {

							Spacer()

							Text("Forgot Password?")

								.font(.footnote)

								.foregroundColor(.accentColor)

								.onTapGesture {

									navigateToResetPassword = true

								}

						}

					}

					.padding(.horizontal, 20)

					// Auth Options

					VStack(spacing: 20) {

						TKButton("Login") {

							Task {

								// Clear previous errors before attempting login
								await MainActor.run {
									errorMessage = nil
									authViewModel.errorMessage = ""
								}

								do {

									try await authViewModel.login()

									// AuthService will automatically handle navigation based on authentication state

								} catch {

									await MainActor.run {

										if let authError = error as? AuthError {
											switch authError {
											case .invalidCredentials(let message):
												errorMessage = message
											}
										} else {
											errorMessage = "Email or password is incorrect"
										}

									}

								}

							}

						}

						.disabled(authService.isLoading || authViewModel.emailOrUsername.isEmpty || authViewModel.password.isEmpty)

						HStack {
							VStack { Divider() }
							Text("New here?")
								.font(.footnote)
								.foregroundColor(.primary)
							VStack { Divider() }
						}

						TKButton("Sign up with Email", iconName: "envelope") {

							showEmailSignUp = true

						}

						.foregroundColor(.black)

						SignInWithAppleButton(.signUp, onRequest: { request in
							print("🍎 Apple Sign-In: Starting authorization request...")
							let nonce = randomNonceString()
							currentNonce = nonce
							request.requestedScopes = [.fullName, .email]
							request.nonce = sha256(nonce)
							print("🍎 Apple Sign-In: Request configured with nonce")
						}, onCompletion: { result in
							switch result {
							case .success(let authResults):
								print("✅ Apple Sign-In: Authorization successful")
								handleAppleAuth(authResults)
							case .failure(let err):
								// Provide more helpful error messages
								let errorCode = (err as NSError).code
								let nsError = err as NSError
								
								print("❌ Apple Sign-In Error: \(err.localizedDescription) (Code: \(errorCode))")
								print("   Error domain: \(nsError.domain)")
								print("   Error userInfo: \(nsError.userInfo)")
								
								if errorCode == 1000 {
									errorMessage = "Apple Sign-In not configured. Please enable 'Sign in with Apple' capability in Xcode."
								} else if errorCode == 1001 {
									// Error 1001 = ASAuthorizationErrorCanceled
									// If this happens every time, it's likely a configuration issue
									errorMessage = "Apple Sign-In failed. Please check:\n1. Sign in with Apple capability is enabled in Xcode\n2. You're signed into iCloud on this device\n3. Bundle ID is configured in Apple Developer Portal"
								} else {
									errorMessage = "Apple sign in failed: \(err.localizedDescription)"
								}
							}
						})
						.signInWithAppleButtonStyle(.black)
						.frame(height: 50)
						.clipShape(RoundedRectangle(cornerRadius: 10))

					}

					.padding(.horizontal, 20)

					// Footer

					VStack(spacing: 8) {

						Text("By continuing, you acknowledge that you have read the ")

							.font(.footnote)

							.foregroundColor(.secondary)

						HStack(spacing: 4) {

							Button(action: {

								navigateToPrivacyPolicy = true

							}) {

								Text("Privacy Policy")

									.font(.footnote)

									.foregroundColor(.blue)

							}

							Text("and agree to the")

								.font(.footnote)

								.foregroundColor(.secondary)

							Button(action: {

								navigateToTermsOfService = true

							}) {

								Text("Terms of Service.")

									.font(.footnote)

									.foregroundColor(.blue)

							}

						}

					}

					.multilineTextAlignment(.center)

					.frame(maxWidth: .infinity)

					.padding(.horizontal, 20)

					.padding(.bottom, 40)

				}

			}

			.scrollContentBackground(.hidden)

			.background(Color(.systemBackground))

			.fullScreenCover(isPresented: $showEmailSignUp) {

				CYEmailSignUp()

			}
			.fullScreenCover(isPresented: $showAppleProfileSetup) {
				AppleProfileSetupView(
					prefilledName: appleSignupName,
					prefilledEmail: appleSignupEmail
				)
				.environmentObject(authService)
			}

			.navigationDestination(isPresented: $navigateToResetPassword) {

				CYRestPassword()

			

			}

			.onAppear {
				// Inject AuthService into AuthViewModel
				authViewModel.authService = authService
				// Clear login fields and errors when view appears
				authViewModel.emailOrUsername = ""
				authViewModel.password = ""
				authViewModel.errorMessage = ""
				errorMessage = nil
			}

		}

	}
	
	// MARK: - Apple Sign In Handler
	private func handleAppleAuth(_ authResults: ASAuthorization) {
		if let appleIDCredential = authResults.credential as? ASAuthorizationAppleIDCredential {
			guard let nonce = currentNonce else {
				errorMessage = "Sign in failed: Invalid state"
				return
			}
			currentNonce = nil
			
			guard let appleIDToken = appleIDCredential.identityToken,
				  let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
				errorMessage = "Sign in failed: Unable to process token"
				return
			}
			
			Task {
				do {
					// Get user info from Apple
					var name = ""
					if let fullName = appleIDCredential.fullName {
						var components: [String] = []
						if let given = fullName.givenName { components.append(given) }
						if let family = fullName.familyName { components.append(family) }
						name = components.joined(separator: " ")
					}
					let email = appleIDCredential.email ?? ""
					
					// Create Firebase credential using Objective-C helper
					var credential: AuthCredential?
					
					// Try to get the Objective-C class
					if let helperClass = NSClassFromString("AppleSignInHelper") {
						let selector = NSSelectorFromString("credentialWithProviderID:idToken:rawNonce:")
						if helperClass.responds(to: selector),
						   let method = class_getClassMethod(helperClass, selector) {
							let imp = method_getImplementation(method)
							typealias CredentialMethod = @convention(c) (AnyClass, Selector, NSString, NSString, NSString) -> Unmanaged<AnyObject>?
							let methodFunc: CredentialMethod = unsafeBitCast(imp, to: CredentialMethod.self)
							if let result = methodFunc(helperClass, selector, "apple.com" as NSString, idTokenString as NSString, nonce as NSString)?.takeUnretainedValue() {
								credential = result as? AuthCredential
							}
						}
					}
					
					guard let cred = credential else {
						await MainActor.run {
							errorMessage = "Apple Sign-in failed. Please use email signup."
						}
						return
					}
					
					// Sign in with Firebase (creates account if new, signs in if existing)
					let authResult = try await Auth.auth().signIn(with: cred)
					
					// Check if user has complete profile
					let db = Firestore.firestore()
					let userDoc = try await db.collection("users").document(authResult.user.uid).getDocument()
					
					if let userData = userDoc.data(),
					   let username = userData["username"] as? String,
					   !username.isEmpty,
					   let savedName = userData["name"] as? String,
					   !savedName.isEmpty {
						// User exists with complete profile - they're logged in
						await MainActor.run {
							authService.user = authResult.user
							authService.markProfileSetupComplete()
							authService.setInSignUpFlow(false)
						}
					} else {
						// New user or incomplete profile - collect username and birthday first
						await MainActor.run {
							authService.user = authResult.user
							authService.setInSignUpFlow(true)
							// Store Apple signup data and navigate to profile setup
							appleSignupName = name
							appleSignupEmail = email.isEmpty ? (authResult.user.email ?? "") : email
							showAppleProfileSetup = true
						}
					}
				} catch {
					await MainActor.run {
						errorMessage = "Sign in failed: \(error.localizedDescription)"
					}
				}
			}
		}
	}
	
	// MARK: - Helper Functions
	
	// Generates a random nonce string
	private func randomNonceString(length: Int = 32) -> String {
		precondition(length > 0)
		let charset: [Character] =
			Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
		var result = ""
		var remainingLength = length
		
		while remainingLength > 0 {
			let randoms: [UInt8] = (0 ..< 16).map { _ in
				var random: UInt8 = 0
				let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
				if errorCode != errSecSuccess {
					fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
				}
				return random
			}
			
			randoms.forEach { random in
				if remainingLength == 0 {
					return
				}
				
				if random < charset.count {
					result.append(charset[Int(random)])
					remainingLength -= 1
				}
			}
		}
		
		return result
	}
	
	// SHA256 hash for nonce
	private func sha256(_ input: String) -> String {
		let inputData = Data(input.utf8)
		let hashedData = SHA256.hash(data: inputData)
		let hashString = hashedData.compactMap {
			String(format: "%02x", $0)
		}.joined()
		
		return hashString
	}

}


