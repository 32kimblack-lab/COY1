require('dotenv').config();
const express = require('express');
const cors = require('cors');
const mongoose = require('mongoose');
const path = require('path');

const app = express();

// Middleware
app.use(cors());
app.use(express.json({ limit: '50mb' })); // Increase JSON payload limit
app.use(express.urlencoded({ extended: true, limit: '50mb' })); // Increase URL-encoded payload limit

// Serve static files from public directory
app.use(express.static(path.join(__dirname, '../public')));

// Database Connection (async for serverless - lazy connection)
let dbConnected = false;
const connectDB = async () => {
  if (dbConnected) {
    return mongoose.connection;
  }
  
  try {
    const uri = process.env.MONGODB_URI;
    if (!uri) {
      console.error('MONGODB_URI not set');
      return;
    }
    
    const conn = await mongoose.connect(uri, {
      serverSelectionTimeoutMS: 5000,
    });
    dbConnected = true;
    console.log('✅ Connected to MongoDB');
    return conn;
  } catch (error) {
    console.error('❌ MongoDB connection error:', error.message);
    throw error;
  }
};

// Connect DB on first request
app.use(async (req, res, next) => {
  if (!dbConnected) {
    try {
      await connectDB();
    } catch (error) {
      console.error('DB connection failed:', error);
      // Continue anyway - routes can handle errors
    }
  }
  next();
});

// Routes - load with error handling
let authRoutes, userRoutes, collectionRoutes, postRoutes, chatRoutes, notificationRoutes, friendRequestRoutes;

try {
  authRoutes = require('../src/routes/auth');
  app.use('/api/auth', authRoutes);
  console.log('✅ Auth routes loaded');
} catch (error) {
  console.log('⚠️ Auth routes not found (optional)');
}

try {
  userRoutes = require('../src/routes/users');
  app.use('/api/users', userRoutes);
  console.log('✅ User routes loaded');
} catch (error) {
  console.error('❌ User routes failed to load:', error.message);
  console.error('Error stack:', error.stack);
}

try {
  collectionRoutes = require('../src/routes/collections');
  app.use('/api/collections', collectionRoutes);
  console.log('✅ Collection routes loaded');
} catch (error) {
  console.error('❌ Collection routes failed to load:', error.message);
  console.error('Error stack:', error.stack);
}

try {
  postRoutes = require('../src/routes/posts');
  app.use('/api/posts', postRoutes);
  console.log('✅ Post routes loaded');
} catch (error) {
  console.log('⚠️ Post routes not found (optional)');
}

try {
  chatRoutes = require('../src/routes/enhancedChat');
  app.use('/api/chat', chatRoutes);
  console.log('✅ Chat routes loaded');
} catch (error) {
  console.log('⚠️ Chat routes not found (optional)');
}

try {
  notificationRoutes = require('../src/routes/notifications');
  app.use('/api/notifications', notificationRoutes);
  console.log('✅ Notification routes loaded');
} catch (error) {
  console.log('⚠️ Notification routes not found (optional)');
}

try {
  friendRequestRoutes = require('../src/routes/friendRequests');
  app.use('/api/friend-requests', friendRequestRoutes);
  console.log('✅ Friend request routes loaded');
} catch (error) {
  console.log('⚠️ Friend request routes not found (optional)');
}

// Root route
app.get('/', (req, res) => {
  res.json({ 
    message: 'COY Backend API is running!', 
    version: '1.0.0',
    timestamp: new Date().toISOString()
  });
});

// API root route
app.get('/api', (req, res) => {
  res.json({ 
    message: 'COY Backend API is running!', 
    version: '1.0.0',
    timestamp: new Date().toISOString()
  });
});

// Health check
app.get('/health', async (req, res) => {
  try {
    const dbStatus = mongoose.connection.readyState === 1 ? 'Connected' : 'Disconnected';
    res.json({ 
      status: 'OK', 
      database: dbStatus,
      timestamp: new Date().toISOString(),
      env: process.env.NODE_ENV || 'development'
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('/api/health', (req, res) => {
  res.json({
    message: 'COY Backend API is running!',
    version: '1.0.0',
    status: 'ok',
    timestamp: new Date().toISOString()
  });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({ error: err.message || 'Internal server error' });
});

const PORT = process.env.PORT || 10000;

if (process.env.VERCEL !== '1') {
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server running on port ${PORT}`);
  });
} else {
  console.log(`Running as Vercel serverless function on port ${PORT}`);
}

// Export app for Vercel serverless functions
module.exports = app;

// Deploy fix 2025-11-11T00:00:00Z placeholder
