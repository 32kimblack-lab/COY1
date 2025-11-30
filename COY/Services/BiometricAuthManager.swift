import Foundation
import LocalAuthentication

@MainActor
class BiometricAuthManager {
	func authenticateWithFallback(reason: String) async -> Bool {
		let context = LAContext()
		var error: NSError?
		
		// STEP 1: First, try biometrics-only (Face ID/Touch ID)
		// Check if biometric authentication is available
		if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
			do {
				// Try Face ID/Touch ID first
				let success = try await context.evaluatePolicy(
					.deviceOwnerAuthenticationWithBiometrics,
					localizedReason: reason
				)
				if success {
					print("✅ Biometric authentication successful")
					return true
				}
			} catch let biometricError {
				// Biometric authentication failed or was cancelled
				// Error code -2 = user cancel, -3 = user fallback (wants to use passcode)
				let errorCode = (biometricError as NSError).code
				print("⚠️ Biometric authentication failed/cancelled: \(biometricError.localizedDescription) (code: \(errorCode))")
				
				// If user cancelled (-2) or explicitly wants fallback (-3), proceed to passcode
				// Error code -3 specifically means "User fallback" - they want to use passcode
				if errorCode == -2 || errorCode == -3 {
					print("🔄 User cancelled biometrics or requested passcode, falling back to passcode...")
					// Continue to passcode fallback below
				} else {
					// Other errors (like biometrics not available) - try passcode
					print("🔄 Biometrics unavailable, trying passcode...")
				}
			}
		} else {
			// Biometrics not available, go straight to passcode
			print("⚠️ Biometric authentication not available, using passcode fallback")
		}
		
		// STEP 2: Fallback to passcode if biometrics failed or are unavailable
		// Create a new context for passcode authentication
		let passcodeContext = LAContext()
		var passcodeError: NSError?
		
		guard passcodeContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError) else {
			// If passcode authentication is also not available, deny access
			print("❌ Passcode authentication not available: \(passcodeError?.localizedDescription ?? "Unknown error")")
			return false
		}
		
		do {
			// This will show the passcode entry screen
			let success = try await passcodeContext.evaluatePolicy(
				.deviceOwnerAuthentication,
				localizedReason: reason
			)
			if success {
				print("✅ Passcode authentication successful")
				return true
			} else {
				print("❌ Passcode authentication failed")
				return false
			}
		} catch let passcodeAuthError {
			// Passcode authentication failed (wrong passcode or user cancelled)
			print("❌ Passcode authentication failed: \(passcodeAuthError.localizedDescription)")
			return false
		}
	}
}

