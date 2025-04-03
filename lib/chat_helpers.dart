import 'package:cloud_firestore/cloud_firestore.dart';

/// Generates a unique chat document ID for the given ride and the two users.
/// The format is: rideId_minUserId_maxUserId.
String generateChatDocId(String rideId, String userId1, String userId2) {
  final List<String> sortedIds = [userId1, userId2]..sort();
  return '${rideId}_${sortedIds[0]}_${sortedIds[1]}';
}

/// Gets (or creates) a chat document for a one-to-one conversation between the driver and the passenger.
/// Returns the chat document ID.
Future<String> getOrCreateChat({
  required String rideId,
  required String driverId,
  required String passengerId,
}) async {
  final String chatDocId = generateChatDocId(rideId, driverId, passengerId);
  final chatDoc = FirebaseFirestore.instance
      .collection('RideChats')
      .doc(chatDocId);
  final snapshot = await chatDoc.get();

  if (!snapshot.exists) {
    await chatDoc.set({
      'rideId': rideId,
      'participants': [driverId, passengerId],
      'lastMessage': '', // Optional preview field.
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
  return chatDocId;
}
