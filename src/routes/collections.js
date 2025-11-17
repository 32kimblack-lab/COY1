// src/routes/collections.js
const express = require('express');
const router = express.Router();
const multer = require('multer');
const Collection = require('../models/Collection');
const Post = require('../models/Post');
const { verifyToken } = require('../middleware/auth');
const { uploadToS3 } = require('../utils/s3Upload');

// Configure multer for memory storage (for Vercel serverless)
const upload = multer({ storage: multer.memoryStorage() });

// Create a new collection
router.post('/', verifyToken, upload.single('image'), async (req, res) => {
  try {
    const userId = req.userId; // From verifyToken middleware
    const body = req.body;

    // Parse invited users (comma-separated string or array)
    let invitedUsers = [];
    if (body.invitedUsers) {
      if (typeof body.invitedUsers === 'string') {
        invitedUsers = body.invitedUsers.split(',').map(u => u.trim()).filter(u => u);
      } else if (Array.isArray(body.invitedUsers)) {
        invitedUsers = body.invitedUsers;
      }
    }

    const collectionData = {
      name: body.name || '',
      description: body.description || '',
      type: body.type || 'Individual',
      isPublic: body.isPublic === 'true' || body.isPublic === true,
      ownerId: body.ownerId || userId,
      ownerName: body.ownerName || '',
      members: [body.ownerId || userId, ...invitedUsers],
      memberCount: 1 + invitedUsers.length
    };

    // Handle collection image upload
    if (req.file) {
      try {
        const imageURL = await uploadToS3(req.file.buffer, 'collections', req.file.mimetype);
        collectionData.imageURL = imageURL;
      } catch (error) {
        console.error('Collection image upload error:', error);
        // Continue without image if upload fails
      }
    }

    const collection = await Collection.create(collectionData);

    res.json({
      id: collection._id.toString(),
      name: collection.name,
      description: collection.description || '',
      type: collection.type,
      isPublic: collection.isPublic || false,
      ownerId: collection.ownerId,
      ownerName: collection.ownerName || '',
      imageURL: collection.imageURL || null,
      members: collection.members || [],
      memberCount: collection.memberCount || collection.members?.length || 0,
      createdAt: collection.createdAt ? collection.createdAt.toISOString() : new Date().toISOString()
    });
  } catch (error) {
    console.error('Create collection error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Create a post in a collection
router.post('/:collectionId/posts', verifyToken, upload.fields([
  { name: 'media0', maxCount: 1 },
  { name: 'media1', maxCount: 1 },
  { name: 'media2', maxCount: 1 },
  { name: 'media3', maxCount: 1 },
  { name: 'media4', maxCount: 1 }
]), async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware
    const body = req.body;

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

    // Get author name from user or use default
    let authorName = body.authorName || 'Unknown';
    try {
      const User = require('../models/User');
      const user = await User.findOne({ uid: userId });
      if (user && user.name) {
        authorName = user.name;
      }
    } catch (error) {
      console.error('Error fetching author name:', error);
    }

    // Parse tagged users
    let taggedUsers = [];
    if (body.taggedUsers) {
      if (typeof body.taggedUsers === 'string') {
        taggedUsers = body.taggedUsers.split(',').map(u => u.trim()).filter(u => u);
      } else if (Array.isArray(body.taggedUsers)) {
        taggedUsers = body.taggedUsers;
      }
    }

    // Process media files (images and videos)
    const mediaItems = [];
    const mediaFiles = req.files || {};
    
    // Sort media files by key (media0, media1, etc.)
    const sortedKeys = Object.keys(mediaFiles).sort((a, b) => {
      const numA = parseInt(a.replace('media', ''));
      const numB = parseInt(b.replace('media', ''));
      return numA - numB;
    });

    for (const key of sortedKeys) {
      const fileArray = mediaFiles[key];
      if (fileArray && fileArray.length > 0) {
        const file = fileArray[0];
        const isVideo = file.mimetype && file.mimetype.startsWith('video/');
        
        try {
          // Upload to S3
          const mediaURL = await uploadToS3(file.buffer, 'posts', file.mimetype);
          
          const mediaItem = {
            imageURL: isVideo ? null : mediaURL,
            thumbnailURL: null, // Can be generated later if needed
            videoURL: isVideo ? mediaURL : null,
            videoDuration: isVideo ? (parseFloat(body[`${key}_duration`]) || null) : null,
            isVideo: isVideo
          };
          
          mediaItems.push(mediaItem);
        } catch (error) {
          console.error(`Error uploading media ${key}:`, error);
          // Continue with other media items
        }
      }
    }

    if (mediaItems.length === 0) {
      return res.status(400).json({ error: 'At least one media item is required' });
    }

    // Create post data
    const postData = {
      title: body.caption || '',
      caption: body.caption || '',
      collectionId: collectionId,
      authorId: userId,
      authorName: authorName,
      firstMediaItem: mediaItems[0], // First media item for preview
      allowDownload: body.allowDownload === 'true' || body.allowDownload === true,
      allowReplies: body.allowReplies !== 'false' && body.allowReplies !== false, // Default to true
      taggedUsers: taggedUsers,
      // Store all media items (can be expanded in Post model if needed)
      mediaItems: mediaItems
    };

    // Create post in MongoDB
    const post = await Post.create(postData);

    res.json({
      postId: post._id.toString(),
      collectionId: post.collectionId,
      mediaURLs: mediaItems.map(m => m.imageURL || m.videoURL).filter(Boolean)
    });
  } catch (error) {
    console.error('Create post error:', error);
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
      createdAt: p.createdAt ? p.createdAt.toISOString() : new Date().toISOString(),
      firstMediaItem: p.firstMediaItem || null,
      caption: p.caption || '',
      allowDownload: p.allowDownload || false,
      allowReplies: p.allowReplies !== false, // Default to true
      taggedUsers: p.taggedUsers || []
    })) });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;


