import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

// Import the reusable SeatLayoutWidget (adjust path if needed)
import 'widgets/seat_layout_widget.dart';
// Import pages needed for bottom navigation
import 'home_page.dart';
import 'my_ride_page.dart';
import 'my_cars.dart'; // Assuming this page exists for navigation
import 'chat_list_page.dart'; // Assuming this page exists for navigation
import 'get_started_page.dart'; // For potential error navigation if user is null
import 'add_car.dart'
    as add_car; // Self import needed for AddCarPage type if used internally

class AddCarPage extends StatefulWidget {
  const AddCarPage({super.key});

  @override
  State<AddCarPage> createState() => _AddCarPageState();
}

class _AddCarPageState extends State<AddCarPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _firstDigitsController = TextEditingController();
  final TextEditingController _secondDigitsController = TextEditingController();
  // REMOVED: final TextEditingController _seatsController = TextEditingController();
  bool _isLoading = false;

  // State for seat layout preview
  int? _selectedSeatCount; // Changed to nullable int for dropdown
  List<Map<String, dynamic>> _previewSeatLayout = [];

  // Define asset paths (UPDATE THESE TO MATCH YOUR PROJECT AND FILE EXTENSIONS)
  final String _driverSeatImagePath =
      'assets/images/DRIVERSEAT.png'; // Use .png
  final String _passengerSeatImagePath =
      'assets/images/PASSENGER SEAT.png'; // Use .png

  // --- State for Bottom Navigation Bar ---
  int _currentIndex = 2; // Default to 'My Cars' index visually for this page

  // --- Allowed Seat Counts ---
  final List<int> _allowedSeatCounts = const [2, 4, 5, 6, 7, 8, 9];

  @override
  void initState() {
    super.initState();
    // REMOVED: Listener for _seatsController
  }

  @override
  void dispose() {
    _modelController.dispose();
    _firstDigitsController.dispose();
    _secondDigitsController.dispose();
    // REMOVED: _seatsController listener removal and dispose
    super.dispose();
  }

  /// Generates the basic seat layout data structure based on the selected dropdown value.
  void _generateAndUpdateLayout(int? count) {
    // Generate layout only if count is valid and positive
    if (count != null && count > 0) {
      // Use setState to trigger rebuild with new layout
      setState(() {
        _selectedSeatCount = count; // Update selected count
        _previewSeatLayout = _generateFlatSeatLayout(
          _selectedSeatCount!,
        ); // Generate layout
      });
    } else {
      // Clear preview if selection is cleared or invalid
      setState(() {
        _selectedSeatCount = null; // Ensure count is null if input is null
        _previewSeatLayout = [];
      });
    }
  }

  /// Generates the basic seat layout data structure.
  /// (Copied/Adapted from CreateRidePage - Consider moving to a shared utility)
  List<Map<String, dynamic>> _generateFlatSeatLayout(int totalSeats) {
    if (totalSeats < 1) return [];
    final List<Map<String, dynamic>> layout = [];
    // Add driver seat
    layout.add({
      "seatIndex": 0,
      "type": "driver",
      "offered": false,
      "bookedBy": null,
      "approvalStatus": "n/a",
    });
    // Add passenger seats
    for (int i = 1; i < totalSeats; i++) {
      layout.add({
        "seatIndex": i,
        "type": "share",
        "offered": false,
        "bookedBy": null,
        "approvalStatus": "pending",
      });
    }
    return layout;
  }

  // Check if the given license plate is unique.
  Future<bool> _isLicensePlateUnique(String plate) async {
    // Ensure plate is not empty before checking
    if (plate.trim().length < 5) {
      // Adjust minimum length based on actual format
      debugPrint("Plate format seems incorrect: $plate");
      return false;
    }
    try {
      DocumentSnapshot plateDoc =
          await FirebaseFirestore.instance
              .collection('RegisteredPlates')
              .doc(plate)
              .get();
      return !plateDoc.exists; // Unique if not found.
    } catch (e) {
      debugPrint("Error checking plate uniqueness for '$plate': $e");
      // Decide how to handle Firestore errors - maybe allow proceeding with a warning?
      // Returning false is safer, preventing potential duplicates if check fails.
      return false;
    }
  }

  // Combine the two parts and "تونس" text into a complete plate.
  String _getFullLicensePlate() {
    String firstPart = _firstDigitsController.text.trim();
    String secondPart = _secondDigitsController.text.trim();
    // Consider adding padding or more robust formatting based on Tunisian standards
    return "$firstPart تونس $secondPart";
  }

  /// Handles the submission of the new car form.
  Future<void> _addCar() async {
    // 1. Validate Form Inputs
    if (!(_formKey.currentState?.validate() ?? false)) {
      return; // Exit if form is invalid
    }

    // 2. Ensure a seat count is selected
    if (_selectedSeatCount == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("يرجى اختيار عدد المقاعد")));
      return;
    }

    // Prevent multiple submissions
    if (_isLoading) return;
    setState(() => _isLoading = true);

    // 3. Get Current User
    User? currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("لم يتم تسجيل الدخول. لا يمكن إضافة سيارة."),
          ),
        );
        setState(() => _isLoading = false);
      }
      return;
    }

    // 4. Format and Check License Plate Uniqueness
    String plate = _getFullLicensePlate();
    bool unique = await _isLicensePlateUnique(plate);
    if (!unique) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("رقم اللوحة هذا مسجل بالفعل لسيارة أخرى."),
          ),
        );
        setState(() => _isLoading = false);
      }
      return;
    }

    // 5. Prepare Car Data
    CollectionReference carsRef = FirebaseFirestore.instance.collection('cars');
    final carData = {
      'ownerId': currentUser.uid,
      'model': _modelController.text.trim(),
      'brand':
          '', // TODO: Add a field for Brand (e.g., Toyota, VW) - Requires another input field
      'plateNumber': plate,
      'seatCount': _selectedSeatCount, // Use the selected count
      'isVerified': false, // Cars likely start unverified
      'createdAt': FieldValue.serverTimestamp(),
      // Add other relevant fields: color, year, etc. - Requires more input fields
    };

    // 6. Perform Atomic Write (Register Plate + Add Car)
    try {
      WriteBatch batch = FirebaseFirestore.instance.batch();

      // Operation 1: Register the plate globally.
      DocumentReference plateRef = FirebaseFirestore.instance
          .collection('RegisteredPlates')
          .doc(plate);
      batch.set(plateRef, {
        'ownerId': currentUser.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Operation 2: Add car document.
      DocumentReference carRef = carsRef.doc(); // Let Firestore generate ID
      batch.set(carRef, carData);

      // Commit both operations together
      await batch.commit();

      // 7. Handle Success
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("تم إضافة السيارة بنجاح!"),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop(); // Go back after success
      }
    } catch (e) {
      // 8. Handle Error
      debugPrint("Error adding car: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("حدث خطأ أثناء إضافة السيارة: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
      // Note: Batch writes are atomic, so no need for manual cleanup on failure here.
    } finally {
      // 9. Reset Loading State
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
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
            // Use ListView to prevent overflow on smaller screens
            children: [
              // Car Model Input
              TextFormField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: "طراز السيارة (مثال: Polo 7)",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.directions_car),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return "يرجى إدخال طراز السيارة";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // License Plate Input Row
              Text(
                "رقم لوحة التسجيل",
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
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
                        if (value == null || value.isEmpty) return "مطلوب";
                        if (int.tryParse(value) == null) return "رقم";
                        return null;
                      },
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
                        if (value == null || value.isEmpty) return "مطلوب";
                        if (int.tryParse(value) == null) return "رقم";
                        return null;
                      },
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // --- Seat Count Dropdown ---
              DropdownButtonFormField<int>(
                value: _selectedSeatCount,
                items:
                    _allowedSeatCounts.map((int count) {
                      return DropdownMenuItem<int>(
                        value: count,
                        child: Text("$count مقاعد (بما في ذلك السائق)"),
                      );
                    }).toList(),
                onChanged: (int? newValue) {
                  // Update state and preview directly
                  _generateAndUpdateLayout(newValue);
                },
                decoration: const InputDecoration(
                  labelText: "عدد المقاعد",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.event_seat),
                ),
                validator: (value) {
                  if (value == null) {
                    return "يرجى اختيار عدد المقاعد";
                  }
                  return null;
                },
                hint: const Text("اختر عدد المقاعد"),
              ),
              const SizedBox(height: 16),

              // --- Seat Layout Preview ---
              AnimatedSwitcher(
                // Add animation for smoother appearance
                duration: const Duration(milliseconds: 300),
                child:
                    (_selectedSeatCount != null && _selectedSeatCount! > 0)
                        ? Column(
                          // Use Column to group title and widget
                          key: ValueKey(
                            _selectedSeatCount,
                          ), // Key for animation
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "معاينة تخطيط المقعد:",
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.grey.shade50,
                              ),
                              child: SeatLayoutWidget(
                                // key: ValueKey(_selectedSeatCount), // Key moved to Column
                                seatCount: _selectedSeatCount!,
                                seatLayoutData: _previewSeatLayout,
                                mode: SeatLayoutMode.displayOnly,
                                driverSeatAssetPath: _driverSeatImagePath,
                                passengerSeatAssetPath: _passengerSeatImagePath,
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],
                        )
                        : const SizedBox.shrink(
                          key: ValueKey(0),
                        ), // Empty space when no selection
              ),

              // Submit Button
              _isLoading
                  ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(8.0),
                      child: CircularProgressIndicator(),
                    ),
                  )
                  : ElevatedButton.icon(
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text("أضف السيارة"),
                    onPressed: _addCar,
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
              const SizedBox(height: 20), // Bottom padding
            ],
          ),
        ),
      ),
      // --- ADDED Bottom Navigation Bar ---
      bottomNavigationBar: _buildBottomNavigationBar(),
    );
  }

  // --- Bottom Navigation Methods ---
  Widget _buildBottomNavigationBar() {
    // Builds the bottom navigation bar UI
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
        BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
        BottomNavigationBarItem(
          icon: Icon(Icons.directions_car_outlined),
          label: 'My Rides',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.car_rental_outlined),
          label: 'My Cars',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.message_outlined),
          label: 'Messages',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.person_outline),
          label: 'Account',
        ),
      ],
    );
  }

  void _onBottomNavTapped(int index) {
    // Handles tap events on the bottom navigation bar items
    if (!mounted || index == _currentIndex) return;
    // TODO: Consider adding a check here if the form has unsaved changes
    _navigateToIndex(index);
  }

  void _navigateToIndex(int index) {
    // Performs the actual navigation based on the selected index
    Widget? targetPage;
    bool removeUntil = false;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      // Navigate to GetStartedPage if user is somehow null
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const GetStartedPage()),
        (route) => false,
      );
      return;
    }

    switch (index) {
      case 0:
        targetPage = HomePage(user: currentUser);
        removeUntil = true;
        break;
      case 1:
        targetPage = MyRidePage(user: currentUser);
        removeUntil = true;
        break; // Navigate home-like for main sections
      case 2:
        targetPage = const MyCarsPage();
        removeUntil = true;
        break; // Navigate home-like for main sections
      case 3:
        targetPage = const ChatListPage();
        removeUntil = true;
        break; // Navigate home-like for main sections
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
      // No need to setState for _currentIndex as we are navigating away
    } else {
      print("Error: Target page was null for index $index");
    }
  }
} // End of _AddCarPageState
// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   # Import the pages used in bottom navigation (HomePage, MyRidePage, etc.)
//   # Import SeatLayoutWidget

// --- Asset Setup (Required by SeatLayoutWidget) ---
// 1. Create folder: `assets/images/`
// 2. Add Images: Copy `DRIVERSEAT.png` and `PASSENGER SEAT.png` into `assets/images/`.
// 3. Declare in pubspec.yaml:
//    flutter:
//      assets:
//        - assets/images/
