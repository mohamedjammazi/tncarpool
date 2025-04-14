import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart'; // Added for potential date formatting if needed
import 'dart:math'; // For max function in seat count calculation

// Import project pages & widgets
import 'widgets/seat_layout_widget.dart'; // Adjust path if needed
import 'home_page.dart';
import 'my_ride_page.dart';
import 'my_cars.dart';
import 'chat_list_page.dart';
import 'get_started_page.dart';
import 'add_car.dart'; // Import AddCarPage for navigation

class EditCarPage extends StatefulWidget {
  final String carId;
  // Pass initial data for faster loading, but fetch latest in initState
  final Map<String, dynamic> initialData;

  const EditCarPage({
    super.key,
    required this.carId,
    required this.initialData,
  });

  @override
  State<EditCarPage> createState() => _EditCarPageState();
}

class _EditCarPageState extends State<EditCarPage> {
  final _formKey = GlobalKey<FormState>();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Controllers for editable fields
  late TextEditingController _modelController;
  late TextEditingController _brandController;
  late TextEditingController _firstDigitsController;
  late TextEditingController _secondDigitsController;

  // State for seat layout preview
  int? _selectedSeatCount;
  List<Map<String, dynamic>> _previewSeatLayout = [];

  // Allowed Seat Counts for Dropdown
  final List<int> _allowedSeatCounts = const [2, 4, 5, 6, 7, 8, 9];

  // Loading states
  bool _isLoading = true; // Loading initial data
  bool _isSaving = false; // Saving updates

  // Store original plate to check for changes
  String _originalPlateNumber = '';

  // Asset Paths (Ensure these match your project and pubspec.yaml)
  final String _driverSeatImagePath = 'assets/images/DRIVERSEAT.png';
  final String _passengerSeatImagePath = 'assets/images/PASSENGER SEAT.png';

  // Bottom Nav State
  int _currentIndex = 2; // Default to 'My Cars' index

  @override
  void initState() {
    super.initState();
    _initializeFields();
  }

