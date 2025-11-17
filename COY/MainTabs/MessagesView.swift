import SwiftUI

struct MessagesView: View {
	@State private var searchText = ""
	@State private var isSearching = false

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				MessagesHeaderWithSearch(searchText: $searchText, isSearching: $isSearching)
				VStack(spacing: 20) {
					Image(systemName: "message.fill")
						.font(.system(size: 60))
						.foregroundColor(.gray)
					Text("No messages yet")
						.font(.title2)
						.fontWeight(.medium)
					Text("Start a conversation from profiles you follow.")
						.font(.body)
						.foregroundColor(.secondary)
						.multilineTextAlignment(.center)
						.padding(.horizontal)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.navigationBarHidden(true)
		}
	}
}

struct MessagesHeaderWithSearch: View {
	@Binding var searchText: String
	@Binding var isSearching: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Messages")
					.font(.system(size: 22, weight: .bold))
					.foregroundColor(.primary)
				Spacer()
			}
			.padding(.horizontal)
			.padding(.top, 10)
			.padding(.bottom, 16)

			HStack {
				HStack {
					Image(systemName: "magnifyingglass")
						.foregroundColor(.gray)
						.font(.system(size: 16))
					TextField("Search friends...", text: $searchText)
						.textFieldStyle(PlainTextFieldStyle())
						.font(.body)
						.onTapGesture {
							withAnimation(.easeInOut(duration: 0.2)) { isSearching = true }
						}
					if !searchText.isEmpty {
						Button(action: {
							searchText = ""
							withAnimation(.easeInOut(duration: 0.2)) { isSearching = false }
						}) {
							Image(systemName: "xmark.circle.fill")
								.foregroundColor(.gray)
								.font(.system(size: 16))
						}
					}
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.background(Color(.systemGray5))
				.cornerRadius(12)
				if isSearching {
					Button("Cancel") {
						searchText = ""
						withAnimation(.easeInOut(duration: 0.2)) { isSearching = false }
					}
					.foregroundColor(.blue)
					.font(.body)
				}
			}
			.padding(.horizontal)
			.padding(.bottom, 12)
		}
	}
}


