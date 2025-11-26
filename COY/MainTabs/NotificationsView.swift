import SwiftUI
import FirebaseAuth

struct NotificationsView: View {
	@Binding var isPresented: Bool
	@EnvironmentObject var authService: AuthService
	@State private var notifications: [NotificationService.AppNotification] = []
	@State private var isLoading = true
	@State private var errorMessage: String?
	@State private var selectedJoinNotification: NotificationService.AppNotification?
	@State private var showingJoinedUsers = false
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
				Group {
					if isLoading {
						ProgressView()
							.frame(maxWidth: .infinity, maxHeight: .infinity)
					} else if notifications.isEmpty {
						VStack(spacing: 12) {
							Image(systemName: "bell.slash")
								.font(.system(size: 48))
								.foregroundColor(.secondary)
							Text("You have no notifications yet.")
								.foregroundColor(.secondary)
						}
						.frame(maxWidth: .infinity, maxHeight: .infinity)
					} else {
						ScrollView {
							LazyVStack(spacing: 12) {
								ForEach(notifications) { notification in
									NotificationRow(
										notification: notification,
										onAccept: {
											if notification.type == "collection_request" {
												handleAccept(notification: notification)
											} else if notification.type == "collection_invite" {
												handleAcceptInvite(notification: notification)
											}
										},
										onDeny: {
											if notification.type == "collection_request" {
												handleDeny(notification: notification)
											} else if notification.type == "collection_invite" {
												handleDenyInvite(notification: notification)
											}
										},
										onTap: {
											if notification.type == "collection_join" {
												selectedJoinNotification = notification
												showingJoinedUsers = true
											}
										}
									)
									.padding(.horizontal, 16)
								}
							}
							.padding(.vertical, 8)
						}
					}
				}
			}
			.navigationTitle("Notifications")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button {
						isPresented = false
					} label: {
						Image(systemName: "xmark")
							.font(.system(size: 16, weight: .semibold))
					}
					.accessibilityLabel("Close")
				}
			}
			.sheet(isPresented: $showingJoinedUsers) {
				if let notification = selectedJoinNotification {
					JoinedUsersView(notification: notification)
						.environmentObject(authService)
				}
			}
			.onAppear {
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestSent"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestAccepted"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRequestDenied"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionMembersJoined"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteSent"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteAccepted"))) { _ in
				loadNotifications()
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionInviteDenied"))) { _ in
				loadNotifications()
			}
		}
	}
	
	private func loadNotifications() {
		guard let currentUserId = Auth.auth().currentUser?.uid else {
			isLoading = false
			return
		}
		
		Task {
			do {
				let loadedNotifications = try await NotificationService.shared.getNotifications(userId: currentUserId)
				await MainActor.run {
					notifications = loadedNotifications
					isLoading = false
				}
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
					isLoading = false
				}
			}
		}
	}
	
	private func handleAccept(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId,
			  Auth.auth().currentUser?.uid != nil else {
			return
		}
		
		Task {
			do {
				try await CollectionService.shared.acceptCollectionRequest(
					collectionId: collectionId,
					requesterId: notification.userId,
					notificationId: notification.id
				)
				// Reload notifications
				loadNotifications()
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
				}
			}
		}
	}
	
	private func handleDeny(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId,
			  Auth.auth().currentUser?.uid != nil else {
			return
		}
		
		Task {
			do {
				try await CollectionService.shared.denyCollectionRequest(
					collectionId: collectionId,
					requesterId: notification.userId,
					notificationId: notification.id
				)
				// Reload notifications
				loadNotifications()
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
				}
			}
		}
	}
	
	private func handleAcceptInvite(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId else {
			return
		}
		
		Task {
			do {
				try await CollectionService.shared.acceptCollectionInvite(
					collectionId: collectionId,
					notificationId: notification.id
				)
				// Reload notifications
				loadNotifications()
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
				}
			}
		}
	}
	
	private func handleDenyInvite(notification: NotificationService.AppNotification) {
		guard let collectionId = notification.collectionId else {
			return
		}
		
		Task {
			do {
				try await CollectionService.shared.denyCollectionInvite(
					collectionId: collectionId,
					notificationId: notification.id
				)
				// Reload notifications
				loadNotifications()
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
				}
			}
		}
	}
}

struct NotificationRow: View {
	let notification: NotificationService.AppNotification
	let onAccept: () -> Void
	let onDeny: () -> Void
	let onTap: (() -> Void)?
	
	init(notification: NotificationService.AppNotification, onAccept: @escaping () -> Void, onDeny: @escaping () -> Void, onTap: (() -> Void)? = nil) {
		self.notification = notification
		self.onAccept = onAccept
		self.onDeny = onDeny
		self.onTap = onTap
	}
	
	var body: some View {
		HStack(spacing: 12) {
			// Profile Image
			if let profileImageURL = notification.userProfileImageURL, !profileImageURL.isEmpty {
				CachedProfileImageView(url: profileImageURL, size: 50)
					.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 50)
			}
			
			// Message
			VStack(alignment: .leading, spacing: 4) {
				Text(notification.message)
					.font(.subheadline)
					.foregroundColor(.primary)
				
				Text(timeAgoString(from: notification.createdAt))
					.font(.caption)
					.foregroundColor(.secondary)
			}
			
			Spacer()
			
			// Action Buttons (for pending collection requests and invites)
			if (notification.type == "collection_request" || notification.type == "collection_invite") && notification.status == "pending" {
				HStack(spacing: 6) {
					Button(action: onAccept) {
						Text("Accept")
							.font(.system(size: 12, weight: .semibold))
							.foregroundColor(.white)
							.frame(minWidth: 60, maxWidth: 60)
							.padding(.vertical, 6)
							.background(Color.blue)
							.cornerRadius(8)
					}
					.buttonStyle(.plain)
					
					Button(action: onDeny) {
						Text("Deny")
							.font(.system(size: 12, weight: .semibold))
							.foregroundColor(.white)
							.frame(minWidth: 60, maxWidth: 60)
							.padding(.vertical, 6)
							.background(Color.red)
							.cornerRadius(8)
					}
					.buttonStyle(.plain)
				}
			} else if notification.type == "collection_request" || notification.type == "collection_invite" {
				// Show status for accepted/denied requests/invites
				Text(notification.status == "accepted" ? "Accepted" : "Denied")
					.font(.caption)
					.foregroundColor(notification.status == "accepted" ? .green : .red)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background((notification.status == "accepted" ? Color.green : Color.red).opacity(0.1))
					.cornerRadius(6)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(Color(.systemBackground))
		.cornerRadius(12)
		.shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
		.onTapGesture {
			if notification.type == "collection_join" {
				onTap?()
			}
		}
	}
	
	private func timeAgoString(from date: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return formatter.localizedString(for: date, relativeTo: Date())
	}
}