  /// Initialize controllers with data passed to the widget.
  void _initializeFields() {
    // Use data passed via widget constructor
    _modelController = TextEditingController(
      text: widget.initialData['model'] as String? ?? '',
    );
    _brandController = TextEditingController(
      text: widget.initialData['brand'] as String? ?? '',
    );
    _selectedSeatCount = widget.initialData['seatCount'] as int?;
    _originalPlateNumber = widget.initialData['plateNumber'] as String? ?? '';

    // Parse plate number - adjust splitting logic based on your exact format
    final plateParts = _originalPlateNumber.split(' تونس ');
    _firstDigitsController = TextEditingController(
      text: plateParts.isNotEmpty ? plateParts[0] : '',
    );
    _secondDigitsController = TextEditingController(
      text: plateParts.length > 1 ? plateParts[1] : '',
    );

    // Generate initial layout preview if seat count exists
    if (_selectedSeatCount != null && _selectedSeatCount! > 0) {
      _previewSeatLayout = _generateFlatSeatLayout(_selectedSeatCount!);
    }

    // Mark initial loading as complete
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    });
  }

  @override
  void dispose() {
    // Dispose all controllers
    _modelController.dispose();
    _brandController.dispose();
    _firstDigitsController.dispose();
    _secondDigitsController.dispose();
    super.dispose();
  }

  /// Updates the seat layout preview based on the selected dropdown value.
  void _generateAndUpdateLayout(int? count) {
    // Generate layout only if count is valid, positive, and different from current
    if (count != null && count > 0 && count != _selectedSeatCount) {
      setState(() {
        _selectedSeatCount = count;
        _previewSeatLayout = _generateFlatSeatLayout(_selectedSeatCount!);
      });
    } else if (count == null && _selectedSeatCount != null) {
      // Clear preview if selection is cleared
      setState(() {
        _selectedSeatCount = null;
        _previewSeatLayout = [];
      });
    }
    // If count is invalid or same as current, do nothing
  }

  /// Generates the basic seat layout data structure.
  List<Map<String, dynamic>> _generateFlatSeatLayout(int totalSeats) {
    if (totalSeats < 1) return [];
    final List<Map<String, dynamic>> layout = [];
    layout.add({
      "seatIndex": 0,
      "type": "driver",
      "offered": false,
      "bookedBy": "n/a",
      "approvalStatus": "n/a",
    });
    for (int i = 1; i < totalSeats; i++) {
      layout.add({
        "seatIndex": i,
        "type": "share",
        "offered": false,
        "bookedBy": "n/a",
        "approvalStatus": "pending",
      });
    }
    return layout;
  }

  /// Check if the given license plate is unique (excluding the original plate).
  Future<bool> _isLicensePlateUnique(
    String newPlate,
    String originalPlate,
  ) async {
    if (newPlate == originalPlate) return true;
    if (newPlate.trim().length < 5) return false;
    try {
      DocumentSnapshot plateDoc =
          await _firestore.collection('RegisteredPlates').doc(newPlate).get();
      return !plateDoc.exists;
    } catch (e) {
      debugPrint("Error checking plate uniqueness: $e");
      return false;
    }
  }

  /// Combine the two parts and "تونس" text into a complete plate.
  String _getFullLicensePlate() {
    String firstPart = _firstDigitsController.text.trim();
    String secondPart = _secondDigitsController.text.trim();
    return "$firstPart تونس $secondPart";
  }

  /// Saves the updated car details to Firestore.
  Future<void> _updateCar() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_selectedSeatCount == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("يرجى اختيار عدد المقاعد")));
      return;
    }

    setState(() => _isSaving = true);

    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("User not logged in."),
          backgroundColor: Colors.red,
        ),
      );
      setState(() => _isSaving = false);
      return;
    }

    final newPlateNumber = _getFullLicensePlate();
    final bool plateChanged = newPlateNumber != _originalPlateNumber;
    bool isNewPlateUnique = true;

    if (plateChanged) {
      isNewPlateUnique = await _isLicensePlateUnique(
        newPlateNumber,
        _originalPlateNumber,
      );
      if (!isNewPlateUnique) {
        if (mounted) {
          // --- FIX: Removed 'const' from SnackBar ---
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "رقم اللوحة الجديد ($newPlateNumber) مستخدم بالفعل لسيارة أخرى.",
              ), // No unnecessary braces here
              backgroundColor: Colors.orange,
            ),
          );
          setState(() => _isSaving = false);
        }
        return;
      }
    }

    final updatedData = {
      'model': _modelController.text.trim(),
      'brand': _brandController.text.trim(),
      'plateNumber': newPlateNumber,
      'seatCount': _selectedSeatCount!,
      'updatedAt': FieldValue.serverTimestamp(),
      'ownerId': widget.initialData['ownerId'] ?? currentUser.uid,
      'isVerified': widget.initialData['isVerified'] ?? false,
      'createdAt': widget.initialData['createdAt'],
    };

    try {
      WriteBatch batch = _firestore.batch();
      DocumentReference carRef = _firestore
          .collection('cars')
          .doc(widget.carId);
      batch.update(carRef, updatedData);
      if (plateChanged) {
        if (_originalPlateNumber.isNotEmpty) {
          batch.delete(
            _firestore.collection('RegisteredPlates').doc(_originalPlateNumber),
          );
        }
        batch.set(
          _firestore.collection('RegisteredPlates').doc(newPlateNumber),
          {
            'ownerId': currentUser.uid,
            'createdAt': FieldValue.serverTimestamp(),
          },
        );
      }
      await batch.commit();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("تم تحديث بيانات السيارة بنجاح!"),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint("Error updating car: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("حدث خطأ أثناء تحديث السيارة: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("تعديل السيارة")),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                padding: const EdgeInsets.all(16.0),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    children: [
                      // Car Details Card
                      Card(
                        elevation: 2,
                        margin: const EdgeInsets.only(bottom: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "تفاصيل السيارة",
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _brandController,
                                decoration: const InputDecoration(
                                  labelText: "ماركة السيارة (مثال: Volkswagen)",
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.label_outline),
                                ),
                                validator:
                                    (value) =>
                                        (value == null || value.trim().isEmpty)
                                            ? "يرجى إدخال ماركة السيارة"
                                            : null,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _modelController,
                                decoration: const InputDecoration(
                                  labelText: "طراز السيارة (مثال: Polo 7)",
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.directions_car_filled),
                                ),
                                validator:
                                    (value) =>
                                        (value == null || value.trim().isEmpty)
                                            ? "يرجى إدخال طراز السيارة"
                                            : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // License Plate Card
                      Card(
                        elevation: 2,
                        margin: const EdgeInsets.only(bottom: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "رقم لوحة التسجيل",
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 16),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: TextFormField(
                                      controller: _firstDigitsController,
                                      keyboardType: TextInputType.number,
                                      textAlign: TextAlign.center,
                                      maxLength: 4,
                                      decoration: const InputDecoration(
                                        labelText: "0000",
                                        counterText: "",
                                        border: OutlineInputBorder(),
                                      ),
                                      validator: (value) {
                                        if (value == null || value.isEmpty)
                                          return "مطلوب";
                                        if (int.tryParse(value) == null)
                                          return "رقم";
                                        return null;
                                      },
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                    ),
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 8.0,
                                      vertical: 10.0,
                                    ),
                                    child: Text(
                                      "تونس",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: TextFormField(
                                      controller: _secondDigitsController,
                                      keyboardType: TextInputType.number,
                                      textAlign: TextAlign.center,
                                      maxLength: 3,
                                      decoration: const InputDecoration(
                                        labelText: "000",
                                        counterText: "",
                                        border: OutlineInputBorder(),
                                      ),
                                      validator: (value) {
                                        if (value == null || value.isEmpty)
                                          return "مطلوب";
                                        if (int.tryParse(value) == null)
                                          return "رقم";
                                        return null;
                                      },
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Seats Card
                      Card(
                        elevation: 2,
                        margin: const EdgeInsets.only(bottom: 24),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "المقاعد",
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 16),
                              DropdownButtonFormField<int>(
                                value: _selectedSeatCount,
                                items:
                                    _allowedSeatCounts
                                        .map(
                                          (int count) => DropdownMenuItem<int>(
                                            value: count,
                                            child: Text(
                                              "$count مقاعد (بما في ذلك السائق)",
                                            ),
                                          ),
                                        )
                                        .toList(),
                                onChanged: _generateAndUpdateLayout,
                                decoration: const InputDecoration(
                                  labelText: "عدد المقاعد",
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.event_seat),
                                ),
                                validator:
                                    (value) =>
                                        (value == null)
                                            ? "يرجى اختيار عدد المقاعد"
                                            : null,
                                hint: const Text("اختر عدد المقاعد"),
                              ),
                              const SizedBox(height: 16),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child:
                                    (_selectedSeatCount != null &&
                                            _selectedSeatCount! > 0)
                                        ? Column(
                                          key: ValueKey(_selectedSeatCount),
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              "معاينة تخطيط المقعد:",
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Container(
                                              padding: const EdgeInsets.all(12),
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: Colors.grey.shade300,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                color: Colors.grey.shade50,
                                              ),
                                              child: SeatLayoutWidget(
                                                key: ValueKey(
                                                  _selectedSeatCount,
                                                ),
                                                seatCount: _selectedSeatCount!,
                                                seatLayoutData:
                                                    _previewSeatLayout,
                                                mode:
                                                    SeatLayoutMode.displayOnly,
                                                driverSeatAssetPath:
                                                    _driverSeatImagePath,
                                                passengerSeatAssetPath:
                                                    _passengerSeatImagePath,
                                              ),
                                            ),
                                          ],
                                        )
                                        : SizedBox.shrink(key: ValueKey(0)),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Submit Button
                      _isSaving
                          ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(8.0),
                              child: CircularProgressIndicator(),
                            ),
                          )
                          : ElevatedButton.icon(
                            icon: const Icon(Icons.save_alt),
                            label: const Text("حفظ التغييرات"),
                            onPressed: _updateCar,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 50),
                              backgroundColor: Theme.of(context).primaryColor,
                              foregroundColor: Colors.white,
                              textStyle: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
      bottomNavigationBar: _buildBottomNavigationBar(),
    );
  }

  // --- Bottom Navigation Methods ---
  Widget _buildBottomNavigationBar() {
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
        targetPage = const ChatListPage();
        removeUntil = true;
        break;
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
} // End of _EditCarPageState class

// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   # Add SeatLayoutWidget dependency (if published) or ensure file import is correct
//   # Add imports for pages used in navigation (HomePage, MyRidePage, MyCarsPage, ChatListPage etc.)

// --- Firestore Setup ---
// * Ensure 'cars' collection has fields like 'ownerId', 'model', 'brand', 'plateNumber', 'seatCount', 'isVerified', 'createdAt'.
// * Ensure 'RegisteredPlates' collection exists for plate uniqueness check.

// --- Asset Setup (Required by SeatLayoutWidget) ---
// 1. Create folder: `assets/images/`
// 2. Add Images: Copy `DRIVERSEAT.png` and `PASSENGER SEAT.png` into `assets/images/`.
// 3. Declare in pubspec.yaml:
//    flutter:
//      assets:
//        - assets/images/
