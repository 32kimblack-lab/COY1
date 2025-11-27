import SwiftUI

struct SplashScreenView: View {
	@Environment(\.colorScheme) var colorScheme
	
	var body: some View {
		ZStack {
			// Background color: black in dark mode, white in light mode
			Color(colorScheme == .dark ? .black : .white)
				.ignoresSafeArea()
			
			VStack {
				Spacer()
				
				// App Icon centered (smaller size)
				Image("SplashIcon")
					.resizable()
					.scaledToFit()
					.frame(width: 120, height: 120)
				
				Spacer()
				
				// From COY text at the very bottom
				VStack(spacing: 4) {
					Text("From")
						.font(.system(size: 14, weight: .regular, design: .default))
						.foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.7))
					Text("COY")
						.font(.system(size: 24, weight: .medium, design: .default))
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
				.padding(.bottom, 50)
			}
		}
	}
}

