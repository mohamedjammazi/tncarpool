import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'home_page.dart';

class PhoneNumberEntryPage extends StatefulWidget {
  const PhoneNumberEntryPage({Key? key}) : super(key: key);

  @override
  _PhoneNumberEntryPageState createState() => _PhoneNumberEntryPageState();
}

class _PhoneNumberEntryPageState extends State<PhoneNumberEntryPage> {
  final _formKey = GlobalKey<FormState>();
  String _phoneNumber = '';
  bool _isLoading = false;
  String? _errorMessage;

  // Check if the phone number is already in use (optional).
  Future<bool> _isPhoneInUse(String phone) async {
    QuerySnapshot query =
        await FirebaseFirestore.instance
            .collection('users') // UPDATED
            .where('phone', isEqualTo: phone) // UPDATED
            .get();
    return query.docs.isNotEmpty;
  }

  Future<void> _savePhoneNumber() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      try {
        User? currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser != null) {
          bool inUse = await _isPhoneInUse(_phoneNumber);
          if (inUse) {
            setState(() {
              _errorMessage = 'رقم الهاتف مستخدم بالفعل';
              _isLoading = false;
            });
            return;
          }
          // Update the user doc with 'phone' instead of 'phoneNumber'
          await FirebaseFirestore.instance
              .collection('users') // UPDATED
              .doc(currentUser.uid)
              .update({'phone': _phoneNumber}); // UPDATED

          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => HomePage(user: currentUser),
            ),
          );
        }
      } catch (e) {
        setState(() {
          _errorMessage = 'Error saving phone number: $e';
        });
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تأكيد رقم الهاتف')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'يرجى إدخال رقم الهاتف الخاص بك لإكمال التسجيل.',
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              const Text(
                'لا يمكنك استخدام التطبيق بدون إضافة رقم هاتف',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              IntlPhoneField(
                decoration: InputDecoration(
                  labelText: 'رقم الهاتف',
                  hintText: 'أدخل رقم الهاتف',
                  border: OutlineInputBorder(
                    borderSide: const BorderSide(),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                initialCountryCode: 'TN', // Default to Tunisia (+216)
                onChanged: (phone) {
                  _phoneNumber = phone.completeNumber;
                },
                validator: (phone) {
                  if (phone == null || phone.number.isEmpty) {
                    return 'يرجى إدخال رقم الهاتف';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                ),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                    onPressed: _savePhoneNumber,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      backgroundColor: Colors.green.shade600,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'تأكيد',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              const SizedBox(height: 15),
              TextButton(
                onPressed: () async {
                  // Sign out if user wants to cancel
                  await GoogleSignIn().signOut();
                  await FirebaseAuth.instance.signOut();
                },
                child: const Text('العودة وتسجيل الخروج'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
