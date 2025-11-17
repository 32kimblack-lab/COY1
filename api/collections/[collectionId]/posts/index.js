// api/collections/[collectionId]/posts/index.js
const { connectToDatabase } = require('../../../lib/mongodb');
const { verifyToken } = require('../../../lib/auth');

async function handler(req, res) {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    // Verify authentication
    const token = req.headers.authorization?.replace('Bearer ', '');
    if (!token) {
      return res.status(401).json({ error: 'No token provided' });
    }

    const userId = await verifyToken(token);
    if (!userId) {
      return res.status(401).json({ error: 'Invalid token' });
    }

    const { collectionId } = req.query;

    // Connect to MongoDB
    const { db } = await connectToDatabase();

    // Get collection to verify it exists and user has access
    const collection = await db.collection('collections').findOne({
      _id: collectionId
    });

    if (!collection) {
      return res.status(404).json({ error: 'Collection not found' });
    }

    // Check if user has access (owner, member, or public)
    const hasAccess = 
      collection.ownerId === userId ||
      collection.members?.includes(userId) ||
      collection.isPublic === true;

    if (!hasAccess) {
      return res.status(403).json({ error: 'Access denied' });
    }

    // Get posts for this collection
    const posts = await db.collection('posts')
      .find({ collectionId: collectionId })
      .sort({ createdAt: -1 }) // Newest first
      .toArray();

    // Format posts for response
    const formattedPosts = posts.map(post => ({
      id: post._id,
      title: post.title || post.caption || '',
      collectionId: post.collectionId,
      authorId: post.authorId,
      authorName: post.authorName || '',
      createdAt: post.createdAt,
      firstMediaItem: post.firstMediaItem || null,
      caption: post.caption || '',
      allowDownload: post.allowDownload || false,
      allowReplies: post.allowReplies || true,
      taggedUsers: post.taggedUsers || []
    }));

    return res.status(200).json({ posts: formattedPosts });

  } catch (error) {
    console.error('Error fetching posts:', error);
    return res.status(500).json({ error: 'Internal server error' });
  }
}

module.exports = handler;
