import SwiftUI
import PhotosUI

struct CYSignupProfileView: View {

	@EnvironmentObject var authService: AuthService
	@Environment(\.dismiss) private var dismiss
	
	@State private var profileImage: UIImage?
	@State private var showImagePicker = false
	@State private var showBackgroundView = false
	@State private var isLoading = false
	@State private var errorMessage: String? = nil
	@Environment(\.colorScheme) var colorScheme

	// User data from signup
	var name: String
	var username: String
	var email: String
	var birthday: String
	var password: String = "" // Add password for email signup

	var body: some View {
		ScrollView {
			VStack(spacing: 30) {
				// Header
				headerView()
					.padding(.top, 40)
					.padding(.horizontal, 20)

				// Description
				descriptionText()
					.padding(.horizontal, 20)

				// Profile Image Selection
				profileImageSelectionView()
					.padding(.horizontal, 20)

				// Error Message
				if let error = errorMessage {
					Text(error)
						.foregroundStyle(.red)
						.font(.caption)
						.padding(.horizontal, 20)
				}
				
				// Next Button
				VStack(spacing: 15) {
					TKButton("Next") {
						// Just navigate to next screen - don't create account yet
						showBackgroundView = true
					}
					.disabled(false)
					.padding(.top, 30)
				}
				.padding(.horizontal, 20)
				.padding(.bottom, 40)
			}
		}
		.scrollContentBackground(.hidden)
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarBackButtonHidden(true)
		.fullScreenCover(isPresented: $showBackgroundView) {
			CYSignUpBackgroundimage(
				name: name,
				username: username,
				email: email,
				birthday: birthday,
				profileImage: profileImage
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
					UserDefaults.standard.removeObject(forKey: "pendingPhoneSignupData")
					print("🧹 Cleared pending sign-up data - user exited profile setup")
					dismiss()
				}
			}
		}
	}

	// MARK: - Header View
	@ViewBuilder
	private func headerView() -> some View {
		HStack {
			Text("Profile")
				.font(.title2)
				.fontWeight(.semibold)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Spacer()
			Button(action: {
				showBackgroundView = true
			}) {
				Text("Skip")
					.font(.headline)
					.foregroundColor(.blue)
					.padding()
			}
		}
	}

	// MARK: - Description
	@ViewBuilder
	private func descriptionText() -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Upload Profile Image")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Text("Choose a profile picture that easily identifies you")
				.font(.subheadline)
				.foregroundColor(.secondary)
		}
	}

	// MARK: - Profile Image Selection
	@ViewBuilder
	private func profileImageSelectionView() -> some View {
		Group {
			if let profileImage {
				Image(uiImage: profileImage)
					.resizable()
					.scaledToFill()
					.frame(width: 150, height: 150)
					.clipShape(Circle())
			} else {
				Circle()
					.stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
					.frame(width: 150, height: 150)
					.foregroundColor(.gray)
					.overlay {
						VStack {
							Image(systemName: "camera.fill")
								.resizable()
								.scaledToFit()
								.frame(width: 35, height: 35)
								.foregroundColor(.gray)
							Text("Browse here")
								.foregroundColor(.gray)
								.font(.subheadline)
						}
					}
			}
		}
		.frame(maxWidth: .infinity, alignment: .center)
		.contentShape(Rectangle())
		.onTapGesture { showImagePicker = true }
		.sheet(isPresented: $showImagePicker) {
			PhotoPicker(selectedImage: $profileImage)
		}
	}
}

