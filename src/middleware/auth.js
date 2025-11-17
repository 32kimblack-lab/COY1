const admin = require('firebase-admin');

// Initialize Firebase Admin if not already initialized
if (!admin.apps.length) {
  try {
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
  } catch (error) {
    console.error('❌ Failed to initialize Firebase Admin:', error);
  }
}

// Middleware to verify Firebase Auth token
const verifyToken = async (req, res, next) => {
  try {
    const token = req.headers.authorization?.split(' ')[1]; // Bearer TOKEN
    
    if (!token) {
      return res.status(401).json({ error: 'No token provided' });
    }

    try {
      let decoded;
      
      // Try to verify with Firebase Admin if available
      if (admin.apps.length) {
        try {
          decoded = await admin.auth().verifyIdToken(token);
          req.userId = decoded.uid;
          req.userEmail = decoded.email;
          next();
          return;
        } catch (firebaseError) {
          console.error('Firebase token verification failed:', firebaseError);
          return res.status(401).json({ error: 'Invalid token' });
        }
      } else {
        // Fallback: For development, accept token without verification
        console.warn('⚠️ Firebase Admin not initialized - accepting token without verification');
        // Try to decode JWT manually (basic check only)
        const parts = token.split('.');
        if (parts.length === 3) {
          const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString());
          req.userId = payload.uid || payload.user_id;
          req.userEmail = payload.email;
          next();
          return;
        }
        return res.status(401).json({ error: 'Invalid token format' });
      }
    } catch (error) {
      console.error('Token verification error:', error);
      return res.status(401).json({ error: 'Invalid token' });
    }
  } catch (error) {
    console.error('Auth middleware error:', error);
    return res.status(500).json({ error: 'Authentication error' });
  }
};

module.exports = { verifyToken };

