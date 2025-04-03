import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'chat_page.dart';

class MyMessagesPage extends StatefulWidget {
  const MyMessagesPage({super.key});

  @override
  _MyMessagesPageState createState() => _MyMessagesPageState();
}

class _MyMessagesPageState extends State<MyMessagesPage> {
  late String currentUserId;

  @override
  void initState() {
    super.initState();
    currentUserId =
        FirebaseAuth.instance.currentUser!.uid; // Fetch current user ID
  }

  @override
  Widget build(BuildContext context) {
    final messagesRef = FirebaseFirestore.instance
        .collection('RideChats')
        .where(
          'participants',
          arrayContains: currentUserId,
        ); // Fetch chats for the current user

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        elevation: 1,
        backgroundColor: Colors.white,
        title: const Text(
          "My Messages",
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: messagesRef.snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data!.docs;

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 70,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "No messages yet",
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              final chatDocId = docs[index].id;
              final participants = data['participants'] as List<dynamic>;
              final lastMessage =
                  data['lastMessage'] as String? ?? 'Start a conversation';

              // Get partner's ID and name
              String partnerId = participants.firstWhere(
                (id) => id != currentUserId,
                orElse: () => 'Partner',
              );

              // Using FutureBuilder to fetch user data
              return FutureBuilder<DocumentSnapshot>(
                future:
                    FirebaseFirestore.instance
                        .collection('Users')
                        .doc(partnerId)
                        .get(),
                builder: (context, userSnapshot) {
                  // Default values
                  String displayName = 'User';
                  String photoURL = '';

                  // Update with actual user data if available
                  if (userSnapshot.hasData &&
                      userSnapshot.data != null &&
                      userSnapshot.data!.exists) {
                    final userData =
                        userSnapshot.data!.data() as Map<String, dynamic>?;
                    if (userData != null) {
                      displayName = userData['displayName'] ?? 'User';
                      photoURL = userData['photoURL'] ?? '';
                    }
                  }

                  return Card(
                    margin: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 2,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0.5,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.blue[100],
                        backgroundImage:
                            photoURL.isNotEmpty ? NetworkImage(photoURL) : null,
                        child:
                            photoURL.isEmpty
                                ? Text(
                                  displayName.isNotEmpty
                                      ? displayName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                )
                                : null,
                      ),
                      title: Text(
                        displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      subtitle: Text(
                        lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: Colors.grey[400],
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) => ChatPage(
                                  chatDocId: chatDocId,
                                  currentUserId:
                                      currentUserId, // Pass current user ID
                                ),
                          ),
                        );
                      },
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
