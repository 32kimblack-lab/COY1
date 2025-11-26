import SwiftUI
import Combine
import FirebaseFirestore

@MainActor
final class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()
    
    @Published var pendingProfileUsername: String?
    @Published var pendingProfileUserId: String?
    @Published var shouldNavigateToProfile = false
    
    private init() {}
    
    // Handle Universal Link: https://coy.services/username
    func handleUniversalLink(_ url: URL) {
        print("🔗 DeepLinkManager: Handling Universal Link: \(url.absoluteString)")
        
        // Extract username from URL path
        // URL format: https://coy.services/username
        let path = url.path
        
        // Remove leading slash and extract username
        let pathComponents = path.components(separatedBy: "/").filter { !$0.isEmpty }
        
        guard let username = pathComponents.first else {
            print("⚠️ DeepLinkManager: No username found in URL path")
            return
        }
        
        print("✅ DeepLinkManager: Extracted username: \(username)")
        
        // Look up userId from username
        Task {
            await lookupUserIdFromUsername(username)
        }
    }
    
    // Handle custom URL scheme: coy://profile/username
    func handleCustomURL(_ url: URL) {
        print("🔗 DeepLinkManager: Handling custom URL: \(url.absoluteString)")
        
        guard url.scheme == "coy" else {
            print("⚠️ DeepLinkManager: Invalid URL scheme: \(url.scheme ?? "nil")")
            return
        }
        
        let path = url.path
        let pathComponents = path.components(separatedBy: "/").filter { !$0.isEmpty }
        
        guard pathComponents.count >= 2,
              pathComponents[0] == "profile",
              let username = pathComponents.last else {
            print("⚠️ DeepLinkManager: Invalid URL format. Expected: coy://profile/username")
            return
        }
        
        print("✅ DeepLinkManager: Extracted username from custom URL: \(username)")
        
        // Look up userId from username
        Task {
            await lookupUserIdFromUsername(username)
        }
    }
    
    // Look up userId from username in Firestore
    private func lookupUserIdFromUsername(_ username: String) async {
        print("🔍 DeepLinkManager: Looking up userId for username: \(username)")
        
        let db = Firestore.firestore()
        
        do {
            // Query Firestore for user with matching username
            let snapshot = try await db.collection("users")
                .whereField("username", isEqualTo: username)
                .limit(to: 1)
                .getDocuments()
            
            guard let document = snapshot.documents.first else {
                print("⚠️ DeepLinkManager: No user found with username: \(username)")
                return
            }
            
            let userId = document.documentID
            print("✅ DeepLinkManager: Found userId: \(userId) for username: \(username)")
            
            await MainActor.run {
                self.pendingProfileUsername = username
                self.pendingProfileUserId = userId
                self.shouldNavigateToProfile = true
                
                // Post notification for MainTabView to handle navigation
                NotificationCenter.default.post(
                    name: NSNotification.Name("NavigateToUserProfile"),
                    object: userId,
                    userInfo: ["userId": userId, "username": username]
                )
            }
        } catch {
            print("❌ DeepLinkManager: Error looking up username: \(error)")
        }
    }
    
    func clearPendingNavigation() {
        pendingProfileUsername = nil
        pendingProfileUserId = nil
        shouldNavigateToProfile = false
    }
}

