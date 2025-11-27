import SwiftUI

// MARK: - Phone Size Container View
struct PhoneSizeContainer<Content: View>: View {
	let content: Content
	// Maximum phone width (iPhone 14 Pro Max width)
	private let maxPhoneWidth: CGFloat = 430
	
	// Check if device is iPad
	private var isIPad: Bool {
		UIDevice.current.userInterfaceIdiom == .pad
	}
	
	init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}
	
	var body: some View {
		if isIPad {
			// On iPad, just return the content without any constraints
			content
		} else {
			// On iPhone, apply phone size constraints
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
}

extension View {
	/// Constrains the view to phone size on iPhones only. On iPad, uses full width.
	func phoneSizeContainer() -> some View {
		PhoneSizeContainer {
			self
		}
	}
}

