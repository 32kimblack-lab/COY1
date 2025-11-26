import SwiftUI

struct AboutUsView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	
	var body: some View {
		PhoneSizeContainer {
			ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				HStack {
					Button(action: { presentationMode.wrappedValue.dismiss() }) {
						Image(systemName: "chevron.backward")
							.font(.title2)
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					Spacer()
					Text("About Us")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
				VStack(spacing: 20) {
					HStack(spacing: 12) {
						Text("COY")
							.font(.system(size: 32, weight: .bold))
							.foregroundColor(colorScheme == .dark ? .white : .black)
						
						Image("Icon")
							.resizable()
							.scaledToFit()
							.frame(width: 50, height: 50)
					}
					
					Text("Version 1.0")
						.font(.subheadline)
						.foregroundColor(.gray)
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 20)
				
				VStack(alignment: .leading, spacing: 20) {
					aboutSection(
						title: "Our Story",
						content: "We are twin sisters who wanted to create a better social network experience. Growing up in the digital age, we saw how existing platforms could be improved to make sharing memories more meaningful and personal."
					)
					
					aboutSection(
						title: "Our Mission",
						content: "Our goal is to create a healthier and more enjoyable social media experience   one that feels fun, meaningful, positive, and free from pressure. Whether you're here to keep up with close friends, meet new people, or just have fun, COY is made for you."
					)
					
					aboutSection(
						title: "Thank You!",
						content: "We just want to take a moment to thank everyone who gave COY a chance. Whether you're one of our first users or just joined, we appreciate you being part of this journey. COY wouldn't exist without the support of our friends, family, and everyone who believed in creating something different. We hope you love using COY as much as we loved building it. Welcome to COY!"
					)
				}
				.padding(.horizontal, 20)
				
				Spacer(minLength: 40)
			}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
	}
	
	private func aboutSection(title: String, content: String) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title)
				.font(.headline)
				.fontWeight(.semibold)
				.foregroundColor(colorScheme == .dark ? .white : .black)
			
			Text(content)
				.font(.body)
				.foregroundColor(colorScheme == .dark ? .white.opacity(0.9) : .black.opacity(0.8))
				.lineSpacing(4)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

