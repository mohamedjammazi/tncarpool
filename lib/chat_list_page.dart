import 'dart:async'; // For Debouncer Timer
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart'; // For date/time formatting

// Import project pages & widgets
import 'chat_helpers.dart'; // Assuming this defines createOrGetChatRoom
import 'chat_detail_page.dart';
import 'home_page.dart';
import 'my_ride_page.dart';
import 'my_cars.dart';
import 'get_started_page.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  final User? currentUser = FirebaseAuth.instance.currentUser;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce; // Timer for search debouncing

  // State for search query
  String _searchQuery = '';

  // State for Bottom Navigation
  int _currentIndex = 3; // Default index for 'Messages' tab

  @override
  void initState() {
    super.initState();
    // Update search query state when text changes (with debounce)
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _debounce?.cancel(); // Cancel timer on dispose
    super.dispose();
  }

  /// Debounced search handler
  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text.trim();
        });
      }
    });
  }

  /// Builds the list of existing chats for the current user.
  Widget _buildChatList() {
    if (currentUser == null) return const Center(child: Text("Please log in."));

    return StreamBuilder<QuerySnapshot>(
      stream:
          _firestore
              .collection('chats')
              .where('participants', arrayContains: currentUser!.uid)
              // ** IMPORTANT: Requires a composite Firestore index on 'participants' array and 'lastMessageTime' **
              // Create this index in your Firebase console for sorting to work efficiently.
              .orderBy('lastMessageTime', descending: true)
              .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text("Error loading chats: ${snapshot.error}"));
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 80,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "لا توجد محادثات حتى الآن.",
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.grey.shade700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    "ابحث عن مستخدم لبدء محادثة جديدة.",
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        final chatDocs = snapshot.data!.docs;

        return ListView.separated(
          itemCount: chatDocs.length,
          separatorBuilder:
              (context, index) => Divider(
                height: 1,
                indent: 70,
                endIndent: 16,
                color: Colors.grey.shade200,
              ), // Add dividers
          itemBuilder: (context, index) {
            final chatDoc = chatDocs[index];
            return _buildChatListItem(chatDoc); // Use helper widget
          },
        );
      },
    );
  }

  /// Builds a single list item representing a chat conversation.
  Widget _buildChatListItem(DocumentSnapshot chatDoc) {
    final chatData = chatDoc.data() as Map<String, dynamic>? ?? {};
    final participants = chatData['participants'] as List<dynamic>? ?? [];
    if (participants.length < 2 || currentUser == null) {
      return const SizedBox.shrink(); // Invalid chat data
    }

    // Determine the other participant's ID
    final otherUserId =
        (participants.first.toString() == currentUser!.uid)
            ? participants.last.toString()
            : participants.first.toString();

    // Fetch other user's details and unread count using FutureBuilder
    // Note: This still causes N+1 reads. Denormalizing other user's name/pic
    // and unread count into the 'chats' or a 'userChats' doc is recommended for performance.
    return FutureBuilder<DocumentSnapshot>(
      future: _firestore.collection('users').doc(otherUserId).get(),
      builder: (context, userSnap) {
        if (userSnap.connectionState == ConnectionState.waiting &&
            !userSnap.hasData) {
          // Show basic ListTile structure while loading user data
          return ListTile(
            leading: const CircleAvatar(
              radius: 24,
              backgroundColor: Colors.grey,
            ),
            title: Container(
              height: 16,
              width: 100,
              color: Colors.grey.shade300,
            ), // Shimmer placeholder
            subtitle: Container(
              height: 12,
              width: 150,
              color: Colors.grey.shade200,
            ),
            trailing: Container(
              height: 10,
              width: 40,
              color: Colors.grey.shade200,
            ),
          );
        }
        if (!userSnap.hasData || !userSnap.data!.exists) {
          return ListTile(
            leading: const CircleAvatar(
              radius: 24,
              child: Icon(Icons.person_off_outlined),
            ),
            title: const Text('مستخدم غير معروف'),
            subtitle: Text(
              chatData['lastMessage'] ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        }

        final otherUserData =
            userSnap.data!.data() as Map<String, dynamic>? ?? {};
        final name =
            otherUserData['name'] as String? ??
            otherUserData['displayName'] as String? ??
            'مستخدم';
        final imageUrl = otherUserData['imageUrl'] as String? ?? '';
        final lastMessage = chatData['lastMessage'] as String? ?? '';
        final Timestamp? lastTs = chatData['lastMessageTime'] as Timestamp?;
        final String timeString =
            lastTs != null ? _formatTimestamp(lastTs) : '';

        // Fetch unread count (assuming userChats collection exists)
        // Structure: userChats/{currentUserId}_{chatId} -> { unreadCount: number }
        final userChatDocId = "${currentUser!.uid}_${chatDoc.id}";

        return StreamBuilder<DocumentSnapshot>(
          // Use StreamBuilder for live unread count
          stream:
              _firestore.collection('userChats').doc(userChatDocId).snapshots(),
          builder: (context, unreadSnap) {
            int unreadCount = 0;
            if (unreadSnap.hasData && unreadSnap.data!.exists) {
              unreadCount =
                  (unreadSnap.data!.data()
                          as Map<String, dynamic>?)?['unreadCount']
                      as int? ??
                  0;
            }

            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              leading: CircleAvatar(
                radius: 28, // Slightly larger avatar
                backgroundColor: Colors.grey.shade300,
                backgroundImage:
                    imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
                child:
                    imageUrl.isEmpty
                        ? const Icon(Icons.person, size: 28)
                        : null,
              ),
              title: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                lastMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey.shade600),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    timeString,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  // Unread count badge
                  if (unreadCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        unreadCount > 9 ? '9+' : unreadCount.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  else
                    const SizedBox(
                      height: 18,
                    ), // Placeholder to maintain alignment
                ],
              ),
              onTap: () async {
                // Clear unread count when opening chat (optional)
                try {
                  await _firestore
                      .collection('userChats')
                      .doc(userChatDocId)
                      .set({'unreadCount': 0}, SetOptions(merge: true));
                } catch (e) {
                  print("Error clearing unread count: $e");
                }

                if (mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder:
                          (ctx) => ChatDetailPage(
                            chatId: chatDoc.id,
                            otherUserId: otherUserId,
                          ),
                    ),
                  );
                }
              },
            );
          },
        );
      },
    );
  }

  /// Formats a Timestamp into a user-friendly string (e.g., "10:30 AM", "Yesterday", "Apr 10").
  String _formatTimestamp(Timestamp ts) {
    final DateTime now = DateTime.now();
    final DateTime messageTime = ts.toDate();
    final Duration difference = now.difference(messageTime);

    if (difference.inDays == 0 && now.day == messageTime.day) {
      // Today: Show time
      return DateFormat.jm().format(messageTime); // e.g., 5:08 PM
    } else if (difference.inDays == 1 ||
        (difference.inDays == 0 && now.day != messageTime.day)) {
      // Yesterday
      return "Yesterday";
    } else if (difference.inDays < 7) {
      // Within the last week: Show weekday name
      return DateFormat.EEEE().format(messageTime); // e.g., Tuesday
    } else {
      // Older than a week: Show date
      return DateFormat.yMd().format(messageTime); // e.g., 4/10/2025
    }
  }

  /// Displays search results for users.
  /// **WARNING:** Fetches ALL users and filters client-side. Inefficient for large user bases.
  /// Consider implementing server-side search (e.g., Algolia) or more targeted queries.
  Widget _buildSearchResults(String query) {
    if (query.isEmpty)
      return const SizedBox.shrink(); // Don't search if query is empty

    return FutureBuilder<List<DocumentSnapshot>>(
      future: _searchUsers(query), // Call the search function
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text("Error searching: ${snapshot.error}"));
        }
        final results = snapshot.data ?? [];
        if (results.isEmpty) {
          return const Center(child: Text('لا يوجد نتائج مطابقة.'));
        }

        // Display results
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final userDoc = results[index];
            final userData = userDoc.data() as Map<String, dynamic>? ?? {};
            final userId = userDoc.id;

            // Avoid showing current user in search results
            if (userId == currentUser?.uid) {
              return const SizedBox.shrink();
            }

            final name = userData['name'] as String? ?? 'مستخدم';
            final phone = userData['phone'] as String? ?? '';
            final imageUrl = userData['imageUrl'] as String? ?? '';

            return ListTile(
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: Colors.grey.shade200,
                backgroundImage:
                    imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
                child:
                    imageUrl.isEmpty
                        ? const Icon(Icons.person, size: 28)
                        : null,
              ),
              title: Text(name),
              subtitle: Text(phone),
              onTap: () async {
                if (currentUser == null) return;
                // Create or get chat room and navigate
                final chatId = await createOrGetChatRoom(
                  currentUser!.uid,
                  userId,
                );
                if (!mounted) return;
                // Clear search and navigate
                _searchController.clear();
                FocusScope.of(context).unfocus(); // Hide keyboard
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (ctx) =>
                            ChatDetailPage(chatId: chatId, otherUserId: userId),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// Client-side user search (limited for performance).
  Future<List<DocumentSnapshot>> _searchUsers(String query) async {
    if (query.isEmpty) return [];
    final firestore = FirebaseFirestore.instance;

    // **PERFORMANCE WARNING:** Fetching all users is not scalable.
    // Limiting to 100 results for demonstration. Implement server-side search for production.
    print("Searching users (client-side, limited)... Query: $query");
    try {
      final allUsersSnapshot =
          await firestore.collection('users').limit(100).get();
      final lowerQuery = query.toLowerCase();

      // Filter on client
      final filteredDocs =
          allUsersSnapshot.docs.where((doc) {
            final data = doc.data();
            final name =
                (data['name'] ?? data['displayName'] ?? '')
                    as String; // Check both name and displayName
            final phone = (data['phone'] ?? '') as String;
            // Match start of name/phone OR contains query (adjust as needed)
            return name.toLowerCase().contains(lowerQuery) ||
                phone.contains(query); // Phone match might not need lowercasing
          }).toList();

      return filteredDocs;
    } catch (e) {
      print("Error searching users: $e");
      return []; // Return empty list on error
    }
  }

  @override
  Widget build(BuildContext context) {
    if (currentUser == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('الرسائل'),
          backgroundColor: Colors.green.shade700,
        ),
        body: const Center(child: Text("User not logged in.")),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('الرسائل'),
        // backgroundColor: Colors.green.shade700, // Keep theme color
      ),
      bottomNavigationBar: _buildBottomNavigationBar(), // Added Nav Bar
      body: Column(
        children: [
          // --- Improved Search Bar ---
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: "ابحث عن مستخدم...",
                prefixIcon: const Icon(Icons.search),
                // Add clear button
                suffixIcon:
                    _searchQuery.isNotEmpty
                        ? IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: "Clear Search",
                          onPressed: () {
                            _searchController.clear();
                            // Listener will update state via _onSearchChanged
                          },
                        )
                        : null,
                filled: true,
                fillColor: Colors.grey.shade100, // Subtle background
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 0,
                  horizontal: 16,
                ), // Adjust padding
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30.0), // Rounded border
                  borderSide: BorderSide.none, // No visible border initially
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30.0),
                  borderSide: BorderSide(
                    color: Colors.grey.shade300,
                    width: 0.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30.0),
                  borderSide: BorderSide(
                    color: Theme.of(context).primaryColor,
                    width: 1.5,
                  ),
                ),
              ),
              // onChanged handled by listener + debouncer
              // onSubmitted not strictly needed if using debouncer
              // onSubmitted: (value) => setState(() => _searchQuery = value.trim()),
            ),
          ),
          // --- List / Search Results ---
          Expanded(
            child:
                _searchQuery.isEmpty
                    ? _buildChatList() // Show list of existing chats
                    : _buildSearchResults(_searchQuery), // Show search results
          ),
        ],
      ),
    );
  }

  // --- Bottom Navigation Methods ---
  Widget _buildBottomNavigationBar() {
    // Copied from other pages, ensure icons/labels match
    return BottomNavigationBar(
      currentIndex: _currentIndex,
      onTap: _onBottomNavTapped,
      selectedItemColor: Colors.green.shade800,
      unselectedItemColor: Colors.grey.shade600,
      selectedLabelStyle: const TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 11,
      ),
      unselectedLabelStyle: const TextStyle(fontSize: 10),
      type: BottomNavigationBarType.fixed,
      backgroundColor: Colors.white,
      elevation: 8.0,
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.home_outlined),
          activeIcon: Icon(Icons.home),
          label: 'الرئيسية',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.directions_car_outlined),
          activeIcon: Icon(Icons.directions_car),
          label: 'رحلاتي',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.car_rental_outlined),
          activeIcon: Icon(Icons.car_rental),
          label: 'سياراتي',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.message_outlined),
          activeIcon: Icon(Icons.message),
          label: 'الرسائل',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.person_outline),
          activeIcon: Icon(Icons.person),
          label: 'حسابي',
        ),
      ],
    );
  }

  void _onBottomNavTapped(int index) {
    if (!mounted || index == _currentIndex) return;
    _navigateToIndex(index);
  }

  void _navigateToIndex(int index) {
    Widget? targetPage;
    bool removeUntil = false;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const GetStartedPage()),
        (route) => false,
      );
      return;
    }
    // Prevent navigating to self
    if (index == _currentIndex) return;

    switch (index) {
      case 0:
        targetPage = HomePage(user: currentUser);
        removeUntil = true;
        break;
      case 1:
        targetPage = MyRidePage(user: currentUser);
        removeUntil = true;
        break;
      case 2:
        targetPage = const MyCarsPage();
        removeUntil = true;
        break;
      case 3:
        return; // Already on ChatListPage
      case 4:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account page not implemented yet.')),
        );
        return;
    }
    if (targetPage != null) {
      if (removeUntil) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => targetPage!),
          (route) => false,
        );
      } else {
        Navigator.push(context, MaterialPageRoute(builder: (_) => targetPage!));
      }
    } else {
      print("Error: Target page was null for index $index");
    }
  }
} // End of _ChatListPageState class

/// Simple Search Delegate (can be removed if search handled directly in page)
// class RideSearchDelegate extends SearchDelegate<String?> { /* ... */ } // Removed as search is inline now

// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   intl: ^...             # For date formatting
//   # Add imports for pages used in navigation (HomePage, MyRidePage, MyCarsPage, ChatDetailPage etc.)
//   # Ensure chat_helpers.dart exists and defines createOrGetChatRoom

// --- Firestore Setup ---
// * Ensure 'chats' collection has 'participants' (Array<String>), 'lastMessage' (String), 'lastMessageTime' (Timestamp).
// * Ensure 'users' collection has 'name', 'displayName', 'phone', 'imageUrl', 'fcmToken'.
// * **IMPORTANT:** Create a composite index in Firestore for the chat list query:
//   Collection: 'chats', Fields: 'participants' (Array Contains), 'lastMessageTime' (Descending).
// * Consider a 'userChats' collection (e.g., docs named '{userId}_{chatId}') to store unread counts efficiently,
//   as updated by the provided Cloud Function. This code assumes such a collection exists for unread counts.
