import Foundation
import LocalAuthentication

@MainActor
class BiometricAuthManager {
	func authenticateWithFallback(reason: String) async -> Bool {
		let context = LAContext()
		var error: NSError?
		
		// Check if biometric authentication is available
		guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
			// Biometric authentication not available, allow access
			return true
		}
		
		do {
			let success = try await context.evaluatePolicy(
				.deviceOwnerAuthenticationWithBiometrics,
				localizedReason: reason
			)
			return success
		} catch {
			// If authentication fails, deny access
			print("Biometric authentication failed: \(error.localizedDescription)")
			return false
		}
	}
}

