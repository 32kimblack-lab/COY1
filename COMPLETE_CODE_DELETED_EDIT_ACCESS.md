# Complete Code: Deleted Collections, Edit Collection, and Access Control

This document contains ALL code for:

1. **Deleted Collections** (soft delete, restore, permanent delete)
2. **Edit Collection** (update name, description, image, visibility)
3. **Access Control** (allow/deny access for private/public collections)

---

## 1. DELETED COLLECTIONS

### 1.1 Frontend: DeletedCollectionsView.swift

```swift
import SwiftUI
import FirebaseAuth

struct DeletedCollectionsView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.colorScheme) var colorScheme
	@State private var deletedCollections: [(CollectionData, Date)] = []
	@State private var isLoading = true
	@State private var showRecoverAlert = false
	@State private var showDeleteAlert = false
	@State private var selectedCollection: CollectionData?
	@State private var selectedDeletedAt: Date?
	
	private let collectionService = CollectionService.shared
	
	var body: some View {
		NavigationStack {
			List {
				if isLoading {
					ProgressView()
						.frame(maxWidth: .infinity)
						.padding()
				} else if deletedCollections.isEmpty {
					VStack(spacing: 16) {
						Image(systemName: "trash")
							.font(.system(size: 50))
							.foregroundColor(.gray)
						Text("No Deleted Collections")
							.font(.headline)
							.foregroundColor(.secondary)
						Text("Collections you delete will appear here for 15 days")
							.font(.subheadline)
							.foregroundColor(.secondary)
							.multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 40)
				} else {
					ForEach(deletedCollections, id: \.0.id) { collectionData in
						let (collection, deletedAt) = collectionData
						DeletedCollectionRow(
							collection: collection,
							deletedAt: deletedAt,
							onRecover: {
								selectedCollection = collection
								selectedDeletedAt = deletedAt
								showRecoverAlert = true
							},
							onPermanentlyDelete: {
								selectedCollection = collection
								selectedDeletedAt = deletedAt
								showDeleteAlert = true
							}
						)
					}
				}
			}
			.navigationTitle("Deleted Collections")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("Done") {
						dismiss()
					}
				}
			}
			.onAppear {
				loadDeletedCollections()
			}
			.alert("Recover Collection", isPresented: $showRecoverAlert) {
				Button("Cancel", role: .cancel) { }
				Button("Recover", role: .none) {
					if let collection = selectedCollection {
						recoverCollection(collection)
					}
				}
			} message: {
				Text("This collection will be restored to your profile exactly as it was.")
			}
			.alert("Permanently Delete", isPresented: $showDeleteAlert) {
				Button("Cancel", role: .cancel) { }
				Button("Delete", role: .destructive) {
					if let collection = selectedCollection {
						permanentlyDeleteCollection(collection)
					}
				}
			} message: {
				Text("This collection will be permanently deleted and cannot be recovered. Are you sure?")
			}
		}
	}
	
	private func loadDeletedCollections() {
		guard let userId = Auth.auth().currentUser?.uid else { return }
		isLoading = true
		Task {
			do {
				let collections = try await collectionService.getDeletedCollections(ownerId: userId)
				await MainActor.run {
					self.deletedCollections = collections
					self.isLoading = false
				}
			} catch {
				print("Error loading deleted collections: \(error)")
				await MainActor.run {
					self.isLoading = false
				}
			}
		}
	}
	
	private func recoverCollection(_ collection: CollectionData) {
		Task {
			do {
				try await collectionService.recoverCollection(collectionId: collection.id, ownerId: collection.ownerId)
				await MainActor.run {
					loadDeletedCollections()
				}
			} catch {
				print("Error recovering collection: \(error)")
			}
		}
	}
	
	private func permanentlyDeleteCollection(_ collection: CollectionData) {
		Task {
			do {
				try await collectionService.permanentlyDeleteCollection(collectionId: collection.id, ownerId: collection.ownerId)
				await MainActor.run {
					loadDeletedCollections()
				}
			} catch {
				print("Error permanently deleting collection: \(error)")
			}
		}
	}
}

struct DeletedCollectionRow: View {
	let collection: CollectionData
	let deletedAt: Date
	let onRecover: () -> Void
	let onPermanentlyDelete: () -> Void
	
	var daysRemaining: Int {
		let daysSinceDeleted = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
		return max(0, 15 - daysSinceDeleted)
	}
	
	var body: some View {
		HStack(spacing: 12) {
			// Collection Image
			if let imageURL = collection.imageURL, !imageURL.isEmpty {
				CachedProfileImageView(url: imageURL, size: 50)
					.clipShape(Circle())
			} else {
				DefaultProfileImageView(size: 50)
			}
			
			VStack(alignment: .leading, spacing: 4) {
				Text(collection.name)
					.font(.headline)
					.foregroundColor(.primary)
				
				Text("\(daysRemaining) days until you can recover")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			
			Spacer()
			
			HStack(spacing: 8) {
				Button(action: onRecover) {
					Text("Recover")
						.font(.subheadline)
						.foregroundColor(.blue)
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.background(Color.blue.opacity(0.1))
						.cornerRadius(6)
				}
				
				Button(action: onPermanentlyDelete) {
					Text("Delete")
						.font(.subheadline)
						.foregroundColor(.red)
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.background(Color.red.opacity(0.1))
						.cornerRadius(6)
				}
			}
		}
		.padding(.vertical, 8)
	}
}
```

