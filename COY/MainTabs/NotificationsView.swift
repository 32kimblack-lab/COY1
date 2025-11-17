import SwiftUI

struct NotificationsView: View {
	@Binding var isPresented: Bool
	
	var body: some View {
		NavigationStack {
			List {
				Section(header: Text("Notifications")) {
					Text("You have no notifications yet.")
						.foregroundColor(.secondary)
				}
			}
			.listStyle(.insetGrouped)
			.navigationTitle("Notifications")
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button {
						isPresented = false
					} label: {
						Image(systemName: "xmark")
							.font(.system(size: 16, weight: .semibold))
					}
					.accessibilityLabel("Close")
				}
			}
		}
	}
}


