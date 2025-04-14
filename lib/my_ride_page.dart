import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // For date formatting

// Import project pages
import 'ride_manage_page.dart'; // Assuming this exists and takes ride map
import 'ride_details_page.dart'; // Uses rideId constructor
import 'home_page.dart';
import 'my_cars.dart';
import 'chat_list_page.dart'; // Assuming this exists
import 'get_started_page.dart'; // For navigation fallback

class MyRidePage extends StatefulWidget {
  final User user;
  const MyRidePage({super.key, required this.user});

  @override
  State<MyRidePage> createState() => _MyRidePageState();
}

class _MyRidePageState extends State<MyRidePage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // State for filtering and sorting
  String searchQuery = '';
  String sortBy = 'date'; // 'date' or 'status'

  // State for UI updates
  bool _isUpdatingStatus = false; // Loading indicator for status updates

  // State for Bottom Navigation
  int _currentIndex = 1; // Default index for 'My Rides' tab

  /// Stream that fetches rides where the user is the driver OR a booked passenger.
  /// Applies filtering and sorting based on state variables.
  Stream<List<Map<String, dynamic>>> _ridesStream() {
    String? uid = widget.user.uid;
    if (uid == null) {
      return Stream.value([]); // Return empty stream if no user ID
    }

    return _firestore.collection('rides').snapshots().map((snapshot) {
      List<Map<String, dynamic>> userRides = [];
      for (var doc in snapshot.docs) {
        try {
          // Add try-catch for robust data parsing
          Map<String, dynamic> ride = {
            'id': doc.id,
            ...doc.data(),
          }; // Add document ID

          bool isDriver = ride['driverId'] == uid;
          bool isPassenger = false;
          if (!isDriver && ride['seatLayout'] is List) {
            isPassenger = (ride['seatLayout'] as List<dynamic>).any(
              (seat) => seat is Map && seat['bookedBy'] == uid,
            );
          }

          if (isDriver || isPassenger) {
            userRides.add(ride);
          }
        } catch (e) {
          debugPrint("Error processing ride doc ${doc.id}: $e");
          // Skip this ride if data is malformed
        }
      }

      // --- Client-side Filtering ---
      if (searchQuery.isNotEmpty) {
        String lowerQuery = searchQuery.toLowerCase();
        userRides =
            userRides.where((ride) {
              String start =
                  (ride['startLocationName'] as String? ?? '').toLowerCase();
              String end =
                  (ride['endLocationName'] as String? ?? '').toLowerCase();
              String status = (ride['status'] as String? ?? '').toLowerCase();
              return start.contains(lowerQuery) ||
                  end.contains(lowerQuery) ||
                  status.contains(lowerQuery);
            }).toList();
      }

      // --- Client-side Sorting ---
      try {
        userRides.sort((a, b) {
          if (sortBy == 'date') {
            Timestamp aTime = a['date'] as Timestamp? ?? Timestamp(0, 0);
            Timestamp bTime = b['date'] as Timestamp? ?? Timestamp(0, 0);
            return bTime.compareTo(aTime); // Descending
          } else if (sortBy == 'status') {
            String aStatus = a['status'] as String? ?? '';
            String bStatus = b['status'] as String? ?? '';
            return aStatus.compareTo(bStatus);
          }
          return 0;
        });
      } catch (e) {
        debugPrint("Error during sorting: $e");
      }

      return userRides;
    });
  }

  /// Updates ride status in Firestore, handling seat approvals/declines.
  Future<void> _updateRideStatus(
    Map<String, dynamic> ride,
    String newStatus,
  ) async {
    if (_isUpdatingStatus) {
      return; // Prevent double taps
    }
    setState(() => _isUpdatingStatus = true);

    String rideId = ride['id'];
    // List<dynamic> currentLayout = List.from(ride['seatLayout'] ?? []); // Not needed here

    try {
      await _firestore.runTransaction((transaction) async {
        DocumentReference rideRef = _firestore.collection('rides').doc(rideId);
        DocumentSnapshot snapshot = await transaction.get(rideRef);
        if (!snapshot.exists) {
          throw Exception("Ride not found");
        }

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
                s['bookedBy'] != null &&
                (s['bookedBy'] as String).isNotEmpty &&
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
                seat['bookedBy'] != null &&
                (seat['bookedBy'] as String).isNotEmpty &&
                seat['offered'] == true &&
                seat['approvalStatus'] == 'pending') {
              var mutableSeat = Map<String, dynamic>.from(seat);
              mutableSeat['approvalStatus'] = 'declined';
              updatedLayout[i] = mutableSeat;
              changed = true;
            }
          }
          if (changed) {
            debugPrint(
              "Declined pending requests for ride $rideId due to status change to $newStatus",
            );
          }
        }

        // Update status and potentially modified layout
        transaction.update(rideRef, {
          'status': newStatus,
          'seatLayout': updatedLayout, // Use the potentially modified layout
        });
      });

      // If ride completed successfully, clear driver role (run outside transaction)
      if (newStatus == 'completed') {
        await _firestore.collection('users').doc(widget.user.uid).set({
          'role': '',
        }, SetOptions(merge: true));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("تم إكمال الرحلة وتحديث الدور."),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          // --- FIX: Use Colors.blue instead of Colors.info ---
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("تم تحديث حالة الرحلة إلى $newStatus."),
              backgroundColor: Colors.blue,
            ),
          );
        }
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

  /// Builds a ride card with enhanced styling.
  Widget _buildRideCard(Map<String, dynamic> ride) {
    String rideId = ride['id'] ?? 'unknown_id';
    String status = ride['status'] as String? ?? 'unknown';
    String startLocation = ride['startLocationName'] as String? ?? 'N/A';
    String endLocation = ride['endLocationName'] as String? ?? 'N/A';
    Timestamp? ts = ride['date'] as Timestamp?;
    String departureTimeStr = "N/A";
    if (ts != null) {
      try {
        departureTimeStr = DateFormat(
          'EEE, MMM d, yy - hh:mm a',
          'en_US',
        ).format(ts.toDate());
      } catch (e) {
        departureTimeStr = "Invalid Date";
      }
    }

    bool isDriver = ride['driverId'] == widget.user.uid;
    bool isPassenger =
        !isDriver &&
        (ride['seatLayout'] is List &&
            (ride['seatLayout'] as List<dynamic>).any(
              (seat) => seat is Map && seat['bookedBy'] == widget.user.uid,
            ));

    IconData roleIcon = Icons.help_outline;
    Color roleColor = Colors.grey;
    String roleLabel = "غير محدد";
    if (isDriver) {
      roleIcon = Icons.directions_car;
      roleColor = Colors.teal;
      roleLabel = "أنت السائق";
    } else if (isPassenger) {
      roleIcon = Icons.person;
      roleColor = Colors.blue;
      roleLabel = "أنت راكب";
    }

    Color statusColor = Colors.grey;
    switch (status) {
      case 'scheduled':
        statusColor = Colors.blue;
        break;
      case 'started':
        statusColor = Colors.orange;
        break;
      case 'completed':
        statusColor = Colors.green;
        break;
      case 'cancelled':
        statusColor = Colors.red;
        break;
    }

    List<Widget> driverActions = [];
    if (isDriver) {
      if (status == 'scheduled') {
        driverActions.addAll([
          TextButton(
            onPressed:
                _isUpdatingStatus
                    ? null
                    : () => _updateRideStatus(ride, 'cancelled'),
            child: const Text('إلغاء', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed:
                _isUpdatingStatus
                    ? null
                    : () => _updateRideStatus(ride, 'started'),
            child: const Text('بدأت', style: TextStyle(color: Colors.orange)),
          ),
        ]);
      } else if (status == 'started') {
        driverActions.add(
          TextButton(
            onPressed:
                _isUpdatingStatus
                    ? null
                    : () => _updateRideStatus(ride, 'completed'),
            child: const Text('أُكمِلت', style: TextStyle(color: Colors.green)),
          ),
        );
      }
    }

    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (rideId == 'unknown_id') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Cannot open details: Invalid Ride ID.'),
              ),
            );
            return;
          }
          if (isDriver) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => RideManagePage(ride: ride),
              ),
            );
          } else {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => RideDetailPage(rideId: rideId),
              ),
            );
          } // Pass only rideId
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Chip(
                    avatar: Icon(roleIcon, color: roleColor, size: 18),
                    label: Text(roleLabel),
                    backgroundColor: roleColor.withOpacity(0.1),
                    side: BorderSide.none,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    labelStyle: TextStyle(
                      color: roleColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Chip(
                    label: Text(status.toUpperCase()),
                    backgroundColor: statusColor.withOpacity(0.15),
                    side: BorderSide.none,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    labelStyle: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.trip_origin,
                    color: Colors.green.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      startLocation,
                      style: Theme.of(context).textTheme.bodyLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8.0, top: 2, bottom: 2),
                child: Icon(
                  Icons.more_vert,
                  size: 16,
                  color: Colors.grey.shade400,
                ),
              ),
              Row(
                children: [
                  Icon(Icons.location_on, color: Colors.red.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      endLocation,
                      style: Theme.of(context).textTheme.bodyLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.access_time_filled,
                    color: Colors.grey.shade600,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      departureTimeStr,
                      style: TextStyle(color: Colors.grey.shade800),
                    ),
                  ),
                ],
              ),
              if (driverActions.isNotEmpty) ...[
                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: driverActions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Initiates the search UI.
  void _startSearch() async {
    final result = await showSearch<String?>(
      context: context,
      delegate: RideSearchDelegate(),
    );
    if (result != null && mounted) {
      setState(() => searchQuery = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('رحلاتي'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: "بحث",
            onPressed: _startSearch,
          ),
          PopupMenuButton<String>(
            tooltip: "فرز حسب",
            icon: const Icon(Icons.sort),
            onSelected: (value) {
              if (mounted) setState(() => sortBy = value);
            },
            itemBuilder:
                (context) => [
                  PopupMenuItem(
                    value: 'date',
                    child: Text(
                      'فرز حسب التاريخ',
                      style: TextStyle(
                        color:
                            sortBy == 'date'
                                ? Theme.of(context).primaryColor
                                : null,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'status',
                    child: Text(
                      'فرز حسب الحالة',
                      style: TextStyle(
                        color:
                            sortBy == 'status'
                                ? Theme.of(context).primaryColor
                                : null,
                      ),
                    ),
                  ),
                ],
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _ridesStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Error loading rides: ${snapshot.error}'),
            );
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Text(
                  searchQuery.isEmpty
                      ? 'لم يتم العثور على رحلات لك.'
                      : 'لا توجد نتائج مطابقة لبحثك.',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          List<Map<String, dynamic>> rides = snapshot.data!;
          return ListView.builder(
            itemCount: rides.length,
            itemBuilder: (context, index) => _buildRideCard(rides[index]),
          );
        },
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
    if (!mounted || index == _currentIndex) {
      return;
    }
    _navigateToIndex(index);
  }

  void _navigateToIndex(int index) {
    Widget? targetPage;
    bool removeUntil = false;
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      // Use curly braces for clarity
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const GetStartedPage()),
        (route) => false,
      );
      return;
    }

    if (index == _currentIndex) {
      return; // Avoid navigating to the same page
    }

    switch (index) {
      case 0:
        targetPage = HomePage(user: currentUser);
        removeUntil = true;
        break;
      case 1:
        return; // Already on MyRidePage
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
        // Use curly braces
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => targetPage!),
          (route) => false,
        );
      } else {
        // Use curly braces
        Navigator.push(context, MaterialPageRoute(builder: (_) => targetPage!));
      }
      // No need to setState for _currentIndex when navigating away like this
    } else {
      // Use curly braces
      print("Error: Target page was null for index $index");
    }
  }
} // End of _MyRidePageState class

/// A simple search delegate (can be customized further).
class RideSearchDelegate extends SearchDelegate<String?> {
  // Return nullable string
  @override
  String? get searchFieldLabel => "ابحث عن طريق الوجهة، البداية، أو الحالة"; // Set hint text

  @override
  List<Widget>? buildActions(BuildContext context) {
    // Clear button
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
        ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    // Back button
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed:
          () => close(
            context,
            null,
          ), // Close returning null (no search submitted)
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    // Called when user presses search button on keyboard
    // Return the query to the previous page
    WidgetsBinding.instance.addPostFrameCallback((_) {
      close(context, query.trim());
    });
    return Container(); // Return empty container while closing
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    // Optionally show suggestions based on query as user types
    // For now, just show a prompt or recent searches
    return ListTile(
      leading: const Icon(Icons.search),
      title: Text('ابحث عن "$query"'),
      onTap:
          () => close(
            context,
            query.trim(),
          ), // Allow tapping suggestion to search
    );
  }
}

// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   intl: ^...             # For date formatting
//   # Add imports for pages used in navigation (HomePage, MyCarsPage, ChatListPage, RideManagePage, RideDetailPage etc.)