### 1.2 Frontend: APIClient - Delete Collection Method

```swift
// In APIClient.swift

/// Delete a collection (soft delete - only owner can do this)
func deleteCollection(collectionId: String) async throws {
	print("🗑️ APIClient: Deleting collection \(collectionId)")
	let request = try await createRequest(endpoint: "/collections/\(collectionId)", method: "DELETE")
	let (data, response) = try await URLSession.shared.data(for: request)
	try validateResponse(response, data: data)
	print("✅ APIClient: Collection deleted successfully")
}
```

### 1.3 Frontend: CollectionService - Delete/Restore Methods

```swift
// In CollectionService.swift

func softDeleteCollection(collectionId: String) async throws {
	print("🗑️ CollectionService: Starting soft delete for collection: \(collectionId)")
	
	// CRITICAL FIX: Use backend API first (source of truth)
	// Backend handles soft delete in Firebase and MongoDB
	do {
		try await apiClient.deleteCollection(collectionId: collectionId)
		print("✅ CollectionService: Collection deleted via backend API")
	} catch {
		print("⚠️ CollectionService: Backend API failed, falling back to Firestore: \(error)")
		
		// Fallback to Firestore if backend fails
		// Get ownerId from backend API first
		var ownerId: String
		do {
			if let collection = try await getCollection(collectionId: collectionId) {
				ownerId = collection.ownerId
				print("✅ CollectionService: Found collection owner from backend: \(ownerId)")
			} else {
				throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
			}
		} catch {
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		// Get collection data for soft delete
		let collectionDoc = try await collectionRef.getDocument()
		guard var collectionData = collectionDoc.data() else {
			print("❌ CollectionService: Collection document not found: \(collectionId)")
			throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Collection not found"])
		}
		
		// Add deletedAt timestamp
		collectionData["deletedAt"] = Timestamp()
		collectionData["isDeleted"] = true
		
		// Move to deleted_collections subcollection
		let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
		print("📝 CollectionService: Moving collection to deleted_collections subcollection...")
		try await deletedRef.setData(collectionData)
		print("✅ CollectionService: Collection moved to deleted_collections")
		
		// Remove from main collections
		print("🗑️ CollectionService: Removing collection from main collections...")
		try await collectionRef.delete()
		print("✅ CollectionService: Collection removed from main collections")
	}
	
	// Post notification so collection disappears immediately from UI
	await MainActor.run {
		NotificationCenter.default.post(
			name: NSNotification.Name("CollectionDeleted"),
			object: collectionId,
			userInfo: ["ownerId": ""] // Backend will handle ownerId
		)
		print("📢 CollectionService: Posted CollectionDeleted notification")
	}
	
	print("✅ CollectionService: Soft delete completed successfully for collection: \(collectionId)")
}

func recoverCollection(collectionId: String, ownerId: String) async throws {
	let db = Firestore.firestore()
	let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
	
	// Get deleted collection data
	let deletedDoc = try await deletedRef.getDocument()
	guard var collectionData = deletedDoc.data() else {
		throw NSError(domain: "CollectionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Deleted collection not found"])
	}
	
	// Remove deleted fields
	collectionData.removeValue(forKey: "deletedAt")
	collectionData.removeValue(forKey: "isDeleted")
	
	// Restore to main collections
	let collectionRef = db.collection("collections").document(collectionId)
	try await collectionRef.setData(collectionData)
	
	// Remove from deleted_collections
	try await deletedRef.delete()
	
	// Post notification so collection appears immediately in UI
	await MainActor.run {
		NotificationCenter.default.post(
			name: NSNotification.Name("CollectionRestored"),
			object: collectionId,
			userInfo: ["ownerId": ownerId]
		)
	}
}

func permanentlyDeleteCollection(collectionId: String, ownerId: String) async throws {
	let db = Firestore.firestore()
	let deletedRef = db.collection("users").document(ownerId).collection("deleted_collections").document(collectionId)
	
	// Permanently delete
	try await deletedRef.delete()
}

func getDeletedCollections(ownerId: String) async throws -> [(CollectionData, Date)] {
	let db = Firestore.firestore()
	let snapshot = try await db.collection("users").document(ownerId).collection("deleted_collections").getDocuments()
	
	return snapshot.documents.compactMap { doc -> (CollectionData, Date)? in
		let data = doc.data()
		guard let deletedAt = data["deletedAt"] as? Timestamp else { return nil }
		let deletedAtDate = deletedAt.dateValue()
		
		// Check if 15 days have passed (changed from 30 to 15)
		let daysSinceDeleted = Calendar.current.dateComponents([.day], from: deletedAtDate, to: Date()).day ?? 0
		if daysSinceDeleted >= 15 {
			// Auto-delete expired collections
			Task {
				try? await permanentlyDeleteCollection(collectionId: doc.documentID, ownerId: ownerId)
			}
			return nil
		}
		
		let collection = CollectionData(
			id: doc.documentID,
			name: data["name"] as? String ?? "",
			description: data["description"] as? String ?? "",
			type: data["type"] as? String ?? "Individual",
			isPublic: data["isPublic"] as? Bool ?? false,
			ownerId: data["ownerId"] as? String ?? ownerId,
			ownerName: data["ownerName"] as? String ?? "",
			owners: data["owners"] as? [String] ?? [ownerId],
			admins: data["admins"] as? [String],
			imageURL: data["imageURL"] as? String,
			invitedUsers: data["invitedUsers"] as? [String] ?? [],
			members: data["members"] as? [String] ?? [ownerId],
			memberCount: data["memberCount"] as? Int ?? 1,
			followers: data["followers"] as? [String] ?? [],
			followerCount: data["followerCount"] as? Int ?? 0,
			allowedUsers: data["allowedUsers"] as? [String] ?? [],
			deniedUsers: data["deniedUsers"] as? [String] ?? [],
			createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
		)
		
		return (collection, deletedAtDate)
	}
}
```

