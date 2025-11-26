/**
 * Firebase Cloud Function to send push notifications for messages
 * 
 * SETUP INSTRUCTIONS:
 * 1. Install Firebase CLI: npm install -g firebase-tools
 * 2. Login: firebase login
 * 3. Initialize functions: firebase init functions (choose JavaScript)
 * 4. Copy this function to functions/index.js
 * 5. Install dependencies: cd functions && npm install
 * 6. Deploy: firebase deploy --only functions
 * 
 * REQUIRED PACKAGES:
 * - firebase-admin
 * - firebase-functions
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

/**
 * Cloud Function to send push notification when a message is sent
 * This function is called from the iOS app via HTTPS callable
 */
exports.sendMessageNotification = functions.https.onCall(async (data, context) => {
  // Verify authentication (optional but recommended)
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { token, notification, data: notificationData, apns } = data;

  if (!token) {
    throw new functions.https.HttpsError('invalid-argument', 'FCM token is required');
  }

  try {
    // Prepare the message payload
    const message = {
      token: token,
      notification: {
        title: notification?.title || 'New Message',
        body: notification?.body || 'You have a new message',
      },
      data: {
        type: notificationData?.type || 'message',
        chatId: notificationData?.chatId || '',
        senderUid: notificationData?.senderUid || '',
        messageType: notificationData?.messageType || 'text',
        userProfileImageURL: notificationData?.userProfileImageURL || '',
        appProfileImageURL: notificationData?.appProfileImageURL || '',
      },
      apns: {
        payload: {
          aps: {
            alert: {
              title: notification?.title || 'New Message',
              body: notification?.body || 'You have a new message',
            },
            sound: 'default',
            badge: 1,
            'mutable-content': 1, // Enable notification extensions for rich notifications
          },
          userProfileImageURL: notificationData?.userProfileImageURL || '',
          appProfileImageURL: notificationData?.appProfileImageURL || '',
        },
        fcmOptions: {
          imageUrl: notificationData?.userProfileImageURL || '',
        },
      },
    };

    // Send the notification
    const response = await admin.messaging().send(message);
    console.log('Successfully sent message:', response);
    
    return { success: true, messageId: response };
  } catch (error) {
    console.error('Error sending message:', error);
    throw new functions.https.HttpsError('internal', 'Failed to send notification', error);
  }
});

/**
 * Alternative: Firestore trigger that automatically sends notifications when messages are created
 * This is more efficient as it doesn't require an HTTPS call from the client
 */
exports.onMessageCreated = functions.firestore
  .document('chat_rooms/{chatId}/messages/{messageId}')
  .onCreate(async (snap, context) => {
    const messageData = snap.data();
    const chatId = context.params.chatId;
    const senderUid = messageData.senderUid;
    const messageType = messageData.type || 'text';
    const messageContent = messageData.content || '';

    // Get chat room to find participants
    const chatRoomRef = admin.firestore().collection('chat_rooms').doc(chatId);
    const chatRoom = await chatRoomRef.get();
    
    if (!chatRoom.exists) {
      console.error('Chat room not found:', chatId);
      return null;
    }

    const participants = chatRoom.data().participants || [];
    const receiverUid = participants.find((uid) => uid !== senderUid);

    if (!receiverUid) {
      console.error('Receiver not found for chat:', chatId);
      return null;
    }

    // Get receiver's FCM token
    const receiverDoc = await admin.firestore().collection('users').doc(receiverUid).get();
    const receiverToken = receiverDoc.data()?.fcmToken;

    if (!receiverToken) {
      console.log('No FCM token for receiver:', receiverUid);
      return null;
    }

    // Get sender's user data
    const senderDoc = await admin.firestore().collection('users').doc(senderUid).get();
    const senderData = senderDoc.data();
    const senderName = senderData?.username || senderData?.name || 'Someone';
    const senderProfileImageURL = senderData?.profileImageURL || '';

    // Get receiver's profile image for app profile
    const appProfileImageURL = receiverDoc.data()?.profileImageURL || '';

    // Format notification body based on message type
    let notificationBody;
    switch (messageType) {
      case 'voice':
        notificationBody = 'Voice message';
        break;
      case 'image':
      case 'photo':
        notificationBody = 'Sent photo';
        break;
      case 'video':
        notificationBody = 'Sent video';
        break;
      case 'text':
        notificationBody = messageContent;
        break;
      default:
        notificationBody = 'New message';
    }

    // Prepare the message payload
    const message = {
      token: receiverToken,
      notification: {
        title: senderName,
        body: notificationBody,
      },
      data: {
        type: 'message',
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
            sound: 'default',
            badge: 1,
            'mutable-content': 1,
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
      console.log('Successfully sent notification:', response);
      return null;
    } catch (error) {
      console.error('Error sending notification:', error);
      return null;
    }
  });

