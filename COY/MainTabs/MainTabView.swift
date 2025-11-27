import SwiftUI

struct MainTabView: View {

	@EnvironmentObject var authService: AuthService
	@State private var selectedTab = 0
	@State private var showCreateCollection = false
	@StateObject private var deepLinkManager = DeepLinkManager.shared
	@State private var selectedProfileUserId: String?
	@State private var totalUnreadCount = 0
	@State private var friendRequestCount = 0
	
	private var badgeCount: Int? {
		totalUnreadCount > 0 ? totalUnreadCount : nil
	}

	var body: some View {
		TabView(selection: $selectedTab) {
			// Home
			CYHome()
				.phoneSizeContainer()
				.dismissKeyboardOnTap()
				.tabItem {
					Image(systemName: selectedTab == 0 ? "house.fill" : "house")
					Text("Home")
				}
				.tag(0)

			// Search
			SearchView()
				.environmentObject(authService)
				.phoneSizeContainer()
				.dismissKeyboardOnTap()
				.tabItem {
					Image(systemName: selectedTab == 1 ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
					Text("Search")
				}
				.tag(1)

			// Create (plus)
			Color.clear
				.tabItem {
					Image(systemName: "plus.circle.fill")
					Text("Create")
				}
				.tag(2)

			// Messages
			MessagesView()
				.phoneSizeContainer()
				.dismissKeyboardOnTap()
				.tabItem {
					Image(systemName: selectedTab == 3 ? "message.fill" : "message")
					Text("Messages")
				}
				.tag(3)
				.badge(badgeCount ?? 0)

			// Profile
			ProfileView()
				.phoneSizeContainer()
				.dismissKeyboardOnTap()
				.tabItem {
					Image(systemName: selectedTab == 4 ? "person.fill" : "person")
					Text("Profile")
				}
				.tag(4)
		}
		.accentColor(.blue)
		.onChange(of: selectedTab) { oldValue, newValue in
			// When plus button tab is selected, show create sheet and reset tab
			if newValue == 2 {
				showCreateCollection = true
				DispatchQueue.main.async { selectedTab = oldValue }
			}
		}
		.sheet(isPresented: $showCreateCollection) {
			CYBuildCollectionDesign()
				.onDisappear {
					if selectedTab == 2 { selectedTab = 0 }
				}
		}
		.navigationDestination(isPresented: Binding(
			get: { selectedProfileUserId != nil },
			set: { if !$0 { selectedProfileUserId = nil; deepLinkManager.clearPendingNavigation() } }
		)) {
			if let userId = selectedProfileUserId {
				ViewerProfileView(userId: userId)
					.environmentObject(authService)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToUserProfile"))) { notification in
			if let userId = notification.object as? String {
				print("🔗 MainTabView: Received NavigateToUserProfile notification for userId: \(userId)")
				selectedProfileUserId = userId
			} else if let userInfo = notification.userInfo,
					  let userId = userInfo["userId"] as? String {
				print("🔗 MainTabView: Received NavigateToUserProfile notification for userId: \(userId)")
				selectedProfileUserId = userId
			}
		}
		.onChange(of: deepLinkManager.shouldNavigateToProfile) { oldValue, newValue in
			if newValue, let userId = deepLinkManager.pendingProfileUserId {
				print("🔗 MainTabView: DeepLinkManager triggered navigation to userId: \(userId)")
				selectedProfileUserId = userId
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TotalUnreadCountChanged"))) { notification in
			if let userInfo = notification.userInfo,
			   let count = userInfo["count"] as? Int {
				totalUnreadCount = count
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FriendRequestCountChanged"))) { notification in
			if let userInfo = notification.userInfo,
			   let count = userInfo["count"] as? Int {
				friendRequestCount = count
			}
		}
	}
}



