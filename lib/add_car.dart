import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

class AddCarPage extends StatefulWidget {
  const AddCarPage({super.key});

  @override
  _AddCarPageState createState() => _AddCarPageState();
}

class _AddCarPageState extends State<AddCarPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _firstDigitsController = TextEditingController();
  final TextEditingController _secondDigitsController = TextEditingController();
  final TextEditingController _seatsController = TextEditingController();
  bool _isLoading = false;

  // Check if the given license plate is unique.
  Future<bool> _isLicensePlateUnique(String plate) async {
    DocumentSnapshot plateDoc =
        await FirebaseFirestore.instance
            .collection('RegisteredPlates')
            .doc(plate)
            .get();
    return !plateDoc.exists; // Unique if not found.
  }

  // Combine the two parts and "تونس" text into a complete plate.
  String _getFullLicensePlate() {
    String firstPart = _firstDigitsController.text.trim();
    String secondPart = _secondDigitsController.text.trim();
    return "$firstPart تونس $secondPart";
  }

  Future<void> _addCar() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("لم يتم تسجيل الدخول.")));
        setState(() {
          _isLoading = false;
        });
        return;
      }

      String plate = _getFullLicensePlate();
      bool unique = await _isLicensePlateUnique(plate);
      if (!unique) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("رقم اللوحة مستخدم بالفعل.")),
        );
        setState(() {
          _isLoading = false;
        });
        return;
      }

      // Reference to the top-level "cars" collection.
      CollectionReference carsRef = FirebaseFirestore.instance.collection(
        'cars',
      );
      try {
        // Register the plate globally.
        await FirebaseFirestore.instance
            .collection('RegisteredPlates')
            .doc(plate)
            .set({'ownerId': currentUser.uid});

        // Add car document with updated field names.
        await carsRef.add({
          'ownerId': currentUser.uid,
          'model': _modelController.text.trim(),
          'plateNumber': plate,
          'seatCount': int.tryParse(_seatsController.text) ?? 0,
          // Optionally, you can initialize an empty seatLayout or set isVerified to false.
          'isVerified': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("تم إضافة السيارة بنجاح!")),
        );
        Navigator.of(context).pop();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("حدث خطأ أثناء إضافة السيارة: $e")),
        );
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _modelController.dispose();
    _firstDigitsController.dispose();
    _secondDigitsController.dispose();
    _seatsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("إضافة سيارة")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: "طراز السيارة",
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return "يرجى إدخال طراز السيارة";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _firstDigitsController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: "9999",
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return "يرجى إدخال الرقم الأول";
                        }
                        if (int.tryParse(value) == null) {
                          return "يرجى إدخال رقم صحيح";
                        }
                        if (value.length > 4) {
                          return "الرقم الأول يجب أن يحتوي على 4 أرقام كحد أقصى";
                        }
                        return null;
                      },
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Directionality(
                    textDirection: TextDirection.rtl,
                    child: Text(
                      "تونس",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: TextFormField(
                      controller: _secondDigitsController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: "999",
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return "يرجى إدخال الرقم الثاني";
                        }
                        if (int.tryParse(value) == null) {
                          return "يرجى إدخال رقم صحيح";
                        }
                        if (value.length > 3) {
                          return "الرقم الثاني يجب أن يحتوي على 3 أرقام كحد أقصى";
                        }
                        return null;
                      },
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _seatsController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: "عدد المقاعد المتاحة",
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return "يرجى إدخال عدد المقاعد";
                  }
                  if (int.tryParse(value) == null) {
                    return "يرجى إدخال رقم صحيح";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                    onPressed: _addCar,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      backgroundColor: Colors.green.shade600,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: const Text(
                      "أضف السيارة",
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
