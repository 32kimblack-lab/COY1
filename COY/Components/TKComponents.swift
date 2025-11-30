import SwiftUI
import SafariServices

struct TKTextField: View {
	@Binding var text: String
	var placeholder: String
	var image: String
	var isSecure: Bool = false

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: image)
				.foregroundColor(.secondary)
			if isSecure {
				SecureField(placeholder, text: $text)
					.textContentType(.none)
					.autocorrectionDisabled()
			} else {
				TextField(placeholder, text: $text)
					.autocorrectionDisabled()
			}
		}
		.padding()
		.background(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.gray.opacity(0.4), lineWidth: 1)
		)
	}
}

struct TKButton: View {
	var title: String
	var iconName: String?
	var action: () -> Void

	init(_ title: String, iconName: String? = nil, action: @escaping () -> Void) {
		self.title = title
		self.iconName = iconName
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			HStack {
				if let icon = iconName {
					Image(systemName: icon)
				}
				Text(title)
					.fontWeight(.semibold)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 14)
			.background(Color.accentColor)
			.foregroundColor(.white)
			.cornerRadius(10)
		}
	}
}

struct CombinedIconView: View {
	var body: some View {
		HStack(spacing: 8) {
			Text("COY")
				.font(.title)
				.fontWeight(.bold)
			Image("SplashIcon")
				.resizable()
				.scaledToFit()
				.frame(width: 40, height: 40)
		}
	}
}

// MARK: - Keyboard Dismissal Modifier
struct DismissKeyboardModifier: ViewModifier {
	func body(content: Content) -> some View {
		content
			.simultaneousGesture(
				TapGesture()
					.onEnded { _ in
						UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
					}
			)
	}
}

extension View {
	func dismissKeyboardOnTap() -> some View {
		modifier(DismissKeyboardModifier())
	}
}

// MARK: - Safari View Controller Wrapper
struct SafariViewController: UIViewControllerRepresentable {
	let url: URL
	
	func makeUIViewController(context: Context) -> SFSafariViewController {
		return SFSafariViewController(url: url)
	}
	
	func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
		// No update needed
	}
}

