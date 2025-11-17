import SwiftUI

struct TermsOfServiceView: View {
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
					Text("Terms of Service")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
				VStack(alignment: .leading, spacing: 20) {
					VStack(alignment: .leading, spacing: 12) {
						Text("COY Terms of Service and Community Guidelines")
							.font(.title)
							.fontWeight(.bold)
							.foregroundColor(colorScheme == .dark ? .white : .black)
						
						Text("Last updated: [Insert Date]")
							.font(.subheadline)
							.foregroundColor(.secondary)
						
						Text("Welcome to COY! These Terms of Service (\"Terms\") and Community Guidelines (\"Guidelines\") govern your access to and use of the COY platform, services, and applications (\"COY,\" \"we,\" \"our,\" or \"us\"). By creating an account or using COY, you agree to these Terms. Please read them carefully.")
							.font(.body)
							.foregroundColor(colorScheme == .dark ? .white.opacity(0.9) : .black.opacity(0.8))
							.lineSpacing(4)
					}
					
					termsSection(
						title: "1. Eligibility",
						content: """
						• You must be at least 13 years old to use COY.
						• An open collection requires the user to be 18 or older.
						• By using COY, you confirm that you meet these requirements.
						"""
					)
					
					termsSection(
						title: "2. Community Guidelines",
						content: """
						To keep COY safe and enjoyable, users must follow these rules:
						
						• No nudity or sexually explicit content.
						• No graphic violence, blood, or gore.
						• No harassment, bullying, hate speech, or threats.
						• No illegal activity or promotion of illegal activity.
						• Respect intellectual property rights. Only post content you own or have permission to share.
						
						Violation of these rules may result in removal of content, suspension, or termination of your account.
						"""
					)
					
					termsSection(
						title: "3. Collections",
						content: """
						COY is built around "Collections." Collections allow users to organize and share posts in different ways. There are four types of collections:
						
						1. Individual Collection – Only the owner can post.
						2. Invite Collection – Owners can invite others to post, and members can invite the owner to join.
						3. Request Collection – Users must request and be approved by the owner before posting.
						4. Open Collection – Anyone can join and post without requesting or being invited. An open collection requires the user to be 18 or older.
						
						Public vs. Private Viewing:
						• Individual and Invite Collections can be public or private.
						• Request and Open Collections must be public so users can see them before requesting or joining.
						
						Owners and Members:
						• Owner: The person who created the collection. Owners can:
						  - Add or remove members
						  - Promote members to co-owners
						  - Delete posts within the collection
						  - Delete the collection entirely
						  - Manage viewing and posting permissions
						• Member: A participant in the collection. Members can:
						  - Post content (depending on collection type)
						  - Delete their own posts
						  - Cannot control or delete others' posts or the collection itself
						"""
					)
					
					termsSection(
						title: "4. Privacy & Visibility Rules",
						content: """
						• Only you (the owner) can see who has saved or started your posts. Other users cannot see this.
						• Only you can see the collections you follow.
						• Only you can see who is following your collections.
						• Owners have access to see who can view and follow their collections.
						• Invite Collections are the exception: everyone can see who can view and follow them.
						"""
					)
					
					termsSection(
						title: "5. Your Content",
						content: """
						• You own the content you post on COY.
						• By posting on COY, you grant us a limited, non-exclusive license to host, display, and share your content as needed to operate the platform.
						• We do not claim ownership of your content.
						"""
					)
					
					termsSection(
						title: "6. Enforcement",
						content: """
						We reserve the right to:
						
						• Remove any content that violates these Terms or Guidelines.
						• Suspend or terminate accounts that break the rules.
						• Restrict access to certain features if necessary.
						"""
					)
					
					termsSection(
						title: "7. Safety",
						content: """
						• Do not share personal information you don't want others to see.
						• Report inappropriate behavior or content through our reporting tools.
						• COY is not responsible for interactions between users but will enforce community safety standards.
						"""
					)
					
					termsSection(
						title: "8. Changes to These Terms",
						content: """
						We may update these Terms and Guidelines from time to time. We will notify users of significant changes, and continued use of COY means you accept the updated Terms.
						"""
					)
					
					termsSection(
						title: "9. Contact Us",
						content: """
						If you have questions about these Terms or Guidelines, please contact us at:
						teamcoy.social@gmail.com
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
	
	private func termsSection(title: String, content: String) -> some View {
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

