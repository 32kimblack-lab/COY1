const mongoose = require('mongoose');

const collectionSchema = new mongoose.Schema({
  name: { type: String, required: true },
  description: String,
  type: String,
  isPublic: { type: Boolean, default: false },
  ownerId: { type: String, required: true },
  ownerName: String,
  imageURL: String,
  members: [{ type: String }],
  memberCount: { type: Number, default: 0 }
}, { timestamps: true });

module.exports = mongoose.model('Collection', collectionSchema);


