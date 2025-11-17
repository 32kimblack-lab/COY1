import UIKit
import FirebaseCore

// AppDelegate to fix Firebase Analytics warning
class AppDelegate: NSObject, UIApplicationDelegate {
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
		// Firebase is already configured in COYApp.init()
		return true
	}
}

