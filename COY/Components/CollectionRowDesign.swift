import SwiftUI
import FirebaseAuth

// MARK: - Collection Row Design (Clean & Minimal)
struct CollectionRowDesign: View {
	let collection: CollectionData
	let isFollowing: Bool
	let hasRequested: Bool
	let isMember: Bool
	let isOwner: Bool
	
	let onFollowTapped: () -> Void
	let onActionTapped: () -> Void
	let onProfileTapped: () -> Void
	
	@StateObject private var cyServiceManager = CYServiceManager.shared
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Header: Image + Name + Buttons
			HStack(spacing: 12) {
				// Profile Image Placeholder
				profileImageView
				
				// Name + Type/Members
				VStack(alignment: .leading, spacing: 4) {
					Text(collection.name)
						.font(.headline)
						.foregroundColor(.primary)
					
					Text(memberLabel)
						.font(.caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
				
				// Action Buttons
				HStack(spacing: 8) {
					if !isMember && !isOwner {
						followButton
					}
					
					if shouldShowActionButton {
						actionButton
					}
				}
			}
			.padding(.horizontal)
			
			// Description
			if !collection.description.isEmpty {
				Text(collection.description)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(2)
					.padding(.horizontal)
			}
			
			// Grid Placeholders (No real images)
			gridPlaceholders
				.padding(.horizontal)
				.padding(.bottom, 8)
		}
		.background(Color(.systemBackground))
		.cornerRadius(12)
		.overlay(
			RoundedRectangle(cornerRadius: 12)
				.stroke(Color(.separator), lineWidth: 0.5)
		)
	}
	
	// MARK: - Profile Image
	private var profileImageView: some View {
		Button(action: onProfileTapped) {
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				// Use collection's profile image if available
				CachedProfileImageView(url: imageURL, size: 50)
					.clipShape(Circle())
			} else {
				// Use user's own profile image as default
				if let userProfileImageURL = cyServiceManager.currentUser?.profileImageURL,
				   !userProfileImageURL.isEmpty {
					CachedProfileImageView(url: userProfileImageURL, size: 50)
						.clipShape(Circle())
				} else {
					// Fallback to default icon if user has no profile image
					DefaultProfileImageView(size: 50)
				}
			}
		}
		.buttonStyle(.plain)
	}
	
	// MARK: - Member Label
	private var memberLabel: String {
		if collection.type == "Individual" {
			return "Individual"
		} else {
			return "\(collection.memberCount) member\(collection.memberCount == 1 ? "" : "s")"
		}
	}
	
	// MARK: - Follow Button
	private var followButton: some View {
		Button(action: onFollowTapped) {
			Circle()
				.fill(isFollowing ? Color.blue : Color(.systemGray4))
				.frame(width: 28, height: 28)
				.overlay(
					Image(systemName: isFollowing ? "checkmark" : "plus")
						.font(.caption)
						.fontWeight(.bold)
						.foregroundColor(isFollowing ? .white : .primary)
				)
		}
		.buttonStyle(.plain)
	}
	
	// MARK: - Action Button (Request / Join / Leave)
	private var shouldShowActionButton: Bool {
		return collection.type == "Request" || collection.type == "Open"
	}
	
	private var actionButton: some View {
		Button(action: onActionTapped) {
			Text(actionButtonText)
				.font(.subheadline)
				.fontWeight(.medium)
				.foregroundColor(actionButtonTextColor)
				.padding(.horizontal, 12)
				.padding(.vertical, 6)
				.background(actionButtonBackground)
				.cornerRadius(6)
				.overlay(
					RoundedRectangle(cornerRadius: 6)
						.stroke(actionButtonBorderColor, lineWidth: 1)
				)
		}
		.buttonStyle(.plain)
	}
	
	private var actionButtonText: String {
		switch collection.type {
		case "Request":
			return hasRequested ? "Requested" : "Request"
		case "Open":
			return isMember || isOwner ? "Leave" : "Join"
		default:
			return ""
		}
	}
	
	private var actionButtonTextColor: Color {
		if collection.type == "Request" && hasRequested {
			return .blue
		}
		return .primary
	}
	
	private var actionButtonBackground: Color {
		if collection.type == "Request" && hasRequested {
			return .blue.opacity(0.1)
		}
		return Color(.systemGray6)
	}
	
	private var actionButtonBorderColor: Color {
		if collection.type == "Request" && hasRequested {
			return .blue
		}
		return .clear
	}
	
	// MARK: - Grid Placeholders
	private var gridPlaceholders: some View {
		HStack(spacing: 8) {
			ForEach(0..<4, id: \.self) { _ in
				Rectangle()
					.fill(Color.gray.opacity(0.2))
					.frame(width: 90, height: 130)
					.cornerRadius(8)
			}
		}
	}
}

// MARK: - Static Factory Method for ID-based Creation
extension CollectionRowDesign {
	static func withId(_ collectionId: String) -> some View {
		// This is a placeholder that will be replaced by actual implementation
		// The actual view should fetch the collection data by ID
		Text("Collection \(collectionId)")
			.font(.headline)
	}
}