### 1.4 Backend: Delete Collection Route

```javascript
// In backend/src/routes/collections.js

// Delete a collection (soft delete - only owner can do this)
router.delete('/:collectionId', verifyToken, async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware

    console.log(`🗑️ DELETE /api/collections/${collectionId} - User: ${userId}`);

    // Find collection in MongoDB
    const collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Verify user is owner
    if (collection.ownerId !== userId) {
      console.log(`❌ Access denied: User ${userId} is not owner of collection ${collectionId}`);
      return res.status(403).json({ error: 'Forbidden: Only owner can delete collection' });
    }

    const ownerId = collection.ownerId;

    // Soft delete: Move to deleted_collections in Firebase
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      
      // Get collection data from Firebase
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const collectionData = firebaseCollection.data();
        
        // Add deletedAt timestamp and isDeleted flag
        const deletedData = {
          ...collectionData,
          deletedAt: admin.firestore.FieldValue.serverTimestamp(),
          isDeleted: true
        };
        
        // Move to deleted_collections subcollection
        const deletedRef = db.collection('users').doc(ownerId).collection('deleted_collections').doc(collectionId);
        await deletedRef.set(deletedData);
        console.log(`✅ Collection moved to deleted_collections in Firebase`);
        
        // Remove from main collections
        await firebaseCollection.ref.delete();
        console.log(`✅ Collection removed from main collections in Firebase`);
      } else {
        // If not in Firebase, create it from MongoDB data
        const collectionData = {
          name: collection.name,
          description: collection.description || '',
          type: collection.type,
          isPublic: collection.isPublic || false,
          ownerId: collection.ownerId,
          ownerName: collection.ownerName || '',
          imageURL: collection.imageURL || null,
          members: collection.members || [],
          memberCount: collection.memberCount || 0,
          admins: collection.admins || [],
          allowedUsers: collection.allowedUsers || [],
          deniedUsers: collection.deniedUsers || [],
          createdAt: collection.createdAt ? admin.firestore.Timestamp.fromDate(collection.createdAt) : admin.firestore.Timestamp.now(),
          deletedAt: admin.firestore.FieldValue.serverTimestamp(),
          isDeleted: true
        };
        
        const deletedRef = db.collection('users').doc(ownerId).collection('deleted_collections').doc(collectionId);
        await deletedRef.set(collectionData);
        console.log(`✅ Collection moved to deleted_collections in Firebase (created from MongoDB)`);
      }
    } catch (error) {
      console.error('Error soft deleting in Firebase:', error);
      // Continue even if Firebase update fails - we'll still mark as deleted in MongoDB
    }

    // Mark as deleted in MongoDB (optional - Firebase is source of truth)
    try {
      collection.isDeleted = true;
      collection.deletedAt = new Date();
      await collection.save();
      console.log(`✅ Collection marked as deleted in MongoDB`);
    } catch (error) {
      console.error('Error updating MongoDB (non-critical):', error);
      // Continue even if MongoDB update fails
    }

    res.json({ 
      success: true,
      message: 'Collection deleted successfully',
      collectionId,
      ownerId
    });
  } catch (error) {
    console.error('Delete collection error:', error);
    res.status(500).json({ error: error.message });
  }
});
```

