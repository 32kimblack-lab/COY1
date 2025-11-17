const mongoose = require('mongoose');

const userSchema = new mongoose.Schema({
  uid: { type: String, required: true, unique: true }, // Firebase user ID
  name: String,
  username: { type: String, unique: true, sparse: true },
  email: String,
  profileImageURL: String,
  backgroundImageURL: String,
  birthMonth: String,
  birthDay: String,
  birthYear: String,
  blockedUsers: [{ type: String }],
  blockedCollectionIds: [{ type: String }],
  hiddenPostIds: [{ type: String }],
  starredPostIds: [{ type: String }],
  collectionSortPreference: String,
  customCollectionOrder: [{ type: String }]
}, { timestamps: true });

module.exports = mongoose.model('User', userSchema);

