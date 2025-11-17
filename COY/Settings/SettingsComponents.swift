import SwiftUI

struct SettingsRow: View {
	@Environment(\.colorScheme) var colorScheme
	let title: String
	let icon: String
	var isDestructive: Bool = false
	
	var body: some View {
		HStack {
			Image(systemName: icon)
				.foregroundColor(isDestructive ? .red : (colorScheme == .dark ? .white : .black))
			Text(title)
				.foregroundColor(isDestructive ? .red : (colorScheme == .dark ? .white : .black))
			Spacer()
			Image(systemName: "chevron.right")
				.foregroundColor(.gray)
		}
		.padding()
		.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
		.cornerRadius(10)
		.padding(.horizontal)
	}
}

struct SettingsToggleRow: View {
	@Environment(\.colorScheme) var colorScheme
	let title: String
	let icon: String
	@State private var isOn: Bool = false
	
	var body: some View {
		HStack {
			Image(systemName: icon)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Text(title)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			Spacer()
			Toggle("", isOn: $isOn)
				.toggleStyle(SwitchToggleStyle(tint: .blue))
				.labelsHidden()
		}
		.padding()
		.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
		.cornerRadius(10)
		.padding(.horizontal)
	}
}

struct COYplusicon: View {
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		ZStack {
			HStack(spacing: 10) {
				Text("COY")
					.font(.system(size: 60, weight: .bold))
					.foregroundColor(colorScheme == .dark ? .white : .black)
				
				Image(systemName: "photo.fill")
					.resizable()
					.scaledToFit()
					.frame(width: 70, height: 65)
					.offset(x: -20)
					.padding(.top, -10)
			}
			.frame(maxWidth: .infinity, alignment: .center)
			.fixedSize()
		}
	}
}

struct BackButton: View {
	@Environment(\.presentationMode) var presentationMode
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		Image(systemName: "chevron.backward")
			.font(.title)
			.foregroundColor(colorScheme == .dark ? .white : .blue)
			.padding()
			.onTapGesture {
				presentationMode.wrappedValue.dismiss()
			}
	}
}

