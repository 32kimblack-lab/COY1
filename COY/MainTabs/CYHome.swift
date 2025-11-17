import SwiftUI

// MARK: - Static Cache for CYHome
class HomeViewCache {
	static let shared = HomeViewCache()
	private init() {}
	
	private var hasLoadedDataOnce = false
	private var cachedFollowedCollections: [CollectionData] = []
	private var cachedPostsWithCollections: [(post: CollectionPost, collection: CollectionData)] = []
	private var cachedFollowedCollectionIds: Set<String> = []
	
	func hasDataLoaded() -> Bool {
		return hasLoadedDataOnce
	}
	
	func getCachedData() -> (collections: [CollectionData], postsWithCollections: [(post: CollectionPost, collection: CollectionData)], followedIds: Set<String>) {
		return (cachedFollowedCollections, cachedPostsWithCollections, cachedFollowedCollectionIds)
	}
	
	func setCachedData(collections: [CollectionData], postsWithCollections: [(post: CollectionPost, collection: CollectionData)], followedIds: Set<String>) {
		self.cachedFollowedCollections = collections
		self.cachedPostsWithCollections = postsWithCollections
		self.cachedFollowedCollectionIds = followedIds
		self.hasLoadedDataOnce = true
	}
	
	func clearCache() {
		hasLoadedDataOnce = false
		cachedFollowedCollections.removeAll()
		cachedPostsWithCollections.removeAll()
		cachedFollowedCollectionIds.removeAll()
	}
	
	func matchesCurrentFollowedIds(_ currentIds: Set<String>) -> Bool {
		return cachedFollowedCollectionIds == currentIds
	}
}

struct CYHome: View {
	
	@Environment(\.colorScheme) var colorScheme
	@State private var isMenuOpen = false
	@State private var followedCollections: [CollectionData] = []
	@State private var postsWithCollections: [(post: CollectionPost, collection: CollectionData)] = []
	@State private var isLoading = false
	@State private var selectedPost: CollectionPost?
	@State private var selectedCollection: CollectionData?
	@State private var isLoadingMore = false
	@State private var hasMoreData = true
	@State private var lastPostTimestamp: Date?
	@State private var showNotifications = false
	@State private var unreadNotificationCount = 0
	private let pageSize = 20
	
	var body: some View {
		NavigationStack {
			ZStack {
				// Main Content
				VStack(spacing: 0) {
					// Custom Header
					HStack {
						HStack {
							Image(systemName: "line.3.horizontal")
								.resizable()
								.frame(width: 25, height: 25)
								.foregroundColor(colorScheme == .dark ? .white : .black)
								.onTapGesture {
									withAnimation(.easeInOut(duration: 0.3)) {
										isMenuOpen.toggle()
									}
								}
							
							Text("COY")
								.font(.system(size: 28, weight: .bold))
								.foregroundColor(colorScheme == .dark ? .white : .black)
							
							if let uiImage = UIImage(named: "Icon") {
								Image(uiImage: uiImage)
									.resizable()
									.scaledToFit()
									.frame(width: 40, height: 40)
									.padding(.leading, -15)
							} else {
								EmptyView()
							}
						}
						
						Spacer()
						
						HStack(spacing: 15) {
							NavigationLink(destination: Text("Add User View")) {
								Image(systemName: "person.badge.plus")
									.resizable()
									.frame(width: 25, height: 25)
									.foregroundColor(colorScheme == .dark ? .white : .black)
							}
							
							Button(action: {
								showNotifications = true
							}) {
								ZStack(alignment: .topTrailing) {
									Image(systemName: "bell.fill")
										.resizable()
										.frame(width: 25, height: 25)
										.foregroundColor(colorScheme == .dark ? .white : .black)
									
									if unreadNotificationCount > 0 {
										Text("\(unreadNotificationCount)")
											.font(.caption2)
											.fontWeight(.bold)
											.foregroundColor(.white)
											.padding(4)
											.background(Color.red)
											.clipShape(Circle())
											.offset(x: 8, y: -8)
									}
								}
							}
							.fullScreenCover(isPresented: $showNotifications) {
								NotificationsView(isPresented: $showNotifications)
							}
						}
					}
					.padding(.horizontal)
					.padding(.top, 8)
					.background(colorScheme == .dark ? Color.black : Color.white)
					
					// Posts content
					if isLoading {
						ProgressView("Loading posts...")
							.frame(maxWidth: .infinity, maxHeight: .infinity)
					} else if postsWithCollections.isEmpty {
						emptyStateView
					} else {
						postsView
					}
				}
				.scaleEffect(isMenuOpen ? 0.95 : 1.0)
				.animation(.easeInOut(duration: 0.3), value: isMenuOpen)
				
				// Side Menu Overlay (invisible - for tap to close)
				if isMenuOpen {
					Color.clear
						.ignoresSafeArea()
						.onTapGesture {
							withAnimation(.easeInOut(duration: 0.3)) {
								isMenuOpen = false
							}
						}
				}
				
				// Side Menu
				HStack {
					sideMenuView
						.frame(width: 320)
						.background(colorScheme == .dark ? Color.black : Color.white)
						.offset(x: isMenuOpen ? 0 : -320)
						.animation(.easeInOut(duration: 0.3), value: isMenuOpen)
					
					Spacer()
				}
			}
		}
	}
	
	private var emptyStateView: some View {
		VStack(spacing: 12) {
			Image(systemName: "tray")
				.font(.system(size: 42))
				.foregroundColor(.secondary)
			Text("No posts yet")
				.font(.headline)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	private var postsView: some View {
		List {
			ForEach(postsWithCollections.indices, id: \.self) { index in
				let item = postsWithCollections[index]
				Button {
					selectedPost = item.post
					selectedCollection = item.collection
				} label: {
					HStack {
						Text(item.collection.title)
							.font(.headline)
						Spacer()
						Text(item.post.title)
							.foregroundColor(.secondary)
					}
				}
				.onAppear {
					if index == postsWithCollections.count - 3 {
						loadMoreIfNeeded()
					}
				}
			}
			
			if isLoadingMore {
				HStack {
					Spacer()
					ProgressView()
					Spacer()
				}
			} else if !hasMoreData {
				HStack {
					Spacer()
					Text("No more posts")
						.font(.footnote)
						.foregroundColor(.secondary)
					Spacer()
				}
			}
		}
		.listStyle(.plain)
	}
	
	private var sideMenuView: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack {
				Text("Following")
					.font(.title2)
					.fontWeight(.semibold)
				Spacer()
				Button(action: { withAnimation { isMenuOpen = false } }) {
					Image(systemName: "xmark")
						.font(.system(size: 16, weight: .semibold))
				}
				.accessibilityLabel("Close menu")
			}
			
			Button {
				withAnimation { isMenuOpen = false }
			} label: {
				EmptyView()
			}
			
			Spacer()
		}
		.padding()
	}
	
	private func loadMoreIfNeeded() {
		guard !isLoadingMore, hasMoreData else { return }
		isLoadingMore = true
		// Placeholder pagination logic; wire to your data source
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
			isLoadingMore = false
			hasMoreData = false
		}
	}
}

