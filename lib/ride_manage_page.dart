import 'dart:math'; // For max function
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // For date formatting
import 'package:url_launcher/url_launcher.dart'; // For phone calls

// Import project pages & widgets
import 'home_page.dart';
import 'my_ride_page.dart';
import 'my_cars.dart';
import 'chat_list_page.dart';
import 'get_started_page.dart';
import 'widgets/seat_layout_widget.dart'; // Import the updated layout widget
import 'chat_helpers.dart'; // For chat function
import 'chat_detail_page.dart'; // For chat navigation
import 'ride_details_page.dart'; // For potential navigation
import 'add_car.dart' as add_car; // Added for potential use

class RideManagePage extends StatefulWidget {
  // Pass the initial ride data - might be slightly stale, use StreamBuilder for live data
  final Map<String, dynamic> ride;
  const RideManagePage({super.key, required this.ride});

  @override
  State<RideManagePage> createState() => _RideManagePageState();
}

class _RideManagePageState extends State<RideManagePage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late String rideId; // Get rideId from widget

  bool _isUpdatingStatus = false; // Loading indicator for ride status updates
  bool _isUpdatingApproval =
      false; // Loading indicator for seat approval updates

  // State for fetched Car Data
  Map<String, dynamic>? _carData;
  int _carSeatCount = 0;
  bool _isCarDataLoading = true; // Separate loading for car data

  // Bottom Nav State
  int _currentIndex = 1; // Default to 'My Rides' index

  // Asset Paths (Ensure these match your project structure and pubspec.yaml)
  final String _driverSeatImagePath = 'assets/images/DRIVERSEAT.png';
  final String _passengerSeatImagePath = 'assets/images/PASSENGER SEAT.png';

  @override
  void initState() {
    super.initState();
    // Extract rideId - ensure 'id' key exists in the passed map
    rideId = widget.ride['id'] as String? ?? '';
    if (rideId.isEmpty) {
      _handleInvalidRideId(); // Handle missing ID immediately
    } else {
      _fetchCarData(); // Fetch car data initially if ID is valid
    }
  }

  @override
  void dispose() {
    // Clean up resources if needed (e.g., controllers, listeners)
    super.dispose();
  }

  /// Handles the case where rideId is invalid on init.
  void _handleInvalidRideId() {
    print("Error: Ride ID missing in RideManagePage");
    // Schedule actions after the build phase to safely use context
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Error: Ride ID not found."),
            backgroundColor: Colors.red,
          ),
        );
        // Pop back immediately if ID is invalid
        if (Navigator.canPop(context)) {
          Navigator.of(context).pop();
        }
      }
    });
  }

  /// Fetches car details to get the accurate seat count.
  Future<void> _fetchCarData() async {
    // Don't show loading indicator on manual refresh, only initial load
    if (mounted && _carData == null) {
      // Only set loading true on initial fetch
      setState(() => _isCarDataLoading = true);
    }
    final carId = widget.ride['carId'] as String?;
    if (carId == null || carId.isEmpty) {
      print("Ride data missing carId. Deriving seat count from layout.");
      // Attempt to get seat count from layout as fallback
      final layout = widget.ride['seatLayout'] as List<dynamic>? ?? [];
      if (layout.isNotEmpty) {
        try {
          _carSeatCount =
              layout
                  .map((s) => s is Map ? (s['seatIndex'] as int? ?? -1) : -1)
                  .reduce(max) +
              1;
        } catch (e) {
          _carSeatCount = 1;
        } // Handle empty layout case for reduce
      } else {
        _carSeatCount = 1; // Default fallback if layout is empty
      }
    } else {
      // Fetch car document from Firestore
      try {
        final carDoc = await _firestore.collection('cars').doc(carId).get();
        if (mounted && carDoc.exists) {
          _carData = carDoc.data() as Map<String, dynamic>?;
          _carSeatCount =
              (_carData?['seatCount'] as int?) ??
              0; // Get seat count from car doc
        } else {
          print(
            "Car document not found for carId: $carId. Deriving seat count from layout.",
          );
          // Fallback using layout length if car doc missing
          final layout = widget.ride['seatLayout'] as List<dynamic>? ?? [];
          if (layout.isNotEmpty) {
            try {
              _carSeatCount =
                  layout
                      .map(
                        (s) => s is Map ? (s['seatIndex'] as int? ?? -1) : -1,
                      )
                      .reduce(max) +
                  1;
            } catch (e) {
              _carSeatCount = 1;
            }
          } else {
            _carSeatCount = 1;
          }
        }
      } catch (e) {
        print("Error fetching car data: $e");
        // Fallback using layout length on error
        final layout = widget.ride['seatLayout'] as List<dynamic>? ?? [];
        if (layout.isNotEmpty) {
          try {
            _carSeatCount =
                layout
                    .map((s) => s is Map ? (s['seatIndex'] as int? ?? -1) : -1)
                    .reduce(max) +
                1;
          } catch (e) {
            _carSeatCount = 1;
          }
        } else {
          _carSeatCount = 1;
        }
      }
    }
    // Ensure seat count is at least 1 (for driver)
    if (_carSeatCount <= 0) {
      _carSeatCount = 1;
    }
    // Update UI after fetching/calculating
    if (mounted) {
      setState(() => _isCarDataLoading = false);
    }
  }

  /// Function to handle pull-to-refresh. Re-fetches car data.
  Future<void> _loadInitialData() async {
    // Re-fetch car data on refresh
    await _fetchCarData();
    // Note: Ride data itself is updated by the StreamBuilder, no need to fetch here.
  }

  /// Formats the repeat information string.
  String _formatRepeatInfo(String? repeatType, dynamic daysList) {
    if (repeatType == 'daily') {
      return "يوميًا";
    }
    if (repeatType == 'daysOfWeek' && daysList is List && daysList.isNotEmpty) {
      const dayNames = [
        "الأحد",
        "الاثنين",
        "الثلاثاء",
        "الأربعاء",
        "الخميس",
        "الجمعة",
        "السبت",
      ];
      // Sort the days first for consistent output
      final sortedDays = List<int>.from(daysList.whereType<int>())..sort();
      final selectedDays = sortedDays
          .map((d) => (d >= 0 && d < 7) ? dayNames[d] : null)
          .where((d) => d != null)
          .join(', ');
      return selectedDays.isNotEmpty
          ? "أيام الأسبوع: $selectedDays"
          : "مرة واحدة";
    }
    return "مرة واحدة"; // Default
  }

  /// Updates the overall ride status (e.g., started, completed, cancelled).
  Future<void> _updateRideStatus(String currentStatus, String newStatus) async {
    if (_isUpdatingStatus || rideId.isEmpty) return;
    setState(() => _isUpdatingStatus = true);

    try {
      await _firestore.runTransaction((transaction) async {
        DocumentReference rideRef = _firestore.collection('rides').doc(rideId);
        DocumentSnapshot snapshot = await transaction.get(rideRef);
        if (!snapshot.exists) throw Exception("Ride not found");

        List<dynamic> layoutFromTransaction = List.from(
          snapshot.get('seatLayout') ?? [],
        );
        List<dynamic> updatedLayout = List.from(
          layoutFromTransaction,
        ); // Create mutable copy

        // Logic for 'completed' status check
        if (newStatus == 'completed') {
          bool hasPending = updatedLayout.any(
            (s) =>
                s is Map &&
                s['type'] == 'share' &&
                (s['bookedBy'] as String? ?? 'n/a') != 'n/a' &&
                s['offered'] == true &&
                s['approvalStatus'] == 'pending',
          );
          if (hasPending) {
            throw Exception(
              "يرجى الموافقة أو الرفض لجميع حجوزات المقاعد قبل إكمال الرحلة.",
            );
          }
        }

        // Logic for 'cancelled' or 'started' status - decline pending requests
        if (newStatus == 'cancelled' || newStatus == 'started') {
          bool changed = false;
          for (int i = 0; i < updatedLayout.length; i++) {
            var seat = updatedLayout[i];
            if (seat is Map &&
                seat['type'] == 'share' &&
                (seat['bookedBy'] as String? ?? 'n/a') != 'n/a' &&
                seat['offered'] == true &&
                seat['approvalStatus'] == 'pending') {
              var mutableSeat = Map<String, dynamic>.from(seat);
              mutableSeat['approvalStatus'] = 'declined';
              // Decide if decline should also unbook:
              // mutableSeat['bookedBy'] = 'n/a';
              updatedLayout[i] = mutableSeat;
              changed = true;
            }
          }
          if (changed) {
            debugPrint(
              "Updated pending requests for ride $rideId due to status change to $newStatus",
            );
          }
        }

        // Update status and potentially modified layout
        transaction.update(rideRef, {
          'status': newStatus,
          'seatLayout': updatedLayout,
        });
      });

      // If ride completed successfully, clear driver role (run outside transaction)
      if (newStatus == 'completed' && mounted) {
        await _firestore.collection('users').doc(widget.ride['driverId']).set({
          'role': '',
        }, SetOptions(merge: true));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("تم إكمال الرحلة وتحديث الدور."),
            backgroundColor: Colors.green,
          ),
        );
        // Optionally pop back after completion
        // if (Navigator.canPop(context)) Navigator.of(context).pop();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("تم تحديث حالة الرحلة إلى $newStatus."),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error updating ride status: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ في تحديث الحالة: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdatingStatus = false);
      }
    }
  }

  /// Updates the approval status for a specific seat booking.
  Future<void> _updateSeatApproval(int seatIndex, String newStatus) async {
    if (_isUpdatingApproval || rideId.isEmpty) return;
    setState(() => _isUpdatingApproval = true);

    try {
      await _firestore.runTransaction((transaction) async {
        DocumentReference rideRef = _firestore.collection('rides').doc(rideId);
        DocumentSnapshot snapshot = await transaction.get(rideRef);
        if (!snapshot.exists) throw Exception("Ride not found");

        List<dynamic> layout = List.from(snapshot.get('seatLayout') ?? []);
        int seatListIndex = layout.indexWhere(
          (s) => s is Map && s['seatIndex'] == seatIndex,
        );

        if (seatListIndex == -1) throw Exception("Seat not found in layout.");
        final seat = Map<String, dynamic>.from(layout[seatListIndex]);

        // Only update if the status is actually changing
        if (seat['approvalStatus'] != newStatus) {
          seat['approvalStatus'] = newStatus;
          // If declining, also clear the booking by setting bookedBy to "n/a"
          if (newStatus == 'declined') {
            seat['bookedBy'] = "n/a"; // Make seat available again
          }
          layout[seatListIndex] = seat;
          transaction.update(rideRef, {'seatLayout': layout});
        } else {
          print(
            "Seat $seatIndex already has status $newStatus. No update needed.",
          );
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "تم ${newStatus == 'approved' ? 'قبول' : 'رفض'} الحجز.",
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error updating seat approval: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdatingApproval = false);
      }
    }
  }

  /// Fetches the booked user's details from Firestore.
  Future<Map<String, dynamic>?> _fetchBookedUser(String userId) async {
    try {
      DocumentSnapshot userDoc =
          await _firestore.collection('users').doc(userId).get();
      return userDoc.exists ? userDoc.data() as Map<String, dynamic> : null;
    } catch (e) {
      debugPrint("Error fetching booked user $userId: $e");
      return null;
    }
  }

  /// Shows a dialog with the booked user's details along with call/message and approval actions.
  Future<void> _showBookedUserDialog(Map<String, dynamic> seat) async {
    final String bookedUserId = seat['bookedBy'] as String? ?? '';
    final int seatIndex = seat['seatIndex'] as int? ?? -1;
    final String currentApprovalStatus =
        seat['approvalStatus'] as String? ?? 'pending';

    if (bookedUserId.isEmpty || bookedUserId == 'n/a' || seatIndex == -1) {
      print("Cannot show dialog: Invalid seat data or not booked.");
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    ); // Show loading

    Map<String, dynamic>? userData = await _fetchBookedUser(bookedUserId);

    if (!mounted) return;
    Navigator.pop(context); // Dismiss loading

    if (userData == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("User details not found.")));
      return;
    }
    String userName = userData['name'] as String? ?? 'Unknown';
    String imageUrl = userData['imageUrl'] as String? ?? '';
    String phone = userData['phone'] as String? ?? '';

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text("طلب حجز للمقعد ${seatIndex + 1}"),
          contentPadding: const EdgeInsets.all(16),
          content: SingleChildScrollView(
            // Make content scrollable if needed
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 35,
                  backgroundImage:
                      imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
                  child:
                      imageUrl.isEmpty
                          ? const Icon(Icons.person, size: 35)
                          : null,
                ),
                const SizedBox(height: 12),
                Text(
                  userName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (phone.isNotEmpty)
                  InkWell(
                    onTap: () async {
                      final Uri callUri = Uri(scheme: 'tel', path: phone);
                      if (await canLaunchUrl(callUri)) {
                        await launchUrl(callUri);
                      }
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.phone, size: 16, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          phone,
                          style: const TextStyle(
                            color: Colors.blue,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                // Contact Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.call_outlined, size: 18),
                      label: const Text("اتصال"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade100,
                        foregroundColor: Colors.green.shade800,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed:
                          phone.isNotEmpty
                              ? () async {
                                final Uri callUri = Uri(
                                  scheme: 'tel',
                                  path: phone,
                                );
                                if (await canLaunchUrl(callUri)) {
                                  await launchUrl(callUri);
                                }
                              }
                              : null,
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.message_outlined, size: 18),
                      label: const Text("رسالة"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade100,
                        foregroundColor: Colors.blue.shade800,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: () async {
                        final currentUser = _auth.currentUser;
                        if (currentUser == null) return;
                        final chatId = await createOrGetChatRoom(
                          currentUser.uid,
                          bookedUserId,
                        );
                        if (!mounted) return;
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (_) => ChatDetailPage(
                                  chatId: chatId,
                                  otherUserId: bookedUserId,
                                ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          actionsAlignment: MainAxisAlignment.spaceEvenly,
          actions:
              currentApprovalStatus == 'pending'
                  ? [
                    // Show Approve/Decline only if pending
                    TextButton(
                      onPressed:
                          _isUpdatingApproval
                              ? null
                              : () {
                                Navigator.of(ctx).pop();
                                _updateSeatApproval(seatIndex, 'declined');
                              },
                      child:
                          _isUpdatingApproval
                              ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Text(
                                "رفض",
                                style: TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                    ),
                    TextButton(
                      onPressed:
                          _isUpdatingApproval
                              ? null
                              : () {
                                Navigator.of(ctx).pop();
                                _updateSeatApproval(seatIndex, 'approved');
                              },
                      child:
                          _isUpdatingApproval
                              ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Text(
                                "قبول",
                                style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                    ),
                  ]
                  : [
                    // Show status and close button if already decided
                    Text(
                      "الحالة: $currentApprovalStatus",
                      style: TextStyle(
                        color:
                            currentApprovalStatus == 'approved'
                                ? Colors.green
                                : Colors.red,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text("إغلاق"),
                    ),
                  ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (rideId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text("Error")),
        body: const Center(child: Text("Invalid Ride ID.")),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('إدارة الرحلة')),
      bottomNavigationBar: _buildBottomNavigationBar(),
      body: StreamBuilder<DocumentSnapshot>(
        // Use StreamBuilder for live updates
        stream: _firestore.collection('rides').doc(rideId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } // Show loading initially
          if (snapshot.hasError) {
            return Center(child: Text('خطأ: ${snapshot.error}'));
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(
              child: Text("لم يتم العثور على الرحلة أو تم حذفها."),
            );
          }

          final rideDoc = snapshot.data!;
          final rideData = rideDoc.data() as Map<String, dynamic>;
          final seatLayout = List<Map<String, dynamic>>.from(
            rideData['seatLayout'] ?? [],
          );
          final rideStatus = rideData['status'] as String? ?? 'unknown';
          final driverId = rideData['driverId'] as String? ?? '';

          // Calculate seat count (prefer from car, fallback to layout)
          // Use _isCarDataLoading to wait for car data before calculating
          int seatCount =
              _isCarDataLoading
                  ? 0
                  : _carSeatCount; // Use 0 if car data still loading
          if (seatCount <= 0 && seatLayout.isNotEmpty) {
            try {
              seatCount =
                  seatLayout
                      .map((s) => s['seatIndex'] as int? ?? -1)
                      .reduce(max) +
                  1;
            } catch (e) {
              seatCount = 1;
            }
          }
          if (seatCount <= 0 && !_isCarDataLoading)
            seatCount =
                1; // Final fallback if car fetch failed but layout exists

          return RefreshIndicator(
            onRefresh:
                _loadInitialData, // Use the defined _loadInitialData method
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Show header loading or content
                _isCarDataLoading
                    ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: CircularProgressIndicator(),
                      ),
                    )
                    : _buildRideHeaderCard(rideData), // Pass live rideData
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),

                // Seat Layout Section
                Text(
                  "إدارة طلبات الحجز",
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (_isCarDataLoading)
                  const Center(child: Text("Loading seat layout..."))
                else if (seatCount > 0)
                  AbsorbPointer(
                    // Disable taps while updating approval
                    absorbing: _isUpdatingApproval,
                    child: SeatLayoutWidget(
                      key: ValueKey(rideId + seatLayout.hashCode.toString()),
                      seatCount: seatCount,
                      seatLayoutData: seatLayout, // Use live data from stream
                      mode:
                          SeatLayoutMode.driverManage, // Use driver manage mode
                      driverSeatAssetPath: _driverSeatImagePath,
                      passengerSeatAssetPath: _passengerSeatImagePath,
                      onPendingSeatTap:
                          _showBookedUserDialog, // Trigger dialog on tap
                      currentUserId:
                          _auth.currentUser?.uid, // Pass current user ID
                    ),
                  )
                else
                  const Text("لم يتم تحديد تخطيط المقاعد لهذه السيارة."),
                if (_isUpdatingApproval)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16.0),
                    child: Center(child: CircularProgressIndicator()),
                  ),

                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),

                // Ride Status Management Section
                Text(
                  "إدارة حالة الرحلة",
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                _buildRideStatusActions(
                  rideData,
                  rideStatus,
                ), // Pass live rideData
                if (_isUpdatingStatus)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16.0),
                    child: Center(child: CircularProgressIndicator()),
                  ),

                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Builds the top card with ride details. Uses state variables and passed rideData.
  Widget _buildRideHeaderCard(Map<String, dynamic> rideData) {
    // Extract data directly from the passed map for potentially live info
    final departureTimestamp = rideData['date'] as Timestamp?;
    final startLocationName = rideData['startLocationName'] as String? ?? 'N/A';
    final endLocationName = rideData['endLocationName'] as String? ?? 'N/A';
    final price = (rideData['price'] as num?)?.toDouble() ?? 0.0;
    final preferences = rideData['preferences'] as Map<String, dynamic>? ?? {};
    final bool smokingAllowed = preferences['smoking'] == true;
    // Use _formatRepeatInfo which is now defined
    final repeatInfo = _formatRepeatInfo(rideData['repeat'], rideData['days']);
    final String departureFormatted =
        departureTimestamp != null
            ? DateFormat(
              'EEE, MMM d, yyyy - hh:mm a',
              'en_US',
            ).format(departureTimestamp.toDate())
            : 'N/A';

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "تفاصيل الرحلة",
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const Divider(height: 20),
            // Use _carData (fetched initially) for car details
            _buildDetailRow(
              Icons.directions_car,
              "السيارة:",
              "${_carData?['brand'] ?? ''} ${_carData?['model'] ?? ''} (${_carData?['plateNumber'] ?? 'N/A'})",
            ),
            _buildDetailRow(
              Icons.person,
              "السائق:",
              "أنت",
            ), // Driver is viewing this page
            _buildDetailRow(Icons.pin_drop_outlined, "من:", startLocationName),
            _buildDetailRow(Icons.location_on, "إلى:", endLocationName),
            _buildDetailRow(
              Icons.calendar_today,
              "المغادرة:",
              departureFormatted,
            ),
            _buildDetailRow(Icons.repeat, "التكرار:", repeatInfo),
            _buildDetailRow(
              Icons.attach_money,
              "سعر المقعد:",
              "${price.toStringAsFixed(0)} DZD",
            ),
            _buildDetailRow(
              Icons.smoking_rooms,
              "التدخين:",
              smokingAllowed ? 'مسموح' : 'غير مسموح',
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the card with driver contact options (Simplified for Manage Page).
  Widget _buildDriverContactCard(String driverId) {
    // Simplified card for this page
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.grey.shade100,
      child: const Padding(
        padding: EdgeInsets.all(12.0),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blueGrey),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                "أنت تدير هذه الرحلة. يمكنك إدارة طلبات الحجز وحالة الرحلة أدناه.",
                style: TextStyle(color: Colors.blueGrey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the buttons for managing ride status.
  Widget _buildRideStatusActions(
    Map<String, dynamic> rideData,
    String currentStatus,
  ) {
    List<Widget> actions = [];
    // Add rideId if missing (important for _updateRideStatus)
    if (!rideData.containsKey('id') && rideId.isNotEmpty) {
      rideData = {...rideData, 'id': rideId};
    }

    if (currentStatus == 'scheduled') {
      actions.addAll([
        ElevatedButton.icon(
          icon: const Icon(Icons.cancel_outlined),
          label: const Text('إلغاء الرحلة'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade100,
            foregroundColor: Colors.red.shade800,
          ),
          onPressed:
              _isUpdatingStatus
                  ? null
                  : () => _updateRideStatus(currentStatus, 'cancelled'),
        ),
        const SizedBox(width: 10),
        ElevatedButton.icon(
          icon: const Icon(Icons.play_arrow_outlined),
          label: const Text('بدء الرحلة'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange.shade100,
            foregroundColor: Colors.orange.shade800,
          ),
          onPressed:
              _isUpdatingStatus
                  ? null
                  : () => _updateRideStatus(currentStatus, 'started'),
        ),
      ]);
    } else if (currentStatus == 'started') {
      actions.add(
        ElevatedButton.icon(
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('إكمال الرحلة'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade100,
            foregroundColor: Colors.green.shade800,
          ),
          onPressed:
              _isUpdatingStatus
                  ? null
                  : () => _updateRideStatus(currentStatus, 'completed'),
        ),
      );
    } else {
      actions.add(
        Chip(
          label: Text("الحالة: $currentStatus"),
          backgroundColor: Colors.grey.shade200,
        ),
      );
    }
    return Wrap(
      spacing: 8.0,
      alignment: WrapAlignment.center,
      children: actions,
    );
  }

  /// Helper to build a row in the details card.
  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).primaryColor),
          const SizedBox(width: 8),
          Text("$label ", style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: Text(value, style: TextStyle(color: Colors.grey.shade800)),
          ),
        ],
      ),
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
    if (!mounted || index == _currentIndex) {
      return;
    }
    // TODO: Consider adding check if updating status/approval
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
    // Prevent navigating to self if already on the target page conceptually
    if (index == 1) {
      return;
    } // Already on My Rides section conceptually

    switch (index) {
      case 0:
        targetPage = HomePage(user: currentUser);
        removeUntil = true;
        break;
      // case 1: // Already handled above
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
} // End
// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   intl: ^...             # For date formatting
//   url_launcher: ^...     # For phone calls
//   # Add SeatLayoutWidget dependency (if published) or ensure file import is correct
//   # Add imports for pages used in navigation (HomePage, MyRidePage, MyCarsPage, ChatListPage etc.)

// --- Firestore Setup ---
// * Ensure 'users' collection has: 'phone', 'name', 'imageUrl', 'role', etc.
// * Ensure 'cars' collection has relevant fields including 'seatCount'.
// * Ensure 'rides' collection schema matches the data being read/updated (incl. seatLayout with approvalStatus).

// --- Asset Setup (Required by SeatLayoutWidget) ---
// 1. Create folder: `assets/images/`
// 2. Add Images: Copy `DRIVERSEAT.png` and `PASSENGER SEAT.png` into `assets/images/`.
// 3. Declare in pubspec.yaml:
//    flutter:
//      assets:
//        - assets/images/
