// src/routes/collections.js
const express = require('express');
const router = express.Router();
const Collection = require('../models/Collection');
const Post = require('../models/Post');
const { verifyToken } = require('../middleware/auth');

// Get user's collections
router.get('/users/:userId/collections', verifyToken, async (req, res) => {
  try {
    const { userId } = req.params;
    
    const collections = await Collection.find({
      $or: [
        { ownerId: userId },
        { members: userId }
      ]
    }).sort({ createdAt: -1 });

    res.json(collections.map(c => ({
      id: c._id.toString(),
      name: c.name,
      description: c.description || '',
      type: c.type,
      isPublic: c.isPublic || false,
      ownerId: c.ownerId,
      ownerName: c.ownerName || '',
      imageURL: c.imageURL || null,
      members: c.members || [],
      memberCount: c.memberCount || c.members?.length || 0,
      createdAt: c.createdAt
    })));
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Get collection posts
router.get('/:collectionId/posts', verifyToken, async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware

    // Verify collection exists and user has access
    const collection = await Collection.findById(collectionId);
    if (!collection) {
      return res.status(404).json({ error: 'Collection not found' });
    }

    const hasAccess = 
      collection.ownerId === userId ||
      collection.members?.includes(userId) ||
      collection.isPublic === true;

    if (!hasAccess) {
      return res.status(403).json({ error: 'Access denied' });
    }

    // Get posts
    const posts = await Post.find({ collectionId })
      .sort({ createdAt: -1 });

    res.json({ posts: posts.map(p => ({
      id: p._id.toString(),
      title: p.title || p.caption || '',
      collectionId: p.collectionId,
      authorId: p.authorId,
      authorName: p.authorName || '',
      createdAt: p.createdAt,
      firstMediaItem: p.firstMediaItem || null,
      caption: p.caption || '',
      allowDownload: p.allowDownload || false,
      allowReplies: p.allowReplies || true,
      taggedUsers: p.taggedUsers || []
    })) });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;

