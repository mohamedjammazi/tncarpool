const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {setGlobalOptions} = require("firebase-functions/v2");
const {getMessaging} = require("firebase-admin/messaging");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const admin = require("firebase-admin");

// Initialize Firebase Admin SDK
admin.initializeApp();
// Set region for functions
setGlobalOptions({region: "europe-west1"});

/**
 * Checks if a booking value represents an empty seat.
 * @param {*} bookedByValue - The value to check.
 * @return {boolean} - Returns true if the seat is empty, false otherwise.
 */
function isEmptyBooking(bookedByValue) {
  // Considers null, undefined, empty string, and "n/a" as empty
  return bookedByValue == null || bookedByValue === "" || bookedByValue === "n/a";
}

// ============================================================================
// 1. Chat Notification Function
// ============================================================================
exports.sendChatNotification = onDocumentCreated(
    "chats/{chatId}/messages/{messageId}",
    async (event) => {
      try {
        console.log("Chat Function triggered for new message", event.params);
        const snap = event.data;
        if (!snap) {
          console.log("No data associated with the event");
          return;
        }

        const messageData = snap.data();
        console.log("Message data:", JSON.stringify(messageData));

        const senderId = messageData.senderId;
        if (!senderId) {
          console.log("No sender ID in message data");
          return;
        }

        const messageText = messageData.text || "لديك رسالة جديدة";
        const chatId = event.params.chatId;

        // Get chat document
        const db = getFirestore();
        const chatRef = db.collection("chats").doc(chatId);
        const chatDoc = await chatRef.get();

        if (!chatDoc.exists) {
          console.log(`Chat ${chatId} not found.`);
          return;
        }

        const chatInfo = chatDoc.data();
        console.log("Chat data:", JSON.stringify(chatInfo));

        const participants = chatInfo.participants || [];
        console.log("Found participants:", participants);

        if (participants.length === 0) {
          console.log(`No participants found in chat ${chatId}.`);
          return;
        }

        const recipientId = participants.find((uid) => uid !== senderId);
        console.log("Identified recipient:", recipientId);

        if (!recipientId) {
          console.log(`Recipient not found for chat ${chatId}.`);
          return;
        }

        // Get recipient's FCM token
        const userRef = db.collection("users").doc(recipientId);
        const userDoc = await userRef.get();

        if (!userDoc.exists) {
          console.log(`User ${recipientId} not found.`);
          return;
        }

        const userData = userDoc.data();
        const token = userData.fcmToken;

        if (!token) {
          console.log(`User ${recipientId} has no FCM token.`);
          return;
        }

        console.log(`Retrieved FCM token for user ${recipientId}: ${token.substring(0, 10)}...`);

        // Get sender's name if available
        let senderName = "مستخدم"; // Default name ("User" in Arabic)
        if (messageData.senderName) {
          senderName = messageData.senderName;
        } else {
          try {
            const senderDoc = await db.collection("users").doc(senderId).get();
            if (senderDoc.exists) {
              const senderData = senderDoc.data();
              senderName = senderData.displayName || senderData.name || senderName;
            }
          } catch (error) {
            console.log(`Error fetching sender info: ${error.message}`);
          }
        }

        // Prepare push notification payload with enhanced options
        const message = {
          notification: {
            title: senderName,
            body: messageText,
            ...(messageData.imageUrl ? {imageUrl: messageData.imageUrl} : {}),
          },
          data: {
            chatId: chatId,
            senderId: senderId,
            messageId: event.params.messageId,
            timestamp: String(Date.now()),
            type: messageData.type || "text",
            notificationType: "chat_message",
          },
          android: {
            notification: {
              channelId: "chat_messages",
              priority: "high",
              sound: "default",
              clickAction: "FLUTTER_NOTIFICATION_CLICK",
            },
          },
          apns: {
            payload: {
              aps: {
                contentAvailable: true,
                sound: "default",
                badge: 1,
                category: "NEW_MESSAGE",
              },
            },
          },
          token: token,
        };

        const messaging = getMessaging();
        const response = await messaging.send(message);
        console.log(`Successfully sent notification to ${recipientId}, response:`, response);

        // Update unread count in a separate user-specific chat collection
        try {
          const userChatRef = db.collection("userChats").doc(`${recipientId}_${chatId}`);
          // Use set with merge to create the doc if it doesn't exist
          await userChatRef.set({
            unreadCount: FieldValue.increment(1),
            lastMessage: messageText,
            lastMessageTime: FieldValue.serverTimestamp(),
          }, {merge: true});
          console.log(`Updated unread count for user ${recipientId} in chat ${chatId}`);
        } catch (error) {
          console.log(`Error updating unread count: ${error.message}`);
        }
      } catch (error) {
        console.error(`Error in sendChatNotification function: ${error.message}`);
        console.error(error.stack);
      }
    },
);

