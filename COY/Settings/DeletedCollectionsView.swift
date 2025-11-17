import SwiftUI

struct DeletedCollectionsView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				HStack {
					Button(action: { presentationMode.wrappedValue.dismiss() }) {
						Image(systemName: "chevron.backward")
							.font(.title2)
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					Spacer()
					Text("Deleted Collections")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
				Spacer()
				VStack(spacing: 16) {
					Image(systemName: "trash")
						.resizable()
						.scaledToFit()
						.frame(width: 100, height: 100)
						.foregroundColor(.gray)
					Text("No Deleted Collections")
						.font(.headline)
						.foregroundColor(.gray)
					Text("Collections you delete will appear here for 30 days before permanent deletion.")
						.font(.subheadline)
						.foregroundColor(.gray)
						.multilineTextAlignment(.center)
				}
				Spacer()
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
	}
}

