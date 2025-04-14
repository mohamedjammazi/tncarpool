import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
// Import an icon package if you want to use a specific Google icon

class GetStartedPage extends StatefulWidget {
  const GetStartedPage({super.key});

  @override
  State<GetStartedPage> createState() => _GetStartedPageState();
}

class _GetStartedPageState extends State<GetStartedPage> {
  // Firebase & Google Sign In Services
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  // State Variables
  bool _isLoading = false; // Tracks loading state for the button
  String? _errorMessage; // To display errors

  // --- Google Sign-In Logic ---
  Future<void> _loginWithGoogle() async {
    if (_isLoading) return; // Prevent multiple sign-in attempts
    setState(() {
      _isLoading = true; // Show loading indicator
      _errorMessage = null;
    });
    try {
      // Start the Google Sign-In flow
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        // User cancelled the sign-in flow
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      // Obtain the auth details from the request
      final googleAuth = await googleUser.authentication;
      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      // Sign in to Firebase with the credential
      // This handles both sign-in for existing users and sign-up for new users
      final userCredential = await _auth.signInWithCredential(credential);
      print('Google Sign-In successful: ${userCredential.user?.uid}');

      // --- IMPORTANT ---
      // No navigation here! AuthWrapper listens to authStateChanges
      // and will handle navigating to PhoneNumberEntryPage or HomePage.
      // --- ----------- ---
    } catch (e) {
      print('Google Sign-In Error: $e');
      if (mounted) {
        setState(() {
          // Provide a user-friendly error message
          _errorMessage =
              'Sign-In Failed. Please check your connection or Google account and try again.';
          // You could add more specific messages based on error types if needed
        });
      }
    } finally {
      // Ensure loading indicator is turned off
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Use a gradient background for better visual appeal
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.green.shade200, Colors.green.shade600],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            // Center the content vertically
            child: SingleChildScrollView(
              // Allow scrolling if needed
              padding: const EdgeInsets.symmetric(
                horizontal: 30.0,
                vertical: 20.0,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // --- App Logo/Icon ---
                  Icon(
                    Icons.directions_car_filled, // Example icon
                    size: 80,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 5,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // --- App Title ---
                  Text(
                    'شيعني', // Your App Name
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          color: Colors.black.withOpacity(0.4),
                          blurRadius: 3,
                          offset: const Offset(1, 1),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // --- Subtitle ---
                  Text(
                    'مشاركة الرحلات الذكية', // "Smart Ridesharing"
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.white.withOpacity(0.9),
                    ),
                  ),
                  const SizedBox(height: 60), // Increased spacing
                  // --- Error Message Display ---
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),

                  // --- Google Sign In Button ---
                  _isLoading
                      ? const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      )
                      : ElevatedButton.icon(
                        // Use an icon for the Google button
                        // Add google logo to assets
                        // Or use: icon: const FaIcon(FontAwesomeIcons.google, size: 20), // If using font_awesome_flutter
                        label: const Text(
                          'ابدأ رحلتك مع جوجل', // "Start your journey with Google"
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onPressed: _loginWithGoogle,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: 15,
                            horizontal: 30,
                          ),
                          backgroundColor: Colors.white, // White button
                          foregroundColor: Colors.black87, // Black text
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                          elevation: 3,
                        ),
                      ),
                  const SizedBox(height: 40),

                  // --- Terms & Privacy Placeholder ---
                  Text(
                    'By continuing, you agree to our Terms of Service and Privacy Policy.', // TODO: Add actual links
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
