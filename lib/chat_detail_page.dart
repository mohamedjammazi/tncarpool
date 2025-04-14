import 'dart:convert'; // Needed for jsonEncode in notification payload potentially
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'; // Keep if ads needed elsewhere
import 'package:intl/intl.dart'; // For timestamp formatting
import 'package:url_launcher/url_launcher.dart'; // Keep if needed

// Import Helpers and Pages
import 'chat_helpers.dart'; // Import the updated helpers
import 'chat_detail_page.dart';
import 'home_page.dart';
import 'my_ride_page.dart';
import 'my_cars.dart';
import 'get_started_page.dart';
import 'call_page.dart'; // Ensure this page exists

class ChatDetailPage extends StatefulWidget {
  final String chatId;
  final String otherUserId;
  final String? otherUserName; // Optional pre-fetched name

  const ChatDetailPage({
    super.key,
    required this.chatId,
    required this.otherUserId,
    this.otherUserName,
  });

  @override
  State<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<ChatDetailPage> {
  final User? currentUser = FirebaseAuth.instance.currentUser;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _messageController = TextEditingController();

  // State for UI
  String _otherUserDisplayName = "Chat"; // Default title
  String _otherUserImageUrl = ""; // For AppBar avatar
  bool _isOtherUserLoading = true;
  bool _isSending = false; // Loading indicator for sending message
  bool _isCallInProgress = false; // Loading indicator for initiating call

  @override
  void initState() {
    super.initState();
    _loadOtherUserInfo(); // Fetch user info for AppBar
    // Mark messages as seen when entering the chat
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (currentUser != null) {
        // Call the updated helper function
        markMessagesAsSeen(chatId: widget.chatId, userId: currentUser!.uid);
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  /// Load other user's info for AppBar display
  Future<void> _loadOtherUserInfo() async {
    if (widget.otherUserName != null && widget.otherUserName!.isNotEmpty) {
      setState(() {
        _otherUserDisplayName = widget.otherUserName!;
        _isOtherUserLoading = false; // Assume name is enough if passed
      });
      // Optionally still fetch image URL if name was passed but image wasn't
    }

    try {
      final userDoc =
          await _firestore.collection('users').doc(widget.otherUserId).get();
      if (mounted && userDoc.exists) {
        final userData = userDoc.data() as Map<String, dynamic>;
        setState(() {
          // Prioritize fetched name if initial one wasn't provided or is basic
          _otherUserDisplayName =
              userData['displayName'] ??
              userData['name'] ??
              _otherUserDisplayName; // Keep passed name if fetched is null
          _otherUserImageUrl = userData['imageUrl'] ?? '';
          _isOtherUserLoading = false;
        });
      } else if (mounted) {
        setState(() {
          _isOtherUserLoading = false;
        }); // Stop loading even if user not found
      }
    } catch (e) {
      print('Error loading other user info: $e');
      if (mounted)
        setState(() {
          _isOtherUserLoading = false;
        }); // Stop loading on error
    }
  }

  /// Initiate a call (voice or video)
  Future<void> _initiateCall({required bool isVideoCall}) async {
    if (currentUser == null || _isCallInProgress) return;

    setState(() => _isCallInProgress = true);

    try {
      final callDocRef = _firestore.collection('calls').doc();
      final callId = callDocRef.id;

      // Create call document (triggers Cloud Function)
      await callDocRef.set({
        'callerId': currentUser!.uid,
        'calleeId': widget.otherUserId,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'calling',
        'isVideoCall': isVideoCall,
        'callerName': currentUser!.displayName ?? "User", // Pass caller name
        'callType': isVideoCall ? 'video' : 'voice',
        // Add caller image URL if needed for notification/call screen
        'callerImageUrl': currentUser!.photoURL ?? '',
      });

      if (!mounted) return;

      // Navigate to CallPage immediately for the caller
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => CallPage(channelId: callId)),
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start call: ${e.toString()}')),
        );
    } finally {
      if (mounted) setState(() => _isCallInProgress = false);
    }
  }

  /// Send message using the helper function
  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (currentUser == null || text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _messageController.clear(); // Clear input immediately

    try {
      // Call the helper function from chat_helpers.dart
      await sendMessage(
        chatId: widget.chatId,
        senderId: currentUser!.uid,
        text: text,
      );
      // Success feedback is optional, message appears via StreamBuilder
    } catch (e) {
      print('Error sending message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to send message'),
            backgroundColor: Colors.red,
          ),
        );
        // Optionally restore text to controller if send failed
        // _messageController.text = text;
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Formats timestamp for display in message bubble
  String _formatMessageTimestamp(DateTime? timestamp) {
    if (timestamp == null) return '';
    // Simple time format for messages
    return DateFormat.jm().format(timestamp); // e.g., 5:08 PM
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.grey.shade300,
              backgroundImage:
                  _otherUserImageUrl.isNotEmpty
                      ? NetworkImage(_otherUserImageUrl)
                      : null,
              child:
                  _otherUserImageUrl.isEmpty
                      ? const Icon(Icons.person, size: 18)
                      : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _isOtherUserLoading ? "Loading..." : _otherUserDisplayName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // Voice call button
          IconButton(
            icon: const Icon(Icons.call_outlined),
            tooltip: "Voice Call",
            onPressed:
                _isCallInProgress
                    ? null
                    : () => _initiateCall(isVideoCall: false),
          ),
          // Video call button
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: "Video Call",
            onPressed:
                _isCallInProgress
                    ? null
                    : () => _initiateCall(isVideoCall: true),
          ),
        ],
      ),
      body: Column(
        children: [
          // --- Messages list ---
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream:
                  _firestore
                      .collection('chats')
                      .doc(widget.chatId)
                      .collection('messages')
                      .orderBy(
                        'timestamp',
                        descending: true,
                      ) // Order by time, newest last
                      .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final messages = snapshot.data?.docs ?? [];

                if (messages.isEmpty) {
                  return const Center(child: Text('ابدأ المحادثة!'));
                }

                // Mark messages as seen when the list rebuilds with new messages
                // Note: This might still miss some edge cases if user scrolls fast
                // A more robust solution involves tracking visible messages.
                // WidgetsBinding.instance.addPostFrameCallback((_) {
                //   if (currentUser != null) {
                //     markMessagesAsSeen(chatId: widget.chatId, userId: currentUser!.uid);
                //   }
                // });

                return ListView.builder(
                  reverse: true, // Show newest messages at the bottom
                  padding: const EdgeInsets.symmetric(
                    vertical: 10.0,
                    horizontal: 8.0,
                  ),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final messageData =
                        messages[index].data() as Map<String, dynamic>? ?? {};
                    final bool isMe =
                        messageData['senderId'] == currentUser?.uid;
                    final timestamp = messageData['timestamp'] as Timestamp?;
                    final bool seen =
                        (messageData['seenBy'] as List<dynamic>? ?? [])
                            .contains(widget.otherUserId); // Example check

                    return _buildMessageBubble(
                      text: messageData['text'] ?? '',
                      isMe: isMe,
                      timestamp: timestamp?.toDate(),
                      seen: seen, // Pass seen status
                    );
                  },
                );
              },
            ),
          ),

          // --- Message input area ---
          SafeArea(
            // Ensure input isn't hidden by notches/system UI
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 8.0,
              ),
              decoration: BoxDecoration(
                color:
                    Theme.of(
                      context,
                    ).cardColor, // Use card color for background
                boxShadow: [
                  BoxShadow(
                    offset: const Offset(0, -1),
                    blurRadius: 2.0,
                    color: Colors.black.withOpacity(0.05),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment:
                    CrossAxisAlignment.end, // Align items to bottom
                children: [
                  // TODO: Add attachment button (optional)
                  // IconButton(icon: Icon(Icons.attach_file), onPressed: () {}),

                  // Message text field
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'اكتب رسالة...',
                        filled: true,
                        fillColor:
                            Colors.grey.shade100, // Background for text field
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            25.0,
                          ), // Rounded corners
                          borderSide: BorderSide.none, // No border line
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 10.0,
                        ), // Adjust padding
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      minLines: 1,
                      maxLines: 5, // Allow multiple lines
                      // onChanged: (value) => setState((){}), // To enable/disable send button
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  // Send button
                  // Use ValueListenableBuilder or similar if disabling based on text field content
                  Material(
                    // Wrap IconButton in Material for splash effect on background
                    color: Theme.of(context).primaryColor,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap:
                          _isSending
                              ? null
                              : _sendMessage, // Disable while sending
                      child: Padding(
                        padding: const EdgeInsets.all(10.0),
                        child:
                            _isSending
                                ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                                : const Icon(
                                  Icons.send,
                                  color: Colors.white,
                                  size: 24,
                                ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a styled message bubble.
  Widget _buildMessageBubble({
    required String text,
    required bool isMe,
    DateTime? timestamp,
    required bool seen, // Receive seen status
  }) {
    final alignment = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isMe ? Theme.of(context).primaryColor : Colors.grey.shade200;
    final textColor = isMe ? Colors.white : Colors.black87;
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMe ? 16 : 0),
      bottomRight: Radius.circular(isMe ? 0 : 16),
    );
    final time = _formatMessageTimestamp(timestamp);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Row(
            // Use Row to align bubble and potentially avatar (if added back)
            mainAxisAlignment:
                isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Container(
                constraints: BoxConstraints(
                  maxWidth:
                      MediaQuery.of(context).size.width *
                      0.75, // Max width constraint
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14.0,
                  vertical: 10.0,
                ),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: borderRadius,
                  boxShadow: [
                    // Add subtle shadow
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 3,
                      offset: const Offset(1, 1),
                    ),
                  ],
                ),
                child: Text(
                  text,
                  style: TextStyle(color: textColor, fontSize: 15),
                ),
              ),
            ],
          ),
          // Timestamp and Seen Status (aligned below bubble)
          Padding(
            padding: EdgeInsets.only(
              top: 3.0,
              left: isMe ? 0 : 8,
              right: isMe ? 8 : 0,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min, // Take only needed space
              mainAxisAlignment:
                  isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                Text(
                  time,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
                // Show seen status only for messages sent by 'me'
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    seen
                        ? Icons.done_all
                        : Icons.done, // Use double check for seen
                    size: 14,
                    color:
                        seen
                            ? Colors.blue.shade400
                            : Colors.grey.shade500, // Blue when seen
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
} // End of _ChatDetailPageState class

// --- Add required dependencies to pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   intl: ^...             # For date formatting
//   google_mobile_ads: ^... # Keep if needed for other parts of app
//   url_launcher: ^...     # For phone calls
//   # Add imports for pages used in navigation (CallPage, etc.)
//   # Ensure chat_helpers.dart exists and defines createOrGetChatRoom, sendMessage

// --- Firestore Setup ---
// * Ensure 'chats/{chatId}/messages' subcollection has 'senderId', 'text', 'timestamp', 'seenBy' (Array<String> or bool 'seen').
// * Ensure 'chats' collection has 'participants', 'lastMessage', 'lastMessageTime', 'lastMessageSenderId'.
// * Ensure 'users' collection has 'displayName', 'name', 'imageUrl', 'phone', 'fcmToken'.
// * Ensure 'userChats/{userId}_{chatId}' collection/document exists with 'unreadCount' field if using unread badges.
// * Ensure 'calls' collection exists for call initiation.

// --- TODO ---
// * Implement CallPage for handling voice/video calls.
// * Refine seen status logic: The current implementation relies on the 'seen' field from Firestore which might not be updated reliably by the current `markMessagesAsSeen`. Consider updating individual messages or using last read timestamps per user in the chat document for a more accurate 'seen' indicator.
