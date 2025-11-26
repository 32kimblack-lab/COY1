import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CYWelcome: View {

	@EnvironmentObject var authService: AuthService
	@StateObject private var authViewModel = AuthViewModel.shared
	
	init() {
		// Inject AuthService into AuthViewModel
		AuthViewModel.shared.authService = nil // Will be set in onAppear
	}
	@State private var showEmailSignUp = false
	@State private var showPhoneSignUp = false
	@State private var navigateToResetPassword = false
	@State private var navigateToPrivacyPolicy = false
	@State private var navigateToTermsOfService = false
	@State private var errorMessage: String? = nil

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

					Button(action: {
						showPhoneSignUp = true
					}) {
						HStack {
							Image(systemName: "phone")
							Text("Sign up with number")
								.fontWeight(.semibold)
						}
						.frame(maxWidth: .infinity)
						.padding(.vertical, 14)
						.background(Color.black)
						.foregroundColor(.white)
						.cornerRadius(10)
					}
					.frame(height: 50)

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
			.fullScreenCover(isPresented: $showPhoneSignUp) {
				CYPhoneSignUp()
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
	
}