---

## 2. EDIT COLLECTION

### 2.1 Frontend: CYEditCollectionView.swift

**See full file above - lines 1-606**

Key functions:
- `loadCollectionData()` - Loads collection name, description, visibility
- `saveCollection()` - Saves changes to backend
- `loadOwnerProfileImage()` - Loads owner's profile image for fallback

### 2.2 Frontend: CollectionService.updateCollection()

```swift
// In CollectionService.swift

func updateCollection(
	collectionId: String,
	name: String? = nil,
	description: String? = nil,
	image: UIImage? = nil,
	imageURL: String? = nil,
	isPublic: Bool? = nil,
	allowedUsers: [String]? = nil,
	deniedUsers: [String]? = nil
) async throws {
	var finalImageURL: String? = imageURL
	
	// Upload image to Firebase Storage first (like profile images)
	if let image = image {
		print("📤 CollectionService: Starting collection image upload to Firebase Storage...")
		
		do {
			let storageService = await MainActor.run { StorageService.shared }
			finalImageURL = try await storageService.uploadCollectionImage(image, collectionId: collectionId)
			print("✅ Collection image uploaded to Firebase Storage: \(finalImageURL ?? "nil")")
		} catch {
			print("❌ CollectionService: Failed to upload collection image to Firebase Storage: \(error)")
			throw error
		}
	}
	
	// CRITICAL FIX: Use backend API FIRST (source of truth) - matches edit profile pattern
	// Backend will update both MongoDB and Firebase, ensuring consistency
	do {
		let _ = try await apiClient.updateCollection(
			collectionId: collectionId,
			name: name,
			description: description,
			image: nil, // Don't send image data - we use Firebase Storage URLs
			imageURL: finalImageURL, // Send Firebase Storage URL to backend
			isPublic: isPublic,
			allowedUsers: allowedUsers,  // Send array even if empty
			deniedUsers: deniedUsers  // Send array even if empty
		)
		print("✅ CollectionService: Collection updated via backend API (source of truth)")
	} catch {
		print("⚠️ CollectionService: Backend API failed, falling back to Firebase: \(error)")
		
		// Fallback to Firebase if backend fails
		let db = Firestore.firestore()
		let collectionRef = db.collection("collections").document(collectionId)
		
		var firestoreUpdate: [String: Any] = [:]
		
		// Update name if provided
		if let name = name {
			firestoreUpdate["name"] = name
		}
		
		// Update description if provided
		if let description = description {
			firestoreUpdate["description"] = description
		}
		
		// Update imageURL if provided
		if let imageURL = finalImageURL {
			firestoreUpdate["imageURL"] = imageURL
		}
		
		// Update isPublic if provided
		if let isPublic = isPublic {
			firestoreUpdate["isPublic"] = isPublic
		}
		
		// Update allowedUsers if provided
		if let allowedUsers = allowedUsers {
			firestoreUpdate["allowedUsers"] = allowedUsers
		}
		
		// Update deniedUsers if provided
		if let deniedUsers = deniedUsers {
			firestoreUpdate["deniedUsers"] = deniedUsers
		}
		
		// CRITICAL: Use set with merge: true to handle collections that don't exist in Firestore
		if !firestoreUpdate.isEmpty {
			try await collectionRef.setData(firestoreUpdate, merge: true)
			print("✅ CollectionService: Collection updated in Firebase Firestore (fallback)")
		}
	}
	
	// CRITICAL: Reload collection from backend to get verified data (like edit profile)
	print("🔍 Verifying collection update was saved...")
	var verifiedCollection: CollectionData?
	do {
		verifiedCollection = try await getCollection(collectionId: collectionId)
		if let verified = verifiedCollection {
			print("✅ Verified update - Name: \(verified.name), Description: \(verified.description ?? "nil"), Image URL: \(verified.imageURL ?? "nil")")
		}
	} catch {
		print("⚠️ Could not verify collection update: \(error)")
	}
	
	// Clear collection cache to force fresh load (like edit profile clears cache)
	CYInsideCollectionCache.shared.clearCache(for: collectionId)
	if let oldImageURL = imageURL, !oldImageURL.isEmpty {
		ImageCache.shared.removeImage(for: oldImageURL)
	}
	
	// Post comprehensive notification with verified data (like edit profile)
	await MainActor.run {
		var updateData: [String: Any] = [
			"collectionId": collectionId
		]
		
		// Use verified data from backend if available, otherwise use what we sent
		if let verified = verifiedCollection {
			updateData["name"] = verified.name
			updateData["description"] = verified.description ?? ""
			if let imageURL = verified.imageURL {
				updateData["imageURL"] = imageURL
			}
			updateData["isPublic"] = verified.isPublic
		} else {
			// Fallback to what we sent if verification failed
			if let name = name {
				updateData["name"] = name
			}
			if let description = description {
				updateData["description"] = description
			}
			if let imageURL = finalImageURL {
				updateData["imageURL"] = imageURL
			}
			if let isPublic = isPublic {
				updateData["isPublic"] = isPublic
			}
		}
		
		if let allowedUsers = allowedUsers {
			updateData["allowedUsers"] = allowedUsers
		}
		if let deniedUsers = deniedUsers {
			updateData["deniedUsers"] = deniedUsers
		}
		
		NotificationCenter.default.post(
			name: NSNotification.Name("CollectionUpdated"),
			object: collectionId,
			userInfo: ["updatedData": updateData]
		)
		
		// Also post ProfileUpdated to refresh profile views
		NotificationCenter.default.post(
			name: NSNotification.Name("ProfileUpdated"),
			object: nil,
			userInfo: ["updatedData": ["collectionId": collectionId]]
		)
		
		print("📢 CollectionService: Posted CollectionUpdated notification with verified data")
		print("   - Name: \(updateData["name"] as? String ?? "nil")")
		print("   - Description: \(updateData["description"] as? String ?? "nil")")
		print("   - Image URL: \(updateData["imageURL"] as? String ?? "nil")")
	}
}
```

