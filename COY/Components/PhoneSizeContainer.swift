import SwiftUI

// MARK: - Phone Size Container View
struct PhoneSizeContainer<Content: View>: View {
	let content: Content
	// Maximum phone width (iPhone 14 Pro Max width)
	private let maxPhoneWidth: CGFloat = 430
	
	init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}
	
	var body: some View {
		GeometryReader { geometry in
			let contentWidth = min(geometry.size.width, maxPhoneWidth)
			let horizontalPadding = (geometry.size.width - contentWidth) / 2
			
			HStack(spacing: 0) {
				Spacer()
					.frame(width: max(0, horizontalPadding))
				
				content
					.frame(width: contentWidth)
				
				Spacer()
					.frame(width: max(0, horizontalPadding))
			}
			.frame(width: geometry.size.width, height: geometry.size.height)
		}
	}
}

extension View {
	/// Constrains the view to phone size on tablets, similar to Depop's design
	func phoneSizeContainer() -> some View {
		PhoneSizeContainer {
			self
		}
	}
}

