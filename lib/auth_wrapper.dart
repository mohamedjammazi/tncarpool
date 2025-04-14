import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // For FCM initialization

// Ensure these imports point to the correct files in your project
import 'get_started_page.dart';
import 'phone_number_page.dart'; // Make sure this page exists
import 'home_page.dart'; // Make sure HomePage exists and takes a User object

/// AuthWrapper handles the authentication state and navigates the user
/// to the appropriate screen (Login, Phone Entry, or Home).
/// It uses a FutureBuilder after login to get a stable user document read
/// before deciding the initial navigation path.
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  // Tracks the last user for whom FCM was initialized
  User? _currentUserInitializedFCM;

  @override
  Widget build(BuildContext context) {
    // Listen to Firebase Authentication state changes
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        // 1) Show loading indicator while waiting for auth state
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          print("AuthWrapper: Waiting for auth state...");
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // 2) Auth state received
        if (authSnapshot.connectionState == ConnectionState.active) {
          final user = authSnapshot.data;

          if (user == null) {
            // --- User is NOT logged in ---
            print("AuthWrapper: User is null. Navigating to GetStartedPage.");
            _currentUserInitializedFCM = null; // Reset FCM tracker on logout
            return const GetStartedPage();
          } else {
            // --- User IS logged in ---
            print("AuthWrapper: User ${user.uid} is logged in.");

            // Ensure user document exists and has necessary default fields.
            // Run this asynchronously, FutureBuilder will handle waiting if needed.
            _createOrUpdateUserDoc(user);

            // Initialize FCM only once per user session
            if (_currentUserInitializedFCM == null ||
                _currentUserInitializedFCM!.uid != user.uid) {
              print("AuthWrapper: Initializing FCM for user: ${user.uid}");
              _initFCM(user.uid);
              _currentUserInitializedFCM = user;
            }

            // *** USE FutureBuilder for INITIAL check after login ***
            // Perform a one-time 'get' which is less prone to intermediate states
            // than the first emission of a 'snapshots()' stream right after login.
            return FutureBuilder<DocumentSnapshot>(
              future:
                  FirebaseFirestore.instance
                      .collection('users')
                      .doc(user.uid)
                      .get(),
              builder: (context, userSnapshot) {
                // Show loader while the future is resolving
                if (userSnapshot.connectionState == ConnectionState.waiting) {
                  print(
                    "AuthWrapper: FutureBuilder waiting for user document get() for ${user.uid}...",
                  );
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                // Handle errors during the 'get' operation
                if (userSnapshot.hasError) {
                  print(
                    "AuthWrapper: FutureBuilder Error fetching user document for ${user.uid}: ${userSnapshot.error}",
                  );
                  return Scaffold(
                    body: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          'Error loading user data: ${userSnapshot.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  );
                }

                // Handle case where document doesn't exist (shouldn't happen if _createOrUpdateUserDoc works)
                if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
                  print(
                    "AuthWrapper: FutureBuilder User document doesn't exist for ${user.uid} after get(). This is unexpected.",
                  );
                  // Maybe show error or retry, but loader is safer for now
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                // --- Document exists, proceed with phone check ---
                final userData =
                    userSnapshot.data!.data() as Map<String, dynamic>? ?? {};
                final phone = userData['phone'] as String?;

                print(
                  "AuthWrapper FutureBuilder DEBUG: Checking phone for ${user.uid}. Read from Firestore get(): '$phone'",
                );

                if (phone == null || phone.isEmpty) {
                  print(
                    "AuthWrapper FutureBuilder: Navigating to PhoneNumberEntryPage for ${user.uid}.",
                  );
                  return const PhoneNumberEntryPage();
                } else {
                  print(
                    "AuthWrapper FutureBuilder: Phone ('$phone') found. Navigating to HomePage for ${user.uid}.",
                  );
                  return HomePage(user: user);
                }
              },
            );
            // --- End of FutureBuilder ---
          }
        }

        // Fallback loading indicator
        print(
          "AuthWrapper: Auth state connection not active or waiting, showing fallback loader.",
        );
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    );
  }

  /// Creates/updates the user document in Firestore. (Keep the corrected version)
  Future<void> _createOrUpdateUserDoc(User user) async {
    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);
    try {
      final doc = await userRef.get();
      if (!doc.exists) {
        print('AuthWrapper: Creating new user document for UID: ${user.uid}');
        await userRef.set({
          'name': user.displayName ?? '',
          'email': user.email ?? '',
          'imageUrl': user.photoURL ?? '',
          'phone': '',
          'role': 'user',
          'averageRating': 0.0,
          'reviewCount': 0,
          'isAvailable': true,
          'blockedUsers': [],
          'gold': 5,
          'rewardedAdTimestamps': [],
          'createdAt': FieldValue.serverTimestamp(),
          'lastLogin': FieldValue.serverTimestamp(),
        });
      } else {
        print(
          'AuthWrapper: User document exists for UID: ${user.uid}. Updating lastLogin & checking missing defaults...',
        );
        final data = doc.data() as Map<String, dynamic>? ?? {};
        Map<String, dynamic> updates = {
          'lastLogin': FieldValue.serverTimestamp(),
        };
        if (!data.containsKey('role')) updates['role'] = 'user';
        if (!data.containsKey('averageRating')) updates['averageRating'] = 0.0;
        if (!data.containsKey('reviewCount')) updates['reviewCount'] = 0;
        if (!data.containsKey('isAvailable')) updates['isAvailable'] = true;
        if (!data.containsKey('blockedUsers')) updates['blockedUsers'] = [];
        if (!data.containsKey('gold')) updates['gold'] = 5;
        if (!data.containsKey('rewardedAdTimestamps'))
          updates['rewardedAdTimestamps'] = [];
        if (!data.containsKey('createdAt'))
          updates['createdAt'] = FieldValue.serverTimestamp();

        if (updates.length > 1) {
          print(
            'AuthWrapper: Adding missing default fields for UID: ${user.uid}. Updates: ${updates.keys}',
          );
          await userRef.update(updates);
        } else {
          print(
            'AuthWrapper: No missing default fields found for UID: ${user.uid}. Updating lastLogin only.',
          );
          await userRef.update({'lastLogin': updates['lastLogin']!});
        }
      }
    } catch (e) {
      print(
        "AuthWrapper: Error in _createOrUpdateUserDoc for UID ${user.uid}: $e",
      );
    }
  }

  /// Initializes FCM. (Function remains the same)
  Future<void> _initFCM(String uid) async {
    try {
      FirebaseMessaging messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      String? token = await messaging.getToken();
      print("AuthWrapper: FCM token for $uid: $token");
      if (token != null && token.isNotEmpty) {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'fcmToken': token,
          'fcmTokenTimestamp': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        print("AuthWrapper: FCM token refreshed for $uid: $newToken");
        if (newToken.isNotEmpty) {
          await FirebaseFirestore.instance.collection('users').doc(uid).set({
            'fcmToken': newToken,
            'fcmTokenTimestamp': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      });
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print('AuthWrapper: FCM: Foreground message received!');
        if (message.data.isNotEmpty)
          print('Foreground Message data payload: ${message.data}');
      });
    } catch (e) {
      print("AuthWrapper: Error initializing FCM for UID $uid: $e");
    }
  }
}