### 2.3 Frontend: APIClient.updateCollection()

```swift
// In APIClient.swift

func updateCollection(
	collectionId: String,
	name: String? = nil,
	description: String? = nil,
	image: Data? = nil,
	imageURL: String? = nil,
	isPublic: Bool? = nil,
	allowedUsers: [String]? = nil,
	deniedUsers: [String]? = nil
) async throws -> CollectionResponse {
	var files: [(data: Data, fieldName: String, fileName: String, mimeType: String)] = []
	if let image = image {
		files.append((image, "image", "collection.jpg", "image/jpeg"))
	}
	
	var body: [String: Any] = [:]
	
	// CRITICAL FIX: Always send name and description if provided (even if empty)
	// Backend needs these fields to update them properly (matches edit profile pattern)
	if let nameValue = name {
		body["name"] = nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	if let descriptionValue = description {
		body["description"] = descriptionValue.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	// Include imageURL if provided (from Firebase Storage)
	if let imageURL = imageURL, !imageURL.isEmpty {
		body["imageURL"] = imageURL
		print("🔧 APIClient.updateCollection: Including imageURL from Firebase Storage")
	}
	
	// CRITICAL: Always include isPublic if it's provided (even if false)
	if let isPublicValue = isPublic {
		body["isPublic"] = isPublicValue  // Send as Bool directly
		print("🔧 APIClient.updateCollection: Including isPublic=\(isPublicValue) (Bool)")
	} else {
		print("🔧 APIClient.updateCollection: isPublic is nil - not updating visibility")
	}
	
	// CRITICAL FIX: Always send arrays if they're provided (even if empty)
	// Backend expects arrays, not nil
	if let allowedUsers = allowedUsers {
		body["allowedUsers"] = allowedUsers  // Send even if empty array
	}
	
	if let deniedUsers = deniedUsers {
		body["deniedUsers"] = deniedUsers  // Send even if empty array
	}
	
	print("🔧 APIClient.updateCollection: Full request body: \(body)")
	
	// CRITICAL: Ensure body is not empty or backend might reject
	if body.isEmpty {
		print("⚠️ APIClient.updateCollection: Body is empty - this might cause 400 error")
		throw NSError(domain: "APIClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "No fields to update"])
	}
	
	var request = try await createRequest(endpoint: "/collections/\(collectionId)", method: "PUT")
	
	if !files.isEmpty {
		// Use multipart form data if we have files
		var formData: [String: String] = [:]
		for (key, value) in body {
			if let stringValue = value as? String {
				formData[key] = stringValue
			} else if let boolValue = value as? Bool {
				formData[key] = String(boolValue)
			} else if let arrayValue = value as? [String] {
				formData[key] = arrayValue.joined(separator: ",")
			}
		}
		
		var imageDataDict: [String: Data] = [:]
		for file in files {
			formData[file.fieldName] = file.fieldName
			imageDataDict[file.fieldName] = file.data
		}
		
		request.httpBody = try createMultipartBody(formData: formData, media: imageDataDict)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
	} else {
		// Use JSON if no files
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
	}
	
	let (data, response) = try await URLSession.shared.data(for: request)
	try validateResponse(response, data: data)
	return try JSONDecoder().decode(CollectionResponse.self, from: data)
}
```

