import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';

class ChatPage extends StatefulWidget {
  final String chatDocId;
  final String currentUserId;

  const ChatPage({
    super.key,
    required this.chatDocId,
    required this.currentUserId,
  });

  @override
  _ChatPageState createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _messageController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void dispose() {
    _messageController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  /// Send a text message with an "isNotified" flag set to false.
  Future<void> _sendTextMessage() async {
    final messageText = _messageController.text.trim();
    if (messageText.isEmpty) return;

    final messagesRef = FirebaseFirestore.instance
        .collection('RideChats')
        .doc(widget.chatDocId)
        .collection('Messages');

    await messagesRef.add({
      'senderId': widget.currentUserId,
      'message': messageText,
      'timestamp': FieldValue.serverTimestamp(),
      'isNotified': false,
      'messageType': 'text',
    });

    // Update the last message in the parent chat document.
    await FirebaseFirestore.instance
        .collection('RideChats')
        .doc(widget.chatDocId)
        .update({
          'lastMessage': messageText,
          'updatedAt': FieldValue.serverTimestamp(),
        });

    _messageController.clear();
  }

  /// Play a notification sound from your assets.
  void _playNotificationSound() {
    _audioPlayer.play(AssetSource('assets/sounds/notification.mp3'));
  }

  /// Listen to Firestore for new messages that have not been notified.
  void _listenForNewMessages() {
    FirebaseFirestore.instance
        .collection('RideChats')
        .doc(widget.chatDocId)
        .collection('Messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .listen((snapshot) {
          for (var change in snapshot.docChanges) {
            if (change.type == DocumentChangeType.added) {
              final data = change.doc.data() as Map<String, dynamic>;
              // Play sound if the message is not from the current user and not yet notified.
              if (data['senderId'] != widget.currentUserId &&
                  (data['isNotified'] == null || data['isNotified'] == false)) {
                _playNotificationSound();
                // Mark the message as notified to avoid duplicate notifications.
                change.doc.reference.update({'isNotified': true});
              }
            }
          }
        });
  }

  @override
  void initState() {
    super.initState();
    _listenForNewMessages();
  }

  @override
  Widget build(BuildContext context) {
    final messagesStream =
        FirebaseFirestore.instance
            .collection('RideChats')
            .doc(widget.chatDocId)
            .collection('Messages')
            .orderBy('timestamp', descending: true)
            .snapshots();

    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: messagesStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No messages yet'));
                }

                final docs = snapshot.data!.docs;
                return ListView.builder(
                  reverse: true,
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final senderId = data['senderId'] as String;
                    final message = data['message'] as String;
                    final isMe = senderId == widget.currentUserId;
                    return Container(
                      alignment:
                          isMe ? Alignment.centerRight : Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.blue[200] : Colors.grey[300],
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(message),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type your message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.grey[200],
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  color: Colors.blue,
                  onPressed: _sendTextMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
