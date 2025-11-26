import SwiftUI
import Combine
import FirebaseAuth

enum ReportType: String, Codable {
	case post = "post"
	case collection = "collection"
	case user = "user"
}

enum ReportCategory: String, CaseIterable, Codable {
	case nudityOrSexualContent = "Nudity or Sexual Content"
	case violenceOrGraphicContent = "Violence or Graphic Content"
	case harassmentOrBullying = "Harassment or Bullying"
	case hateSpeech = "Hate Speech"
	case illegalActivity = "Illegal Activity"
	case spam = "Spam"
	
	var description: String {
		switch self {
		case .nudityOrSexualContent:
			return "Inappropriate sexual or nude content"
		case .violenceOrGraphicContent:
			return "Violent or disturbing imagery"
		case .harassmentOrBullying:
			return "Targeted harassment or bullying"
		case .hateSpeech:
			return "Hateful or discriminatory content"
		case .illegalActivity:
			return "Content promoting illegal activities"
		case .spam:
			return "Repetitive or unwanted content"
		}
	}
	
	var severity: ReportSeverity {
		switch self {
		case .nudityOrSexualContent, .violenceOrGraphicContent:
			return .critical
		case .harassmentOrBullying, .hateSpeech, .illegalActivity:
			return .high
		case .spam:
			return .low
		}
	}
}

enum ReportSeverity {
	case critical
	case high
	case low
}

@MainActor
class ReportViewModel: ObservableObject {
	@Published var selectedCategory: ReportCategory?
	@Published var additionalDetails: String = ""
	@Published var isSubmitting = false
	@Published var showSuccessMessage = false
	@Published var errorMessage: String?
	
	func submitReport(itemId: String, itemType: ReportType) async {
		guard let category = selectedCategory else { return }
		
		isSubmitting = true
		errorMessage = nil
		
		do {
			if itemType == .post {
				// Report and hide the post (post is hidden even if API fails)
				try await CYServiceManager.shared.reportPost(
					postId: itemId,
					category: category.rawValue,
					additionalDetails: additionalDetails.isEmpty ? nil : additionalDetails
				)
				showSuccessMessage = true
			}
		} catch {
			// Even if there's an error, the post should be hidden
			// Show success message anyway since hiding succeeded
			print("⚠️ ReportView: Error during report: \(error.localizedDescription)")
			showSuccessMessage = true
		}
		
		isSubmitting = false
	}
}

