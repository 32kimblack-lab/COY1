import SwiftUI

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
					.textContentType(.password)
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
			Image(systemName: "triangle.fill")
			Text("COY")
				.font(.title)
				.fontWeight(.bold)
		}
	}
}

