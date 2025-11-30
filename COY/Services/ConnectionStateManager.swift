import Foundation
import Network
import Combine

/// Monitors network connection state and provides offline/online detection
@MainActor
class ConnectionStateManager: ObservableObject {
	static let shared = ConnectionStateManager()
	
	@Published var isConnected: Bool = true
	@Published var connectionType: ConnectionType = .unknown
	
	enum ConnectionType {
		case wifi
		case cellular
		case ethernet
		case unknown
		case unavailable
	}
	
	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "NetworkMonitor")
	private var cancellables = Set<AnyCancellable>()
	
	private init() {
		startMonitoring()
	}
	
	/// Start monitoring network connection
	private func startMonitoring() {
		monitor.pathUpdateHandler = { [weak self] path in
			guard let strongSelf = self else { return }
			Task { @MainActor in
				let wasConnected = strongSelf.isConnected
				strongSelf.isConnected = path.status == .satisfied
				
				// Determine connection type
				if path.status == .satisfied {
					if path.usesInterfaceType(.wifi) {
						strongSelf.connectionType = .wifi
					} else if path.usesInterfaceType(.cellular) {
						strongSelf.connectionType = .cellular
					} else if path.usesInterfaceType(.wiredEthernet) {
						strongSelf.connectionType = .ethernet
					} else {
						strongSelf.connectionType = .unknown
					}
				} else {
					strongSelf.connectionType = .unavailable
				}
				
				// Notify when connection state changes
				if wasConnected != strongSelf.isConnected {
					if strongSelf.isConnected {
						#if DEBUG
						print("✅ ConnectionStateManager: Network connection restored")
						#endif
						NotificationCenter.default.post(name: NSNotification.Name("NetworkConnectionRestored"), object: nil)
					} else {
						#if DEBUG
						print("⚠️ ConnectionStateManager: Network connection lost")
						#endif
						NotificationCenter.default.post(name: NSNotification.Name("NetworkConnectionLost"), object: nil)
					}
				}
			}
		}
		
		monitor.start(queue: queue)
		
		// Initial check
		let currentPath = monitor.currentPath
		isConnected = currentPath.status == .satisfied
		if currentPath.status == .satisfied {
			if currentPath.usesInterfaceType(.wifi) {
				connectionType = .wifi
			} else if currentPath.usesInterfaceType(.cellular) {
				connectionType = .cellular
			} else {
				connectionType = .unknown
			}
		} else {
			connectionType = .unavailable
		}
	}
	
	/// Check if currently connected
	func checkConnection() -> Bool {
		return isConnected
	}
}

