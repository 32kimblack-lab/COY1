import SwiftUI

struct MainTabView: View {

	@EnvironmentObject var authService: AuthService
	@State private var selectedTab = 0
	@State private var showCreateCollection = false

	var body: some View {
		TabView(selection: $selectedTab) {
			// Home
			CYHome()
				.tabItem {
					Image(systemName: selectedTab == 0 ? "house.fill" : "house")
					Text("Home")
				}
				.tag(0)

			// Search
			SearchView()
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
				.tabItem {
					Image(systemName: selectedTab == 3 ? "message.fill" : "message")
					Text("Messages")
				}
				.tag(3)

			// Profile
			ProfileView()
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
	}
}