// ============================================================================
// 2. Call Notification Function
// ============================================================================
exports.sendCallNotification = onDocumentCreated(
    "calls/{callId}",
    async (event) => {
      try {
        console.log("Call Function triggered, callId:", event.params.callId);
        const snap = event.data;
        if (!snap) {
          console.log("No call data");
          return;
        }
        const callData = snap.data();
        const callerId = callData.callerId;
        const calleeId = callData.calleeId;

        if (!callerId || !calleeId) {
          console.log("Caller/Callee ID missing");
          return;
        }

        // Use || false for compatibility
        const isVideoCall = callData.isVideoCall || false;
        const callTypeText = isVideoCall ? "video" : "voice";

        const db = getFirestore();
        const userRef = db.collection("users").doc(calleeId);
        const userDoc = await userRef.get();

        if (!userDoc.exists) {
          console.log(`Callee ${calleeId} not found.`);
          return;
        }

        const userData = userDoc.data();
        const token = userData.fcmToken;

        if (!token) {
          console.log(`User ${calleeId} has no FCM token.`);
          return;
        }

        console.log(`Token for ${calleeId}: ${token.substring(0, 10)}...`);

        let callerName = "متصل";
        try {
          const callerDoc = await db.collection("users").doc(callerId).get();
          if (callerDoc.exists) {
            const callerData = callerDoc.data();
            callerName = callerData.displayName || callerData.name || callerName;
          }
        } catch (error) {
          console.log(`Error fetching caller info: ${error.message}`);
        }

        const message = {
          notification: {
            title: `Incoming ${callTypeText} call`,
            body: `${callerName} is calling you`,
          },
          data: {
            call: "true",
            callerId: callerId,
            channelId: event.params.callId,
            isVideoCall: isVideoCall.toString(),
            callType: callTypeText,
          },
          android: {
            notification: {
              channelId: "call_notifications",
              priority: "high",
              sound: "default",
              clickAction: "FLUTTER_NOTIFICATION_CLICK",
            },
          },
          apns: {
            payload: {
              aps: {
                contentAvailable: true,
                sound: "default",
                badge: 1,
                category: "CALL_NOTIFICATION",
              },
            },
          },
          token: token,
        };

        const response = await getMessaging().send(message);
        console.log(`Call notification sent to ${calleeId}, response: ${response}`);
      } catch (error) {
        console.error(`Error in sendCallNotification: ${error.message}\n${error.stack}`);
      }
    },
);

