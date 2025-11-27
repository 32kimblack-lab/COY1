/**
 * Firebase Cloud Functions for COY App
 * Handles push notifications for messages and profile pages
 */

const admin = require("firebase-admin");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall} = require("firebase-functions/v2/https");
const {onRequest} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const profileServerApp = require("./profileServer");

// Initialize Firebase Admin
admin.initializeApp();

/**
 * Firestore trigger that automatically sends push notifications
 * when messages are created. This is more efficient as it doesn't
 * require an HTTPS call from the client.
 */
exports.onMessageCreated = onDocumentCreated(
  {
    document: "chat_rooms/{chatId}/messages/{messageId}",
    maxInstances: 10,
  },
  async (event) => {
    const messageData = event.data.data();
    const chatId = event.params.chatId;
    const senderUid = messageData.senderUid;
    const messageType = messageData.type || "text";
    const messageContent = messageData.content || "";

    logger.info("New message created", { chatId, senderUid, messageType });

    // Get chat room to find participants
    const chatRoomRef = admin.firestore().collection("chat_rooms").doc(chatId);
    const chatRoom = await chatRoomRef.get();

    if (!chatRoom.exists) {
      logger.error("Chat room not found", { chatId });
      return null;
    }

    const participants = chatRoom.data().participants || [];
    const receiverUid = participants.find((uid) => uid !== senderUid);

    if (!receiverUid) {
      logger.error("Receiver not found for chat", { chatId });
      return null;
    }

    // Get receiver's FCM token
    const receiverDoc = await admin
      .firestore()
      .collection("users")
      .doc(receiverUid)
      .get();
    const receiverToken = receiverDoc.data()?.fcmToken;

    if (!receiverToken) {
      logger.info("No FCM token for receiver", { receiverUid });
      return null;
    }

    // Get sender's user data
    const senderDoc = await admin
      .firestore()
      .collection("users")
      .doc(senderUid)
      .get();
    const senderData = senderDoc.data();
    const senderName = senderData?.username || senderData?.name || "Someone";
    const senderProfileImageURL = senderData?.profileImageURL || "";

    // Get receiver's profile image for app profile
    const appProfileImageURL = receiverDoc.data()?.profileImageURL || "";

    // Format notification body based on message type
    let notificationBody;
    switch (messageType) {
      case "image":
      case "photo":
        notificationBody = "Sent photo";
        break;
      case "video":
        notificationBody = "Sent video";
        break;
      case "text":
        notificationBody = messageContent;
        break;
      default:
        notificationBody = "New message";
    }

    // Prepare the message payload
    const message = {
      token: receiverToken,
      notification: {
        title: senderName,
        body: notificationBody,
      },
      data: {
        type: "message",
        chatId: chatId,
        senderUid: senderUid,
        messageType: messageType,
        userProfileImageURL: senderProfileImageURL,
        appProfileImageURL: appProfileImageURL,
      },
      apns: {
        payload: {
          aps: {
            alert: {
              title: senderName,
              body: notificationBody,
            },
            sound: "default",
            badge: 1,
            "mutable-content": 1,
          },
          userProfileImageURL: senderProfileImageURL,
          appProfileImageURL: appProfileImageURL,
        },
        fcmOptions: {
          imageUrl: senderProfileImageURL,
        },
      },
    };

    try {
      const response = await admin.messaging().send(message);
      logger.info("Successfully sent notification", { response });
      return null;
    } catch (error) {
      logger.error("Error sending notification", { error });
      return null;
    }
  }
);

/**
 * HTTPS callable function to send push notifications (alternative method)
 * This can be called directly from the iOS app
 */
