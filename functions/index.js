/**
 * Firebase Cloud Functions for COY App
 * Handles push notifications for messages
 */

const admin = require("firebase-admin");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");

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
      case "voice":
        notificationBody = "Voice message";
        break;
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
