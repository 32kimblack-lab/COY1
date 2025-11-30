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
    
    // Handle Universal Link: https://coy.services/profile/userId OR https://coy.services/username (backward compatibility)
    func handleUniversalLink(_ url: URL) {
        #if DEBUG
        print("🔗 DeepLinkManager: Handling Universal Link: \(url.absoluteString)")
        #endif
        
        let path = url.path
        let pathComponents = path.components(separatedBy: "/").filter { !$0.isEmpty }
        
        // Check if URL is new format: /profile/userId
        if pathComponents.count >= 2 && pathComponents[0] == "profile" {
            // New format: https://coy.services/profile/userId
            let userId = pathComponents[1]
            #if DEBUG
            print("✅ DeepLinkManager: Extracted userId from profile URL: \(userId)")
            #endif
            
            Task {
                await navigateToProfile(userId: userId, username: nil)
        }
        } else if let username = pathComponents.first {
            // Old format (backward compatibility): https://coy.services/username
        #if DEBUG
            print("✅ DeepLinkManager: Extracted username (backward compatibility): \(username)")
        #endif
        
        // Look up userId from username
        Task {
            await lookupUserIdFromUsername(username)
            }
        } else {
            #if DEBUG
            print("⚠️ DeepLinkManager: No valid path found in URL")
            #endif
        }
    }
    
    // Handle custom URL scheme: coy://profile/userId OR coy://profile/username (backward compatibility)
    func handleCustomURL(_ url: URL) {
        #if DEBUG
        print("🔗 DeepLinkManager: Handling custom URL: \(url.absoluteString)")
        #endif
        
        guard url.scheme == "coy" else {
            #if DEBUG
            print("⚠️ DeepLinkManager: Invalid URL scheme: \(url.scheme ?? "nil")")
            #endif
            return
        }
        
        let path = url.path
        let pathComponents = path.components(separatedBy: "/").filter { !$0.isEmpty }
        
        guard pathComponents.count >= 2,
              pathComponents[0] == "profile" else {
            #if DEBUG
            print("⚠️ DeepLinkManager: Invalid URL format. Expected: coy://profile/userId or coy://profile/username")
            #endif
            return
        }
        
        let identifier = pathComponents[1]
        
        // Check if identifier looks like a Firebase user ID (typically 28 characters, alphanumeric)
        // Firebase user IDs are usually 28 characters long
        if identifier.count == 28 && identifier.allSatisfy({ $0.isLetter || $0.isNumber }) {
            // Likely a user ID - use directly
        #if DEBUG
            print("✅ DeepLinkManager: Extracted userId from custom URL: \(identifier)")
        #endif
            Task {
                await navigateToProfile(userId: identifier, username: nil)
            }
        } else {
            // Likely a username - lookup userId (backward compatibility)
            #if DEBUG
            print("✅ DeepLinkManager: Extracted username from custom URL (backward compatibility): \(identifier)")
            #endif
        Task {
                await lookupUserIdFromUsername(identifier)
            }
        }
    }
    
    // Look up userId from username in Firestore
    private func lookupUserIdFromUsername(_ username: String) async {
        #if DEBUG
        print("🔍 DeepLinkManager: Looking up userId for username: \(username)")
        #endif
        
        let db = Firestore.firestore()
        
        do {
            // Query Firestore for user with matching username
            let snapshot = try await db.collection("users")
                .whereField("username", isEqualTo: username)
                .limit(to: 1)
                .getDocuments()
            
            guard let document = snapshot.documents.first else {
                #if DEBUG
                print("⚠️ DeepLinkManager: No user found with username: \(username)")
                #endif
                return
            }
            
            let userId = document.documentID
            #if DEBUG
            print("✅ DeepLinkManager: Found userId: \(userId) for username: \(username)")
            #endif
            
            await navigateToProfile(userId: userId, username: username)
        } catch {
            #if DEBUG
            print("❌ DeepLinkManager: Error looking up username: \(error)")
            #endif
        }
    }
    
    // Navigate to profile using userId (and optional username for display)
    private func navigateToProfile(userId: String, username: String?) async {
            await MainActor.run {
                self.pendingProfileUsername = username
                self.pendingProfileUserId = userId
                self.shouldNavigateToProfile = true
                
                // Post notification for MainTabView to handle navigation
                NotificationCenter.default.post(
                    name: NSNotification.Name("NavigateToUserProfile"),
                    object: userId,
                userInfo: ["userId": userId, "username": username ?? ""]
                )
            
            #if DEBUG
            print("✅ DeepLinkManager: Navigating to profile - userId: \(userId), username: \(username ?? "nil")")
            #endif
        }
    }
    
    func clearPendingNavigation() {
        pendingProfileUsername = nil
        pendingProfileUserId = nil
        shouldNavigateToProfile = false
    }
}

