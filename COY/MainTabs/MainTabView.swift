import SwiftUI
import UIKit

struct MainTabView: View {

	@EnvironmentObject var authService: AuthService
	@State private var selectedTab = 0
	@State private var lastSelectedTab = -1
	@StateObject private var deepLinkManager = DeepLinkManager.shared
	@State private var selectedProfileUserId: String?
	@State private var totalUnreadCount = 0
	@State private var friendRequestCount = 0
	@State private var navigateToBuildCollection = false
	
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

			// Create (plus) - Same CYBuildCollectionDesign view as ProfileView (directly shown for fast performance)
			CreateTabView()
				.environmentObject(authService)
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
		.background(
			TabBarTapDetector(selectedTab: $selectedTab, lastSelectedTab: $lastSelectedTab)
		)
		.onAppear {
			// Initialize lastSelectedTab
			lastSelectedTab = selectedTab
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

// Helper view for Create tab - shows CYBuildCollectionDesign directly (same view as ProfileView navigates to)
struct CreateTabView: View {
	@EnvironmentObject var authService: AuthService
	
	var body: some View {
		NavigationStack {
			// Show CYBuildCollectionDesign directly - same view ProfileView navigates to
			// This ensures fast performance like ProfileView
			CYBuildCollectionDesign()
				.environmentObject(authService)
		}
	}
}

// Helper to detect tab bar taps using UITabBarController
struct TabBarTapDetector: UIViewControllerRepresentable {
	@Binding var selectedTab: Int
	@Binding var lastSelectedTab: Int
	
	func makeUIViewController(context: Context) -> UIViewController {
		let controller = UIViewController()
		DispatchQueue.main.async {
			if let tabBarController = controller.tabBarController {
				// Store reference to coordinator
				context.coordinator.tabBarController = tabBarController
				tabBarController.delegate = context.coordinator
			}
		}
		return controller
	}
	
	func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
		if let tabBarController = uiViewController.tabBarController {
			context.coordinator.tabBarController = tabBarController
			tabBarController.delegate = context.coordinator
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(selectedTab: $selectedTab, lastSelectedTab: $lastSelectedTab)
	}
	
	class Coordinator: NSObject, UITabBarControllerDelegate {
		@Binding var selectedTab: Int
		@Binding var lastSelectedTab: Int
		weak var tabBarController: UITabBarController?
		
		init(selectedTab: Binding<Int>, lastSelectedTab: Binding<Int>) {
			_selectedTab = selectedTab
			_lastSelectedTab = lastSelectedTab
		}
		
		func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
			let newIndex = tabBarController.viewControllers?.firstIndex(of: viewController) ?? -1
			let currentIndex = tabBarController.selectedIndex
			
			// If tapping the same tab, scroll to top
			if newIndex == currentIndex && newIndex != -1 {
				switch newIndex {
				case 0: // Home
					NotificationCenter.default.post(name: NSNotification.Name("ScrollToTopHome"), object: nil)
				case 1: // Search/Discover
					NotificationCenter.default.post(name: NSNotification.Name("ScrollToTopSearch"), object: nil)
				case 3: // Messages
					NotificationCenter.default.post(name: NSNotification.Name("ScrollToTopMessages"), object: nil)
				case 4: // Profile
					NotificationCenter.default.post(name: NSNotification.Name("ScrollToTopProfile"), object: nil)
				default:
					break
				}
				return false // Prevent tab change
			}
			
			selectedTab = newIndex
			return true
		}
	}
}

