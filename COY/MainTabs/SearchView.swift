import SwiftUI

struct SearchView: View {
	@State private var searchText = ""
	@State private var selectedTab: Int = 0
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				header

				tabSwitcher
					.padding(.top, 16)
					.padding(.bottom, 8)

				content
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.navigationBarHidden(true)
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
			selectedTab = index
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
		VStack(spacing: 16) {
			Spacer()
			switch selectedTab {
			case 0:
				placeholder(icon: "square.stack.3d.up", title: "Collections")
			case 1:
				placeholder(icon: "text.bubble", title: "Posts")
			default:
				placeholder(icon: "person.crop.circle", title: "Usernames")
			}
			Spacer()
		}
	}

	private func placeholder(icon: String, title: String) -> some View {
		VStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: 48))
				.foregroundColor(.secondary)
			Text("Search \(title.lowercased()) to get started")
				.foregroundColor(.secondary)
		}
	}
}