exports.sendMessageNotification = onCall(async (request) => {
  const data = request.data;
  const token = data.token;

  if (!token) {
    throw new Error("FCM token is required");
  }

  try {
    const message = {
      token: token,
      notification: {
        title: data.notification?.title || "New Message",
        body: data.notification?.body || "You have a new message",
      },
      data: {
        type: data.data?.type || "message",
        chatId: data.data?.chatId || "",
        senderUid: data.data?.senderUid || "",
        messageType: data.data?.messageType || "text",
        userProfileImageURL: data.data?.userProfileImageURL || "",
        appProfileImageURL: data.data?.appProfileImageURL || "",
      },
      apns: {
        payload: {
          aps: {
            alert: {
              title: data.notification?.title || "New Message",
              body: data.notification?.body || "You have a new message",
            },
            sound: "default",
            badge: 1,
            "mutable-content": 1,
          },
          userProfileImageURL: data.data?.userProfileImageURL || "",
          appProfileImageURL: data.data?.appProfileImageURL || "",
        },
        fcmOptions: {
          imageUrl: data.data?.userProfileImageURL || "",
        },
      },
    };

    const response = await admin.messaging().send(message);
    logger.info("Successfully sent message via callable", { response });
    return { success: true, messageId: response };
  } catch (error) {
    logger.error("Error sending message", { error });
    throw new Error("Failed to send notification");
  }
});

/**
 * Callable function to get user email by username (for login)
 * This allows unauthenticated users to look up their email by username
 */
exports.getUserEmailByUsername = onCall(async (request) => {
  const username = request.data?.username;
  
  if (!username) {
    throw new Error("Username is required");
  }
  
  try {
    const normalizedUsername = username.toLowerCase().trim();
    
    // Query users collection by username
    const usersSnapshot = await admin
      .firestore()
      .collection("users")
      .where("username", "==", normalizedUsername)
      .limit(1)
      .get();
    
    if (usersSnapshot.empty) {
      // Try case-insensitive search as fallback
      const allUsersSnapshot = await admin
        .firestore()
        .collection("users")
        .limit(1000)
        .get();
      
      const matchingUser = allUsersSnapshot.docs.find((doc) => {
        const userData = doc.data();
        return userData.username?.toLowerCase() === normalizedUsername;
      });
      
      if (matchingUser) {
        const userData = matchingUser.data();
        return {
          email: userData.email || "",
          userId: matchingUser.id,
        };
      }
      
      return { email: null, userId: null };
    }
    
    const userDoc = usersSnapshot.docs[0];
    const userData = userDoc.data();
    
    return {
      email: userData.email || "",
      userId: userDoc.id,
    };
  } catch (error) {
    logger.error("Error looking up user by username", { error, username });
    throw new Error("Failed to look up user");
  }
});

/**
 * Callable function to block a user
 * This uses admin privileges to update both user documents
 */
exports.blockUser = onCall(async (request) => {
  const currentUid = request.auth?.uid;
  const blockedUid = request.data?.blockedUid;
  
  if (!currentUid) {
    throw new Error("User must be authenticated");
  }
  
  if (!blockedUid) {
    throw new Error("blockedUid is required");
  }
  
  if (currentUid === blockedUid) {
    throw new Error("Cannot block yourself");
  }
  
  try {
    const db = admin.firestore();
    const batch = db.batch();
    
    // Get current user document to check if they were friends
    const currentUserRef = db.collection("users").doc(currentUid);
    const currentUserDoc = await currentUserRef.get();
    const currentUserData = currentUserDoc.data();
    
    // 1. Remove from friends arrays if they were friends
    if (currentUserData?.friends?.includes(blockedUid)) {
      batch.update(currentUserRef, {
        friends: admin.firestore.FieldValue.arrayRemove(blockedUid)
      });
      
      const blockedUserRef = db.collection("users").doc(blockedUid);
      batch.update(blockedUserRef, {
        friends: admin.firestore.FieldValue.arrayRemove(currentUid)
      });
    }
    
    // 2. Add to blocked lists
    // Current user adds blockedUid to their blockedUsers
    batch.update(currentUserRef, {
      blockedUsers: admin.firestore.FieldValue.arrayUnion(blockedUid)
    });
    
    // Blocked user adds currentUid to their blockedByUsers
    const blockedUserRef = db.collection("users").doc(blockedUid);
    batch.update(blockedUserRef, {
      blockedByUsers: admin.firestore.FieldValue.arrayUnion(currentUid)
    });
    
    // 3. Update or create chat room with blocked status
    const sortedIds = [currentUid, blockedUid].sort();
    const chatRoomId = sortedIds.join("_");
    const chatRoomRef = db.collection("chat_rooms").doc(chatRoomId);
    const chatRoomDoc = await chatRoomRef.get();
    
    if (chatRoomDoc.exists) {
      batch.update(chatRoomRef, {
        [`chatStatus.${currentUid}`]: "blocked",
        [`chatStatus.${blockedUid}`]: "blocked"
      });
    } else {
      batch.set(chatRoomRef, {
        participants: [currentUid, blockedUid],
        lastMessageTs: admin.firestore.FieldValue.serverTimestamp(),
        lastMessage: "",
        lastMessageType: "text",
        unreadCount: {
          [currentUid]: 0,
          [blockedUid]: 0
        },
        chatStatus: {
          [currentUid]: "blocked",
          [blockedUid]: "blocked"
        }
      });
    }
    
    await batch.commit();
    
    logger.info("User blocked successfully", { currentUid, blockedUid });
    return { success: true };
  } catch (error) {
    logger.error("Error blocking user", { error, currentUid, blockedUid });
    throw new Error("Failed to block user: " + error.message);
  }
});

