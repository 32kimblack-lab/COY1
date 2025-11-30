import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import SDWebImageSwiftUI

struct DeletedCollectionsView: View {
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.presentationMode) var presentationMode
	@EnvironmentObject var authService: AuthService
	
	@State private var deletedCollections: [(CollectionData, Date)] = []
	@State private var isLoading = false
	@State private var showRestoreAlert = false
	@State private var showDeleteAlert = false
	@State private var selectedCollection: CollectionData?
	@State private var isDeleting = false
	
	var body: some View {
		PhoneSizeContainer {
			VStack(spacing: 0) {
			// Header
				HStack {
					Button(action: { presentationMode.wrappedValue.dismiss() }) {
						Image(systemName: "chevron.backward")
							.font(.title2)
							.foregroundColor(colorScheme == .dark ? .white : .black)
					}
					Spacer()
					Text("Deleted Collections")
						.font(.title2)
						.fontWeight(.bold)
						.foregroundColor(colorScheme == .dark ? .white : .black)
					Spacer()
				// Refresh button
				Button(action: {
					loadDeletedCollections()
				}) {
					Image(systemName: "arrow.clockwise")
						.font(.title2)
						.foregroundColor(colorScheme == .dark ? .white : .black)
				}
				}
				.padding(.top, 10)
				.padding(.horizontal)
				
			if isLoading {
				Spacer()
				ProgressView()
					.scaleEffect(1.2)
				Spacer()
			} else if deletedCollections.isEmpty {
				Spacer()
				VStack(spacing: 16) {
					Image(systemName: "trash")
						.resizable()
						.scaledToFit()
						.frame(width: 100, height: 100)
						.foregroundColor(.gray)
					Text("No Deleted Collections")
						.font(.headline)
						.foregroundColor(.gray)
					Text("Collections you delete will appear here for 15 days before permanent deletion.")
						.font(.subheadline)
						.foregroundColor(.gray)
						.multilineTextAlignment(.center)
						.padding(.horizontal)
				}
				Spacer()
			} else {
				ScrollView {
					LazyVStack(spacing: 16) {
						ForEach(deletedCollections, id: \.0.id) { item in
							VStack(alignment: .leading, spacing: 12) {
								// Deleted date and action buttons at the top
								HStack {
									Text("Deleted \(formatDate(item.1))")
										.font(.caption2)
										.foregroundColor(.secondary)
									
									Spacer()
									
									// Action Buttons
									HStack(spacing: 6) {
										// Restore Button
										Button(action: {
									selectedCollection = item.0
									showRestoreAlert = true
										}) {
											Text("Restore")
												.font(.caption)
												.fontWeight(.medium)
												.foregroundColor(.white)
												.padding(.horizontal, 8)
												.padding(.vertical, 4)
												.background(Color.blue)
												.cornerRadius(6)
										}
										
										// Delete Permanently Button
										Button(action: {
									selectedCollection = item.0
									showDeleteAlert = true
										}) {
											Text("Delete")
												.font(.caption)
												.fontWeight(.medium)
												.foregroundColor(.white)
												.padding(.horizontal, 8)
												.padding(.vertical, 4)
												.background(Color.red)
												.cornerRadius(6)
										}
									}
								}
								.padding(.horizontal)
								.padding(.top, 12)
								
								CollectionRowDesign(
									collection: item.0,
									isFollowing: false,
									hasRequested: false,
									isMember: {
										let currentUserId = Auth.auth().currentUser?.uid ?? ""
										return item.0.members.contains(currentUserId) || item.0.owners.contains(currentUserId)
									}(),
									isOwner: item.0.ownerId == Auth.auth().currentUser?.uid,
									isDeletedCollection: true, // Mark as deleted collection to skip filtering
									onFollowTapped: {},
									onActionTapped: {},
									onProfileTapped: {},
									onCollectionTapped: {}
								)
							}
							.background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
							.cornerRadius(12)
							.padding(.horizontal)
						}
					}
					.padding(.vertical)
				}
			}
		}
		.background(colorScheme == .dark ? Color.black : Color.white)
			}
		.navigationBarBackButtonHidden(true)
		.navigationTitle("")
		.toolbar(.hidden, for: .tabBar)
		.onAppear {
			loadDeletedCollections()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionDeleted"))) { notification in
			if let userInfo = notification.userInfo, userInfo["permanent"] as? Bool == true {
				// Collection was permanently deleted, reload list
				loadDeletedCollections()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CollectionRestored"))) { _ in
			// Collection was restored, reload list
			loadDeletedCollections()
		}
		.alert("Restore Collection", isPresented: $showRestoreAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Restore") {
				if let collection = selectedCollection {
					restoreCollection(collection)
				}
			}
		} message: {
			Text("Are you sure you want to restore this collection? It will appear back in your profile.")
		}
		.alert("Delete Permanently", isPresented: $showDeleteAlert) {
			Button("Cancel", role: .cancel) { }
			Button("Delete", role: .destructive) {
				if let collection = selectedCollection {
					deletePermanently(collection)
				}
			}
		} message: {
			Text("Are you sure you want to permanently delete this collection? This will delete all posts, comments, and media. This action cannot be undone.")
		}
	}
	
	private func loadDeletedCollections() {
		guard let userId = authService.user?.uid else { return }
		isLoading = true
		Task { @MainActor in
			do {
				let collections = try await CollectionService.shared.getDeletedCollections(ownerId: userId)
				deletedCollections = collections
				isLoading = false
			} catch {
				print("Error loading deleted collections: \(error)")
				isLoading = false
			}
		}
	}
	
	private func restoreCollection(_ collection: CollectionData) {
		Task {
			do {
				try await CollectionService.shared.recoverCollection(collectionId: collection.id, ownerId: collection.ownerId)
				loadDeletedCollections()
			} catch {
				print("Error restoring collection: \(error)")
			}
		}
	}
	
	private func deletePermanently(_ collection: CollectionData) {
		isDeleting = true
		Task {
			do {
				try await CollectionService.shared.permanentlyDeleteCollection(collectionId: collection.id, ownerId: collection.ownerId)
				await MainActor.run {
					isDeleting = false
					loadDeletedCollections()
				}
			} catch {
				print("Error permanently deleting collection: \(error)")
				await MainActor.run {
					isDeleting = false
				}
			}
		}
	}
}

	// Helper function to format deleted date
	private func formatDate(_ date: Date) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .abbreviated
		return formatter.localizedString(for: date, relativeTo: Date())
}
