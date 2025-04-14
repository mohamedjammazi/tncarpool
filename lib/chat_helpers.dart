import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // For debugPrint

/// Helper functions for chat operations.

/// Creates a chat room document if one doesn't exist between two users,
/// or returns the ID of the existing chat room.
Future<String> createOrGetChatRoom(String myUserId, String otherUserId) async {
  final firestore = FirebaseFirestore.instance;
  // Ensure consistent document ID regardless of who initiates the chat
  final participants = [myUserId, otherUserId]..sort();
  final chatIdPart1 = participants[0];
  final chatIdPart2 = participants[1];
  // Consider using a more robust ID generation if needed, but sorted UIDs often work
  final potentialChatId = '${chatIdPart1}_$chatIdPart2'; // Example ID format

  // Check if a chat with this specific ID or participants list already exists
  final chatQuery = firestore
      .collection('chats')
      .where('participants', isEqualTo: participants)
      .limit(1);

  final existing = await chatQuery.get();

  if (existing.docs.isNotEmpty) {
    // Chat already exists, return its ID
    debugPrint("Existing chat found: ${existing.docs.first.id}");
    return existing.docs.first.id;
  } else {
    // Chat doesn't exist, create a new one
    debugPrint("Creating new chat for participants: $participants");
    try {
      final newChatRef = await firestore.collection('chats').add({
        'participants': participants,
        'createdAt': FieldValue.serverTimestamp(),
        'lastMessage': '', // Initialize last message fields
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': '',
        // 'seenBy': [], // Initializing seenBy might be redundant here
      });
      debugPrint("New chat created with ID: ${newChatRef.id}");
      return newChatRef.id;
    } catch (e) {
      debugPrint("Error creating chat room: $e");
      // Fallback or rethrow error as needed
      // Maybe try fetching again in case of race condition?
      final retry = await chatQuery.get();
      if (retry.docs.isNotEmpty) {
        return retry.docs.first.id;
      } else {
        throw Exception("Failed to create or get chat room: $e");
      }
    }
  }
}

/// Marks messages in a chat as seen by the current user by updating the
/// unread count in the corresponding userChats document.
/// **ASSUMPTION:** You have a 'userChats' collection where each document ID
/// is '{userId}_{chatId}' and contains an 'unreadCount' field updated by Cloud Functions.
Future<void> markMessagesAsSeen({
  required String chatId,
  required String userId, // The ID of the user whose perspective we're updating
}) async {
  if (chatId.isEmpty || userId.isEmpty) return;

  final firestore = FirebaseFirestore.instance;
  // Construct the document ID for the user-specific chat data
  final userChatDocId = "${userId}_$chatId";
  final userChatRef = firestore.collection('userChats').doc(userChatDocId);

  try {
    // Set unreadCount to 0. Use set with merge to create the doc if it doesn't exist.
    await userChatRef.set(
      {'unreadCount': 0},
      SetOptions(
        merge: true,
      ), // Merge to avoid overwriting other fields if they exist
    );
    debugPrint(
      "Marked chat $chatId as seen for user $userId (set unreadCount to 0 in userChats)",
    );
  } catch (e) {
    debugPrint("Error marking chat $chatId as seen for user $userId: $e");
    // Handle error appropriately, maybe log it
  }

  // REMOVED: Old logic querying messages subcollection - inefficient and query was invalid.
  // Rely on Cloud Function to increment unreadCount and this function to reset it.
}

/// Sends a text message to a specific chat.
Future<void> sendMessage({
  required String chatId,
  required String senderId,
  required String text,
}) async {
  if (chatId.isEmpty || senderId.isEmpty || text.trim().isEmpty) {
    debugPrint("sendMessage: Invalid parameters provided.");
    return;
  }

  final firestore = FirebaseFirestore.instance;
  final chatDocRef = firestore.collection('chats').doc(chatId);
  final messagesRef = chatDocRef.collection('messages');
  final timestamp = FieldValue.serverTimestamp(); // Use server timestamp

  try {
    // Add message to the messages subcollection
    await messagesRef.add({
      'senderId': senderId,
      'text': text.trim(),
      'timestamp': timestamp,
      // 'seenBy': [senderId], // Initial seenBy array with only the sender
      // Simpler: Cloud function can check senderId != recipientId before incrementing unreadCount
      'seen':
          false, // Use a simple boolean if preferred, update via Cloud Function/read receipts
    });

    // Update the parent chat document with the last message info
    await chatDocRef.set(
      {
        // Use set merge to ensure doc exists
        'lastMessage': text.trim(),
        'lastMessageTime': timestamp,
        'lastMessageSenderId': senderId,
        // 'seenBy': [senderId], // Update seenBy on parent doc as well? Optional.
      },
      SetOptions(merge: true),
    ); // Merge ensures we don't overwrite participants etc.

    debugPrint("Message sent successfully to chat $chatId");
  } catch (e) {
    debugPrint("Error sending message to chat $chatId: $e");
    // Rethrow or handle error as needed
    throw Exception("Failed to send message: $e");
  }
}

// --- Dependencies ---
// Requires: cloud_firestore

// --- Firestore Setup ---
// * Assumes a 'chats' collection with documents containing 'participants' (Array<String>), 'lastMessage', 'lastMessageTime', 'lastMessageSenderId'.
// * Assumes a 'users' collection for user details.
// * Assumes a 'userChats' collection with documents named '{userId}_{chatId}' containing an 'unreadCount' (Number) field, managed by Cloud Functions.
