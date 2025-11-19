// src/routes/collections.js
const express = require('express');
const router = express.Router();
const multer = require('multer');
const Collection = require('../models/Collection');
const Post = require('../models/Post');
const { verifyToken } = require('../middleware/auth');
const { uploadToS3 } = require('../utils/s3Upload');

// CRITICAL FIX: Initialize Firebase Admin before any route uses it
const admin = require('firebase-admin');
if (!admin.apps.length) {
  try {
    if (process.env.FIREBASE_SERVICE_ACCOUNT) {
      const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
      });
      console.log('✅ Firebase Admin initialized from FIREBASE_SERVICE_ACCOUNT');
    } else if (process.env.FIREBASE_PROJECT_ID && process.env.FIREBASE_PRIVATE_KEY && process.env.FIREBASE_CLIENT_EMAIL) {
      admin.initializeApp({
        credential: admin.credential.cert({
          projectId: process.env.FIREBASE_PROJECT_ID,
          privateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n'),
          clientEmail: process.env.FIREBASE_CLIENT_EMAIL
        })
      });
      console.log('✅ Firebase Admin initialized from environment variables');
    } else {
      // Try default initialization (uses GOOGLE_APPLICATION_CREDENTIALS or default credentials)
      admin.initializeApp();
      console.log('✅ Firebase Admin initialized with default credentials');
    }
  } catch (error) {
    console.error('❌ Failed to initialize Firebase Admin in collections.js:', error);
    // Continue anyway - routes will handle errors gracefully
  }
}

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

