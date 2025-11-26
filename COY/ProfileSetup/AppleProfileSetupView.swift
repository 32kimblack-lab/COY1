import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct AppleProfileSetupView: View {
	@EnvironmentObject var authService: AuthService
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) var colorScheme
	
	@StateObject private var userService = UserService.shared
	@StateObject private var authViewModel = AuthViewModel.shared
	
	var prefilledName: String
	var prefilledEmail: String
	
	@State private var name: String = ""
	@State private var username: String = ""
	@State private var email: String = ""
	@State private var birthMonth: String = "Month"
	@State private var birthDay: String = ""
	@State private var birthYear: String = ""
	
	@State private var navigateToProfileImage = false
	@State private var isLoading = false
	@State private var errorMessage: String?
	
	@State private var usernameError: String = ""
	
	let months = ["January", "February", "March", "April", "May", "June", "July",
				  "August", "September", "October", "November", "December"]
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
			ScrollView {
				VStack(spacing: 20) {
					// Header
					Text("Complete Your Profile")
						.font(.title2)
						.fontWeight(.semibold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
						.padding(.top, 20)
					
					Text("We need a few more details to set up your account")
						.font(.subheadline)
						.foregroundColor(.gray)
						.multilineTextAlignment(.center)
						.padding(.horizontal)
					
					// Name Field
					VStack(alignment: .leading, spacing: 5) {
						TKTextField(text: $name, placeholder: "Name", image: "person")
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					.padding(.horizontal, 20)
					
					// Username Field
					VStack(alignment: .leading, spacing: 5) {
						TKTextField(text: $username, placeholder: "Username", image: "at")
							.foregroundColor(colorScheme == .dark ? .white : .black)
							.onChange(of: username) { _, newValue in
								Task {
									await validateUsername(newValue)
								}
							}
						
						if !usernameError.isEmpty {
							Text(usernameError)
								.foregroundColor(.red)
								.font(.caption)
								.padding(.horizontal, 5)
						}
					}
					.padding(.horizontal, 20)
					
					// Birthday Fields
					VStack(alignment: .leading, spacing: 5) {
						Text("Date of birth")
							.foregroundColor(.gray)
							.padding(.horizontal, 5)
						
						HStack(spacing: 10) {
							Menu {
								ForEach(months, id: \.self) { month in
									Button(month) {
										birthMonth = month
									}
								}
							} label: {
								HStack {
									Text(birthMonth == "Month" ? "Month" : birthMonth)
										.foregroundColor(birthMonth == "Month" ? .gray : (colorScheme == .dark ? .white : .black))
										.lineLimit(1)
										.truncationMode(.tail)
									Spacer()
									Image(systemName: "chevron.down")
										.foregroundColor(.gray)
										.font(.caption)
								}
								.padding()
								.background(
									RoundedRectangle(cornerRadius: 10)
										.stroke(colorScheme == .dark ? Color.white : Color.gray, lineWidth: 2)
								)
							}
							.frame(width: 130)
							
							HStack(spacing: 10) {
								Image(systemName: "calendar")
									.foregroundColor(.secondary)
								TextField("DD", text: $birthDay)
								.keyboardType(.numberPad)
									.textContentType(.none)
									.autocorrectionDisabled()
									.foregroundColor(colorScheme == .dark ? .white : .black)
							}
							.padding()
							.background(
								RoundedRectangle(cornerRadius: 10)
									.stroke(colorScheme == .dark ? Color.white : Color.gray, lineWidth: 2)
							)
								.frame(width: 80)
							
							HStack(spacing: 10) {
								Image(systemName: "calendar")
									.foregroundColor(.secondary)
								TextField("YYYY", text: $birthYear)
								.keyboardType(.numberPad)
									.textContentType(.none)
									.autocorrectionDisabled()
									.foregroundColor(colorScheme == .dark ? .white : .black)
							}
							.padding()
							.background(
								RoundedRectangle(cornerRadius: 10)
									.stroke(colorScheme == .dark ? Color.white : Color.gray, lineWidth: 2)
							)
								.frame(width: 100)
						}
					}
					.padding(.horizontal, 20)
					
					// Email (read-only, prefilled)
					VStack(alignment: .leading, spacing: 5) {
						TKTextField(text: .constant(email), placeholder: "Email", image: "envelope")
							.foregroundColor(.gray)
							.disabled(true)
					}
					.padding(.horizontal, 20)
					
					// Error Message
					if let error = errorMessage {
						Text(error)
							.foregroundColor(.red)
							.font(.caption)
							.padding(.horizontal, 20)
					}
					
					// Continue Button
					TKButton("Continue") {
						Task {
							await continueToProfileImage()
						}
					}
					.disabled(isLoading || name.isEmpty || username.isEmpty || 
							 birthMonth == "Month" || birthDay.isEmpty || birthYear.isEmpty ||
							 !usernameError.isEmpty)
					.padding(.horizontal, 20)
					.padding(.top, 20)
				}
				.padding(.bottom, 40)
				}
			}
			.background(colorScheme == .dark ? Color.black : Color.white)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Back") {
						dismiss()
					}
				}
			}
			.onAppear {
				// Pre-fill name and email from Apple
				name = prefilledName
				email = prefilledEmail
			}
			.fullScreenCover(isPresented: $navigateToProfileImage) {
				CYSignupProfileView(
					name: name,
					username: username,
					email: email,
					birthday: "\(birthMonth) \(birthDay), \(birthYear)",
					password: "" // No password for Apple sign-in
				)
				.environmentObject(authService)
			}
		}
	}
	
	private func validateUsername(_ value: String) async {
		guard !value.isEmpty else {
			usernameError = ""
			return
		}
		
		// Basic validation
		if value.count < 3 {
			usernameError = "Username must be at least 3 characters"
			return
		}
		
		if !value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) {
			usernameError = "Username can only contain letters, numbers, _, and ."
			return
		}
		
		// Check availability
		do {
			let isAvailable = try await userService.isUsernameAvailable(value)
			if !isAvailable {
				usernameError = "Username is already taken"
			} else {
				usernameError = ""
			}
		} catch {
			usernameError = "Error checking username"
		}
	}
	
	private func continueToProfileImage() async {
		isLoading = true
		errorMessage = nil
		
		// Validate all fields
		guard !name.isEmpty,
			  !username.isEmpty,
			  birthMonth != "Month",
			  !birthDay.isEmpty,
			  !birthYear.isEmpty,
			  usernameError.isEmpty else {
			isLoading = false
			return
		}
		
		// Navigate to profile image selection
		await MainActor.run {
			navigateToProfileImage = true
			isLoading = false
		}
	}
}

