// auth_wrapper.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'get_started_page.dart';
import 'phone_number_page.dart';
import 'home_page.dart';

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // While waiting for auth state, show a loading indicator
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // When auth state is active
        if (snapshot.connectionState == ConnectionState.active) {
          final user = snapshot.data;

          // If no user is logged in, show the GetStartedPage
          if (user == null) {
            return const GetStartedPage();
          } else {
            // Create or update the user document in Firestore
            _createOrUpdateUserDoc(user);

            // Always check the phone field from Firestore
            return StreamBuilder<DocumentSnapshot>(
              stream:
                  FirebaseFirestore.instance
                      .collection('users') // Updated
                      .doc(user.uid)
                      .snapshots(),
              builder: (context, userSnapshot) {
                // Show loading while waiting for user data
                if (userSnapshot.connectionState == ConnectionState.waiting) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                if (userSnapshot.hasError) {
                  return Scaffold(
                    body: Center(child: Text('Error: ${userSnapshot.error}')),
                  );
                }

                // If user document not yet created, show a loading indicator
                if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                final userData =
                    userSnapshot.data!.data() as Map<String, dynamic>;
                final phone = userData['phone'] as String?;

                // If phone is empty/null, always show PhoneNumberEntryPage
                if (phone == null || phone.isEmpty) {
                  return const PhoneNumberEntryPage();
                }

                // Otherwise, show HomePage
                return HomePage(user: user);
              },
            );
          }
        }

        // Default fallback
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    );
  }
}

/// Create or update the user document in Firestore.
Future<void> _createOrUpdateUserDoc(User user) async {
  final userRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
  final doc = await userRef.get();

  if (!doc.exists) {
    // Create a new document with your new DB fields
    await userRef.set({
      'name': user.displayName ?? '',
      'email': user.email ?? '',
      'phone': '', // Initially empty
      'imageUrl': user.photoURL ?? '',
      'role': '', // e.g. "driver" or "rider"
      'rating': 0,
      'isAvailable': true,
      'blockedUsers': [],
      'createdAt': FieldValue.serverTimestamp(),
    });
  } else {
    // Update the imageUrl if needed
    final data = doc.data() as Map<String, dynamic>;
    final currentPhotoUrl = data['imageUrl'] as String? ?? '';
    final userPhotoUrl = user.photoURL ?? '';

    if (userPhotoUrl.isNotEmpty && userPhotoUrl != currentPhotoUrl) {
      await userRef.update({'imageUrl': userPhotoUrl});
    }
  }
}
