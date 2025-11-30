import SwiftUI

struct ViewVisibilityModifier: ViewModifier {
	let onChange: (CGFloat) -> Void
	
	func body(content: Content) -> some View {
		content
			.background(
				GeometryReader { geo in
					Color.clear.preference(
						key: VisibilityKey.self,
						value: geo.frame(in: .global).minY
					)
				}
			)
			.onPreferenceChange(VisibilityKey.self) { topY in
				onChange(topY)
			}
	}
}

struct VisibilityKey: PreferenceKey {
	static var defaultValue: CGFloat = 9999
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		// Take the minimum value to ensure we detect any change
		// This triggers onPreferenceChange whenever any card moves
		value = min(value, nextValue())
	}
}

extension View {
	func onVisibilityChange(_ handler: @escaping (CGFloat) -> Void) -> some View {
		self.modifier(ViewVisibilityModifier(onChange: handler))
	}
}
