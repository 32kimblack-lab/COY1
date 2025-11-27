import SwiftUI
import FirebaseFirestore
import SafariServices

struct CYSettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	@State private var showLogoutAlert = false
	@State private var showPrivacyPolicy = false
	@State private var showTermsOfService = false
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				ScrollView {
				settingsContent
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.navigationBarBackButtonHidden(true)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(action: { dismiss() }) {
						Image(systemName: "chevron.left")
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
				}
			}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.toolbar(.hidden, for: .tabBar)
		.alert("Log Out", isPresented: $showLogoutAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Log Out", role: .destructive) {
				authService.signOut()
			}
		} message: {
			Text("Are you sure you want to log out?")
		}
		.sheet(isPresented: $showPrivacyPolicy) {
			if let url = URL(string: "https://coy.services/privacy") {
				SafariViewController(url: url)
			}
		}
		.sheet(isPresented: $showTermsOfService) {
			if let url = URL(string: "https://coy.services/terms") {
				SafariViewController(url: url)
			}
		}
	}
	
	private var settingsContent: some View {
		VStack(alignment: .leading, spacing: 32) {
			VStack(alignment: .leading, spacing: 32) {
				profileSettingsSection
				myAccountSection
				supportSection
			}
			.padding(.vertical)
		}
	}
	
	private var profileSettingsSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Profile Settings")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
				.padding(.horizontal)
			NavigationLink(destination: AccountManagementView()) {
				SettingsRow(title: "Account Management", icon: "person.2.fill")
			}
		}
	}
	
	private var myAccountSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("My Account")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
				.padding(.horizontal)
			VStack(spacing: 16) {
				NavigationLink(destination: StarredView()) {
					SettingsRow(title: "Starred", icon: "star.fill")
				}
				NavigationLink(destination: DeletedCollectionsView()) {
					SettingsRow(title: "Deleted Collections", icon: "trash.fill")
				}
				NavigationLink(destination: BlockedAccountsView()) {
					SettingsRow(title: "Blocked Accounts", icon: "nosign")
				}
				NavigationLink(destination: HiddenCollectionsView()) {
					SettingsRow(title: "Hidden Collections", icon: "eye.slash")
				}
			}
		}
	}
	
	private var supportSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Support")
				.font(.headline)
				.foregroundColor(colorScheme == .dark ? .white : .black)
				.padding(.horizontal)
			VStack(spacing: 16) {
				NavigationLink(destination: AboutUsView()) {
					SettingsRow(title: "About Us", icon: "info.circle.fill")
				}
				Button(action: {
					showPrivacyPolicy = true
				}) {
					SettingsRow(title: "Privacy Policy", icon: "lock.shield.fill")
				}
				Button(action: {
					showTermsOfService = true
				}) {
					SettingsRow(title: "Terms of Service", icon: "doc.text.fill")
				}
				Button(action: {
					showLogoutAlert = true
				}) {
					SettingsRow(title: "Log out", icon: "power", isDestructive: true)
				}
			}
		}
	}
}
