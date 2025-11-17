// api/[...slug].js
const express = require('express');
const cors = require('cors');
const mongoose = require('mongoose');

const app = express();

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Database Connection
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

// Connect DB before handling requests
app.use(async (req, res, next) => {
  await connectDB();
  next();
});

// Import routes (if they exist)
try {
  const userRoutes = require('../src/routes/users');
  app.use('/api/users', userRoutes);
} catch (e) {
  console.log('Users routes not found');
}

try {
  const collectionRoutes = require('../src/routes/collections');
  app.use('/api/collections', collectionRoutes);
} catch (e) {
  console.log('Collections routes not found');
}

try {
  const postRoutes = require('../src/routes/posts');
  app.use('/api/posts', postRoutes);
} catch (e) {
  console.log('Posts routes not found');
}

// Root endpoint
app.get('/api', (req, res) => {
  res.json({ 
    message: "COY Backend API is running!",
    version: "1.0.0"
  });
});

// Export for Vercel
module.exports = app;


