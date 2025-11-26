import SwiftUI

struct MessageContextMenu: View {
	let message: MessageModel
	let isMine: Bool
	var onDismiss: () -> Void
	var onDelete: () -> Void
	var onEdit: (String) -> Void
	var onReply: () -> Void
	var onReact: (String) -> Void
	var onCopy: () -> Void
	
	@State private var showEditSheet = false
	@State private var editText = ""
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		ZStack {
			// Background overlay
			Color.black.opacity(0.3)
				.ignoresSafeArea()
				.onTapGesture {
					onDismiss()
				}
			
			// Menu
			VStack(spacing: 0) {
				// Edit option (only for own messages)
				if isMine {
					Button(action: {
						editText = message.content
						showEditSheet = true
					}) {
						HStack {
							Image(systemName: "pencil")
							Text("Edit")
							Spacer()
						}
						.padding()
						.foregroundColor(.primary)
					}
					Divider()
				}
				
				// Reply option
				Button(action: {
					onReply()
				}) {
					HStack {
						Image(systemName: "arrowshape.turn.up.left")
						Text("Reply")
						Spacer()
					}
					.padding()
					.foregroundColor(.primary)
				}
				Divider()
				
				// React options
				HStack(spacing: 20) {
					ForEach(["❤️", "😂", "😮", "😢", "👍", "👎"], id: \.self) { emoji in
						Button(action: {
							onReact(emoji)
							onDismiss()
						}) {
							Text(emoji)
								.font(.system(size: 24))
						}
					}
				}
				.padding()
				Divider()
				
				// Copy option
				Button(action: {
					onCopy()
					onDismiss()
				}) {
					HStack {
						Image(systemName: "doc.on.doc")
						Text("Copy")
						Spacer()
					}
					.padding()
					.foregroundColor(.primary)
				}
				
				// Delete option (only for own messages)
				if isMine {
					Divider()
					Button(action: {
						onDelete()
						onDismiss()
					}) {
						HStack {
							Image(systemName: "trash")
							Text("Delete")
							Spacer()
						}
						.padding()
						.foregroundColor(.red)
					}
				}
			}
			.background(colorScheme == .dark ? Color(.systemGray6) : Color.white)
			.cornerRadius(12)
			.shadow(radius: 10)
			.padding()
		}
		.sheet(isPresented: $showEditSheet) {
			NavigationStack {
				VStack {
					TextEditor(text: $editText)
						.padding()
					Spacer()
				}
				.navigationTitle("Edit Message")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .navigationBarLeading) {
						Button("Cancel") {
							showEditSheet = false
						}
					}
					ToolbarItem(placement: .navigationBarTrailing) {
						Button("Save") {
							onEdit(editText)
							showEditSheet = false
							onDismiss()
						}
						.disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
			}
		}
	}
}