// ============================================================================
// 3. Ride Booking/Unbooking Notification Function
// ============================================================================
exports.sendRideBookingNotification = onDocumentUpdated(
    "rides/{rideId}",
    async (event) => {
      try {
        console.log("Ride Booking/Unbooking Function triggered for ride", event.params.rideId);

        const change = event.data;
        if (!change || !change.before || !change.after) {
          console.log("Missing before or after data.");
          return;
        }

        const beforeData = change.before.data();
        const afterData = change.after.data();
        const rideId = event.params.rideId;

        // Use && checks for compatibility
        const beforeSeats = (beforeData && Array.isArray(beforeData.seatLayout)) ? beforeData.seatLayout : [];
        const afterSeats = (afterData && Array.isArray(afterData.seatLayout)) ? afterData.seatLayout : [];

        // Detect changes where bookedBy goes from empty to filled (booked) or filled to empty (unbooked)
        const bookingChanges = [];
        const maxSeats = Math.max(beforeSeats.length, afterSeats.length);

        for (let i = 0; i < maxSeats; i++) {
          const beforeSeat = beforeSeats[i] || {};
          const afterSeat = afterSeats[i] || {};
          const beforeBookedBy = beforeSeat.bookedBy;
          const afterBookedBy = afterSeat.bookedBy;

          if (beforeBookedBy !== afterBookedBy) {
            const beforeIsEmpty = isEmptyBooking(beforeBookedBy);
            const afterIsEmpty = isEmptyBooking(afterBookedBy);

            if (beforeIsEmpty && !afterIsEmpty) { // Seat was booked
              bookingChanges.push({seatIndex: i, status: "booked", userId: afterBookedBy});
            } else if (!beforeIsEmpty && afterIsEmpty) { // Seat was unbooked
              bookingChanges.push({seatIndex: i, status: "unbooked", userId: beforeBookedBy});
            }
          }
        }

        if (bookingChanges.length === 0) {
          console.log("No booking/unbooking changes detected.");
          return;
        }

        console.log("Detected booking changes:", bookingChanges);

        // Process the first detected valid change (usually only one seat changes per user action)
        const bookingChange = bookingChanges[0];
        const bookingUserId = bookingChange.userId; // User who booked or unbooked
        const bookingStatus = bookingChange.status; // 'booked' or 'unbooked'

        // Ensure bookingUserId is valid before proceeding
        if (isEmptyBooking(bookingUserId)) {
          console.log("Invalid bookingUserId detected (empty or n/a).");
          return;
        }

        const db = getFirestore();
        const driverId = afterData.driverId; // Notify the driver

        if (!driverId) {
          console.log("No driver ID in ride data.");
          return;
        }

        const driverDoc = await db.collection("users").doc(driverId).get();
        if (!driverDoc.exists) {
          console.log(`Driver ${driverId} not found.`);
          return;
        }

        const driverData = driverDoc.data();
        const fcmToken = driverData.fcmToken;

        if (!fcmToken) {
          console.log(`Driver ${driverId} has no FCM token.`);
          return;
        }

        console.log(`Token for driver ${driverId}: ${fcmToken.substring(0, 10)}...`);

        // Get booking user's name
        let bookingUserName = "مستخدم";
        try {
          const bookingUserDoc = await db.collection("users").doc(bookingUserId).get();
          if (bookingUserDoc.exists) {
            const d = bookingUserDoc.data();
            bookingUserName = d.displayName || d.name || bookingUserName;
          }
        } catch (error) {
          console.log("Error fetching booking user info:", error.message);
        }

        // Get ride details
        const rideDestination = afterData.endLocationName || "وجهتك";
        let rideDateStr = "";
        if (afterData.date && afterData.date.toDate) { // Check if it's a Timestamp
          try {
            rideDateStr = afterData.date.toDate().toLocaleDateString("en-US", {
              year: "numeric",
              month: "short",
              day: "numeric",
            });
          } catch (e) {
            console.log("Error formatting date", e);
          }
        }

        // Create message based on booking type
        let title; let body;
        if (bookingStatus === "booked") {
          title = "تم حجز مقعد جديد";
          body = `قام ${bookingUserName} بحجز مقعد في رحلتك إلى ${rideDestination}${rideDateStr ? ` في ${rideDateStr}` : ""}. يرجى المراجعة والموافقة.`;
        } else { // unbooked
          title = "تم إلغاء حجز مقعد";
          body = `قام ${bookingUserName} بإلغاء حجز مقعده في رحلتك إلى ${rideDestination}${rideDateStr ? ` في ${rideDateStr}` : ""}.`;
        }

        const messagePayload = {
          notification: {
            title: title,
            body: body,
          },
          data: {
            notificationType: "ride_booking",
            rideId: rideId,
            bookedBy: bookingUserId,
            bookingStatus: bookingStatus,
            timestamp: String(Date.now()),
          },
          android: {
            notification: {
              channelId: "ride_notifications",
              priority: "high",
              sound: "default",
              clickAction: "FLUTTER_NOTIFICATION_CLICK",
            },
          },
          apns: {
            payload: {
              aps: {
                contentAvailable: true,
                sound: "default",
                badge: 1,
                category: "RIDE_BOOKING",
              },
            },
          },
          token: fcmToken,
        };

        await getMessaging().send(messagePayload);
        console.log(`Sent ride booking notification (${bookingStatus}) to driver ${driverId}`);

        // Add to driver's notifications collection
        try {
          await db.collection("users").doc(driverId).collection("notifications").add({
            type: "ride_booking",
            rideId: rideId,
            bookedBy: bookingUserId,
            bookedByName: bookingUserName,
            bookingStatus: bookingStatus,
            createdAt: FieldValue.serverTimestamp(),
            read: false,
          });
          console.log(`Added notification to driver's collection for ${driverId}`);
        } catch (error) {
          console.log(`Error adding notification to collection: ${error.message}`);
        }
      } catch (error) {
        console.error(`Error in sendRideBookingNotification: ${error.message}\n${error.stack}`);
      }
    },
);

