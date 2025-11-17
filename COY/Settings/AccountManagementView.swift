import SwiftUI

struct AccountManagementView: View {
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
					Text("Account Management")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
				Text("Account management features coming soon.")
					.font(.body)
					.foregroundColor(.gray)
					.padding(.horizontal)
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
	}
}

