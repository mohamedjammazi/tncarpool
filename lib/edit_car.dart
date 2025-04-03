import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class EditCarPage extends StatefulWidget {
  final String carId;
  final Map<String, dynamic> initialData;

  const EditCarPage({
    super.key,
    required this.carId,
    required this.initialData,
  });

  @override
  _EditCarPageState createState() => _EditCarPageState();
}

class _EditCarPageState extends State<EditCarPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _modelController;
  late TextEditingController _licensePlateController;
  late TextEditingController _seatsController;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(
      text: widget.initialData['model'] ?? '',
    );
    _licensePlateController = TextEditingController(
      text: widget.initialData['licensePlate'] ?? '',
    );
    _seatsController = TextEditingController(
      text: widget.initialData['availableSeats']?.toString() ?? '',
    );
  }

  /// Check if the updated license plate is unique, ignoring the current document.
  Future<bool> _isLicensePlateUnique(String plate) async {
    DocumentSnapshot plateDoc =
        await FirebaseFirestore.instance
            .collection('RegisteredPlates')
            .doc(plate)
            .get();

    print("Checking plate: $plate - Exists: ${plateDoc.exists}");

    return !plateDoc.exists || plate == widget.initialData['licensePlate'];
  }

  Future<void> _updateCar() async {
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

      String newPlate = _licensePlateController.text.trim();
      String oldPlate = widget.initialData['licensePlate'];

      bool unique = await _isLicensePlateUnique(newPlate);
      if (!unique) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("رقم اللوحة مستخدم بالفعل.")),
        );
        setState(() {
          _isLoading = false;
        });
        return;
      }

      WriteBatch batch = FirebaseFirestore.instance.batch();
      DocumentReference plateRef = FirebaseFirestore.instance
          .collection('RegisteredPlates')
          .doc(newPlate);
      DocumentReference oldPlateRef = FirebaseFirestore.instance
          .collection('RegisteredPlates')
          .doc(oldPlate);
      DocumentReference carRef = FirebaseFirestore.instance
          .collection('Users')
          .doc(currentUser.uid)
          .collection('Cars')
          .doc(widget.carId);

      try {
        // If the plate has changed, update the global collection
        if (newPlate != oldPlate) {
          batch.delete(oldPlateRef); // Remove old plate
          batch.set(plateRef, {'ownerId': currentUser.uid}); // Add new plate
        }

        // Update the car data
        batch.update(carRef, {
          'model': _modelController.text.trim(),
          'licensePlate': newPlate,
          'availableSeats': int.tryParse(_seatsController.text) ?? 0,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await batch.commit();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("تم تحديث بيانات السيارة بنجاح!")),
        );
        Navigator.of(context).pop();
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("حدث خطأ أثناء التحديث: $e")));
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
    _licensePlateController.dispose();
    _seatsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("تعديل بيانات السيارة")),
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
              const SizedBox(height: 16),
              TextFormField(
                controller: _licensePlateController,
                decoration: const InputDecoration(
                  labelText: "رقم اللوحة",
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return "يرجى إدخال رقم اللوحة";
                  }
                  return null;
                },
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
                    onPressed: _updateCar,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      backgroundColor: Colors.green.shade600,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: const Text(
                      "تحديث السيارة",
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
