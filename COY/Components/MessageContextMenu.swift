import SwiftUI
import UIKit

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
				// React options (first)
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
				
				// Edit option (only for own text messages, max 2 edits) - second
				if isMine && message.type == "text" && message.editCount < 2 {
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
				
				// Reply option (third)
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
				
				// Copy option (only for text messages, not photos/videos)
				if message.type == "text" {
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
			EditMessageView(editText: $editText, onSave: {
				onEdit(editText)
				showEditSheet = false
				onDismiss()
			}, onCancel: {
				showEditSheet = false
			})
		}
	}
}

// MARK: - Edit Message View
struct EditMessageView: View {
	@Binding var editText: String
	var onSave: () -> Void
	var onCancel: () -> Void
	
	var body: some View {
			NavigationStack {
			VStack(spacing: 0) {
				TextEditorWithKeyboard(text: $editText)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.frame(minHeight: 100, maxHeight: 150)
					.background(Color(.systemGray6))
					.cornerRadius(20)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					Spacer()
				}
				.navigationTitle("Edit Message")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .navigationBarLeading) {
						Button("Cancel") {
						onCancel()
						}
					}
					ToolbarItem(placement: .navigationBarTrailing) {
						Button("Save") {
						onSave()
						}
						.disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
			}
		.presentationDetents([.height(200)])
	}
}

// MARK: - Text Editor with Auto Keyboard
struct TextEditorWithKeyboard: UIViewRepresentable {
	@Binding var text: String
	
	func makeUIView(context: Context) -> UITextView {
		let textView = UITextView()
		textView.font = UIFont.systemFont(ofSize: 15)
		textView.delegate = context.coordinator
		textView.isScrollEnabled = true
		textView.backgroundColor = .clear
		return textView
	}
	
	func updateUIView(_ uiView: UITextView, context: Context) {
		if uiView.text != text {
			uiView.text = text
		}
		
		// Show keyboard immediately when view appears
		if !uiView.isFirstResponder {
			DispatchQueue.main.async {
				uiView.becomeFirstResponder()
			}
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}
	
	class Coordinator: NSObject, UITextViewDelegate {
		var parent: TextEditorWithKeyboard
		
		init(_ parent: TextEditorWithKeyboard) {
			self.parent = parent
		}
		
		func textViewDidChange(_ textView: UITextView) {
			parent.text = textView.text
		}
	}
}

