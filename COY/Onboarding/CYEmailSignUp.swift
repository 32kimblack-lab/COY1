import SwiftUI

struct CYEmailSignUp: View {

	@EnvironmentObject var authService: AuthService
	@StateObject private var authViewModel = AuthViewModel.shared
	@Environment(\.dismiss) private var dismiss
	
	@State private var navigateToProfile = false
	@State private var isSigningUp = false
	
	let months = ["January", "February", "March", "April", "May", "June", "July",
				  "August", "September", "October", "November", "December"]
	@Environment(\.colorScheme) var colorScheme
	
	private var textColor: Color {
		return colorScheme == .dark ? .white : .black
	}
	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				
				// Logo
				CombinedIconView()
					.offset(y: 60)
					.offset(x: 20)
				
				// Input Fields
				VStack(alignment: .leading, spacing: 15) {
					
					// Email
					VStack(alignment: .leading, spacing: 5) {
						TKTextField(text: $authViewModel.email, placeholder: "Email address", image: "envelope")
							.frame(maxWidth: .infinity)
							.foregroundColor(textColor)
							.onChange(of: authViewModel.email) { _, _ in
								authViewModel.validateEmail()
							}
						
						if !authViewModel.emailError.isEmpty {
							Text(authViewModel.emailError)
								.foregroundColor(.red)
								.font(.caption)
								.padding(.horizontal, 5)
						}
					}
					// Name
					TKTextField(text: $authViewModel.name, placeholder: "Name", image: "person")
						.frame(maxWidth: .infinity)
						.foregroundColor(textColor)
					// Username
					VStack(alignment: .leading, spacing: 5) {
						TKTextField(text: $authViewModel.username, placeholder: "Username", image: "at")
							.frame(maxWidth: .infinity)
							.foregroundColor(textColor)
							.onChange(of: authViewModel.username) { _, _ in
								authViewModel.validateUsername()
							}
						
						if !authViewModel.usernameError.isEmpty {
							Text(authViewModel.usernameError)
								.foregroundColor(.red)
								.font(.caption)
								.padding(.horizontal, 5)
						}
					}
					// Date of Birth
					VStack(alignment: .leading, spacing: 5) {
						HStack(spacing: 10) {
							// Month Dropdown - styled like TKTextField, wider to show full month names
							Menu {
								ForEach(months, id: \.self) { month in
									Button(month) {
										authViewModel.birthMonth = month
										authViewModel.validateBirthday()
									}
								}
							} label: {
								HStack(spacing: 10) {
									Image(systemName: "calendar")
										.foregroundColor(.secondary)
									Text(authViewModel.birthMonth == "Month" ? "Month" : authViewModel.birthMonth)
										.foregroundColor(authViewModel.birthMonth == "Month" ? .secondary : textColor)
										.frame(maxWidth: .infinity, alignment: .leading)
										.fixedSize(horizontal: false, vertical: true)
										.lineLimit(1)
									Image(systemName: "chevron.down")
										.foregroundColor(.secondary)
										.font(.caption)
								}
								.padding()
								.frame(maxWidth: .infinity)
								.background(
									RoundedRectangle(cornerRadius: 10)
										.stroke(Color.gray.opacity(0.4), lineWidth: 1)
								)
							}
							.frame(minWidth: 180, idealWidth: 200, maxWidth: .infinity)
							
							// Day Field - smaller but wide enough to see numbers
							TKTextField(text: $authViewModel.birthDay, placeholder: "DD", image: "calendar", isSecure: false)
								.keyboardType(.numberPad)
								.frame(minWidth: 70, idealWidth: 75, maxWidth: 80)
								.foregroundColor(textColor)
								.onChange(of: authViewModel.birthDay) { _, _ in
									authViewModel.validateBirthday()
								}
							
							// Year Field - smaller but wide enough to see 4 digits
							TKTextField(text: $authViewModel.birthYear, placeholder: "YYYY", image: "calendar", isSecure: false)
								.keyboardType(.numberPad)
								.frame(minWidth: 90, idealWidth: 95, maxWidth: 100)
								.foregroundColor(textColor)
								.onChange(of: authViewModel.birthYear) { _, _ in
									authViewModel.validateBirthday()
								}
						}
						
						if !authViewModel.birthdayError.isEmpty {
							Text(authViewModel.birthdayError)
								.foregroundColor(.red)
								.font(.caption)
								.padding(.horizontal, 5)
						}
					}
					// Password
					VStack(alignment: .leading, spacing: 5) {
						TKTextField(text: $authViewModel.password, placeholder: "Password", image: "lock", isSecure: true)
							.frame(maxWidth: .infinity)
							.foregroundColor(textColor)
							.onChange(of: authViewModel.password) { _, _ in
								authViewModel.validatePassword()
							}
						// Confirm Password
						TKTextField(text: $authViewModel.confirmPassword, placeholder: "Confirm Password", image: "lock.rotation", isSecure: true)
							.frame(maxWidth: .infinity)
							.foregroundColor(textColor)
							.onChange(of: authViewModel.confirmPassword) { _, _ in
								authViewModel.validatePassword()
							}
						
						if !authViewModel.passwordError.isEmpty {
							Text(authViewModel.passwordError)
								.foregroundColor(.red)
								.font(.caption)
								.padding(.horizontal, 5)
						}
					}
				}
				.padding(.horizontal, 20)
				.padding(.bottom, 40)
				.offset(y: 130)
				Spacer()
				// Error Message
				if !authViewModel.errorMessage.isEmpty {
					Text(authViewModel.errorMessage)
						.foregroundStyle(.red)
						.font(.caption)
						.padding(.horizontal, 20)
				}
				
