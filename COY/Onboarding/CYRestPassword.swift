import SwiftUI
import FirebaseAuth

struct CYRestPassword: View {
	@Environment(\.dismiss) private var dismiss
	@State private var message: String = ""
	@State private var isError: Bool = false
	@State private var email: String = ""
	@State private var isLoading: Bool = false
	@State private var hasSentEmail: Bool = false

	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				VStack(spacing: 30) {
					Spacer()
					
					VStack(spacing: 20) {
						Text("Reset Your Password")
							.font(.title)
							.bold()
							.foregroundColor(.primary)
						
						if !hasSentEmail {
							TextField("Enter your email", text: $email)
								.keyboardType(.emailAddress)
								.autocapitalization(.none)
								.padding()
								.background(Color(.systemGray6))
								.cornerRadius(10)
								.disabled(isLoading)
							
							Button(action: sendPasswordReset) {
								if isLoading {
									ProgressView()
										.progressViewStyle(CircularProgressViewStyle(tint: .white))
								} else {
									Text("Send Reset Link")
										.bold()
								}
							}
							.padding()
							.frame(maxWidth: .infinity)
							.background(isLoading ? Color.blue.opacity(0.6) : Color.blue)
							.foregroundColor(.white)
							.cornerRadius(10)
							.disabled(isLoading || email.isEmpty)
							.padding(.horizontal)
						}
					}
					.padding(.horizontal, 20)
					
					if !message.isEmpty {
						VStack(spacing: 10) {
							Text(message)
								.font(.body)
								.foregroundColor(isError ? .red : .green)
								.multilineTextAlignment(.center)
								.padding(.horizontal, 20)
								.padding(.top, 10)
							
							if hasSentEmail && !isError {
								Button(action: {
									dismiss()
								}) {
									Text("Back to Login")
										.font(.body)
										.foregroundColor(.blue)
										.padding(.top, 5)
								}
							}
						}
					}
					
					Spacer()
				}
				.padding()
			}
			.navigationTitle("Reset Password")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(action: {
						dismiss()
					}) {
						Image(systemName: "xmark")
							.foregroundColor(.primary)
					}
				}
			}
		}
	}
	
	private func sendPasswordReset() {
		// Reset previous message
		message = ""
		isError = false
		isLoading = true
		
		// Validate email is not empty
		guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			message = "Email is required"
			isError = true
			isLoading = false
			return
		}
		
		// Validate email format
		let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmedEmail.contains("@") && trimmedEmail.contains(".") else {
			message = "Please enter a valid email address"
			isError = true
			isLoading = false
			return
		}
		
		Task { @MainActor in
			// Call Firebase Auth directly to avoid triggering AuthService state changes
			// that would cause the parent view to re-render and dismiss this modal
			do {
				print("🔄 Sending password reset email to: \(trimmedEmail)")
				try await Auth.auth().sendPasswordReset(withEmail: trimmedEmail)
				print("✅ Password reset email sent successfully")
				
				isLoading = false
				hasSentEmail = true
				message = "A link has been sent to your email to reset your password, please check your email/spam."
				isError = false
			} catch {
				print("❌ Password reset email FAILED: \(error.localizedDescription)")
				isLoading = false
				message = error.localizedDescription
				isError = true
			}
		}
	}
}



