import SwiftUI
import FirebaseAuth

struct SearchView: View {
	@State private var searchText = ""
	@State private var selectedTab: Int = 0
	@State private var collections: [CollectionData] = []
	@State private var posts: [CollectionPost] = []
	@State private var isLoadingCollections = false
	@State private var isLoadingPosts = false
	@State private var searchTask: Task<Void, Never>?
	@Environment(\.colorScheme) private var colorScheme
	
	private let apiClient = APIClient.shared

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				header
				
				searchBar
					.padding(.horizontal)
					.padding(.top, 8)

				tabSwitcher
					.padding(.top, 16)
					.padding(.bottom, 8)

				content
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.navigationBarHidden(true)
			.onAppear {
				// Load initial data when view appears
				Task {
					await performSearch()
				}
			}
		}
	}

	private var header: some View {
		HStack {
			Spacer()
			Text("Discover")
				.font(.system(size: 24, weight: .bold))
				.foregroundColor(.primary)
			Spacer()
			Image(systemName: "magnifyingglass")
				.font(.system(size: 20, weight: .semibold))
				.padding(.trailing, 4)
		}
		.padding(.horizontal)
		.padding(.top, 8)
	}
	
	private var searchBar: some View {
		HStack {
			Image(systemName: "magnifyingglass")
				.foregroundColor(.secondary)
			TextField("Search...", text: $searchText)
				.textFieldStyle(.plain)
				.onChange(of: searchText) { _, _ in
					// Cancel previous search task
					searchTask?.cancel()
					
					// Debounce search
					searchTask = Task {
						try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
						if !Task.isCancelled {
							await performSearch()
						}
					}
				}
			
			if !searchText.isEmpty {
				Button {
					searchText = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundColor(.secondary)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(Color(.systemGray6))
		.cornerRadius(10)
	}

	private var tabSwitcher: some View {
		VStack(spacing: 10) {
			HStack(spacing: 40) {
				tabButton(title: "Collections", index: 0)
				tabButton(title: "Post", index: 1)
				tabButton(title: "Usernames", index: 2)
			}
			.padding(.horizontal, 24)

			// Moving underline
			GeometryReader { proxy in
				let width = (proxy.size.width - 0) / 3 // 3 tabs
				let underlineFraction: CGFloat = 0.9
				ZStack(alignment: .leading) {
					Rectangle()
						.fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.15))
						.frame(height: 1)
					Rectangle()
						.fill(colorScheme == .dark ? .white : .black)
						.frame(width: width * underlineFraction, height: 3)
						.offset(x: underlineOffset(totalWidth: proxy.size.width, fraction: underlineFraction))
						.animation(.easeInOut(duration: 0.25), value: selectedTab)
				}
			}
			.frame(height: 2)
			.padding(.horizontal)
		}
	}

	private func tabButton(title: String, index: Int) -> some View {
		Button {
			withAnimation {
				selectedTab = index
			}
			// Perform search when switching tabs
			Task {
				await performSearch()
			}
		} label: {
			Text(title)
				.font(.system(size: 16, weight: selectedTab == index ? .semibold : .regular))
				.foregroundColor(selectedTab == index ? .primary : .secondary)
		}
		.buttonStyle(.plain)
	}

	private func underlineOffset(totalWidth: CGFloat, fraction: CGFloat) -> CGFloat {
		let cellWidth = totalWidth / 3
		// Center the underline (fraction of the cell width) inside each tab cell
		let inset = (cellWidth - (cellWidth * fraction)) / 2
		return CGFloat(selectedTab) * cellWidth + inset
	}

	@ViewBuilder
	private var content: some View {
		switch selectedTab {
		case 0:
			collectionsContent
		case 1:
			postsContent
		default:
			usernamesContent
		}
	}
	
	private var collectionsContent: some View {
		Group {
			if isLoadingCollections {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if collections.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "square.stack.3d.up")
						.font(.system(size: 48))
						.foregroundColor(.secondary)
					Text(searchText.isEmpty ? "Discover collections from other users" : "No collections found")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 16) {
						ForEach(collections) { collection in
							CollectionRowDesign(
								collection: collection,
								isFollowing: false,
								hasRequested: false,
								isMember: collection.members.contains(Auth.auth().currentUser?.uid ?? ""),
								isOwner: collection.ownerId == Auth.auth().currentUser?.uid,
								onFollowTapped: {},
								onActionTapped: {},
								onProfileTapped: {}
							)
							.padding(.horizontal)
						}
					}
					.padding(.vertical)
				}
			}
		}
	}
	
	private var postsContent: some View {
		Group {
			if isLoadingPosts {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if posts.isEmpty {
				VStack(spacing: 12) {
					Image(systemName: "text.bubble")
						.font(.system(size: 48))
						.foregroundColor(.secondary)
					Text(searchText.isEmpty ? "Discover posts from other users' collections" : "No posts found")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				PinterestPostGrid(
					posts: posts,
					collection: nil,
					isIndividualCollection: false,
					currentUserId: Auth.auth().currentUser?.uid
				)
			}
		}
	}
	
	private var usernamesContent: some View {
		VStack(spacing: 12) {
			Image(systemName: "person.crop.circle")
				.font(.system(size: 48))
				.foregroundColor(.secondary)
			Text("Search usernames to get started")
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	@MainActor
	private func performSearch() async {
		let query = searchText.isEmpty ? nil : searchText
		
		switch selectedTab {
		case 0:
			// Search collections
			isLoadingCollections = true
			do {
				let responses = try await apiClient.searchCollections(query: query)
				// Convert CollectionResponse to CollectionData
				collections = responses.map { response in
					let dateFormatter = ISO8601DateFormatter()
					dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
					let createdAt = dateFormatter.date(from: response.createdAt) ?? Date()
					
					return CollectionData(
						id: response.id,
						name: response.name,
						description: response.description,
						type: response.type,
						isPublic: response.isPublic,
						ownerId: response.ownerId,
						ownerName: response.ownerName,
						owners: [response.ownerId],
						imageURL: response.imageURL,
						invitedUsers: [],
						members: response.members,
						memberCount: response.memberCount,
						followers: [],
						followerCount: 0,
						allowedUsers: [],
						deniedUsers: [],
						createdAt: createdAt
					)
				}
			} catch {
				print("Error searching collections: \(error.localizedDescription)")
				collections = []
			}
			isLoadingCollections = false
			
		case 1:
			// Search posts
			isLoadingPosts = true
			do {
				posts = try await apiClient.searchPosts(query: query)
			} catch {
				print("Error searching posts: \(error.localizedDescription)")
				posts = []
			}
			isLoadingPosts = false
			
		default:
			break
		}
	}
}


