import SwiftUI
import UIKit
import FirebaseAuth


struct InviteShareView: View {

	@EnvironmentObject var authService: AuthService
	@Environment(\.dismiss) private var dismiss
	
	@State private var showShareSheet = false
	
	// User data properties
	var name: String
	var username: String
	var email: String
	var birthday: String
	
	// Image properties
	var profileImage: UIImage?
	var backgroundImage: UIImage?
	
	var body: some View {
		NavigationStack {
			VStack(spacing: 50) {
				Spacer()
				
				// Friends Icon
				Image(systemName: "person.3.fill")
					.resizable()
					.scaledToFit()
					.frame(width: 120, height: 120)
					.foregroundColor(.blue)
				
				// Message
				Text("Invite friends for a better experience at COY")
					.font(.title2)
					.fontWeight(.medium)
					.foregroundColor(.primary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 40)
				
				Spacer()
				
				// Share Button
				VStack(spacing: 20) {
					TKButton("Share Invite", iconName: "square.and.arrow.up") {
						showShareSheet = true
					}
					.foregroundColor(.black)
				}
				.padding(.horizontal, 20)
				
				Spacer()
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Skip") {
						Task {
							// Ensure auth state is properly refreshed before clearing flag
							if let currentUser = Auth.auth().currentUser {
								print("🔄 Refreshing auth state before navigating...")
								
								// CRITICAL: Load user data before navigating to ensure profile shows correctly
								do {
									// Clear user cache to force fresh fetch
									if let currentUserId = Auth.auth().currentUser?.uid {
										UserService.shared.clearUserCache(userId: currentUserId)
										print("🗑️ Cleared user cache before navigation")
									}
									
									try await CYServiceManager.shared.loadCurrentUser()
									print("✅ User data loaded before navigation")
									
									// Post notification to ensure ProfileView refreshes
									if let updatedUser = CYServiceManager.shared.currentUser {
										await MainActor.run {
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
								} catch {
									print("⚠️ Failed to load user data: \(error)")
								}
								
								// Force refresh profile status to ensure everything is loaded
								await authService.checkProfileSetupStatus(user: currentUser)
								print("✅ Profile status checked")
								
								// Reload user data from Firebase
								try? await CYServiceManager.shared.loadCurrentUser()
								print("✅ User data reloaded")
							}
							
							// Small delay to ensure state updates propagate
							try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
							
							print("✅ Clearing sign-up flow flag and dismissing...")
							
							// Clear sign-up flow flag - this will let ContentView show MainTabView
							await MainActor.run {
								authService.setInSignUpFlow(false)
							}
							
							// Dismiss this view - ContentView will handle showing MainTabView
							await MainActor.run {
								dismiss()
							}
						}
					}
					.foregroundColor(.blue)
				}
			}
			.navigationBarBackButtonHidden(true)
			.sheet(isPresented: $showShareSheet) {
				ShareSheet(activityItems: [createInviteContent()])
			}
		}
	}
	
	private func createInviteContent() -> String {
		// App Store download link
		let appStoreURL = "https://apps.apple.com/app/coy" // Update with actual App Store ID when available
		
		return """
		Join me on COY!     
		
		COY is a social platform where you can create and share collections with friends.
		
		Download from App Store: \(appStoreURL)
		
		#COY #SocialMedia #Collections
		"""
	}
}

#Preview {
	InviteShareView(
		name: "Test User",
		username: "testuser",
		email: "test@example.com",
		birthday: "January 1, 2000",
		profileImage: nil,
		backgroundImage: nil
	)
	.environmentObject(AuthService())
}

// MARK: - Inline ShareSheet to reduce extra files
private struct ShareSheet: UIViewControllerRepresentable {
	let activityItems: [Any]
	let applicationActivities: [UIActivity]? = nil

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
	}

	func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

