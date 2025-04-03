import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'get_started_page.dart';
import 'add_car.dart' as add_car;
import 'CreateRide.dart';
import 'ride_details_page.dart';
import 'my_cars.dart';
import 'mymessage.dart';
import 'phone_number_page.dart';
import 'package:url_launcher/url_launcher.dart';

class HomePage extends StatefulWidget {
  final User user;
  const HomePage({super.key, required this.user});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _phoneNumberChecked = false;
  late Future<List<Map<String, dynamic>>> ridesFuture;

  @override
  void initState() {
    super.initState();
    _checkPhone();
    ridesFuture = fetchAvailableRidesWithDriver();
  }

  /// Check if user has a phone field; if not, navigate to phone entry.
  Future<void> _checkPhone() async {
    DocumentSnapshot userDoc =
        await FirebaseFirestore.instance
            .collection('users') // Updated
            .doc(widget.user.uid)
            .get();
    final data = userDoc.data() as Map<String, dynamic>?;
    final phone = data?['phone'] as String?; // Updated field name

    if (phone == null || phone.isEmpty) {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const PhoneNumberEntryPage()),
        );
      }
    } else {
      setState(() {
        _phoneNumberChecked = true;
      });
    }
  }

  /// Fetch rides where 'status' is 'scheduled'; exclude current user's rides.
  Future<List<Map<String, dynamic>>> fetchAvailableRidesWithDriver() async {
    String currentUserId = FirebaseAuth.instance.currentUser!.uid;
    // Updated: search 'rides' collection, look for status == 'scheduled'
    QuerySnapshot ridesSnapshot =
        await FirebaseFirestore.instance
            .collection('rides')
            .where('status', isEqualTo: 'scheduled')
            .get();

    List<Map<String, dynamic>?> rides = await Future.wait(
      ridesSnapshot.docs.map<Future<Map<String, dynamic>?>>((rideDoc) async {
        Map<String, dynamic> rideData = {
          'id': rideDoc.id,
          ...rideDoc.data() as Map<String, dynamic>,
        };

        // Updated: Exclude if driverId == current user
        if (rideData['driverId'] == currentUserId) return null;

        // Fetch driver info from 'users' collection
        DocumentSnapshot driverDoc =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(rideData['driverId'])
                .get();

        if (driverDoc.exists) {
          rideData['driver'] = driverDoc.data();
        }
        return rideData;
      }),
    );

    // Remove null items
    rides.removeWhere((ride) => ride == null);
    return rides.cast<Map<String, dynamic>>();
  }

  /// Sign out logic
  Future<void> _signOut(BuildContext context) async {
    final googleSignIn = GoogleSignIn();
    await googleSignIn.signOut();
    await FirebaseAuth.instance.signOut();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const GetStartedPage()),
    );
  }

  /// Call driver
  void callDriver(String phone) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to make the call.')),
        );
      }
    }
  }

  /// Chat with driver (WhatsApp)
  void chatWithDriver(String phone) async {
    final Uri launchUri = Uri.parse("https://wa.me/$phone");
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open WhatsApp.')),
        );
      }
    }
  }

  /// Navigate to ride details page
  void navigateToRideDetails(Map<String, dynamic> ride) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => RideDetailPage(ride: ride)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_phoneNumberChecked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.green.shade700,
        child: const Icon(Icons.add_road),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => CreateRidePage()),
          );
        },
      ),
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              expandedHeight: 200.0,
              floating: false,
              pinned: true,
              flexibleSpace: FlexibleSpaceBar(
                title: const Text(
                  'رحلات متاحة',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      'https://images.unsplash.com/photo-1449965408869-eaa3f722e40d?crop=entropy&cs=tinysrgb&fit=crop&fm=jpg&h=900&ixid=MnwxfDB8MXxyYW5kb218MHx8Y2FyfHx8fHx8MTY0MzM4Njg5NA&ixlib=rb-1.2.1&q=80&utm_campaign=api-credit&utm_medium=referral&utm_source=unsplash_source&w=1600',
                      fit: BoxFit.cover,
                      errorBuilder:
                          (ctx, obj, st) => Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.green.shade900,
                                  Colors.green.shade700,
                                ],
                              ),
                            ),
                          ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.7),
                            Colors.black.withOpacity(0.3),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.add, color: Colors.white),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => CreateRidePage()),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.white),
                  onPressed: () => _signOut(context),
                ),
              ],
            ),
          ];
        },
        body: RefreshIndicator(
          onRefresh: () async {
            setState(() {
              ridesFuture = fetchAvailableRidesWithDriver();
            });
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildUserProfileCard(),
                  const SizedBox(height: 24),
                  _buildQuickActionsRow(),
                  const SizedBox(height: 24),
                  _buildRidesList(),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        selectedItemColor: Colors.green.shade700,
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'الرئيسية'),
          BottomNavigationBarItem(
            icon: Icon(Icons.car_rental),
            label: 'سياراتي',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.message), label: 'الرسائل'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'حسابي'),
        ],
        currentIndex: 0,
        onTap: (index) {
          if (index == 1) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const MyCarsPage()),
            );
          } else if (index == 2) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const MyMessagesPage()),
            );
          } else if (index == 3) {
            // Add profile navigation here
          }
        },
      ),
    );
  }

  Widget _buildUserProfileCard() {
    return FutureBuilder<DocumentSnapshot>(
      future:
          FirebaseFirestore.instance
              .collection('users') // Updated
              .doc(widget.user.uid)
              .get(),
      builder: (context, snapshot) {
        String? imageUrl =
            snapshot.data?.get('imageUrl') ?? widget.user.photoURL;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.green.shade500, Colors.green.shade700],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.green.shade200.withOpacity(0.5),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: Colors.white,
                backgroundImage:
                    (imageUrl != null && imageUrl.isNotEmpty)
                        ? NetworkImage(imageUrl)
                        : null,
                child:
                    (imageUrl == null || imageUrl.isEmpty)
                        ? const Icon(Icons.person, size: 40, color: Colors.grey)
                        : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'مرحباً, ${widget.user.displayName ?? 'مستخدم'}',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'ابحث عن الرحلات المتاحة أو شارك رحلتك الخاصة',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuickActionsRow() {
    return SizedBox(
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _buildActionCard(
            Icons.add_circle_outline,
            'إضافة سيارة',
            Colors.blue,
            () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const add_car.AddCarPage(),
              ),
            ),
          ),
          _buildActionCard(
            Icons.car_rental,
            'سياراتي',
            Colors.orange,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const MyCarsPage()),
            ),
          ),
          _buildActionCard(
            Icons.message,
            'الرسائل',
            Colors.purple,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const MyMessagesPage()),
            ),
          ),
          _buildActionCard(
            Icons.add_road,
            'إنشاء رحلة',
            Colors.green,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => CreateRidePage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 90,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.shade300,
                blurRadius: 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 30),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade800,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRidesList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'الرحلات المتاحة',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  ridesFuture = fetchAvailableRidesWithDriver();
                });
              },
              child: Row(
                children: [
                  Icon(Icons.refresh, size: 16, color: Colors.green.shade700),
                  const SizedBox(width: 4),
                  Text('تحديث', style: TextStyle(color: Colors.green.shade700)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: ridesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32.0),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return Center(
                child: Column(
                  children: [
                    const SizedBox(height: 30),
                    Icon(
                      Icons.no_transfer,
                      size: 80,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'لا توجد رحلات متاحة حالياً',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('إنشاء رحلة جديدة'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => CreateRidePage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            }
            List<Map<String, dynamic>> rides = snapshot.data!;
            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: rides.length,
              itemBuilder: (context, index) {
                var ride = rides[index];
                // The ride doc includes 'driver' as a sub-map
                Map<String, dynamic>? driver =
                    ride['driver'] as Map<String, dynamic>?;
                return _buildEnhancedRideCard(
                  ride: ride,
                  driver: driver,
                  onCall: () {
                    if (driver != null &&
                        (driver['phone'] as String?)?.isNotEmpty == true) {
                      // Updated 'phone'
                      callDriver(driver['phone'] as String);
                    }
                  },
                  onChat: () {
                    if (driver != null &&
                        (driver['phone'] as String?)?.isNotEmpty == true) {
                      // Updated 'phone'
                      chatWithDriver(driver['phone'] as String);
                    }
                  },
                  onDetails: () => navigateToRideDetails(ride),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildEnhancedRideCard({
    required Map<String, dynamic> ride,
    required Map<String, dynamic>? driver,
    required VoidCallback onCall,
    required VoidCallback onChat,
    required VoidCallback onDetails,
  }) {
    // Rename fields to match your updated DB structure
    String startingPoint = ride['startLocationName'] as String? ?? 'N/A';
    String destination = ride['endLocationName'] as String? ?? 'N/A';
    num seatPrice = ride['price'] as num? ?? 0;
    // For seat availability, you might have to derive from seatLayout
    // (like counting seats that are not booked). We'll keep seatsAvailable = 3 as placeholder.
    int seatsAvailable = 3;

    // If you store a 'driverName' in driver doc, or just use 'displayName'
    String driverName = driver?['displayName'] as String? ?? 'Unknown Driver';
    String driverPhoto = driver?['imageUrl'] as String? ?? '';

    // Departure time
    String departureTime = 'N/A';
    Timestamp? timestamp = ride['date'] as Timestamp?;
    if (timestamp != null) {
      DateTime dateTime = timestamp.toDate();
      departureTime =
          '${dateTime.day}/${dateTime.month},'
          ' ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onDetails,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Driver row
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.grey.shade200,
                      backgroundImage:
                          driverPhoto.isNotEmpty
                              ? NetworkImage(driverPhoto)
                              : null,
                      child:
                          driverPhoto.isEmpty
                              ? const Icon(
                                Icons.person,
                                size: 32,
                                color: Colors.grey,
                              )
                              : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            driverName,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.star,
                                size: 16,
                                color: Colors.amber,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '4.8', // Placeholder rating
                                style: TextStyle(
                                  color: Colors.grey.shade700,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                Icons.access_time,
                                size: 16,
                                color: Colors.grey.shade600,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                departureTime,
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Price & seats
                    Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.attach_money,
                                size: 16,
                                color: Colors.green.shade800,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '$seatPrice',
                                style: TextStyle(
                                  color: Colors.green.shade800,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.event_seat,
                                size: 16,
                                color: Colors.blue.shade800,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '$seatsAvailable',
                                style: TextStyle(
                                  color: Colors.blue.shade800,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Start -> End
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Column(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 16,
                            color: Colors.green.shade700,
                          ),
                          Container(
                            height: 30,
                            width: 2,
                            color: Colors.grey.shade300,
                          ),
                          const Icon(
                            Icons.location_on,
                            size: 16,
                            color: Colors.red,
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              startingPoint,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              destination,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Call & Chat
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.phone),
                        label: const Text('اتصال'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.green.shade700,
                          side: BorderSide(color: Colors.green.shade700),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: onCall,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.chat),
                        label: const Text('دردشة'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: onChat,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
