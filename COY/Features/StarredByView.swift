import SwiftUI
import SDWebImageSwiftUI
import FirebaseAuth

struct StarredByView: View {
	let postId: String
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@EnvironmentObject var authService: AuthService
	@State private var users: [CYUser] = []
	@State private var isLoading = true
	
	var body: some View {
		NavigationStack {
			ZStack {
				// Background
				Color(colorScheme == .dark ? .black : .white)
					.ignoresSafeArea()
				
				if isLoading {
					ProgressView()
				} else if users.isEmpty {
					VStack(spacing: 16) {
						Image(systemName: "star")
							.font(.system(size: 50))
							.foregroundColor(.secondary)
						Text("No stars yet")
							.font(.headline)
							.foregroundColor(.secondary)
						Text("Be the first to star this post!")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
				} else {
					List {
						ForEach(users) { user in
							NavigationLink(destination: ViewerProfileView(userId: user.id).environmentObject(authService)) {
								HStack(spacing: 12) {
									// Profile Picture
									if !user.profileImageURL.isEmpty, let url = URL(string: user.profileImageURL) {
										WebImage(url: url) { image in
											image
												.resizable()
												.scaledToFill()
										} placeholder: {
											Circle()
												.fill(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.8))
										}
										.indicator(.activity)
										.frame(width: 50, height: 50)
										.clipShape(Circle())
									} else {
										Circle()
											.fill(colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.8))
											.frame(width: 50, height: 50)
											.overlay(
												Image(systemName: "person.fill")
													.foregroundColor(.secondary)
													.font(.system(size: 20))
											)
									}
									
									// Username
									VStack(alignment: .leading, spacing: 4) {
										Text(user.username)
											.font(.system(size: 15, weight: .semibold))
											.foregroundColor(.primary)
										if !user.name.isEmpty {
											Text(user.name)
												.font(.system(size: 14))
												.foregroundColor(.secondary)
										}
									}
									
									Spacer()
								}
								.padding(.vertical, 4)
							}
							.listRowBackground(Color.clear)
						}
					}
					.listStyle(PlainListStyle())
					.scrollContentBackground(.hidden)
				}
			}
			.navigationTitle("Starred by")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
			.onAppear {
				Task {
					await loadStarredByUsers()
				}
			}
		}
	}
	
	private func loadStarredByUsers() async {
		isLoading = true
		do {
			let fetchedUsers = try await UpdatesService.shared.fetchStarredByUsers(postId: postId)
			await MainActor.run {
				self.users = fetchedUsers
				self.isLoading = false
			}
		} catch {
			print("❌ StarredByView: Error loading starred by users: \(error)")
			await MainActor.run {
				self.isLoading = false
			}
		}
	}
}

