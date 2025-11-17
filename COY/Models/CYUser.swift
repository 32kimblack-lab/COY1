import Foundation

struct CYUser: Identifiable {
	let id: String
	let name: String
	let username: String
	var profileImageURL: String
	
	init(id: String, name: String, username: String, profileImageURL: String = "") {
		self.id = id
		self.name = name
		self.username = username
		self.profileImageURL = profileImageURL
	}
}