/**
 * Callable function to clear chat for current user
 * This uses admin privileges to update messages and chat room
 */
exports.clearChat = onCall(async (request) => {
  const currentUid = request.auth?.uid;
  const chatId = request.data?.chatId;
  
  if (!currentUid) {
    throw new Error("User must be authenticated");
  }
  
  if (!chatId) {
    throw new Error("chatId is required");
  }
  
  try {
    const db = admin.firestore();
    const storage = admin.storage();
    
    // Get chat room to know both participants
    const chatRef = db.collection("chat_rooms").doc(chatId);
    const chatDoc = await chatRef.get();
    
    if (!chatDoc.exists) {
      throw new Error("Chat room not found");
    }
    
    const chatData = chatDoc.data();
    const participants = chatData.participants || [];
    
    if (participants.length !== 2) {
      throw new Error("Invalid chat room participants");
    }
    
    // Get the other participant
    const otherParticipant = participants.find((uid) => uid !== currentUid) || participants[0];
    
    // Process messages in batches of 500 (Firestore batch limit)
    const batchSize = 500;
    let lastDoc = null;
    let hasMore = true;
    let isFirstBatch = true;
    
    while (hasMore) {
      let query = db.collection("chat_rooms")
        .doc(chatId)
        .collection("messages")
        .limit(batchSize);
      
      if (lastDoc) {
        query = query.startAfter(lastDoc);
      }
      
      const messagesSnapshot = await query.get();
      
      if (messagesSnapshot.empty) {
        hasMore = false;
        break;
      }
      
      // Separate batches for updates and deletes (can't mix in same batch)
      const updateBatch = db.batch();
      const deleteBatch = db.batch();
      let updateCount = 0;
      let deleteCount = 0;
      const messagesToDelete = [];
      
      for (const doc of messagesSnapshot.docs) {
        const data = doc.data();
        const currentDeletedFor = data.deletedFor || [];
        
        const messageType = data.type || "text";
        let messageContent = data.content || "";
        
        // Check if this is a deleted message with original media URL stored
        // If message was deleted (isDeleted: true), check for originalMediaURL field
        const isDeleted = data.isDeleted === true;
        const originalMediaURL = data.originalMediaURL || "";
        
        // Use originalMediaURL if available (for deleted media messages), otherwise use current content
        let mediaURLToDelete = "";
        if (isDeleted && originalMediaURL) {
          mediaURLToDelete = originalMediaURL;
        } else if (messageContent && (
          messageContent.startsWith("http://") || 
          messageContent.startsWith("https://")
        )) {
          mediaURLToDelete = messageContent;
        }
        
        // Check if current user already cleared this message
        if (currentDeletedFor.includes(currentUid)) {
          // Current user already cleared - check if other user also cleared
          if (currentDeletedFor.includes(otherParticipant)) {
            // Both users cleared - delete from Firebase (including "This message has been deleted" messages)
            messagesToDelete.push({
              ref: doc.ref,
              type: messageType,
              content: mediaURLToDelete || messageContent // Use original URL if available
            });
            
            if (deleteCount < 500) {
              deleteBatch.delete(doc.ref);
              deleteCount++;
            }
          }
          // If only current user cleared, do nothing (already marked)
          continue;
        }
        
        // Current user hasn't cleared yet - add them to deletedFor
        // Check if BOTH participants have now cleared this message
        const newDeletedFor = [...currentDeletedFor];
        if (!newDeletedFor.includes(currentUid)) {
          newDeletedFor.push(currentUid);
        }
        
        const bothCleared = newDeletedFor.includes(currentUid) && 
                           newDeletedFor.includes(otherParticipant);
        
        if (bothCleared) {
          // Both users cleared - delete from Firebase (including "This message has been deleted" messages)
          messagesToDelete.push({
            ref: doc.ref,
            type: messageType,
            content: mediaURLToDelete || messageContent // Use original URL if available
          });
          
          if (deleteCount < 500) {
            deleteBatch.delete(doc.ref);
            deleteCount++;
          }
        } else {
          // Only current user cleared - just update deletedFor
          if (updateCount < 500) {
            updateBatch.update(doc.ref, {
              deletedFor: admin.firestore.FieldValue.arrayUnion(currentUid)
            });
            updateCount++;
          }
        }
      }
      
      // Update chat room only once (on first batch)
      if (isFirstBatch) {
        updateBatch.update(chatRef, {
          lastMessage: "",
          lastMessageTs: admin.firestore.FieldValue.serverTimestamp(),
          lastMessageType: "text"
        });
        isFirstBatch = false;
      }
      
      // Commit update batch first
      if (updateCount > 0) {
        await updateBatch.commit();
      }
      
      // Delete media files for messages being deleted
      for (const messageInfo of messagesToDelete) {
        const messageType = messageInfo.type;
        const messageContent = messageInfo.content;
        
        // Delete media file if it's an image or video AND content looks like a URL
        // (not "This media was deleted" replacement text)
        const isMediaType = messageType === "image" || messageType === "video" || messageType === "photo";
        const looksLikeURL = messageContent && (
          messageContent.startsWith("http://") || 
          messageContent.startsWith("https://")
        );
        
        if (isMediaType && looksLikeURL && messageContent.trim() !== "") {
          try {
            // Extract file path from Firebase Storage URL
            const url = new URL(messageContent);
            if (url.hostname.includes("firebasestorage.googleapis.com")) {
              const pathComponents = url.pathname.split("/");
              const oIndex = pathComponents.indexOf("o");
              if (oIndex !== -1 && oIndex + 1 < pathComponents.length) {
                const encodedPath = pathComponents[oIndex + 1];
                const decodedPath = decodeURIComponent(encodedPath);
                const fileRef = storage.bucket().file(decodedPath);
                await fileRef.delete();
                logger.info("Deleted media file from Storage", { path: decodedPath });
              }
            }
          } catch (storageError) {
            logger.warn("Error deleting media file during clear chat", { 
              error: storageError.message,
              messageContent 
            });
            // Continue with message deletion even if storage deletion fails
          }
        }
      }
      
      // Commit delete batch
      if (deleteCount > 0) {
        await deleteBatch.commit();
      }
      
      // Check if there are more messages
      hasMore = messagesSnapshot.docs.length === batchSize;
      if (hasMore) {
        lastDoc = messagesSnapshot.docs[messagesSnapshot.docs.length - 1];
      }
    }
    
    logger.info("Chat cleared successfully", { currentUid, chatId });
    return { success: true };
  } catch (error) {
    logger.error("Error clearing chat", { error: error.message, currentUid, chatId });
    throw new Error("Failed to clear chat: " + error.message);
  }
});

/**
 * Profile server - handles user profile pages
 * Routes:
 * - /profile/{username} - Profile by username
 * - /profile/{userId} - Profile by user ID
 */
exports.profileServer = onRequest(
  {
    maxInstances: 10,
    cors: true,
  },
  profileServerApp
);
