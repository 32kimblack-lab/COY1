// src/routes/collections.js
const express = require('express');
const router = express.Router();
const multer = require('multer');
const Collection = require('../models/Collection');
const Post = require('../models/Post');
const { verifyToken } = require('../middleware/auth');
const { uploadToS3 } = require('../utils/s3Upload');

// Configure multer for memory storage (for Vercel serverless)
// Increase file size limits - Vercel has a 4.5MB limit, but we can try to handle larger files
const upload = multer({ 
	storage: multer.memoryStorage(),
	limits: {
		fileSize: 50 * 1024 * 1024, // 50MB per file
		fieldSize: 50 * 1024 * 1024, // 50MB for fields
		files: 5 // Max 5 files
	}
});

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

// ==========================================
// DISCOVER/SEARCH ROUTES - MUST BE BEFORE ALL PARAMETERIZED ROUTES
// ==========================================

// Search collections - returns all public collections and collections user has access to
router.get('/discover/collections', verifyToken, async (req, res) => {
  try {
    console.log('🔍 Search collections endpoint hit');
    const userId = req.userId; // From verifyToken middleware
    const { query } = req.query; // Optional search query
    console.log('Search query:', query, 'UserId:', userId);

    // Find all collections that the user can see:
    // 1. Public collections (isPublic === true)
    // 2. Collections where user is owner
    // 3. Collections where user is a member
    let collectionsQuery = {
      $or: [
        { isPublic: true },
        { ownerId: userId },
        { members: userId }
      ]
    };

    // If search query provided, filter by name or description
    if (query && query.trim()) {
      const searchRegex = new RegExp(query.trim(), 'i');
      collectionsQuery = {
        $and: [
          {
            $or: [
              { isPublic: true },
              { ownerId: userId },
              { members: userId }
            ]
          },
          {
            $or: [
              { name: searchRegex },
              { description: searchRegex }
            ]
          }
        ]
      };
    }

    const collections = await Collection.find(collectionsQuery)
      .sort({ createdAt: -1 })
      .limit(100); // Limit results

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
      createdAt: c.createdAt ? c.createdAt.toISOString() : new Date().toISOString()
    })));
  } catch (error) {
    console.error('Search collections error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Search posts - returns posts from all accessible collections
router.get('/discover/posts', verifyToken, async (req, res) => {
  try {
    console.log('🔍 Search posts endpoint hit');
    const userId = req.userId; // From verifyToken middleware
    const { query } = req.query; // Optional search query
    console.log('Search query:', query, 'UserId:', userId);

    // First, find all collections the user can access
    const accessibleCollections = await Collection.find({
      $or: [
        { isPublic: true },
        { ownerId: userId },
        { members: userId }
      ]
    });

    const accessibleCollectionIds = accessibleCollections.map(c => c._id.toString());

    if (accessibleCollectionIds.length === 0) {
      return res.json({ posts: [] });
    }

    // Build posts query
    let postsQuery = {
      collectionId: { $in: accessibleCollectionIds }
    };

    // If search query provided, filter by title/caption
    if (query && query.trim()) {
      const searchRegex = new RegExp(query.trim(), 'i');
      postsQuery = {
        $and: [
          { collectionId: { $in: accessibleCollectionIds } },
          {
            $or: [
              { title: searchRegex },
              { caption: searchRegex }
            ]
          }
        ]
      };
    }

    const posts = await Post.find(postsQuery)
      .sort({ createdAt: -1 })
      .limit(100); // Limit results

    res.json({ posts: posts.map(p => ({
      id: p._id.toString(),
      title: p.title || p.caption || '',
      collectionId: p.collectionId,
      authorId: p.authorId,
      authorName: p.authorName || '',
      createdAt: p.createdAt ? p.createdAt.toISOString() : new Date().toISOString(),
      firstMediaItem: p.firstMediaItem || null,
      mediaItems: p.mediaItems || [],
      caption: p.caption || '',
      allowDownload: p.allowDownload || false,
      allowReplies: p.allowReplies !== false, // Default to true
      taggedUsers: p.taggedUsers || []
    })) });
  } catch (error) {
    console.error('Search posts error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Create a post in a collection
router.post('/:collectionId/posts', verifyToken, (req, res, next) => {
  // Handle multer errors
  upload.fields([
    { name: 'media0', maxCount: 1 },
    { name: 'media1', maxCount: 1 },
    { name: 'media2', maxCount: 1 },
    { name: 'media3', maxCount: 1 },
    { name: 'media4', maxCount: 1 }
  ])(req, res, (err) => {
    if (err) {
      console.error('❌ Multer error:', err);
      return res.status(400).json({ error: 'File upload error: ' + err.message });
    }
    next();
  });
}, async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware
    const body = req.body;

    console.log('📝 Create post request:', {
      collectionId,
      userId,
      bodyKeys: Object.keys(body),
      filesKeys: req.files ? Object.keys(req.files) : 'no files',
      filesCount: req.files ? Object.keys(req.files).length : 0
    });

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
    
    console.log('📁 Processing media files:', {
      filesObject: mediaFiles,
      fileKeys: Object.keys(mediaFiles)
    });
    
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
        
        console.log(`📸 Processing ${key}:`, {
          mimetype: file.mimetype,
          size: file.size,
          isVideo
        });
        
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
          console.log(`✅ Uploaded ${key} to S3: ${mediaURL}`);
        } catch (error) {
          console.error(`❌ Error uploading media ${key}:`, error);
          // Continue with other media items
        }
      }
    }

    if (mediaItems.length === 0) {
      console.error('❌ No media items found. Files object:', req.files);
      return res.status(400).json({ 
        error: 'At least one media item is required',
        debug: {
          filesReceived: req.files ? Object.keys(req.files).length : 0,
          bodyKeys: Object.keys(body)
        }
      });
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