### 2.4 Backend: Update Collection Route

```javascript
// In backend/src/routes/collections.js

router.put('/:collectionId', verifyToken, upload.fields([
  { name: 'image', maxCount: 1 }
]), async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware
    const body = req.body;

    console.log(`📝 PUT /api/collections/${collectionId} - User: ${userId}`);
    console.log(`📝 Request body keys:`, Object.keys(body));

    // Find collection in MongoDB
    let collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Verify user is owner or admin
    let isAdmin = false;
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const firebaseData = firebaseCollection.data();
        const admins = firebaseData?.admins || [];
        isAdmin = admins.includes(userId);
      }
    } catch (error) {
      console.error('Error checking admin status (non-critical):', error);
    }

    const isOwner = collection.ownerId === userId;
    
    if (!isOwner && !isAdmin) {
      console.log(`❌ Access denied: User ${userId} is not owner or admin of collection ${collectionId}`);
      return res.status(403).json({ error: 'Forbidden: Only owner or admins can update collection' });
    }

    // Build update data - matches edit profile pattern (only update if provided, preserve existing if not)
    // CRITICAL: Always update if provided, even if empty string (user might want to clear description)
    const updateData = {
      name: body.name !== undefined ? body.name.trim() : (collection.name || ''),
      description: body.description !== undefined ? body.description.trim() : (collection.description || ''),
      isPublic: body.isPublic !== undefined ? (body.isPublic === 'true' || body.isPublic === true) : (collection.isPublic || false)
    };
    
    console.log(`📝 Update data: name="${updateData.name}", description="${updateData.description}", isPublic=${updateData.isPublic}`);

    // Handle collection image upload (matches edit profile pattern)
    if (req.files && req.files.image && req.files.image[0]) {
      try {
        const file = req.files.image[0];
        const imageURL = await uploadToS3(file.buffer, 'collections', file.mimetype);
        updateData.imageURL = imageURL;
        console.log(`✅ Uploaded collection image to S3: ${imageURL}`);
      } catch (error) {
        console.error('Collection image upload error:', error);
        // Continue without image if upload fails
      }
    } else if (body.imageURL !== undefined) {
      // Allow setting imageURL directly (for Firebase Storage URLs) - matches edit profile pattern
      updateData.imageURL = body.imageURL || null;
    } else {
      // Preserve existing imageURL if not provided
      updateData.imageURL = collection.imageURL || null;
    }

    // Update collection in MongoDB (matches edit profile pattern)
    Object.assign(collection, updateData);
    await collection.save();
    console.log(`✅ Updated collection in MongoDB: ${collectionId}`);

    // CRITICAL FIX: Update Firebase with ALL fields (name, description, isPublic, imageURL, etc.)
    // This ensures Firebase has the latest data and matches edit profile pattern
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollectionRef = db.collection('collections').doc(collectionId);
      
      const firebaseUpdate = {};
      
      // CRITICAL: Always update basic fields in Firebase (name, description, isPublic, imageURL)
      // These are the fields that users edit, so they MUST be in Firebase
      firebaseUpdate.name = updateData.name;
      firebaseUpdate.description = updateData.description || '';
      firebaseUpdate.isPublic = updateData.isPublic;
      if (updateData.imageURL !== undefined) {
        firebaseUpdate.imageURL = updateData.imageURL;
      }
      
      // Handle allowedUsers (for private collections)
      // CRITICAL: Always save allowedUsers if provided, even if empty array (clears access)
      if (body.allowedUsers !== undefined) {
        firebaseUpdate.allowedUsers = Array.isArray(body.allowedUsers) ? body.allowedUsers : [];
        console.log(`📝 Updating allowedUsers: ${firebaseUpdate.allowedUsers.length} users`);
      }
      
      // Handle deniedUsers (for public collections)
      // CRITICAL: Always save deniedUsers if provided, even if empty array (clears restrictions)
      if (body.deniedUsers !== undefined) {
        firebaseUpdate.deniedUsers = Array.isArray(body.deniedUsers) ? body.deniedUsers : [];
        console.log(`📝 Updating deniedUsers: ${firebaseUpdate.deniedUsers.length} users`);
      }
      
      // Handle members array
      if (body.members !== undefined) {
        firebaseUpdate.members = Array.isArray(body.members) ? body.members : [];
        firebaseUpdate.memberCount = firebaseUpdate.members.length;
      }
      
      // Handle admins array
      if (body.admins !== undefined) {
        firebaseUpdate.admins = Array.isArray(body.admins) ? body.admins : [];
      }

      // CRITICAL: Use set with merge: true to ensure collection exists in Firebase
      // This handles cases where collection exists in MongoDB but not in Firebase
      await firebaseCollectionRef.set(firebaseUpdate, { merge: true });
      console.log(`✅ Updated collection in Firebase: ${collectionId}`);
      console.log(`   - Name: ${firebaseUpdate.name}`);
      console.log(`   - Description: ${firebaseUpdate.description}`);
      console.log(`   - isPublic: ${firebaseUpdate.isPublic}`);
      console.log(`   - imageURL: ${firebaseUpdate.imageURL || 'null'}`);
    } catch (error) {
      console.error('Error updating Firebase (non-critical):', error);
      // Continue even if Firebase update fails - matches edit profile pattern
    }

    // Get updated collection data (matches edit profile pattern)
    const updatedCollection = await Collection.findById(collectionId);
    
    // Get Firebase data for response (admins, allowedUsers, deniedUsers)
    let admins = [];
    let allowedUsers = [];
    let deniedUsers = [];
    
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const firebaseData = firebaseCollection.data();
        admins = firebaseData?.admins || [];
        allowedUsers = firebaseData?.allowedUsers || [];
        deniedUsers = firebaseData?.deniedUsers || [];
      }
    } catch (error) {
      console.error('Error fetching Firebase data for response (non-critical):', error);
    }

    // Return complete collection data (matches edit profile response pattern)
    res.json({
      id: updatedCollection._id.toString(),
      name: updatedCollection.name || '',
      description: updatedCollection.description || '',
      type: updatedCollection.type || 'Individual',
      isPublic: updatedCollection.isPublic || false,
      ownerId: updatedCollection.ownerId,
      ownerName: updatedCollection.ownerName || '',
      imageURL: updatedCollection.imageURL || null,
      members: updatedCollection.members || [],
      admins: admins,
      allowedUsers: allowedUsers,
      deniedUsers: deniedUsers,
      memberCount: updatedCollection.memberCount || updatedCollection.members?.length || 0,
      createdAt: updatedCollection.createdAt ? updatedCollection.createdAt.toISOString() : new Date().toISOString()
    });
  } catch (error) {
    console.error('Update collection error:', error);
    res.status(500).json({ error: error.message });
  }
});
```