// Search collections - returns public collections that user is NOT owner/member of
router.get('/discover/collections', verifyToken, async (req, res) => {
  try {
    console.log('🔍 Search collections endpoint hit');
    const userId = req.userId; // From verifyToken middleware
    const { query } = req.query; // Optional search query
    console.log('Search query:', query, 'UserId:', userId);

    // Find public collections that user is NOT:
    // 1. The owner of (ownerId !== userId)
    // 2. A member of (members does not contain userId)
    let collectionsQuery = {
      isPublic: true,
      ownerId: { $ne: userId }, // Not the owner
      members: { $nin: [userId] } // Not in members array
    };

    // If search query provided, filter by name or description
    if (query && query.trim()) {
      const searchRegex = new RegExp(query.trim(), 'i');
      collectionsQuery = {
        $and: [
          {
            isPublic: true,
            ownerId: { $ne: userId },
            members: { $nin: [userId] }
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

    // Filter out collections where user is owner or member (client-side safety check)
    const filteredCollections = collections.filter(c => {
      const isOwner = c.ownerId === userId;
      const isMember = c.members && c.members.includes(userId);
      return !isOwner && !isMember;
    });

    console.log(`📊 Found ${collections.length} collections, filtered to ${filteredCollections.length} (excluding user's own collections)`);

    // CRITICAL FIX: Initialize Firebase Admin if not already initialized
    // This ensures Firebase is ready before we try to use it
    let firestore = null;
    try {
      if (!admin.apps.length) {
        if (process.env.FIREBASE_SERVICE_ACCOUNT) {
          const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
          admin.initializeApp({
            credential: admin.credential.cert(serviceAccount)
          });
        } else if (process.env.FIREBASE_PROJECT_ID && process.env.FIREBASE_PRIVATE_KEY && process.env.FIREBASE_CLIENT_EMAIL) {
          admin.initializeApp({
            credential: admin.credential.cert({
              projectId: process.env.FIREBASE_PROJECT_ID,
              privateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n'),
              clientEmail: process.env.FIREBASE_CLIENT_EMAIL
            })
          });
        } else {
          admin.initializeApp();
        }
      }
      firestore = admin.firestore();
      console.log('✅ Firebase Admin initialized for discover endpoint');
    } catch (firebaseError) {
      console.error('⚠️ Firebase Admin initialization failed (non-critical):', firebaseError);
      // Continue without Firebase - we'll just use MongoDB data
    }
    
    // Map collections with optional Firebase imageURL enhancement
    const collectionsWithImages = await Promise.all(filteredCollections.map(async (c) => {
      let imageURL = c.imageURL;
      
      // If no imageURL in MongoDB and Firebase is available, try to get it from Firebase
      if (!imageURL && firestore) {
        try {
          const firebaseCollection = await firestore.collection('collections').doc(c._id.toString()).get();
          if (firebaseCollection.exists) {
            const firebaseData = firebaseCollection.data();
            imageURL = firebaseData?.imageURL || null;
            console.log(`📸 Fetched imageURL from Firebase for collection ${c.name}: ${imageURL ? 'found' : 'not found'}`);
          }
        } catch (error) {
          console.error(`Error fetching imageURL from Firebase for collection ${c._id}:`, error);
          // Continue without Firebase imageURL
        }
      }
      
      return {
        id: c._id.toString(),
        name: c.name,
        description: c.description || '',
        type: c.type,
        isPublic: c.isPublic || false,
        ownerId: c.ownerId,
        ownerName: c.ownerName || '',
        imageURL: imageURL || null,
        members: c.members || [],
        memberCount: c.memberCount || c.members?.length || 0,
        createdAt: c.createdAt ? c.createdAt.toISOString() : new Date().toISOString()
      };
    }));

    res.json(collectionsWithImages);
  } catch (error) {
    console.error('Search collections error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Search posts - returns posts from all accessible collections (queries Firebase directly - source of truth)
router.get('/discover/posts', verifyToken, async (req, res) => {
  try {
    console.log('🔍 Search posts endpoint hit');
    const userId = req.userId; // From verifyToken middleware
    const { query } = req.query; // Optional search query
    console.log('Search query:', query, 'UserId:', userId);

    // Use Firebase Admin to query Firebase directly (source of truth)
    // Firebase Admin is already initialized at the top of the file
    const db = admin.firestore();

    // First, find all collections the user can access (from MongoDB or Firebase)
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

    console.log(`📦 Fetching posts from Firebase for ${accessibleCollectionIds.length} accessible collections`);

    // Fetch posts from Firebase for all accessible collections
    const allPosts = [];
    
    // Fetch posts in parallel for all collections
    const postPromises = accessibleCollectionIds.map(async (collectionId) => {
      try {
        let postsSnapshot = await db.collection('posts')
          .where('collectionId', '==', collectionId)
          .get();
        
        // If no posts found, try fetching all and filtering
        if (postsSnapshot.docs.length === 0) {
          const allPostsSnapshot = await db.collection('posts').get();
          const matchingPosts = allPostsSnapshot.docs.filter(doc => {
            const data = doc.data();
            const postCollectionId = data.collectionId || '';
            return postCollectionId === collectionId || 
                   postCollectionId.toString() === collectionId.toString() ||
                   postCollectionId.trim() === collectionId.trim();
          });
          postsSnapshot = { docs: matchingPosts };
        }
        
        return postsSnapshot.docs.map(doc => {
          const data = doc.data();
          return {
            id: doc.id,
            data: data
          };
        });
      } catch (error) {
        console.error(`Error fetching posts for collection ${collectionId}:`, error);
        return [];
      }
    });

    const postsArrays = await Promise.all(postPromises);
    const flatPosts = postsArrays.flat();

    console.log(`✅ Found ${flatPosts.length} posts from Firebase`);

    // Filter posts by search query if provided
    let filteredPosts = flatPosts;
    if (query && query.trim()) {
      const searchQuery = query.trim().toLowerCase();
      filteredPosts = flatPosts.filter(post => {
        const title = (post.data.title || '').toLowerCase();
        const caption = (post.data.caption || '').toLowerCase();
        return title.includes(searchQuery) || caption.includes(searchQuery);
      });
      console.log(`🔍 Filtered to ${filteredPosts.length} posts matching query: "${query}"`);
    }

    // Sort by createdAt descending (newest first)
    filteredPosts.sort((a, b) => {
      const dateA = a.data.createdAt?.toDate ? a.data.createdAt.toDate() : new Date(a.data.createdAt || 0);
      const dateB = b.data.createdAt?.toDate ? b.data.createdAt.toDate() : new Date(b.data.createdAt || 0);
      return dateB - dateA; // Descending order
    });

    // Limit results
    const limitedPosts = filteredPosts.slice(0, 100);

    // Map to response format
    const postsResponse = limitedPosts.map(p => {
      const data = p.data;
      
      // Parse mediaItems
      let mediaItems = [];
      if (data.mediaItems && Array.isArray(data.mediaItems)) {
        mediaItems = data.mediaItems;
      } else if (data.firstMediaItem) {
        mediaItems = [data.firstMediaItem];
      }

      return {
        id: p.id,
        title: data.title || data.caption || '',
        collectionId: data.collectionId || '',
        authorId: data.authorId || '',
        authorName: data.authorName || '',
        createdAt: data.createdAt?.toDate ? data.createdAt.toDate().toISOString() : (data.createdAt ? new Date(data.createdAt).toISOString() : new Date().toISOString()),
        firstMediaItem: mediaItems[0] || null,
        mediaItems: mediaItems,
        caption: data.caption || '',
        allowDownload: data.allowDownload || false,
        allowReplies: data.allowReplies !== false,
        taggedUsers: data.taggedUsers || []
      };
    });

    console.log(`📊 Returning ${postsResponse.length} posts to client`);
    res.json({ posts: postsResponse });
  } catch (error) {
    console.error('Search posts error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Create a post in a collection with Firebase Storage URLs (no S3 upload needed)
router.post('/:collectionId/posts/urls', verifyToken, async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId;
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

    // Get author name
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
      if (Array.isArray(body.taggedUsers)) {
        taggedUsers = body.taggedUsers;
      } else if (typeof body.taggedUsers === 'string') {
        taggedUsers = body.taggedUsers.split(',').map(u => u.trim()).filter(u => u);
      }
    }

    // Use Firebase Storage URLs directly (no S3 upload needed)
    const mediaItems = body.mediaItems || [];
    
    if (mediaItems.length === 0) {
      return res.status(400).json({ error: 'At least one media item is required' });
    }

    // Create post data with Firebase Storage URLs
    const postData = {
      title: body.caption || '',
      caption: body.caption || '',
      collectionId: collectionId,
      authorId: userId,
      authorName: authorName,
      firstMediaItem: mediaItems[0], // First media item for preview
      allowDownload: body.allowDownload === true || body.allowDownload === 'true',
      allowReplies: body.allowReplies !== false && body.allowReplies !== 'false', // Default to true
      taggedUsers: taggedUsers,
      mediaItems: mediaItems // All media items with Firebase Storage URLs
    };

    // Create post in MongoDB
    const post = await Post.create(postData);

    res.json({
      postId: post._id.toString(),
      collectionId: post.collectionId,
      mediaURLs: mediaItems.map(m => m.imageURL || m.videoURL).filter(Boolean)
    });
  } catch (error) {
    console.error('Create post with URLs error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Create a post in a collection (with file upload to S3 - kept for backward compatibility)
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

// Get collection posts (queries Firebase directly - source of truth)
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

    // Query Firebase directly (source of truth)
    // Firebase Admin is already initialized at the top of the file
    const db = admin.firestore();
    
    console.log(`📡 Fetching posts from Firebase for collection: ${collectionId}`);
    
    // Try querying with the collectionId as-is
    let postsSnapshot = await db.collection('posts')
      .where('collectionId', '==', collectionId)
      .get();
    
    console.log(`🔍 Found ${postsSnapshot.docs.length} posts with exact collectionId match: ${collectionId}`);
    
    // If no posts found, try querying all posts and filter client-side (in case collectionId format differs)
    if (postsSnapshot.docs.length === 0) {
      console.log(`⚠️ No posts found with exact match, trying to fetch all posts and filter...`);
      const allPostsSnapshot = await db.collection('posts').get();
      console.log(`📦 Total posts in Firebase: ${allPostsSnapshot.docs.length}`);
      
      // Log sample collectionIds to debug
      if (allPostsSnapshot.docs.length > 0) {
        const samplePost = allPostsSnapshot.docs[0].data();
        console.log(`📋 Sample post collectionId format: "${samplePost.collectionId}" (type: ${typeof samplePost.collectionId})`);
        console.log(`📋 Looking for collectionId: "${collectionId}" (type: ${typeof collectionId})`);
      }
      
      // Filter posts that match this collectionId (case-insensitive, handle different formats)
      const matchingPosts = allPostsSnapshot.docs.filter(doc => {
        const data = doc.data();
        const postCollectionId = data.collectionId || '';
        // Try exact match, string comparison, and trimmed comparison
        const matches = postCollectionId === collectionId || 
               postCollectionId.toString() === collectionId.toString() ||
               postCollectionId.trim() === collectionId.trim();
        
        if (matches) {
          console.log(`✅ Matched post ${doc.id} with collectionId: "${postCollectionId}"`);
        }
        
        return matches;
      });
      
      console.log(`✅ Found ${matchingPosts.length} posts after filtering for collection: ${collectionId}`);
      postsSnapshot = {
        docs: matchingPosts
      };
    }

    const posts = postsSnapshot.docs.map(doc => {
      const data = doc.data();
      
      // Parse mediaItems
      let mediaItems = [];
      if (data.mediaItems && Array.isArray(data.mediaItems)) {
        mediaItems = data.mediaItems;
      } else if (data.firstMediaItem) {
        mediaItems = [data.firstMediaItem];
      }

      return {
        id: doc.id,
        title: data.title || data.caption || '',
        collectionId: data.collectionId || collectionId,
        authorId: data.authorId || '',
        authorName: data.authorName || '',
        createdAt: data.createdAt?.toDate ? data.createdAt.toDate().toISOString() : (data.createdAt ? new Date(data.createdAt).toISOString() : new Date().toISOString()),
        firstMediaItem: mediaItems[0] || null,
        mediaItems: mediaItems,
        caption: data.caption || '',
        allowDownload: data.allowDownload || false,
        allowReplies: data.allowReplies !== false,
        taggedUsers: data.taggedUsers || []
      };
    });

    // Sort by createdAt descending (newest first)
    posts.sort((a, b) => {
      const dateA = new Date(a.createdAt);
      const dateB = new Date(b.createdAt);
      return dateB - dateA; // Descending order
    });

    console.log(`✅ Decoded ${posts.length} posts for collection: ${collectionId}`);
    res.json({ posts });
  } catch (error) {
    console.error('Get collection posts error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Get a single collection by ID
router.get('/:collectionId', verifyToken, async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware

    console.log(`📦 GET /api/collections/${collectionId} - User: ${userId}`);

    // Find collection in MongoDB
    const collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found in MongoDB: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Verify user has access
    const hasAccess = 
      collection.ownerId === userId ||
      collection.members?.includes(userId) ||
      collection.isPublic === true;

    if (!hasAccess) {
      console.log(`❌ Access denied for user ${userId} to collection ${collectionId}`);
      return res.status(403).json({ error: 'Access denied' });
    }

    // Try to get additional data from Firebase (admins, allowedUsers, deniedUsers)
    let admins = [];
    let allowedUsers = [];
    let deniedUsers = [];
    
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const firebaseData = firebaseCollection.data();
        admins = firebaseData?.admins || [];
        allowedUsers = firebaseData?.allowedUsers || [];
        deniedUsers = firebaseData?.deniedUsers || [];
        console.log(`✅ Fetched additional data from Firebase: ${admins.length} admins, ${allowedUsers.length} allowed, ${deniedUsers.length} denied`);
      }
    } catch (error) {
      console.error('Error fetching Firebase data (non-critical):', error);
      // Continue without Firebase data
    }

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
      admins: admins,
      allowedUsers: allowedUsers,
      deniedUsers: deniedUsers,
      memberCount: collection.memberCount || collection.members?.length || 0,
      createdAt: collection.createdAt ? collection.createdAt.toISOString() : new Date().toISOString()
    });
  } catch (error) {
    console.error('Get collection error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Update a collection (matches edit profile pattern)
router.put('/:collectionId', verifyToken, upload.fields([
  { name: 'image', maxCount: 1 }
]), async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware
    const body = req.body;

    console.log(`📝 PUT /api/collections/${collectionId} - User: ${userId}`);
    console.log(`📝 Request body keys:`, Object.keys(body));

    // Find collection in MongoDB
    let collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Verify user is owner or admin
    let isAdmin = false;
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const firebaseData = firebaseCollection.data();
        const admins = firebaseData?.admins || [];
        isAdmin = admins.includes(userId);
      }
    } catch (error) {
      console.error('Error checking admin status (non-critical):', error);
    }

    const isOwner = collection.ownerId === userId;
    
    if (!isOwner && !isAdmin) {
      console.log(`❌ Access denied: User ${userId} is not owner or admin of collection ${collectionId}`);
      return res.status(403).json({ error: 'Forbidden: Only owner or admins can update collection' });
    }

    // Build update data - matches edit profile pattern (only update if provided, preserve existing if not)
    // CRITICAL: Always update if provided, even if empty string (user might want to clear description)
    const updateData = {
      name: body.name !== undefined ? body.name.trim() : (collection.name || ''),
      description: body.description !== undefined ? body.description.trim() : (collection.description || ''),
      isPublic: body.isPublic !== undefined ? (body.isPublic === 'true' || body.isPublic === true) : (collection.isPublic || false)
    };
    
    console.log(`📝 Update data: name="${updateData.name}", description="${updateData.description}", isPublic=${updateData.isPublic}`);

    // Handle collection image upload (matches edit profile pattern)
    if (req.files && req.files.image && req.files.image[0]) {
      try {
        const file = req.files.image[0];
        const imageURL = await uploadToS3(file.buffer, 'collections', file.mimetype);
        updateData.imageURL = imageURL;
        console.log(`✅ Uploaded collection image to S3: ${imageURL}`);
      } catch (error) {
        console.error('Collection image upload error:', error);
        // Continue without image if upload fails
      }
    } else if (body.imageURL !== undefined) {
      // Allow setting imageURL directly (for Firebase Storage URLs) - matches edit profile pattern
      updateData.imageURL = body.imageURL || null;
    } else {
      // Preserve existing imageURL if not provided
      updateData.imageURL = collection.imageURL || null;
    }

    // Update collection in MongoDB (matches edit profile pattern)
    Object.assign(collection, updateData);
    await collection.save();
    console.log(`✅ Updated collection in MongoDB: ${collectionId}`);

    // CRITICAL FIX: Update Firebase with ALL fields (name, description, isPublic, imageURL, etc.)
    // This ensures Firebase has the latest data and matches edit profile pattern
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollectionRef = db.collection('collections').doc(collectionId);
      
      const firebaseUpdate = {};
      
      // CRITICAL: Always update basic fields in Firebase (name, description, isPublic, imageURL)
      // These are the fields that users edit, so they MUST be in Firebase
      firebaseUpdate.name = updateData.name;
      firebaseUpdate.description = updateData.description || '';
      firebaseUpdate.isPublic = updateData.isPublic;
      if (updateData.imageURL !== undefined) {
        firebaseUpdate.imageURL = updateData.imageURL;
      }
      
      // Handle allowedUsers (for private collections)
      // CRITICAL: Always save allowedUsers if provided, even if empty array (clears access)
      if (body.allowedUsers !== undefined) {
        firebaseUpdate.allowedUsers = Array.isArray(body.allowedUsers) ? body.allowedUsers : [];
        console.log(`📝 Updating allowedUsers: ${firebaseUpdate.allowedUsers.length} users`);
      }
      
      // Handle deniedUsers (for public collections)
      // CRITICAL: Always save deniedUsers if provided, even if empty array (clears restrictions)
      if (body.deniedUsers !== undefined) {
        firebaseUpdate.deniedUsers = Array.isArray(body.deniedUsers) ? body.deniedUsers : [];
        console.log(`📝 Updating deniedUsers: ${firebaseUpdate.deniedUsers.length} users`);
      }
      
      // Handle members array
      if (body.members !== undefined) {
        firebaseUpdate.members = Array.isArray(body.members) ? body.members : [];
        firebaseUpdate.memberCount = firebaseUpdate.members.length;
      }
      
      // Handle admins array
      if (body.admins !== undefined) {
        firebaseUpdate.admins = Array.isArray(body.admins) ? body.admins : [];
      }

      // CRITICAL: Use set with merge: true to ensure collection exists in Firebase
      // This handles cases where collection exists in MongoDB but not in Firebase
      await firebaseCollectionRef.set(firebaseUpdate, { merge: true });
      console.log(`✅ Updated collection in Firebase: ${collectionId}`);
      console.log(`   - Name: ${firebaseUpdate.name}`);
      console.log(`   - Description: ${firebaseUpdate.description}`);
      console.log(`   - isPublic: ${firebaseUpdate.isPublic}`);
      console.log(`   - imageURL: ${firebaseUpdate.imageURL || 'null'}`);
    } catch (error) {
      console.error('Error updating Firebase (non-critical):', error);
      // Continue even if Firebase update fails - matches edit profile pattern
    }

    // Get updated collection data (matches edit profile pattern)
    const updatedCollection = await Collection.findById(collectionId);
    
    // Get Firebase data for response (admins, allowedUsers, deniedUsers)
    let admins = [];
    let allowedUsers = [];
    let deniedUsers = [];
    
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const firebaseData = firebaseCollection.data();
        admins = firebaseData?.admins || [];
        allowedUsers = firebaseData?.allowedUsers || [];
        deniedUsers = firebaseData?.deniedUsers || [];
      }
    } catch (error) {
      console.error('Error fetching Firebase data for response (non-critical):', error);
    }

    // Return complete collection data (matches edit profile response pattern)
    res.json({
      id: updatedCollection._id.toString(),
      name: updatedCollection.name || '',
      description: updatedCollection.description || '',
      type: updatedCollection.type || 'Individual',
      isPublic: updatedCollection.isPublic || false,
      ownerId: updatedCollection.ownerId,
      ownerName: updatedCollection.ownerName || '',
      imageURL: updatedCollection.imageURL || null,
      members: updatedCollection.members || [],
      admins: admins,
      allowedUsers: allowedUsers,
      deniedUsers: deniedUsers,
      memberCount: updatedCollection.memberCount || updatedCollection.members?.length || 0,
      createdAt: updatedCollection.createdAt ? updatedCollection.createdAt.toISOString() : new Date().toISOString()
    });
  } catch (error) {
    console.error('Update collection error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Promote a member to admin (only Owner can do this)
router.post('/:collectionId/members/:memberId/promote', verifyToken, async (req, res) => {
  try {
    const { collectionId, memberId } = req.params;
    const userId = req.userId; // From verifyToken middleware

    console.log(`👤 POST /api/collections/${collectionId}/members/${memberId}/promote - User: ${userId}`);

    // Find collection in MongoDB
    const collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Verify user is owner (only owner can promote to admin)
    if (collection.ownerId !== userId) {
      console.log(`❌ Access denied: User ${userId} is not owner of collection ${collectionId}`);
      return res.status(403).json({ error: 'Forbidden: Only owner can promote members to admin' });
    }

    // Verify member exists in collection
    if (!collection.members?.includes(memberId)) {
      console.log(`❌ Member ${memberId} is not a member of collection ${collectionId}`);
      return res.status(400).json({ error: 'User is not a member of this collection' });
    }

    // Update Firebase with admin status
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollectionRef = db.collection('collections').doc(collectionId);
      
      // Get current admins
      const firebaseCollection = await firebaseCollectionRef.get();
      const currentAdmins = firebaseCollection.exists 
        ? (firebaseCollection.data()?.admins || [])
        : [];
      
      // Add to admins if not already an admin
      if (!currentAdmins.includes(memberId)) {
        await firebaseCollectionRef.update({
          admins: admin.firestore.FieldValue.arrayUnion(memberId)
        });
        console.log(`✅ Added ${memberId} to admins array in Firebase`);
      } else {
        console.log(`⚠️ User ${memberId} is already an admin`);
      }
    } catch (error) {
      console.error('Error updating Firebase (non-critical):', error);
      // Continue even if Firebase update fails
    }

    res.json({ 
      success: true,
      message: 'Member promoted to admin successfully',
      collectionId,
      memberId
    });
  } catch (error) {
    console.error('Promote member to admin error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Delete a collection (soft delete - only owner can do this)
router.delete('/:collectionId', verifyToken, async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware

    console.log(`🗑️ DELETE /api/collections/${collectionId} - User: ${userId}`);

    // Find collection in MongoDB
    const collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Verify user is owner
    if (collection.ownerId !== userId) {
      console.log(`❌ Access denied: User ${userId} is not owner of collection ${collectionId}`);
      return res.status(403).json({ error: 'Forbidden: Only owner can delete collection' });
    }

    const ownerId = collection.ownerId;

    // Soft delete: Move to deleted_collections in Firebase
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      
      // Get collection data from Firebase
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const collectionData = firebaseCollection.data();
        
        // Add deletedAt timestamp and isDeleted flag
        const deletedData = {
          ...collectionData,
          deletedAt: admin.firestore.FieldValue.serverTimestamp(),
          isDeleted: true
        };
        
        // Move to deleted_collections subcollection
        const deletedRef = db.collection('users').doc(ownerId).collection('deleted_collections').doc(collectionId);
        await deletedRef.set(deletedData);
        console.log(`✅ Collection moved to deleted_collections in Firebase`);
        
        // Remove from main collections
        await firebaseCollection.ref.delete();
        console.log(`✅ Collection removed from main collections in Firebase`);
      } else {
        // If not in Firebase, create it from MongoDB data
        const collectionData = {
          name: collection.name,
          description: collection.description || '',
          type: collection.type,
          isPublic: collection.isPublic || false,
          ownerId: collection.ownerId,
          ownerName: collection.ownerName || '',
          imageURL: collection.imageURL || null,
          members: collection.members || [],
          memberCount: collection.memberCount || 0,
          admins: collection.admins || [],
          allowedUsers: collection.allowedUsers || [],
          deniedUsers: collection.deniedUsers || [],
          createdAt: collection.createdAt ? admin.firestore.Timestamp.fromDate(collection.createdAt) : admin.firestore.Timestamp.now(),
          deletedAt: admin.firestore.FieldValue.serverTimestamp(),
          isDeleted: true
        };
        
        const deletedRef = db.collection('users').doc(ownerId).collection('deleted_collections').doc(collectionId);
        await deletedRef.set(collectionData);
        console.log(`✅ Collection moved to deleted_collections in Firebase (created from MongoDB)`);
      }
    } catch (error) {
      console.error('Error soft deleting in Firebase:', error);
      // Continue even if Firebase update fails - we'll still mark as deleted in MongoDB
    }

    // Mark as deleted in MongoDB (optional - Firebase is source of truth)
    try {
      collection.isDeleted = true;
      collection.deletedAt = new Date();
      await collection.save();
      console.log(`✅ Collection marked as deleted in MongoDB`);
    } catch (error) {
      console.error('Error updating MongoDB (non-critical):', error);
      // Continue even if MongoDB update fails
    }

    res.json({ 
      success: true,
      message: 'Collection deleted successfully',
      collectionId,
      ownerId
    });
  } catch (error) {
    console.error('Delete collection error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Leave a collection (member/admin can leave, but not owner)
router.post('/:collectionId/leave', verifyToken, async (req, res) => {
  try {
    const { collectionId } = req.params;
    const userId = req.userId; // From verifyToken middleware

    console.log(`👋 POST /api/collections/${collectionId}/leave - User: ${userId}`);

    // Find collection in MongoDB
    const collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Prevent owner from leaving (they should delete instead)
    if (collection.ownerId === userId) {
      console.log(`❌ Owner cannot leave collection - must delete instead`);
      return res.status(400).json({ error: 'Owner cannot leave collection. Please delete it instead.' });
    }

    // Verify user is a member
    if (!collection.members?.includes(userId)) {
      console.log(`❌ User ${userId} is not a member of collection ${collectionId}`);
      return res.status(400).json({ error: 'User is not a member of this collection' });
    }

    // Update MongoDB - remove from members array and decrement memberCount
    try {
      collection.members = collection.members.filter(id => id !== userId);
      collection.memberCount = Math.max(0, (collection.memberCount || collection.members.length) - 1);
      await collection.save();
      console.log(`✅ Removed ${userId} from members in MongoDB`);
    } catch (error) {
      console.error('Error updating MongoDB (non-critical):', error);
      // Continue even if MongoDB update fails
    }

    // Update Firebase - remove from members and admins, decrement memberCount
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollectionRef = db.collection('collections').doc(collectionId);
      
      await firebaseCollectionRef.update({
        members: admin.firestore.FieldValue.arrayRemove(userId),
        admins: admin.firestore.FieldValue.arrayRemove(userId),
        memberCount: admin.firestore.FieldValue.increment(-1)
      });
      console.log(`✅ Removed ${userId} from members and admins in Firebase`);
    } catch (error) {
      console.error('Error updating Firebase (non-critical):', error);
      // Continue even if Firebase update fails
    }

    res.json({ 
      success: true,
      message: 'Left collection successfully',
      collectionId,
      userId
    });
  } catch (error) {
    console.error('Leave collection error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Remove a member from collection (Owner and Admins can do this)
router.delete('/:collectionId/members/:memberId', verifyToken, async (req, res) => {
  try {
    const { collectionId, memberId } = req.params;
    const userId = req.userId; // From verifyToken middleware

    console.log(`🗑️ DELETE /api/collections/${collectionId}/members/${memberId} - User: ${userId}`);

    // Find collection in MongoDB
    const collection = await Collection.findById(collectionId);
    
    if (!collection) {
      console.log(`❌ Collection not found: ${collectionId}`);
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Verify user is owner or admin
    let isAdmin = false;
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollection = await db.collection('collections').doc(collectionId).get();
      
      if (firebaseCollection.exists) {
        const firebaseData = firebaseCollection.data();
        const admins = firebaseData?.admins || [];
        isAdmin = admins.includes(userId);
      }
    } catch (error) {
      console.error('Error checking admin status (non-critical):', error);
    }

    const isOwner = collection.ownerId === userId;
    
    if (!isOwner && !isAdmin) {
      console.log(`❌ Access denied: User ${userId} is not owner or admin of collection ${collectionId}`);
      return res.status(403).json({ error: 'Forbidden: Only owner or admins can remove members' });
    }

    // Prevent owner from removing themselves
    if (memberId === collection.ownerId) {
      console.log(`❌ Cannot remove owner from collection`);
      return res.status(400).json({ error: 'Cannot remove the owner from the collection' });
    }

    // Verify member exists in collection
    if (!collection.members?.includes(memberId)) {
      console.log(`❌ Member ${memberId} is not a member of collection ${collectionId}`);
      return res.status(400).json({ error: 'User is not a member of this collection' });
    }

    // Update MongoDB - remove from members array and decrement memberCount
    try {
      collection.members = collection.members.filter(id => id !== memberId);
      collection.memberCount = Math.max(0, (collection.memberCount || collection.members.length) - 1);
      await collection.save();
      console.log(`✅ Removed ${memberId} from members in MongoDB`);
    } catch (error) {
      console.error('Error updating MongoDB (non-critical):', error);
      // Continue even if MongoDB update fails
    }

    // Update Firebase - remove from members, admins, and decrement memberCount
    try {
      // Firebase Admin is already initialized at the top of the file
      const db = admin.firestore();
      const firebaseCollectionRef = db.collection('collections').doc(collectionId);
      
      await firebaseCollectionRef.update({
        members: admin.firestore.FieldValue.arrayRemove(memberId),
        admins: admin.firestore.FieldValue.arrayRemove(memberId),
        memberCount: admin.firestore.FieldValue.increment(-1)
      });
      console.log(`✅ Removed ${memberId} from members and admins in Firebase`);
    } catch (error) {
      console.error('Error updating Firebase (non-critical):', error);
      // Continue even if Firebase update fails
    }

    res.json({ 
      success: true,
      message: 'Member removed from collection successfully',
      collectionId,
      memberId
    });
  } catch (error) {
    console.error('Remove member error:', error);
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;


