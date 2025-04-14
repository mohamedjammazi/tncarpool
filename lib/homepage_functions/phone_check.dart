// homepage_functions/phone_check.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../phone_number_page.dart';

/// Checks if the user has a phone number in Firestore.
/// If not, navigates to phone page and returns false.
/// Otherwise, returns true.
Future<bool> checkPhoneNumber(BuildContext context, User user) async {
  final doc =
      await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
  final data = doc.data();
  final phone = data?['phone'] as String?;
  if (phone == null || phone.isEmpty) {
    if (context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PhoneNumberEntryPage()),
      );
    }
    return false;
  }
  return true;
}

/// Signs out the user and navigates to the GetStartedPage.
Future<void> signOutAndNavigate(BuildContext context) async {
  await FirebaseAuth.instance.signOut();
  if (!context.mounted) return;

  // If you have Google Sign-In, also do:
  // await GoogleSignIn().signOut();

  // Then navigate to your get started page:
  Navigator.pushReplacementNamed(context, '/getStarted');
  // or use a direct MaterialPageRoute if you prefer
}
