import Foundation
import FirebaseFirestore
import FirebaseAuth

/// Monitors Firebase usage and alerts when approaching limits
@MainActor
final class FirebaseUsageMonitor {
	static let shared = FirebaseUsageMonitor()
	private init() {}
	
	// Usage tracking
	private var dailyReads: Int = 0
	private var dailyWrites: Int = 0
	private var lastResetDate: Date = Date()
	
	// Alert thresholds (based on Firebase Free tier limits)
	private let freeTierReadLimit = 50_000 // 50K reads/day
	private let freeTierWriteLimit = 20_000 // 20K writes/day
	private let alertThreshold = 0.8 // Alert at 80% of limit
	
	/// Track a Firestore read operation
	func trackRead(count: Int = 1) {
		resetIfNeeded()
		dailyReads += count
		
		// Check if approaching limit
		let usagePercent = Double(dailyReads) / Double(freeTierReadLimit)
		if usagePercent >= alertThreshold {
			print("⚠️ Firebase Usage Alert: \(dailyReads)/\(freeTierReadLimit) reads today (\(Int(usagePercent * 100))%)")
			
			if usagePercent >= 0.95 {
				print("🚨 CRITICAL: Approaching Firebase read limit! Upgrade to Blaze plan immediately!")
				// Post notification for UI alert if needed
				NotificationCenter.default.post(
					name: NSNotification.Name("FirebaseUsageCritical"),
					object: nil,
					userInfo: ["type": "reads", "usage": dailyReads, "limit": freeTierReadLimit]
				)
			}
		}
	}
	
	/// Track a Firestore write operation
	func trackWrite(count: Int = 1) {
		resetIfNeeded()
		dailyWrites += count
		
		// Check if approaching limit
		let usagePercent = Double(dailyWrites) / Double(freeTierWriteLimit)
		if usagePercent >= alertThreshold {
			print("⚠️ Firebase Usage Alert: \(dailyWrites)/\(freeTierWriteLimit) writes today (\(Int(usagePercent * 100))%)")
			
			if usagePercent >= 0.95 {
				print("🚨 CRITICAL: Approaching Firebase write limit! Upgrade to Blaze plan immediately!")
				// Post notification for UI alert if needed
				NotificationCenter.default.post(
					name: NSNotification.Name("FirebaseUsageCritical"),
					object: nil,
					userInfo: ["type": "writes", "usage": dailyWrites, "limit": freeTierWriteLimit]
				)
			}
		}
	}
	
	/// Get current usage statistics
	func getUsageStats() -> (reads: Int, writes: Int, readPercent: Double, writePercent: Double) {
		resetIfNeeded()
		let readPercent = Double(dailyReads) / Double(freeTierReadLimit)
		let writePercent = Double(dailyWrites) / Double(freeTierWriteLimit)
		return (dailyReads, dailyWrites, readPercent, writePercent)
	}
	
	private func resetIfNeeded() {
		let calendar = Calendar.current
		if !calendar.isDate(lastResetDate, inSameDayAs: Date()) {
			// New day - reset counters
			print("📊 Firebase Usage Monitor: Resetting daily counters")
			dailyReads = 0
			dailyWrites = 0
			lastResetDate = Date()
		}
	}
	
	/// Check if app should warn user about Firebase plan
	func shouldWarnAboutPlan() -> Bool {
		let stats = getUsageStats()
		return stats.readPercent >= 0.5 || stats.writePercent >= 0.5 // Warn at 50% usage
	}
}
