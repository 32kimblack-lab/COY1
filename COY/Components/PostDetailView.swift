import SwiftUI

struct PostDetailView: View {
	let post: CollectionPost
	let collection: CollectionData
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					Text(post.title)
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					Text("Collection: \(collection.name)")
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					Text("Author: \(post.authorName)")
						.font(.subheadline)
						.foregroundColor(.secondary)
				}
				.padding()
			}
			.navigationTitle("Post")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
			.background(colorScheme == .dark ? Color.black : Color.white)
		}
	}
}

