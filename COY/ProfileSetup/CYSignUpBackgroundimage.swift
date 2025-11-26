import SwiftUI
import PhotosUI

struct CYSignUpBackgroundimage: View {

	@EnvironmentObject var authService: AuthService
	@Environment(\.dismiss) private var dismiss
	
	// User data from signup
	var name: String = ""
	var username: String = ""
	var email: String = ""
	var birthday: String = ""
	var profileImage: UIImage?

	@State private var showImagePicker = false
	@State private var backgroundImage: UIImage?
	@State private var showProfile = false
	@State private var isLoading = false
	@State private var errorMessage: String? = nil

	@Environment(\.colorScheme) var colorScheme

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

				// Background selection area
				backgroundSelectionView()
					.padding(.horizontal, 20)

				// Error Message
				if let error = errorMessage {
					Text(error)
						.foregroundStyle(.red)
						.font(.caption)
						.padding(.horizontal, 20)
				}
				
				// Next button
				VStack(spacing: 15) {
					TKButton("Next") {
						// Just navigate to next screen
						showProfile = true
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
		.fullScreenCover(isPresented: $showProfile) {
			CYSignUpOverallProfile(
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
				showProfile = true
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
			Text("Choose a Background Image")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Text("Pick a background image for your profile page.")
				.font(.subheadline)
				.foregroundColor(.secondary)
		}
	}

	// MARK: - Background Selection
	@ViewBuilder
	private func backgroundSelectionView() -> some View {
		ZStack(alignment: .bottom) {
			// Background Image - zIndex 0 (behind)
			// Only show background if it exists - no placeholder
			if let backgroundImage {
				Image(uiImage: backgroundImage)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(height: 105)
					.clipped()
					.cornerRadius(1)
					.frame(maxWidth: .infinity)
					.zIndex(0)
			} else {
				// No background image - show dashed border placeholder
				RoundedRectangle(cornerRadius: 1)
					.stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
					.frame(height: 105)
					.frame(maxWidth: .infinity)
					.foregroundColor(.gray)
					.overlay {
						VStack {
							Image(systemName: "photo")
								.resizable()
								.scaledToFit()
								.frame(width: 30, height: 30)
								.foregroundColor(.gray)
							Text("Browse here")
								.foregroundColor(.gray)
								.font(.caption)
						}
					}
					.zIndex(0)
			}
			
			// Profile Image - zIndex 1 (in front)
			if let profileImage {
				Image(uiImage: profileImage)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: 70, height: 70)
					.clipShape(Circle())
					.overlay(
						Circle()
							.stroke(Color.white, lineWidth: 2)
					)
					.offset(y: 35)
					.zIndex(1)
			} else {
				DefaultProfileImageView(size: 70)
					.offset(y: 35)
					.zIndex(1)
			}
		}
		.frame(height: 140)
		.frame(maxWidth: .infinity, alignment: .center)
		.contentShape(Rectangle())
		.onTapGesture { showImagePicker = true }
		.sheet(isPresented: $showImagePicker) {
			PhotoPicker(selectedImage: $backgroundImage)
		}
	}
}


