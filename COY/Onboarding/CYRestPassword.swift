import SwiftUI

struct CYRestPassword: View {

	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var authService: AuthService
	@State private var message: String = ""
	@State private var isError: Bool = false
	@State private var email: String = ""

	var body: some View {
		VStack(spacing: 20) {
			Text("Reset Your Password")
				.font(.title)
				.bold()
			
			TextField("Enter your email", text: $email)
				.keyboardType(.emailAddress)
				.autocapitalization(.none)
				.padding()
				.background(.gray.opacity(0.1))
				.cornerRadius(10)
			
			Button(action: sendPasswordReset) {
				Text("Send Reset Link")
					.bold()
					.padding()
					.frame(maxWidth: .infinity)
					.background(.blue)
					.foregroundColor(.white)
					.cornerRadius(10)
			}
			.padding(.horizontal)
			
			if !message.isEmpty {
				Text(message)
					.foregroundColor(isError ? .red : .green)
					.multilineTextAlignment(.center)
					.padding(.top, 10)
			}
			
			Spacer()
		}
		.padding()
		.navigationTitle("Reset Password")
		.navigationBarTitleDisplayMode(.inline)
	}
	
	private func sendPasswordReset() {
		// Reset previous message
		message = ""
		isError = false
		
		// Validate email is not empty
		guard !email.isEmpty else {
			message = "Email is required"
			isError = true
			return
		}
		
		Task {
			let ok = await authService.sendPasswordReset(email: email)
			await MainActor.run {
				if ok {
					message = "A password reset link has been sent to \(email)"
					isError = false
				} else {
					message = authService.errorMessage ?? "Failed to send reset link"
					isError = true
				}
			}
		}
	}
}



