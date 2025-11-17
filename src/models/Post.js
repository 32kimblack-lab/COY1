const mongoose = require('mongoose');

const postSchema = new mongoose.Schema({
  title: String,
  caption: String,
  collectionId: { type: String, required: true },
  authorId: { type: String, required: true },
  authorName: String,
  firstMediaItem: {
    imageURL: String,
    thumbnailURL: String,
    videoURL: String,
    videoDuration: Number,
    isVideo: Boolean
  },
  mediaItems: [{
    imageURL: String,
    thumbnailURL: String,
    videoURL: String,
    videoDuration: Number,
    isVideo: Boolean
  }],
  allowDownload: { type: Boolean, default: false },
  allowReplies: { type: Boolean, default: true },
  taggedUsers: [{ type: String }]
}, { timestamps: true });

module.exports = mongoose.model('Post', postSchema);