struct ReportView: View {
	let itemId: String
	let itemType: ReportType
	let itemName: String
	
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) var colorScheme
	@StateObject private var viewModel = ReportViewModel()
	
	private var backgroundColor: Color { colorScheme == .dark ? .black : .white }
	private var textColor: Color { colorScheme == .dark ? .white : .black }
	private var secondaryBackgroundColor: Color { colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95) }
	
	var body: some View {
		NavigationStack {
			PhoneSizeContainer {
			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					// Header info
					VStack(alignment: .leading, spacing: 8) {
						Text("What's wrong with this \(itemType.rawValue)?")
							.font(.title2)
							.fontWeight(.bold)
							.foregroundColor(textColor)
						
						Text("Your report is anonymous. If someone is in immediate danger, call local emergency services.")
							.font(.subheadline)
							.foregroundColor(.gray)
					}
					.padding(.horizontal)
					
					// Report categories
					VStack(spacing: 12) {
						ForEach(ReportCategory.allCases, id: \.self) { category in
							ReportCategoryButton(
								category: category,
								isSelected: viewModel.selectedCategory == category,
								action: {
									viewModel.selectedCategory = category
								}
							)
						}
					}
					.padding(.horizontal)
					
					// Additional details
					VStack(alignment: .leading, spacing: 12) {
						Text("Additional Details (Optional)")
							.font(.headline)
							.foregroundColor(textColor)
						
						TextEditor(text: $viewModel.additionalDetails)
							.frame(height: 100)
							.padding(8)
							.background(secondaryBackgroundColor)
							.cornerRadius(8)
							.overlay(
								RoundedRectangle(cornerRadius: 8)
									.stroke(Color.gray.opacity(0.3), lineWidth: 1)
							)
						
						Text("Provide any additional context that might help us review this report.")
							.font(.caption)
							.foregroundColor(.gray)
					}
					.padding(.horizontal)
					
					// Submit button
					Button(action: {
						Task {
							await viewModel.submitReport(itemId: itemId, itemType: itemType)
						}
					}) {
						if viewModel.isSubmitting {
							ProgressView()
								.progressViewStyle(CircularProgressViewStyle(tint: .white))
								.frame(maxWidth: .infinity)
								.frame(height: 50)
						} else {
							Text("Submit Report")
								.font(.headline)
								.foregroundColor(.white)
								.frame(maxWidth: .infinity)
								.frame(height: 50)
						}
					}
					.background(viewModel.selectedCategory == nil ? Color.gray : Color.red)
					.cornerRadius(12)
					.padding(.horizontal)
					.disabled(viewModel.selectedCategory == nil || viewModel.isSubmitting)
				}
				.padding(.vertical)
			}
			.background(backgroundColor)
			.navigationTitle("Report \(itemType.rawValue.capitalized)")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("Cancel") {
						dismiss()
					}
					.foregroundColor(textColor)
				}
			}
			.alert("Report Submitted", isPresented: $viewModel.showSuccessMessage) {
				Button("OK") {
					dismiss()
				}
			} message: {
				Text("Thank you for helping keep COY safe. We'll review your report as soon as possible.")
			}
			.alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
				Button("OK") {
					viewModel.errorMessage = nil
				}
			} message: {
				Text(viewModel.errorMessage ?? "")
				}
			}
		}
	}
}

struct ReportCategoryButton: View {
	let category: ReportCategory
	let isSelected: Bool
	let action: () -> Void
	
	@Environment(\.colorScheme) var colorScheme
	
	private var backgroundColor: Color {
		if isSelected {
			switch category.severity {
			case .critical:
				return Color.red.opacity(0.2)
			case .high:
				return Color.orange.opacity(0.2)
			case .low:
				return Color.blue.opacity(0.2)
			}
		}
		return colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95)
	}
	
	private var borderColor: Color {
		if isSelected {
			switch category.severity {
			case .critical:
				return Color.red
			case .high:
				return Color.orange
			case .low:
				return Color.blue
			}
		}
		return Color.clear
	}
	
	private var iconColor: Color {
		switch category.severity {
		case .critical:
			return .red
		case .high:
			return .orange
		case .low:
			return .blue
		}
	}
	
	private var icon: String {
		switch category {
		case .nudityOrSexualContent:
			return "eye.slash.fill"
		case .violenceOrGraphicContent:
			return "exclamationmark.triangle.fill"
		case .harassmentOrBullying:
			return "person.2.slash.fill"
		case .hateSpeech:
			return "hand.raised.fill"
		case .illegalActivity:
			return "exclamationmark.shield.fill"
		case .spam:
			return "envelope.badge.fill"
		}
	}
	
	var body: some View {
		Button(action: action) {
			HStack(spacing: 16) {
				Image(systemName: icon)
					.font(.title3)
					.foregroundColor(iconColor)
					.frame(width: 30)
				
				VStack(alignment: .leading, spacing: 4) {
					Text(category.rawValue)
						.font(.headline)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					
					Text(category.description)
						.font(.caption)
						.foregroundColor(.gray)
						.fixedSize(horizontal: false, vertical: true)
				}
				
				Spacer()
				
				if isSelected {
					Image(systemName: "checkmark.circle.fill")
						.foregroundColor(iconColor)
				}
			}
			.padding()
			.background(backgroundColor)
			.cornerRadius(12)
			.overlay(
				RoundedRectangle(cornerRadius: 12)
					.stroke(borderColor, lineWidth: isSelected ? 2 : 0)
			)
		}
		.buttonStyle(PlainButtonStyle())
	}
}

