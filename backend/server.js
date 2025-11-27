const express = require('express');
const admin = require('firebase-admin');
const path = require('path');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3000;

// Initialize Firebase Admin SDK
if (admin.apps.length === 0) {
  try {
    // Try to use service account from environment variable or file
    if (process.env.FIREBASE_SERVICE_ACCOUNT) {
      const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
      });
    } else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
      admin.initializeApp({
        credential: admin.credential.applicationDefault()
      });
    } else {
      // Try to load from file
      const serviceAccount = require('./serviceAccountKey.json');
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
      });
    }
    console.log('✅ Firebase Admin SDK initialized');
  } catch (error) {
    console.error('❌ Error initializing Firebase Admin SDK:', error.message);
    console.error('Please set up Firebase Admin SDK credentials');
  }
}

const db = admin.firestore();

// Middleware
app.use(express.static('public'));
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// Health check endpoint (must come before username route)
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Helper function to escape HTML
function escapeHtml(text) {
  if (!text) return '';
  const map = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  };
  return text.replace(/[&<>"']/g, m => map[m]);
}

// Helper function to format date
function formatDate(timestamp) {
  if (!timestamp) return '';
  const date = timestamp.toDate ? timestamp.toDate() : new Date(timestamp);
  return date.toLocaleDateString('en-US', { 
    year: 'numeric', 
    month: 'long', 
    day: 'numeric' 
  });
}

// Route: Preview image for link previews - https://coy.services/preview/{username}
app.get('/preview/:username', async (req, res) => {
  try {
    const { username } = req.params;
    
    console.log(`🖼️ Generating preview for username: ${username}`);
    
    // Find user by username
    const usersSnapshot = await db.collection('users')
      .where('username', '==', username)
      .limit(1)
      .get();
    
    if (usersSnapshot.empty) {
      return res.status(404).send('User not found');
    }
    
    const userDoc = usersSnapshot.docs[0];
    const userData = userDoc.data();
    
    // Escape HTML to prevent XSS
    const safeUsername = escapeHtml(userData.username || '');
    const safeName = escapeHtml(userData.name || '');
    const safeBackgroundURL = userData.backgroundImageURL ? escapeHtml(userData.backgroundImageURL) : '';
    const safeProfileURL = userData.profileImageURL ? escapeHtml(userData.profileImageURL) : '';
    
    // Render a special preview HTML page optimized for link previews
    // This will be used by screenshot services or rendered directly
    const previewHTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #000;
      color: #fff;
      width: 1200px;
      height: 630px;
      overflow: hidden;
      position: relative;
    }
    .preview-container {
      width: 100%;
      height: 100%;
      position: relative;
    }
    .background-section {
      width: 100%;
      height: 315px;
      background: ${safeBackgroundURL ? `url('${safeBackgroundURL}')` : 'linear-gradient(135deg, #667eea 0%, #764ba2 100%)'};
      background-size: cover;
      background-position: center;
      position: relative;
    }
    .profile-image-container {
      position: absolute;
      top: 245px;
      left: 50%;
      transform: translateX(-50%);
      width: 140px;
      height: 140px;
      border-radius: 50%;
      border: 6px solid #000;
      overflow: hidden;
      background: #333;
    }
    .profile-image {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }
    .profile-info {
      position: absolute;
      top: 400px;
      left: 50%;
      transform: translateX(-50%);
      text-align: center;
      width: 100%;
    }
    .profile-username {
      font-size: 36px;
      font-weight: 600;
      color: #fff;
      margin-bottom: 8px;
    }
    .profile-name {
      font-size: 24px;
      font-weight: 400;
      color: #fff;
      opacity: 0.8;
      margin-bottom: 20px;
    }
  </style>
</head>
<body>
  <div class="preview-container">
    <div class="background-section"></div>
    <div class="profile-image-container">
      ${safeProfileURL ? `<img src="${safeProfileURL}" alt="Profile" class="profile-image" onerror="this.style.display='none'">` : ''}
    </div>
    <div class="profile-info">
      <div class="profile-username">@${safeUsername}</div>
      <div class="profile-name">${safeName}</div>
    </div>
  </div>
</body>
</html>`;
    
    res.setHeader('Content-Type', 'text/html');
    res.send(previewHTML);
  } catch (error) {
    console.error('❌ Error generating preview:', error);
    res.status(500).send('Error generating preview');
  }
});

// Route: Profile by username - https://coy.services/{username}
app.get('/:username', async (req, res) => {
  try {
    const { username } = req.params;
    
    if (!username || username === 'terms' || username === 'privacy' || username === 'profile' || username === 'preview') {
      return res.status(404).send('Page not found');
    }
    
    console.log(`📄 Fetching profile for username: ${username}`);
    
    // Find user by username
    const usersSnapshot = await db.collection('users')
      .where('username', '==', username)
      .limit(1)
      .get();
    
    if (usersSnapshot.empty) {
      return res.status(404).send(`
        <!DOCTYPE html>
        <html>
        <head>
          <title>User Not Found - COY</title>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
                   text-align: center; padding: 50px; background: #000; color: #fff; }
          </style>
        </head>
        <body>
          <h1>User Not Found</h1>
          <p>The user "${escapeHtml(username)}" does not exist.</p>
        </body>
        </html>
      `);
    }
    
    const userDoc = usersSnapshot.docs[0];
    const userData = userDoc.data();
    const userId = userDoc.id;
    
    // Fetch only public collections
    const collectionsSnapshot = await db.collection('collections')
      .where('ownerId', '==', userId)
      .where('isPublic', '==', true)
      .orderBy('createdAt', 'desc')
      .get();
    
    const collections = [];
    for (const doc of collectionsSnapshot.docs) {
      const collectionData = doc.data();
      
      // Get first 4 posts for preview
      const postsSnapshot = await db.collection('posts')
        .where('collectionId', '==', doc.id)
        .orderBy('createdAt', 'desc')
        .limit(4)
        .get();
      
      const previewPosts = [];
      for (const postDoc of postsSnapshot.docs) {
        const postData = postDoc.data();
        const mediaItems = postData.mediaItems || [];
        
        // Find first image URL
        let imageURL = null;
        for (const media of mediaItems) {
          if (media.thumbnailURL) {
            imageURL = media.thumbnailURL;
            break;
          }
          if (media.imageURL) {
            imageURL = media.imageURL;
            break;
          }
        }
        
        if (imageURL) {
          previewPosts.push({
            id: postDoc.id,
            imageURL: imageURL
          });
        }
      }
      
      collections.push({
        id: doc.id,
        name: collectionData.name || 'Untitled Collection',
        description: collectionData.description || '',
        imageURL: collectionData.imageURL || null,
        createdAt: collectionData.createdAt,
        postCount: postsSnapshot.size,
        previewPosts: previewPosts
      });
    }
    
    // Render profile page
    res.render('profile', {
      user: {
        id: userId,
        username: userData.username || '',
        name: userData.name || '',
        profileImageURL: userData.profileImageURL || null,
        backgroundImageURL: userData.backgroundImageURL || null,
        bio: userData.bio || ''
      },
      collections: collections,
      escapeHtml: escapeHtml,
      formatDate: formatDate
    });
    
  } catch (error) {
    console.error('❌ Error fetching profile:', error);
    res.status(500).send(`
      <!DOCTYPE html>
      <html>
      <head>
        <title>Error - COY</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
                 text-align: center; padding: 50px; background: #000; color: #fff; }
        </style>
      </head>
      <body>
        <h1>Error</h1>
        <p>An error occurred while loading the profile.</p>
      </body>
      </html>
    `);
  }
});

// Route: Profile by userId - https://coy.services/profile/{userId}
app.get('/profile/:userId', async (req, res) => {
  try {
    const { userId } = req.params;
    
    console.log(`📄 Fetching profile for userId: ${userId}`);
    
    const userDoc = await db.collection('users').doc(userId).get();
    
    if (!userDoc.exists) {
      return res.status(404).send(`
        <!DOCTYPE html>
        <html>
        <head>
          <title>User Not Found - COY</title>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
                   text-align: center; padding: 50px; background: #000; color: #fff; }
          </style>
        </head>
        <body>
          <h1>User Not Found</h1>
          <p>The user does not exist.</p>
        </body>
        </html>
      `);
    }
    
    const userData = userDoc.data();
    
    // Fetch only public collections
    const collectionsSnapshot = await db.collection('collections')
      .where('ownerId', '==', userId)
      .where('isPublic', '==', true)
      .orderBy('createdAt', 'desc')
      .get();
    
    const collections = [];
    for (const doc of collectionsSnapshot.docs) {
      const collectionData = doc.data();
      
      // Get first 4 posts for preview
      const postsSnapshot = await db.collection('posts')
        .where('collectionId', '==', doc.id)
        .orderBy('createdAt', 'desc')
        .limit(4)
        .get();
      
      const previewPosts = [];
      for (const postDoc of postsSnapshot.docs) {
        const postData = postDoc.data();
        const mediaItems = postData.mediaItems || [];
        
        // Find first image URL
        let imageURL = null;
        for (const media of mediaItems) {
          if (media.thumbnailURL) {
            imageURL = media.thumbnailURL;
            break;
          }
          if (media.imageURL) {
            imageURL = media.imageURL;
            break;
          }
        }
        
        if (imageURL) {
          previewPosts.push({
            id: postDoc.id,
            imageURL: imageURL
          });
        }
      }
      
      collections.push({
        id: doc.id,
        name: collectionData.name || 'Untitled Collection',
        description: collectionData.description || '',
        imageURL: collectionData.imageURL || null,
        createdAt: collectionData.createdAt,
        postCount: postsSnapshot.size,
        previewPosts: previewPosts
      });
    }
    
    // Render profile page
    res.render('profile', {
      user: {
        id: userId,
        username: userData.username || '',
        name: userData.name || '',
        profileImageURL: userData.profileImageURL || null,
        backgroundImageURL: userData.backgroundImageURL || null,
        bio: userData.bio || ''
      },
      collections: collections,
      escapeHtml: escapeHtml,
      formatDate: formatDate
    });
    
  } catch (error) {
    console.error('❌ Error fetching profile:', error);
    res.status(500).send(`
      <!DOCTYPE html>
      <html>
      <head>
        <title>Error - COY</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
                 text-align: center; padding: 50px; background: #000; color: #fff; }
        </style>
      </head>
      <body>
        <h1>Error</h1>
        <p>An error occurred while loading the profile.</p>
      </body>
      </html>
    `);
  }
});

// Start server
app.listen(PORT, () => {
  console.log(`🚀 COY Backend Server running on port ${PORT}`);
  console.log(`📱 Profile pages available at:`);
  console.log(`   - https://coy.services/{username}`);
  console.log(`   - https://coy.services/profile/{userId}`);
});

