import SwiftUI
import UIKit

struct MainTabView: View {

	@EnvironmentObject var authService: AuthService
	@State private var selectedTab = 0
	@StateObject private var deepLinkManager = DeepLinkManager.shared
	@State private var selectedProfileUserId: String?
	@State private var totalUnreadCount = 0
	@State private var friendRequestCount = 0
	
	private var badgeCount: Int? {
		totalUnreadCount > 0 ? totalUnreadCount : nil
	}
	
	init() {
		// Ensure tab bar uses default iOS appearance
		let appearance = UITabBarAppearance()
		appearance.configureWithDefaultBackground()
		UITabBar.appearance().standardAppearance = appearance
		UITabBar.appearance().scrollEdgeAppearance = appearance
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

			// Create (plus) - Full screen navigation view
			NavigationStack {
				CYBuildCollectionDesign()
					.environmentObject(authService)
			}
			.phoneSizeContainer()
			.tabItem {
				Image(systemName: selectedTab == 2 ? "plus.circle.fill" : "plus.circle")
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
		.toolbarBackground(.automatic, for: .tabBar)
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
				#if DEBUG
				print("🔗 MainTabView: Received NavigateToUserProfile notification for userId: \(userId)")
				#endif
				selectedProfileUserId = userId
			} else if let userInfo = notification.userInfo,
					  let userId = userInfo["userId"] as? String {
				#if DEBUG
				print("🔗 MainTabView: Received NavigateToUserProfile notification for userId: \(userId)")
				#endif
				selectedProfileUserId = userId
			}
		}
		.onChange(of: deepLinkManager.shouldNavigateToProfile) { oldValue, newValue in
			if newValue, let userId = deepLinkManager.pendingProfileUserId {
				#if DEBUG
				print("🔗 MainTabView: DeepLinkManager triggered navigation to userId: \(userId)")
				#endif
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
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToTab"))) { notification in
			// Handle back button from Create tab - switch to Home tab
			if let userInfo = notification.userInfo,
			   let tabIndex = userInfo["tabIndex"] as? Int {
				selectedTab = tabIndex
			}
		}
	}
}



