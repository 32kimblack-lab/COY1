// api/users/[userId]/collections.js
const { connectToDatabase } = require('../../lib/mongodb');
const { verifyToken } = require('../../lib/auth');

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

    const { userId: requestedUserId } = req.query;

    // Users can only get their own collections (or add permission check)
    if (userId !== requestedUserId) {
      return res.status(403).json({ error: 'Access denied' });
    }

    // Connect to MongoDB
    const { db } = await connectToDatabase();

    // Get collections where user is owner or member
    const collections = await db.collection('collections')
      .find({
        $or: [
          { ownerId: requestedUserId },
          { members: requestedUserId }
        ]
      })
      .sort({ createdAt: -1 })
      .toArray();

    // Format collections for response
    const formattedCollections = collections.map(collection => ({
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
      createdAt: collection.createdAt
    }));

    return res.status(200).json(formattedCollections);

  } catch (error) {
    console.error('Error fetching collections:', error);
    return res.status(500).json({ error: 'Internal server error' });
  }
}

module.exports = handler;