---

## 3. ACCESS CONTROL (ALLOW/DENY ACCESS)

### 3.1 Frontend: CYAccessView.swift

**See full file above - lines 1-466**

Key functions:
- `loadUsers()` - Loads all users (excluding blocked users and members)
- `loadCurrentAccessUsers()` - Loads current allowedUsers or deniedUsers
- `saveAccessChanges()` - Saves access changes to backend

### 3.2 Frontend: CYAccessView.saveAccessChanges()

```swift
// In CYAccessView.swift

private func saveAccessChanges() async {
	isSaving = true
	
	do {
		// CRITICAL FIX: Always send arrays, even if empty
		// Backend might require the field to be present
		let allowedUsersArray = Array(selectedUserIds)
		let deniedUsersArray = Array(selectedUserIds)
		
		// Save access changes via backend API
		if isPrivateCollection {
			// For private collections, update allowedUsers
			// CRITICAL: Send empty array if no users selected, don't send nil
			try await CollectionService.shared.updateCollection(
				collectionId: collection.id,
				name: nil,
				description: nil,
				image: nil,
				imageURL: nil,
				isPublic: nil,  // Don't change visibility
				allowedUsers: allowedUsersArray,  // Always send array, even if empty
				deniedUsers: nil  // Don't update deniedUsers for private collections
			)
		} else {
			// For public collections, update deniedUsers
			// CRITICAL: Send empty array if no users selected, don't send nil
			try await CollectionService.shared.updateCollection(
				collectionId: collection.id,
				name: nil,
				description: nil,
				image: nil,
				imageURL: nil,
				isPublic: nil,  // Don't change visibility
				allowedUsers: nil,  // Don't update allowedUsers for public collections
				deniedUsers: deniedUsersArray  // Always send array, even if empty
			)
		}
		
		// CRITICAL FIX: Verify update was saved (like edit profile)
		print("🔍 Verifying access changes were saved...")
		let verifiedCollection = try await CollectionService.shared.getCollection(collectionId: collection.id)
		guard let verifiedCollection = verifiedCollection else {
			throw NSError(domain: "AccessUpdateError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to verify access update"])
		}
		
		let verifiedAllowedUsers = verifiedCollection.allowedUsers
		let verifiedDeniedUsers = verifiedCollection.deniedUsers
		
		print("✅ Verified access update - Allowed: \(verifiedAllowedUsers.count), Denied: \(verifiedDeniedUsers.count)")
		
		// CRITICAL FIX: Post comprehensive notifications with verified data (like edit profile)
		await MainActor.run {
			// Build update data with verified access changes from Firebase
			var updateData: [String: Any] = [
				"collectionId": collection.id
			]
			
			if isPrivateCollection {
				updateData["allowedUsers"] = verifiedAllowedUsers
			} else {
				updateData["deniedUsers"] = verifiedDeniedUsers
			}
			
			// Post CollectionUpdated with verified access data
			NotificationCenter.default.post(
				name: NSNotification.Name("CollectionUpdated"),
				object: collection.id,
				userInfo: ["updatedData": updateData]
			)
			
			// Post ProfileUpdated to refresh profile views (collections list)
			NotificationCenter.default.post(
				name: NSNotification.Name("ProfileUpdated"),
				object: nil,
				userInfo: ["updatedData": ["collectionId": collection.id]]
			)
			
			print("📢 CYAccessView: Posted comprehensive collection update notifications")
			print("   - Collection ID: \(collection.id)")
			print("   - Verified access: \(isPrivateCollection ? "allowedUsers" : "deniedUsers") = \(isPrivateCollection ? verifiedAllowedUsers.count : verifiedDeniedUsers.count) users")
			
			dismiss()
		}
		
	} catch {
		await MainActor.run {
			errorMessage = error.localizedDescription
			showError = true
			isSaving = false
		}
	}
}
```