				// Sign Up Button
				Button(action: {
					Task {
						// Set loading state immediately
						await MainActor.run {
							isSigningUp = true
						}
						
						// Don't clear errors yet - let validation set them first
						
						// Validate all fields before attempting registration (sync validations)
						authViewModel.validateBirthday()
						authViewModel.validatePassword()
						
						// Wait for async validations to complete
						await authViewModel.validateEmailAsync()
						await authViewModel.validateUsernameAsync()
						
						// Small delay to ensure UI updates
						try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
						
						// Check if there are any validation errors
						if !authViewModel.emailError.isEmpty || 
						   !authViewModel.usernameError.isEmpty || 
						   !authViewModel.birthdayError.isEmpty || 
						   !authViewModel.passwordError.isEmpty {
							print("🚫 Validation errors found:")
							print("  - Email error: '\(authViewModel.emailError)'")
							print("  - Username error: '\(authViewModel.usernameError)'")
							print("  - Birthday error: '\(authViewModel.birthdayError)'")
							print("  - Password error: '\(authViewModel.passwordError)'")
							await MainActor.run {
								isSigningUp = false
							}
							return
						}
						
						// IMPORTANT: Set signup flow flag BEFORE creating account
						// This prevents AuthService from deleting the account as "incomplete"
						authService.setInSignUpFlow(true)
						UserDefaults.standard.set(true, forKey: "profileSaveInProgress")
						
						// Create Firebase Auth account first
						let success = await authViewModel.register()
						if success {
							await MainActor.run {
								isSigningUp = false
								navigateToProfile = true
							}
						} else {
							// Clear flags on error
							authService.setInSignUpFlow(false)
							UserDefaults.standard.removeObject(forKey: "profileSaveInProgress")
							await MainActor.run {
								isSigningUp = false
							}
							// Errors should be set in register() function
							print("🚫 Registration failed. Email error: '\(authViewModel.emailError)', Username error: '\(authViewModel.usernameError)'")
						}
					}
				}) {
					HStack {
						if isSigningUp {
							ProgressView()
								.progressViewStyle(CircularProgressViewStyle(tint: .white))
								.scaleEffect(0.8)
						}
						Text(isSigningUp ? "Signing Up..." : "Sign Up")
							.fontWeight(.semibold)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 14)
					.background(isSigningUp ? Color.accentColor.opacity(0.7) : Color.accentColor)
					.foregroundColor(.white)
					.cornerRadius(10)
				}
				.disabled(isSigningUp || 
						 authService.isLoading || 
						 !authViewModel.emailError.isEmpty || 
						 !authViewModel.usernameError.isEmpty || 
						 !authViewModel.birthdayError.isEmpty || 
						 !authViewModel.passwordError.isEmpty)
				.padding()
				.offset(y: -20)
			}
			.padding()
			.background(textColor == .white ? Color.black : Color.white)
			.edgesIgnoringSafeArea(.all)
			.fullScreenCover(isPresented: $navigateToProfile) {
				CYSignupProfileView(
					name: authViewModel.name,
					username: authViewModel.username,
					email: authViewModel.email,
					birthday: "\(authViewModel.birthMonth) \(authViewModel.birthDay), \(authViewModel.birthYear)",
					password: authViewModel.password
				)
				.environmentObject(authService)
			}
			.navigationBarBackButtonHidden(true)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Back") {
						dismiss()
					}
				}
			}
			.onTapGesture {
				hideKeyboard()
			}
			.onAppear {
				// Clear all sign up fields when view appears
				authViewModel.clearAllFields()
			}
			.onDisappear {
				// Also clear when view disappears to ensure clean state
				authViewModel.clearAllFields()
			}
		}
	}
	
	private func hideKeyboard() {
		UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
	}
}

