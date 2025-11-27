const express = require('express');
const admin = require('firebase-admin');
const path = require('path');

const app = express();

// Add CORS headers for images
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

// Initialize Firebase Admin SDK (already initialized by Firebase Functions)
if (admin.apps.length === 0) {
  admin.initializeApp();
}

const db = admin.firestore();

// Set view engine
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.set('view options', { rmWhitespace: false });

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

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

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
    const path = req.path;
    
    // Skip static files and known routes
    if (path.includes('.') && (path.endsWith('.html') || path.endsWith('.js') || path.endsWith('.css') || 
        path.endsWith('.png') || path.endsWith('.jpg') || path.endsWith('.jpeg') || 
        path.endsWith('.gif') || path.endsWith('.svg') || path.endsWith('.ico') || 
        path.endsWith('.json'))) {
      return res.status(404).send('Not found');
    }
    
    if (!username || username === 'terms' || username === 'privacy' || username === 'profile' || username === 'health' || 
        username === 'preview' || username === '__' || username.startsWith('_')) {
      return res.status(404).send(`
        <!DOCTYPE html>
        <html>
        <head>
          <title>Page Not Found - COY</title>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
                   text-align: center; padding: 50px; background: #000; color: #fff; }
          </style>
        </head>
        <body>
          <h1>Page Not Found</h1>
        </body>
        </html>
      `);
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
    
    console.log(`📄 Fetching profile for username: ${username}`);
    
    // Add logging for debugging
    console.log(`🔍 User data:`, {
      username: userData.username,
      hasProfileImage: !!userData.profileImageURL,
      hasBackgroundImage: !!userData.backgroundImageURL
    });
    
    // Fetch all collections for user, then filter for public ones
    // This avoids needing a composite index
    const collectionsSnapshot = await db.collection('collections')
      .where('ownerId', '==', userId)
      .get();
    
    // Filter for public collections and sort in memory
    const publicCollections = collectionsSnapshot.docs
      .filter(doc => {
        const data = doc.data();
        return data.isPublic === true;
      })
      .sort((a, b) => {
        const aTime = a.data().createdAt?.toMillis() || 0;
        const bTime = b.data().createdAt?.toMillis() || 0;
        return bTime - aTime; // Descending order
      });
    
    const collections = [];
    for (const doc of publicCollections) {
      try {
        const collectionData = doc.data();
        
        // Get posts for preview (without orderBy to avoid index requirement)
        const postsSnapshot = await db.collection('posts')
          .where('collectionId', '==', doc.id)
          .get();
        
        // Sort in memory and take first 4
        const sortedPosts = postsSnapshot.docs.sort((a, b) => {
          const aTime = a.data().createdAt?.toMillis() || 0;
          const bTime = b.data().createdAt?.toMillis() || 0;
          return bTime - aTime; // Descending order
        }).slice(0, 4);
        
        const previewPosts = [];
        for (const postDoc of sortedPosts) {
          const postData = postDoc.data();
          const mediaItems = postData.mediaItems || [];
          
          // Find first image URL - matches CollectionRowDesign.getImageURL logic
          let imageURL = null;
          
          // First, try to find a thumbnailURL from any mediaItem
          for (const media of mediaItems) {
            if (media && media.thumbnailURL && typeof media.thumbnailURL === 'string' && media.thumbnailURL.trim() !== '') {
              imageURL = media.thumbnailURL;
              break;
            }
          }
          
          // If no thumbnail found, try to find an imageURL from any mediaItem
          if (!imageURL) {
            for (const media of mediaItems) {
              if (media && media.imageURL && typeof media.imageURL === 'string' && media.imageURL.trim() !== '') {
                imageURL = media.imageURL;
                break;
              }
            }
          }
          
          // Fallback to firstMediaItem if mediaItems array is empty or no URL found
          if (!imageURL && postData.firstMediaItem) {
            const firstMedia = postData.firstMediaItem;
            if (firstMedia) {
              if (firstMedia.thumbnailURL && typeof firstMedia.thumbnailURL === 'string' && firstMedia.thumbnailURL.trim() !== '') {
                imageURL = firstMedia.thumbnailURL;
              } else if (firstMedia.imageURL && typeof firstMedia.imageURL === 'string' && firstMedia.imageURL.trim() !== '') {
                imageURL = firstMedia.imageURL;
              }
            }
          }
          
          // Always include post (even if no image, will show placeholder)
          previewPosts.push({
            id: postDoc.id,
            imageURL: imageURL || null
          });
          
          // Log for debugging (only if imageURL exists and is a string)
          if (imageURL && typeof imageURL === 'string' && imageURL.length > 0) {
            console.log(`✅ Post ${postDoc.id}: Found image URL: ${imageURL.substring(0, 50)}...`);
          } else {
            console.log(`⚠️ Post ${postDoc.id}: No image URL found (mediaItems: ${mediaItems.length})`);
          }
        }
        
        console.log(`📦 Collection "${collectionData.name}": ${previewPosts.length} preview posts, ${postsSnapshot.size} total posts`);
        
        // Get collection profile image (collection.imageURL or owner's profile image)
        let collectionProfileImageURL = collectionData.imageURL || null;
        if ((!collectionProfileImageURL || (typeof collectionProfileImageURL === 'string' && collectionProfileImageURL.trim() === '')) && collectionData.ownerId) {
          // Fetch owner's profile image as fallback
          try {
            const ownerDoc = await db.collection('users').doc(collectionData.ownerId).get();
            if (ownerDoc.exists) {
              const ownerData = ownerDoc.data();
              collectionProfileImageURL = ownerData.profileImageURL || null;
            }
          } catch (error) {
            console.log(`⚠️ Error fetching owner profile image for collection ${doc.id}: ${error.message}`);
            // Continue without profile image - don't throw
          }
        }
        
        collections.push({
          id: doc.id,
          name: collectionData.name || 'Untitled Collection',
          description: collectionData.description || '',
          imageURL: collectionData.imageURL || null,
          profileImageURL: collectionProfileImageURL,
          isPublic: collectionData.isPublic || false,
          createdAt: collectionData.createdAt,
          postCount: postsSnapshot.size,
          previewPosts: previewPosts
        });
      } catch (collectionError) {
        console.error(`❌ Error processing collection ${doc.id}:`, collectionError);
        // Skip this collection and continue with others
        continue;
      }
    }
    
    // Log image URLs for debugging
    console.log(`🖼️ Profile Image URL: ${userData.profileImageURL || 'NONE'}`);
    console.log(`🖼️ Background Image URL: ${userData.backgroundImageURL || 'NONE'}`);
    console.log(`📊 Collections count: ${collections.length}`);
    collections.forEach((col, idx) => {
      console.log(`  Collection ${idx + 1}: "${col.name}" - ${col.previewPosts.length} posts, profileImage: ${col.profileImageURL ? 'YES' : 'NO'}`);
    });
    
    // Render profile page
    try {
      res.render('profile', {
        user: {
          id: userId,
          username: userData.username || '',
          name: userData.name || '',
          profileImageURL: userData.profileImageURL || null,
          backgroundImageURL: userData.backgroundImageURL || null,
          bio: userData.bio || ''
        },
        collections: collections || [],
        escapeHtml: escapeHtml,
        formatDate: formatDate
      }, (err, html) => {
        if (err) {
          console.error('❌ EJS rendering error:', err);
          console.error('❌ EJS error stack:', err.stack);
          return res.status(500).send(`
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
              <p>An error occurred while rendering the profile.</p>
            </body>
            </html>
          `);
        }
        res.send(html);
      });
    } catch (renderError) {
      console.error('❌ Error rendering template:', renderError);
      throw renderError; // Re-throw to be caught by outer catch
    }
    
  } catch (error) {
    console.error('❌ Error fetching profile:', error);
    console.error('❌ Error stack:', error.stack);
    console.error('❌ Error details:', {
      message: error.message,
      name: error.name,
      code: error.code
    });
    
    // Send a proper error response
    try {
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
          <p style="font-size: 12px; color: #666; margin-top: 20px;">${(error && error.message) ? String(error.message).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;') : 'Unknown error'}</p>
        </body>
        </html>
      `);
    } catch (sendError) {
      console.error('❌ Error sending error response:', sendError);
      // Last resort - send plain text
      res.status(500).send('Internal Server Error');
    }
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
    
    // Fetch all collections for user, then filter for public ones
    // This avoids needing a composite index
    const collectionsSnapshot = await db.collection('collections')
      .where('ownerId', '==', userId)
      .get();
    
    // Filter for public collections and sort in memory
    const publicCollections = collectionsSnapshot.docs
      .filter(doc => {
        const data = doc.data();
        return data.isPublic === true;
      })
      .sort((a, b) => {
        const aTime = a.data().createdAt?.toMillis() || 0;
        const bTime = b.data().createdAt?.toMillis() || 0;
        return bTime - aTime; // Descending order
      });
    
    const collections = [];
    for (const doc of publicCollections) {
      try {
        const collectionData = doc.data();
        
        // Get posts for preview (without orderBy to avoid index requirement)
        const postsSnapshot = await db.collection('posts')
          .where('collectionId', '==', doc.id)
          .get();
        
        // Sort in memory and take first 4
        const sortedPosts = postsSnapshot.docs.sort((a, b) => {
          const aTime = a.data().createdAt?.toMillis() || 0;
          const bTime = b.data().createdAt?.toMillis() || 0;
          return bTime - aTime; // Descending order
        }).slice(0, 4);
        
        const previewPosts = [];
        for (const postDoc of sortedPosts) {
          const postData = postDoc.data();
          const mediaItems = postData.mediaItems || [];
          
          // Find first image URL - matches CollectionRowDesign.getImageURL logic
          let imageURL = null;
          
          // First, try to find a thumbnailURL from any mediaItem
          for (const media of mediaItems) {
            if (media && media.thumbnailURL && typeof media.thumbnailURL === 'string' && media.thumbnailURL.trim() !== '') {
              imageURL = media.thumbnailURL;
              break;
            }
          }
          
          // If no thumbnail found, try to find an imageURL from any mediaItem
          if (!imageURL) {
            for (const media of mediaItems) {
              if (media && media.imageURL && typeof media.imageURL === 'string' && media.imageURL.trim() !== '') {
                imageURL = media.imageURL;
                break;
              }
            }
          }
          
          // Fallback to firstMediaItem if mediaItems array is empty or no URL found
          if (!imageURL && postData.firstMediaItem) {
            const firstMedia = postData.firstMediaItem;
            if (firstMedia) {
              if (firstMedia.thumbnailURL && typeof firstMedia.thumbnailURL === 'string' && firstMedia.thumbnailURL.trim() !== '') {
                imageURL = firstMedia.thumbnailURL;
              } else if (firstMedia.imageURL && typeof firstMedia.imageURL === 'string' && firstMedia.imageURL.trim() !== '') {
                imageURL = firstMedia.imageURL;
              }
            }
          }
          
          // Always include post (even if no image, will show placeholder)
          previewPosts.push({
            id: postDoc.id,
            imageURL: imageURL || null
          });
          
          // Log for debugging (only if imageURL exists and is a string)
          if (imageURL && typeof imageURL === 'string' && imageURL.length > 0) {
            console.log(`✅ Post ${postDoc.id}: Found image URL: ${imageURL.substring(0, 50)}...`);
          } else {
            console.log(`⚠️ Post ${postDoc.id}: No image URL found (mediaItems: ${mediaItems.length})`);
          }
        }
        
        console.log(`📦 Collection "${collectionData.name}": ${previewPosts.length} preview posts, ${postsSnapshot.size} total posts`);
        
        // Get collection profile image (collection.imageURL or owner's profile image)
        let collectionProfileImageURL = collectionData.imageURL || null;
        if ((!collectionProfileImageURL || (typeof collectionProfileImageURL === 'string' && collectionProfileImageURL.trim() === '')) && collectionData.ownerId) {
          // Fetch owner's profile image as fallback
          try {
            const ownerDoc = await db.collection('users').doc(collectionData.ownerId).get();
            if (ownerDoc.exists) {
              const ownerData = ownerDoc.data();
              collectionProfileImageURL = ownerData.profileImageURL || null;
            }
          } catch (error) {
            console.log(`⚠️ Error fetching owner profile image for collection ${doc.id}: ${error.message}`);
            // Continue without profile image - don't throw
          }
        }
        
        collections.push({
          id: doc.id,
          name: collectionData.name || 'Untitled Collection',
          description: collectionData.description || '',
          imageURL: collectionData.imageURL || null,
          profileImageURL: collectionProfileImageURL,
          isPublic: collectionData.isPublic || false,
          createdAt: collectionData.createdAt,
          postCount: postsSnapshot.size,
          previewPosts: previewPosts
        });
      } catch (collectionError) {
        console.error(`❌ Error processing collection ${doc.id}:`, collectionError);
        // Skip this collection and continue with others
        continue;
      }
    }
    
    // Log image URLs for debugging
    console.log(`🖼️ Profile Image URL: ${userData.profileImageURL || 'NONE'}`);
    console.log(`🖼️ Background Image URL: ${userData.backgroundImageURL || 'NONE'}`);
    console.log(`📊 Collections count: ${collections.length}`);
    collections.forEach((col, idx) => {
      console.log(`  Collection ${idx + 1}: "${col.name}" - ${col.previewPosts.length} posts, profileImage: ${col.profileImageURL ? 'YES' : 'NO'}`);
    });
    
    // Render profile page
    try {
      res.render('profile', {
        user: {
          id: userId,
          username: userData.username || '',
          name: userData.name || '',
          profileImageURL: userData.profileImageURL || null,
          backgroundImageURL: userData.backgroundImageURL || null,
          bio: userData.bio || ''
        },
        collections: collections || [],
        escapeHtml: escapeHtml,
        formatDate: formatDate
      }, (err, html) => {
        if (err) {
          console.error('❌ EJS rendering error:', err);
          console.error('❌ EJS error stack:', err.stack);
          return res.status(500).send(`
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
              <p>An error occurred while rendering the profile.</p>
            </body>
            </html>
          `);
        }
        res.send(html);
      });
    } catch (renderError) {
      console.error('❌ Error rendering template:', renderError);
      throw renderError; // Re-throw to be caught by outer catch
    }
    
  } catch (error) {
    console.error('❌ Error fetching profile:', error);
    console.error('❌ Error stack:', error.stack);
    console.error('❌ Error details:', {
      message: error.message,
      name: error.name,
      code: error.code
    });
    
    // Send a proper error response
    try {
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
          <p style="font-size: 12px; color: #666; margin-top: 20px;">${(error && error.message) ? String(error.message).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;') : 'Unknown error'}</p>
        </body>
        </html>
      `);
    } catch (sendError) {
      console.error('❌ Error sending error response:', sendError);
      // Last resort - send plain text
      res.status(500).send('Internal Server Error');
    }
  }
});

// Error handling middleware (must be last)
app.use((err, req, res, next) => {
  console.error('❌ Unhandled error in Express app:', err);
  console.error('❌ Error stack:', err.stack);
  if (!res.headersSent) {
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

module.exports = app;

