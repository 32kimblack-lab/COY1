// api/index.js
export default function handler(req, res) {
  res.json({ 
    message: "COY Backend API is running!",
    version: "1.0.0",
    endpoints: {
      users: "/api/users/[userId]",
      userCollections: "/api/users/[userId]/collections",
      collections: "/api/collections",
      collectionPosts: "/api/collections/[collectionId]/posts"
    }
  });
}
