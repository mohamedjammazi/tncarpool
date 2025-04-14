import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl_phone_field/intl_phone_field.dart'; // Ensure this package is in pubspec.yaml
import 'package:google_sign_in/google_sign_in.dart'; // Needed for sign out button

// Ensure these imports point to the correct files in your project
import 'home_page.dart'; // Assuming HomePage takes a User object

/// Page for users to enter and confirm their phone number after initial login.
class PhoneNumberEntryPage extends StatefulWidget {
  const PhoneNumberEntryPage({super.key});

  @override
  _PhoneNumberEntryPageState createState() => _PhoneNumberEntryPageState();
}

class _PhoneNumberEntryPageState extends State<PhoneNumberEntryPage> {
  // Global key for the form validation
  final _formKey = GlobalKey<FormState>();
  // State variables
  String _phoneNumber =
      ''; // Stores the complete phone number (country code + number)
  bool _isLoading = false; // Tracks loading state for the save button
  String? _errorMessage; // Stores error messages to display to the user

  /// Checks if the provided phone number is already associated with another user account.
  ///
  /// Args:
  ///   phone: The complete phone number string to check.
  ///
  /// Returns:
  ///   True if the phone number is found in any user document, false otherwise.
  Future<bool> _isPhoneInUse(String phone) async {
    try {
      // Query the 'users' collection for documents where 'phone' matches the input
      QuerySnapshot query =
          await FirebaseFirestore.instance
              .collection('users')
              .where('phone', isEqualTo: phone)
              .limit(1) // Limit to 1 doc, we only need to know if *any* exist
              .get();
      // Return true if any documents were found
      return query.docs.isNotEmpty;
    } catch (e) {
      print("Error checking if phone is in use: $e");
      // Treat errors during check as potentially problematic, prevent proceeding
      // Or you might want to show a specific error message
      setState(() {
        _errorMessage = "Error checking phone number. Please try again.";
      });
      return true; // Return true to prevent saving if check fails
    }
  }

  /// Validates the form, checks if the phone number is unique,
  /// saves it to the current user's Firestore document, and navigates to HomePage.
  Future<void> _savePhoneNumber() async {
    // Validate the form using the GlobalKey
    if (_formKey.currentState!.validate()) {
      // Check if the widget is still mounted before updating state
      if (mounted) {
        setState(() {
          _isLoading = true; // Show loading indicator
          _errorMessage = null; // Clear previous errors
        });
      }

      try {
        // Get the currently authenticated user
        User? currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser != null) {
          // Check if the entered phone number is already used by another account
          bool inUse = await _isPhoneInUse(_phoneNumber);
          if (inUse) {
            // If phone number is already in use, show an error and stop
            if (mounted) {
              setState(() {
                _errorMessage =
                    'رقم الهاتف مستخدم بالفعل'; // "Phone number already in use"
                _isLoading = false; // Hide loading indicator
              });
            }
            return; // Stop the saving process
          }

          // Phone number is valid and not in use, proceed to update Firestore
          print(
            "Attempting to save phone '$_phoneNumber' for user ${currentUser.uid}",
          );
          await FirebaseFirestore.instance
              .collection('users')
              .doc(currentUser.uid)
              .update({'phone': _phoneNumber}); // Update the 'phone' field

          print("Phone number saved successfully for ${currentUser.uid}");

          // Navigate to HomePage upon successful save, replacing this page
          if (mounted) {
            // Use pushReplacement to prevent user from navigating back to phone entry
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder:
                    (context) =>
                        HomePage(user: currentUser), // Pass user to HomePage
              ),
            );
          }
        } else {
          // Handle case where user is somehow null (shouldn't happen if AuthWrapper works)
          print("Error: Current user is null in PhoneNumberEntryPage.");
          if (mounted) {
            setState(() {
              _errorMessage =
                  "User session error. Please sign out and sign in again.";
            });
          }
        }
      } catch (e) {
        // Handle potential errors during Firestore update or other issues
        if (mounted) {
          // *** ADDED DETAILED LOGGING HERE ***
          print("!!! ERROR saving phone number in PhoneNumberEntryPage: $e");
          // **********************************
          setState(() {
            _errorMessage = 'Error saving phone number: ${e.toString()}';
          });
        }
      } finally {
        // Ensure loading indicator is hidden regardless of success or failure
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    } else {
      print("Phone number form validation failed.");
    }
  }

  @override
  void dispose() {
    // Dispose any controllers or listeners if they were added
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تأكيد رقم الهاتف'), // "Confirm Phone Number"
        automaticallyImplyLeading: false, // Remove back button
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey, // Associate the form key
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.stretch, // Make buttons stretch
            children: [
              const Text(
                'يرجى إدخال رقم الهاتف الخاص بك لإكمال التسجيل.', // "Please enter your phone number to complete registration."
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              const Text(
                'لا يمكنك استخدام التطبيق بدون إضافة رقم هاتف', // "You cannot use the app without adding a phone number"
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              // International Phone Number Input Field
              IntlPhoneField(
                decoration: InputDecoration(
                  labelText: 'رقم الهاتف', // "Phone Number"
                  hintText: 'أدخل رقم الهاتف', // "Enter phone number"
                  border: OutlineInputBorder(
                    borderSide: const BorderSide(),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                initialCountryCode:
                    'TN', // Default country code (e.g., Tunisia)
                onChanged: (phone) {
                  // Update the state variable with the complete number (incl. country code)
                  _phoneNumber = phone.completeNumber;
                },
                // Basic validation for the phone number field
                validator: (phone) {
                  if (phone == null || phone.number.isEmpty) {
                    return 'يرجى إدخال رقم الهاتف'; // "Please enter phone number"
                  }
                  // Add more specific validation if needed (e.g., length)
                  return null; // Return null if valid
                },
              ),
              const SizedBox(height: 20),
              // Display error message if any
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ),
              // Show loading indicator or confirm button
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                    onPressed: _savePhoneNumber, // Call save function on press
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      backgroundColor: Colors.green.shade600, // Button color
                      foregroundColor: Colors.white, // Text color
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'تأكيد', // "Confirm"
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              const SizedBox(height: 15),
              // Optional: Button to sign out if user doesn't want to proceed
              TextButton(
                onPressed: () async {
                  // Sign out from Google and Firebase
                  await GoogleSignIn().signOut();
                  await FirebaseAuth.instance.signOut();
                  // AuthWrapper will automatically navigate to GetStartedPage
                },
                child: const Text(
                  'العودة وتسجيل الخروج',
                ), // "Return and Sign Out"
              ),
            ],
          ),
        ),
      ),
    );
  }
}