// ============================================================================
// 4. Booking Approval Notification Function
// ============================================================================
exports.sendApprovalNotification = onDocumentUpdated(
    "rides/{rideId}",
    async (event) => {
      try {
        console.log("Approval update function triggered for ride", event.params.rideId);
        const change = event.data;
        if (!change || !change.before || !change.after) {
          console.log("Missing before or after data.");
          return;
        }

        const beforeData = change.before.data();
        const afterData = change.after.data();
        const rideId = event.params.rideId;

        // Use && checks for compatibility
        const beforeSeats = (beforeData && Array.isArray(beforeData.seatLayout)) ? beforeData.seatLayout : [];
        const afterSeats = (afterData && Array.isArray(afterData.seatLayout)) ? afterData.seatLayout : [];

        const approvalChanges = [];
        const maxSeats = Math.max(beforeSeats.length, afterSeats.length);

        for (let i = 0; i < maxSeats; i++) {
          const beforeSeat = beforeSeats[i] || {};
          const afterSeat = afterSeats[i] || {};
          // Check if approvalStatus changed FROM pending TO approved/declined
          if (beforeSeat.approvalStatus !== afterSeat.approvalStatus &&
              beforeSeat.approvalStatus === "pending" &&
              (afterSeat.approvalStatus === "approved" || afterSeat.approvalStatus === "declined")) {
            // Ensure bookedBy is valid *before* the change occurred (it might be cleared on decline)
            const bookedUserId = beforeSeat.bookedBy; // Use before data to identify the user
            if (bookedUserId && bookedUserId !== "n/a") {
              approvalChanges.push({
                seatIndex: i,
                newStatus: afterSeat.approvalStatus,
                bookedBy: bookedUserId,
              });
            } else {
              console.log(`Approval changed for seat ${i}, but original bookedBy is invalid: ${bookedUserId}`);
            }
          }
        }

        if (approvalChanges.length === 0) {
          console.log("No valid approval status change detected.");
          return;
        }

        console.log("Detected approval status changes:", approvalChanges);

        // Process the first detected change
        const approvalChange = approvalChanges[0];
        const bookingUserId = approvalChange.bookedBy; // User who booked the seat
        const newStatus = approvalChange.newStatus; // 'approved' or 'declined'

        const db = getFirestore();
        const userDoc = await db.collection("users").doc(bookingUserId).get();

        if (!userDoc.exists) {
          console.log(`User ${bookingUserId} not found.`);
          return;
        }

        const userData = userDoc.data();
        const fcmToken = userData.fcmToken;

        if (!fcmToken) {
          console.log(`User ${bookingUserId} has no FCM token.`);
          return;
        }

        console.log(`Token for user ${bookingUserId}: ${fcmToken.substring(0, 10)}...`);

        let title; let body;
        if (newStatus === "approved") {
          title = "تمت الموافقة على حجزك";
          body = `تمت الموافقة على حجز مقعدك في الرحلة.`;
        } else {
          title = "تم رفض حجزك";
          body = `تم رفض حجز مقعدك في الرحلة.`;
        }

        const messagePayload = {
          notification: {
            title: title,
            body: body,
          },
          data: {
            notificationType: "approval_update",
            rideId: rideId,
            bookedBy: bookingUserId,
            approvalStatus: newStatus,
            timestamp: String(Date.now()),
          },
          android: {
            notification: {
              channelId: "ride_notifications",
              priority: "high",
              sound: "default",
              clickAction: "FLUTTER_NOTIFICATION_CLICK",
            },
          },
          apns: {
            payload: {
              aps: {
                contentAvailable: true,
                sound: "default",
                badge: 1,
                category: "RIDE_APPROVAL",
              },
            },
          },
          token: fcmToken,
        };

        await getMessaging().send(messagePayload);
        console.log(`Sent approval notification (${newStatus}) to user ${bookingUserId}`);

        // Add to user's notifications collection
        try {
          await db.collection("users").doc(bookingUserId).collection("notifications").add({
            type: "approval_update",
            rideId: rideId,
            bookedBy: bookingUserId,
            approvalStatus: newStatus,
            createdAt: FieldValue.serverTimestamp(),
            read: false,
          });
          console.log(`Added approval notification to user's collection for ${bookingUserId}`);
        } catch (error) {
          console.log(`Error adding notification to user's collection: ${error.message}`);
        }
      } catch (error) {
        console.error(`Error in sendApprovalNotification: ${error.message}\n${error.stack}`);
      }
    },
);

