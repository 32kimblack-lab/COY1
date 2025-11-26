import SwiftUI
import SDWebImageSwiftUI

struct FullScreenImageView: View {
	let imageURL: String
	@Environment(\.dismiss) var dismiss
	@State private var scale: CGFloat = 1.0
	@State private var lastScale: CGFloat = 1.0
	@State private var offset: CGSize = .zero
	@State private var lastOffset: CGSize = .zero
	
	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()
			
			if let url = URL(string: imageURL) {
				WebImage(url: url)
					.resizable()
					.indicator(.activity)
					.scaledToFit()
					.scaleEffect(scale)
					.offset(offset)
					.gesture(
						MagnificationGesture()
							.onChanged { value in
								scale = lastScale * value
							}
							.onEnded { _ in
								lastScale = scale
								if scale < 1.0 {
									withAnimation {
										scale = 1.0
										lastScale = 1.0
									}
								}
							}
					)
					.gesture(
						DragGesture()
							.onChanged { value in
								offset = CGSize(
									width: lastOffset.width + value.translation.width,
									height: lastOffset.height + value.translation.height
								)
							}
							.onEnded { _ in
								lastOffset = offset
							}
					)
			}
			
			VStack {
				HStack {
					Spacer()
					Button(action: {
						dismiss()
					}) {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 30))
							.foregroundColor(.white)
							.padding()
					}
				}
				Spacer()
			}
		}
		.onTapGesture(count: 2) {
			withAnimation {
				if scale > 1.0 {
					scale = 1.0
					lastScale = 1.0
					offset = .zero
					lastOffset = .zero
				} else {
					scale = 2.0
					lastScale = 2.0
				}
			}
		}
	}
}