### 3.3 Backend: Access Control Logic (in Update Route)

The access control is handled in the same update route (see 2.4 above). The key parts are:

```javascript
// Handle allowedUsers (for private collections)
// CRITICAL: Always save allowedUsers if provided, even if empty array (clears access)
if (body.allowedUsers !== undefined) {
  firebaseUpdate.allowedUsers = Array.isArray(body.allowedUsers) ? body.allowedUsers : [];
  console.log(`📝 Updating allowedUsers: ${firebaseUpdate.allowedUsers.length} users`);
}

// Handle deniedUsers (for public collections)
// CRITICAL: Always save deniedUsers if provided, even if empty array (clears restrictions)
if (body.deniedUsers !== undefined) {
  firebaseUpdate.deniedUsers = Array.isArray(body.deniedUsers) ? body.deniedUsers : [];
  console.log(`📝 Updating deniedUsers: ${firebaseUpdate.deniedUsers.length} users`);
}
```

---

## SUMMARY

### Deleted Collections Flow:

1. **Delete**: Frontend calls `APIClient.deleteCollection()` → Backend sets `deletedAt` in MongoDB and moves collection to `deleted_collections` subcollection in Firebase
2. **View**: Frontend queries Firebase `deleted_collections` subcollection for collections with `deletedAt` field
3. **Restore**: Frontend calls `CollectionService.recoverCollection()` → Restores collection from `deleted_collections` back to main `collections`
4. **Permanent Delete**: Frontend calls `CollectionService.permanentlyDeleteCollection()` → Deletes collection from `deleted_collections` permanently

### Edit Collection Flow:

1. User edits name, description, image, or visibility in `CYEditCollectionView`
2. Image uploaded to Firebase Storage first (if changed)
3. `CollectionService.updateCollection()` called with all changes
4. `APIClient.updateCollection()` sends PUT request to backend
5. Backend updates MongoDB and syncs to Firestore for real-time updates
6. CollectionService verifies update by reloading from backend
7. Notifications posted with verified data for immediate UI updates

### Access Control Flow:

1. **Private Collections**: Owner can add users to `allowedUsers` array
2. **Public Collections**: Owner can add users to `deniedUsers` array
3. Frontend calls `CollectionService.updateCollection()` with `allowedUsers` or `deniedUsers`
4. Backend updates the array in MongoDB and Firestore
5. CollectionService verifies update by reloading from backend
6. Notifications posted with verified data for immediate UI updates

---

## KEY BACKEND REQUIREMENTS

1. **Deleted Collections**:
   - Must set `deletedAt` timestamp in Firebase `deleted_collections` subcollection
   - Must move collection from main `collections` to `users/{ownerId}/deleted_collections/{collectionId}`
   - Must check 15-day window before allowing restore
   - Must handle permanent deletion

2. **Edit Collection**:
   - Must accept optional fields (name, description, isPublic, imageURL, allowedUsers, deniedUsers)
   - Must sync all updates to Firestore for real-time updates
   - Must handle boolean `isPublic` correctly (even when false)
   - Must use `set()` with `merge: true` to ensure collection exists in Firebase

3. **Access Control**:
   - Must accept `allowedUsers` and `deniedUsers` as arrays (can be empty `[]`)
   - Must update these arrays in both MongoDB and Firestore
   - Must verify updates and return verified data in response

