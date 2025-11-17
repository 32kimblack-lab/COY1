// src/routes/users.js
const express = require('express');
const router = express.Router();
const multer = require('multer');
const User = require('../models/User');
const Collection = require('../models/Collection');
const { verifyToken } = require('../middleware/auth');
const { uploadToS3 } = require('../utils/s3Upload');

// Configure multer for memory storage (for Vercel serverless)
const upload = multer({ storage: multer.memoryStorage() });

// Get user profile
router.get('/:userId', verifyToken, async (req, res) => {
  try {
    const { userId } = req.params;
    
    let user = await User.findOne({ uid: userId });
    
    if (!user) {
      // Return default user structure if not found
      return res.json({
        uid: userId,
        name: '',
        username: '',
        email: '',
        profileImageURL: null,
        backgroundImageURL: null,
        birthMonth: null,
        birthDay: null,
        birthYear: null,
        blockedUsers: [],
        blockedCollectionIds: [],
        hiddenPostIds: [],
        starredPostIds: [],
        collectionSortPreference: null,
        customCollectionOrder: []
      });
    }

    res.json({
      uid: user.uid,
      name: user.name || '',
      username: user.username || '',
      email: user.email || '',
      profileImageURL: user.profileImageURL || null,
      backgroundImageURL: user.backgroundImageURL || null,
      birthMonth: user.birthMonth || null,
      birthDay: user.birthDay || null,
      birthYear: user.birthYear || null,
      blockedUsers: user.blockedUsers || [],
      blockedCollectionIds: user.blockedCollectionIds || [],
      hiddenPostIds: user.hiddenPostIds || [],
      starredPostIds: user.starredPostIds || [],
      collectionSortPreference: user.collectionSortPreference || null,
      customCollectionOrder: user.customCollectionOrder || []
    });
  } catch (error) {
    console.error('Get user error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Create or update user profile
router.put('/:userId', verifyToken, upload.fields([
  { name: 'profileImage', maxCount: 1 },
  { name: 'backgroundImage', maxCount: 1 }
]), async (req, res) => {
  try {
    const { userId } = req.params;
    const authUserId = req.userId; // From verifyToken middleware
    
    // Verify user can only update their own profile
    if (authUserId !== userId) {
      return res.status(403).json({ error: 'Forbidden: Cannot update another user\'s profile' });
    }

    let user = await User.findOne({ uid: userId });
    
    // Get form fields from body
    const body = req.body;

    // Update user fields
    const updateData = {
      uid: userId,
      name: body.name || user?.name || '',
      username: body.username || user?.username || '',
      email: body.email || user?.email || '',
      birthMonth: body.birthMonth || user?.birthMonth || null,
      birthDay: body.birthDay || user?.birthDay || null,
      birthYear: body.birthYear || user?.birthYear || null
    };

    // Handle profile image upload
    if (req.files && req.files.profileImage && req.files.profileImage[0]) {
      try {
        const file = req.files.profileImage[0];
        const imageURL = await uploadToS3(file.buffer, 'profiles', file.mimetype);
        updateData.profileImageURL = imageURL;
      } catch (error) {
        console.error('Profile image upload error:', error);
        // Continue without image if upload fails
      }
    }

    // Handle background image upload
    if (req.files && req.files.backgroundImage && req.files.backgroundImage[0]) {
      try {
        const file = req.files.backgroundImage[0];
        const imageURL = await uploadToS3(file.buffer, 'backgrounds', file.mimetype);
        updateData.backgroundImageURL = imageURL;
      } catch (error) {
        console.error('Background image upload error:', error);
        // Continue without image if upload fails
      }
    }

    // Create or update user
    if (user) {
      Object.assign(user, updateData);
      await user.save();
    } else {
      user = await User.create(updateData);
    }

    res.json({
      uid: user.uid,
      name: user.name || '',
      username: user.username || '',
      email: user.email || '',
      profileImageURL: user.profileImageURL || null,
      backgroundImageURL: user.backgroundImageURL || null,
      birthMonth: user.birthMonth || null,
      birthDay: user.birthDay || null,
      birthYear: user.birthYear || null,
      blockedUsers: user.blockedUsers || [],
      blockedCollectionIds: user.blockedCollectionIds || [],
      hiddenPostIds: user.hiddenPostIds || [],
      starredPostIds: user.starredPostIds || [],
      collectionSortPreference: user.collectionSortPreference || null,
      customCollectionOrder: user.customCollectionOrder || []
    });
  } catch (error) {
    console.error('Update user error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Get user's collections
router.get('/:userId/collections', verifyToken, async (req, res) => {
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
      createdAt: c.createdAt ? c.createdAt.toISOString() : new Date().toISOString()
    })));
  } catch (error) {
    console.error('Get user collections error:', error);
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;

