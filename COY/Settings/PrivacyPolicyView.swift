import SwiftUI

struct PrivacyPolicyView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				HStack {
					Button(action: { presentationMode.wrappedValue.dismiss() }) {
						Image(systemName: "chevron.left")
							.font(.system(size: 18, weight: .medium))
							.foregroundColor(colorScheme == .dark ? .white : .black)
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					}
					Spacer()
					Text("Privacy Policy")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
				VStack(alignment: .leading, spacing: 20) {
					VStack(alignment: .leading, spacing: 12) {
						Text("COY Privacy Policy")
							.font(.title)
							.fontWeight(.bold)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						
						Text("09/30/2025")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					
					policySection(
						title: "1. Information We Collect",
						content: """
						We may collect the following:
						
						• Account Information: Username, email, password, date of birth, and profile details.
						• Content You Share: Collections, posts, photos, videos, messages, and replies.
						• Usage Data: App interactions, device information (IP address, operating system, device type), and log activity.
						• Ad & Analytics Data: Interests, preferences, and app behavior to personalize ads and recommendations.
						"""
					)
					
					policySection(
						title: "2. How We Use Your Information",
						content: """
						We use your information to:
						
						• Operate, maintain, and improve COY.
						• Keep accounts secure and prevent misuse.
						• Personalize your experience (suggest collections, posts, or users).
						• Show you relevant ads based on your activity and interests.
						• Communicate with you about updates, features, or security issues.
						"""
					)
					
					policySection(
						title: "3. How We Share Information",
						content: """
						We do not sell personal identifiers (like your name, email, or password).
						However, we may share limited data with trusted partners to:
						
						• Provide personalized ads based on your activity and preferences.
						• Measure ad performance and improve advertising relevance.
						• Support platform operations (hosting, analytics, or content moderation).
						
						Examples of shared data for ads:
						• General demographics (age range, interests, device type).
						• Activity data (collections you follow, types of posts you interact with).
						
						We never share private messages or sensitive account details with advertisers.
						"""
					)
					
					policySection(
						title: "4. Content Visibility",
						content: """
						• Open collections are viewable by all users.
						• Other collections may be private, invite-only, or request-based.
						• You control what you post and who can see it.
						"""
					)
					
					policySection(
						title: "5. Age Requirements",
						content: """
						• You must be 13 years or older to use COY.
						• An open collection requires the user to be 18 or older.
						• Accounts created by anyone under 13 will be removed.
						"""
					)
					
					policySection(
						title: "6. Data Retention",
						content: """
						• Your data is stored as long as your account is active.
						• Deleted collections remain recoverable for 30 days before permanent deletion.
						• Some data may be retained as required by law or for security purposes.
						"""
					)
					
					policySection(
						title: "7. Security",
						content: """
						We use technical safeguards to protect your data, but no system is fully secure. Please use a strong password and report suspicious activity.
						"""
					)
					
					policySection(
						title: "8. Your Choices",
						content: """
						• Control ad preferences in your account settings.
						• Manage your profile visibility and collection privacy.
						• Delete your account anytime to remove your data from COY.
						"""
					)
					
					policySection(
						title: "9. Changes to This Policy",
						content: """
						We may update this Privacy Policy as COY grows. Major updates will be shared in the app or via email.
						"""
					)
					
					policySection(
						title: "10. Contact Us",
						content: """
						If you have questions about this policy, contact us at: teamcoy.social@gmail.com
						"""
					)
				}
				.padding(.horizontal, 20)
				
				Spacer(minLength: 40)
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
	}
	
	private func policySection(title: String, content: String) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title)
				.font(.headline)
				.fontWeight(.semibold)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			
			Text(content)
				.font(.body)
				.foregroundColor(colorScheme == .dark ? .white.opacity(0.9) : .black.opacity(0.8))
				.lineSpacing(4)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