// ============================================================================
// 5. Ride Status Change Notification Function
// ============================================================================
exports.sendRideStatusNotification = onDocumentUpdated(
    "rides/{rideId}",
    async (event) => {
      try {
        console.log("Ride status update function triggered for ride", event.params.rideId);
        const change = event.data;
        if (!change || !change.before || !change.after) {
          console.log("Missing before or after data.");
          return;
        }

        const beforeData = change.before.data();
        const afterData = change.after.data();
        const rideId = event.params.rideId;

        const validStatuses = ["cancelled", "started", "completed"];
        if (beforeData.status === afterData.status || !validStatuses.includes(afterData.status)) {
          console.log(`No relevant status transition detected. Before: ${beforeData.status}, After: ${afterData.status}`);
          return;
        }

        const newStatus = afterData.status;
        console.log(`Status transition detected: ${beforeData.status} -> ${newStatus}`);

        // Use && checks for compatibility
        const seatLayout = (afterData && Array.isArray(afterData.seatLayout)) ? afterData.seatLayout : [];
        const bookedUserIds = new Set();

        for (const seat of seatLayout) {
          // Notify only users whose booking was approved
          if (seat && !isEmptyBooking(seat.bookedBy) && seat.approvalStatus === "approved") {
            bookedUserIds.add(seat.bookedBy);
          }
        }

        if (bookedUserIds.size === 0) {
          console.log("No approved booked users found to notify.");
          return;
        }

        console.log("Approved booked user IDs to notify:", Array.from(bookedUserIds));

        const db = getFirestore();
        // Fetch tokens concurrently using Promise.all
        const userFetchPromises = Array.from(bookedUserIds).map((userId) =>
          db.collection("users").doc(userId).get(),
        );
        const userDocs = await Promise.all(userFetchPromises);

        const tokens = [];
        const userIdsNotified = [];
        userDocs.forEach((userDoc) => {
          if (userDoc.exists) {
            const userData = userDoc.data();
            if (userData.fcmToken) {
              tokens.push(userData.fcmToken);
              userIdsNotified.push(userDoc.id);
            } else {
              console.log(`User ${userDoc.id} does not have an FCM token.`);
            }
          } else {
            console.log(`User document not found for one of the booked users.`);
          }
        });

        if (tokens.length === 0) {
          console.log("No FCM tokens available for sending notifications.");
          return;
        }

        console.log(`FCM tokens collected for ${tokens.length} users.`);

        let title; let body;
        if (newStatus === "cancelled") {
          title = "تم إلغاء الرحلة";
          body = "تم إلغاء الرحلة التي قمت بالحجز عليها.";
        } else if (newStatus === "started") {
          title = "بدأت الرحلة";
          body = "بدأت الرحلة التي قمت بالحجز عليها.";
        } else if (newStatus === "completed") {
          title = "انتهت الرحلة";
          body = "انتهت الرحلة التي قمت بالحجز عليها.";
        } else {
          console.log("Unknown new status:", newStatus);
          return;
        }

        const messagePayload = {
          notification: {
            title: title,
            body: body,
          },
          data: {
            notificationType: "ride_status_update",
            rideId: rideId,
            newStatus: newStatus,
            timestamp: String(Date.now()),
          },
          android: {
            notification: {
              channelId: "ride_notifications",
              priority: "high",
              sound: "default",
              clickAction: "FLUTTER_NOTIFICATION_CLICK",
            },
          },
          apns: {
            payload: {
              aps: {
                contentAvailable: true,
                sound: "default",
                badge: 1,
                category: "RIDE_STATUS",
              },
            },
          },
          tokens: tokens,
        };

        const response = await getMessaging().sendEachForMulticast(messagePayload);
        console.log(`Sent ride status notifications. Success count: ${response.successCount}, Failure count: ${response.failureCount}`);

        if (response.failureCount > 0) {
          response.responses.forEach((resp, idx) => {
            if (!resp.success) {
              console.error(`Failed to send to token at index ${idx}: ${resp.error}`);
            }
          });
        }

        // Add record to each notified user's notifications collection
        const notificationPromises = userIdsNotified.map((userId) =>
          db.collection("users").doc(userId).collection("notifications").add({
            type: "ride_status_update",
            rideId: rideId,
            newStatus: newStatus,
            createdAt: FieldValue.serverTimestamp(),
            read: false,
          }),
        );

        await Promise.all(notificationPromises);
        console.log(`Added ride status notification to collections for ${userIdsNotified.length} users`);
      } catch (error) {
        console.error(`Error in sendRideStatusNotification: ${error.message}\n${error.stack}`);
      }
    },
);
