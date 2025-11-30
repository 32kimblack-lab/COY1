import SwiftUI
import FirebaseAuth

struct AccountManagementView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@EnvironmentObject var authService: AuthService
	@StateObject private var cyServiceManager = CYServiceManager.shared
	@State private var showCopiedAlert = false
	@State private var profileURL: String = ""
	
	// Delete Account States
	@State private var showPasswordAlert = false
	@State private var password: String = ""
	@State private var showDeleteConfirmation = false
	@State private var isDeleting = false
	@State private var deleteError: String?
	
	var body: some View {
		PhoneSizeContainer {
			ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				HStack {
					Button(action: { presentationMode.wrappedValue.dismiss() }) {
						Image(systemName: "chevron.backward")
							.font(.title2)
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					Spacer()
					Text("Account Management")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
				// Profile Link Section
				profileLinkSection
				
				// Delete Account Section
				deleteAccountSection
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
			}
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
		.onAppear {
			loadProfileURL()
		}
		.alert("Copied!", isPresented: $showCopiedAlert) {
			Button("OK", role: .cancel) { }
		} message: {
			Text("Profile link copied to clipboard")
		}
		.alert("Enter Password", isPresented: $showPasswordAlert) {
			SecureField("Password", text: $password)
			Button("Cancel", role: .cancel) {
				password = ""
			}
			Button("Continue", role: .destructive) {
				verifyPassword()
			}
		} message: {
			Text("Please enter your password to confirm account deletion.")
		}
		.alert("Permanently Delete Account?", isPresented: $showDeleteConfirmation) {
			Button("Cancel", role: .cancel) {
				password = ""
			}
			Button("Delete Forever", role: .destructive) {
				Task {
					await deleteAccount()
				}
			}
		} message: {
			Text("Are you absolutely sure you want to permanently delete your account? This action cannot be undone.\n\n• All your collections will be deleted\n• All your posts will be deleted\n• All your messages will be deleted\n• Everything will be permanently deleted right away\n• You will NOT be able to restore anything\n• There is NO 30-day restore period\n\nYour entire account and all data will be permanently deleted immediately.")
		}
		.alert("Error", isPresented: Binding(
			get: { deleteError != nil },
			set: { if !$0 { deleteError = nil } }
		)) {
			Button("OK", role: .cancel) {
				deleteError = nil
			}
		} message: {
			if let error = deleteError {
				Text(error)
			}
		}
	}
	
	private var profileLinkSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Share Your Profile")
				.font(.headline)
				.foregroundColor(.primary)
				.padding(.horizontal)
			
			VStack(alignment: .leading, spacing: 12) {
				Text("Your Profile Link")
					.font(.subheadline)
					.foregroundColor(.secondary)
					.padding(.horizontal)
				
				HStack(spacing: 12) {
					// URL Display - make it selectable
					Text(profileURL.isEmpty ? "Loading..." : profileURL)
						.font(.system(.body, design: .monospaced))
						.foregroundColor(.primary)
						.lineLimit(1)
						.textSelection(.enabled) // Allow text selection
						.padding(.horizontal, 12)
						.padding(.vertical, 10)
						.background(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.95))
						.cornerRadius(8)
					
					// Copy Button
					Button(action: {
						copyProfileURL()
					}) {
						Image(systemName: "doc.on.doc")
							.font(.title3)
							.foregroundColor(.blue)
							.padding(10)
							.background(Color.blue.opacity(0.1))
							.cornerRadius(8)
					}
					
					// Share Button - Use system share sheet for proper link sharing
					if let url = shareURL {
						ShareLink(item: url) {
							Image(systemName: "square.and.arrow.up")
								.font(.title3)
								.foregroundColor(.blue)
								.padding(10)
								.background(Color.blue.opacity(0.1))
								.cornerRadius(8)
						}
					}
				}
				.padding(.horizontal)
				
				Text("Share this link to let others view your profile. If they have the app, it will open in the app. Otherwise, it will open on the web.")
					.font(.caption)
					.foregroundColor(.secondary)
					.padding(.horizontal)
			}
			.padding(.vertical, 8)
			.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.98))
			.cornerRadius(12)
			.padding(.horizontal)
		}
	}
	
	private func loadProfileURL() {
		Task {
			// Ensure current user is loaded
			try? await CYServiceManager.shared.loadCurrentUser()
			
			await MainActor.run {
				// CRITICAL: Always use user ID in shareable links (never breaks when username changes)
				// Format: https://coy.services/profile/userId
				if let userId = Auth.auth().currentUser?.uid {
					profileURL = "https://coy.services/profile/\(userId)"
				} else {
					profileURL = "Loading..."
				}
			}
		}
	}
	
	private func copyProfileURL() {
		// CRITICAL: Always use user ID in shareable links (never breaks when username changes)
		guard let userId = Auth.auth().currentUser?.uid else {
			print("❌ No user ID available for profile URL")
			return
		}
		
		let cleanURL = "https://coy.services/profile/\(userId)"
		
		// Validate URL
		guard URL(string: cleanURL) != nil else {
			print("❌ Invalid URL generated: \(cleanURL)")
			return
		}
		
		// Clear clipboard completely first to remove any binary data
		UIPasteboard.general.items = []
		
		// Set ONLY the URL string - no other data
		UIPasteboard.general.string = cleanURL
		
		showCopiedAlert = true
		print("📋 Copied profile URL (user ID-based) to clipboard: \(cleanURL)")
	}
	
	private var shareURL: URL? {
		// CRITICAL: Always use user ID in shareable links (never breaks when username changes)
		// Format: https://coy.services/profile/userId
		if let userId = Auth.auth().currentUser?.uid {
			return URL(string: "https://coy.services/profile/\(userId)")
		}
		return nil
	}
	
	// MARK: - Delete Account Section
	
	private var deleteAccountSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 12) {
				Text("Delete Your Account")
					.font(.subheadline)
					.fontWeight(.semibold)
					.foregroundColor(.primary)
					.padding(.horizontal)
				
				Text("Once you delete your account, there is no going back. All your data, collections, posts, and messages will be permanently deleted immediately.")
					.font(.caption)
					.foregroundColor(.secondary)
					.padding(.horizontal)
				
				Button(action: {
					showPasswordAlert = true
				}) {
					HStack {
						Spacer()
						if isDeleting {
							ProgressView()
								.progressViewStyle(CircularProgressViewStyle(tint: .white))
						} else {
							Text("Delete Account")
								.fontWeight(.semibold)
						}
						Spacer()
					}
					.foregroundColor(.white)
					.padding(.vertical, 12)
					.background(Color.red)
					.cornerRadius(8)
				}
				.disabled(isDeleting)
				.padding(.horizontal)
			}
			.padding(.vertical, 8)
			.background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.98))
			.cornerRadius(12)
			.padding(.horizontal)
		}
	}
	
	private func verifyPassword() {
		guard !password.isEmpty else { return }
		
		// Password is verified, now show confirmation
		showDeleteConfirmation = true
	}
	
	private func deleteAccount() async {
		guard !password.isEmpty else { return }
		
		isDeleting = true
		
		do {
			try await AccountDeletionService.shared.permanentlyDeleteAccount(password: password)
			
			// Account deleted successfully, sign out
			await MainActor.run {
				authService.signOut()
				// The app will handle navigation back to login
			}
		} catch {
			await MainActor.run {
				isDeleting = false
				password = ""
				
				// Check for incorrect password errors - show simple, user-friendly message
				let errorDescription = error.localizedDescription.lowercased()
				let errorString = String(describing: error).lowercased()
				
				// Check if this is a password/authentication error
				// Firebase Auth errors for wrong password include:
				// - "malformed or has expired" (credential error)
				// - "invalid credential"
				// - "wrong password"
				// - "incorrect password"
				// - Error codes: 17009, 17026
				let isPasswordError = errorDescription.contains("password") ||
									  errorDescription.contains("credential") ||
									  errorDescription.contains("malformed") ||
									  errorDescription.contains("expired") ||
									  errorDescription.contains("invalid") ||
									  errorString.contains("password") ||
									  errorString.contains("credential") ||
									  errorString.contains("malformed") ||
									  errorString.contains("expired") ||
									  errorString.contains("invalid")
				
				// Also check Firebase Auth error codes
				if let authError = error as NSError? {
					let errorCode = authError.code
					// Firebase Auth error codes for authentication failures
					if errorCode == 17009 || errorCode == 17026 || errorCode == 17010 || isPasswordError {
						deleteError = "Incorrect password. Please try again."
					} else {
						deleteError = "Failed to delete account: \(authError.localizedDescription)"
					}
				} else if isPasswordError {
					deleteError = "Incorrect password. Please try again."
				} else {
					deleteError = "Failed to delete account: \(error.localizedDescription)"
				}
			}
		}
	}
}

