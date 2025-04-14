import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Import project pages
import 'edit_car.dart'; // Ensure this page exists and handles car editing
import 'add_car.dart';
import 'home_page.dart';
import 'my_ride_page.dart';
import 'chat_list_page.dart';
import 'get_started_page.dart';

class MyCarsPage extends StatefulWidget {
  const MyCarsPage({super.key});

  @override
  State<MyCarsPage> createState() => _MyCarsPageState();
}

class _MyCarsPageState extends State<MyCarsPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final User? currentUser = FirebaseAuth.instance.currentUser;

  // State for delete loading indicator
  bool _isDeleting = false;
  String? _deletingCarId; // Track which car is being deleted

  // --- State for Bottom Navigation Bar ---
  // Set index 2 to highlight 'My Cars'
  int _currentIndex = 2;

  /// Checks if a car is currently associated with an active or scheduled ride.
  Future<bool> _isCarUsedInActiveRide(String carId) async {
    try {
      final query =
          await _firestore
              .collection('rides')
              .where('carId', isEqualTo: carId)
              .where(
                'status',
                whereIn: ['scheduled', 'ongoing', 'started'],
              ) // Check relevant statuses
              .limit(1)
              .get();
      return query.docs.isNotEmpty;
    } catch (e) {
      debugPrint("Error checking active rides for car $carId: $e");
      // Fail safe: Assume it IS used if check fails to prevent accidental deletion
      return true;
    }
  }

  /// Handles the deletion of a car after confirmation and checks.
  Future<void> _deleteCar(DocumentSnapshot car) async {
    if (currentUser == null || _isDeleting) return;

    final carId = car.id;
    final carData = car.data() as Map<String, dynamic>? ?? {};
    final plateNumber = carData['plateNumber'] as String? ?? '';

    // 1. Confirmation Dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text("تأكيد الحذف"),
            content: Text(
              "هل أنت متأكد من رغبتك في حذف هذه السيارة (${carData['model'] ?? ''} - $plateNumber)؟ لا يمكن التراجع عن هذا الإجراء.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text("إلغاء"),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text("حذف", style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
    );

    if (confirm != true || !mounted) return;

    setState(() {
      _isDeleting = true;
      _deletingCarId = carId;
    });

    try {
      // 2. Check if car is used in active rides
      bool isUsed = await _isCarUsedInActiveRide(carId);
      if (isUsed) {
        throw Exception(
          "لا يمكن حذف السيارة لأنها مستخدمة في رحلة مجدولة أو نشطة.",
        );
      }

      // 3. Perform Atomic Delete using WriteBatch
      WriteBatch batch = _firestore.batch();

      // Delete car document
      batch.delete(car.reference);

      // Delete registered plate document (if plateNumber is valid)
      if (plateNumber.isNotEmpty) {
        DocumentReference plateRef = _firestore
            .collection('RegisteredPlates')
            .doc(plateNumber);
        batch.delete(plateRef);
      }

      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("تم حذف السيارة بنجاح!"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error deleting car $carId: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ أثناء حذف السيارة: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
          _deletingCarId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (currentUser == null) {
      // This should ideally not happen if routing is correct, but handle defensively
      return Scaffold(
        appBar: AppBar(title: const Text("سياراتي")),
        body: const Center(child: Text("لم يتم تسجيل الدخول.")),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("سياراتي"),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: "إضافة سيارة جديدة",
            onPressed: () {
              // Navigate to AddCarPage and potentially refresh list on return
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const AddCarPage()),
              );
              // StreamBuilder handles refresh automatically
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream:
            _firestore
                .collection('cars')
                .where('ownerId', isEqualTo: currentUser!.uid)
                .orderBy('createdAt', descending: true) // Show newest first
                .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text("حدث خطأ: ${snapshot.error}"));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final cars = snapshot.data?.docs ?? []; // Use empty list if null

          if (cars.isEmpty) {
            // Enhanced empty state
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.directions_car_filled,
                      size: 80,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      "لم تقم بإضافة أي سيارات بعد.",
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.grey.shade700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text("إضافة أول سيارة"),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const AddCarPage(),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          // Display list of cars
          return ListView.builder(
            padding: const EdgeInsets.all(8.0), // Add padding around the list
            itemCount: cars.length,
            itemBuilder: (context, index) {
              var carDoc = cars[index];
              return _buildCarCard(carDoc); // Use helper to build card
            },
          );
        },
      ),
      // Add Bottom Navigation Bar
      bottomNavigationBar: _buildBottomNavigationBar(),
    );
  }

  /// Builds a styled Card widget for displaying a single car's details.
  Widget _buildCarCard(DocumentSnapshot carDoc) {
    final carData = carDoc.data() as Map<String, dynamic>? ?? {};
    final model = carData['model'] as String? ?? 'N/A';
    final brand =
        carData['brand'] as String? ?? ''; // Assumes brand field exists
    final plate = carData['plateNumber'] as String? ?? 'N/A';
    final seats = carData['seatCount'] as int? ?? 0;
    final carId = carDoc.id;
    final bool isCurrentlyDeleting = _isDeleting && _deletingCarId == carId;

    return Card(
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: Brand/Model and Edit/Delete buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    "$brand $model".trim(), // Combine brand and model
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Edit/Delete Buttons or Loading Indicator
                isCurrentlyDeleting
                    ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Edit Button
                        IconButton(
                          icon: const Icon(
                            Icons.edit_note_outlined,
                            color: Colors.blueAccent,
                          ),
                          tooltip: "تعديل السيارة",
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(), // Remove default padding
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder:
                                    (context) => EditCarPage(
                                      carId: carId,
                                      initialData: carData,
                                    ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        // Delete Button
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                          ),
                          tooltip: "حذف السيارة",
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(), // Remove default padding
                          onPressed: () => _deleteCar(carDoc),
                        ),
                      ],
                    ),
              ],
            ),
            const Divider(height: 20),
            // Details Row
            Row(
              children: [
                _buildDetailItem(Icons.pin_outlined, plate), // Plate Number
                const SizedBox(width: 16),
                _buildDetailItem(
                  Icons.airline_seat_recline_normal_outlined,
                  "$seats مقاعد",
                ), // Seat Count
                // Add more details like 'isVerified' status if needed
                // const Spacer(),
                // Chip(label: Text(carData['isVerified'] == true ? 'Verified' : 'Not Verified'), ...)
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Helper widget for displaying a detail item with icon and text.
  Widget _buildDetailItem(IconData icon, String text) {
    return Row(
      mainAxisSize:
          MainAxisSize.min, // Prevent row from taking full width unnecessarily
      children: [
        Icon(icon, size: 18, color: Colors.grey.shade700),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 14, color: Colors.grey.shade800)),
      ],
    );
  }

  // --- Bottom Navigation Methods ---
  Widget _buildBottomNavigationBar() {
    // Same implementation as other pages
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
    // No form to check here, just navigate
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
    // Prevent navigating to self
    if (index == 2) return; // Already on MyCarsPage

    switch (index) {
      case 0:
        targetPage = HomePage(user: currentUser);
        removeUntil = true;
        break;
      case 1:
        targetPage = MyRidePage(user: currentUser);
        removeUntil = true;
        break;
      // case 2: // Already handled above
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
      // No need to setState for _currentIndex when navigating away like this
    } else {
      print("Error: Target page was null for index $index");
    }
  }
} // End of _MyCarsPageState class

// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   # Add imports for pages used in navigation (HomePage, MyRidePage, ChatListPage, AddCarPage, EditCarPage etc.)

// --- Firestore Setup ---
// * Ensure 'cars' collection has fields like 'ownerId', 'model', 'brand', 'plateNumber', 'seatCount', 'createdAt', 'isVerified'.
// * Ensure 'rides' collection has 'carId' and 'status'.
// * Ensure 'RegisteredPlates' collection exists for checking plate uniqueness.

// --- Important ---
// * EditCarPage: This code assumes you have an `EditCarPage` that takes `carId` and `initialData`. Update or create it as needed.
// * Brand Field: The code assumes a 'brand' field exists on car documents. You might need to add this field in `AddCarPage` and `EditCarPage`.
