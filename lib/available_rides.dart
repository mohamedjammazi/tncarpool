import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'ride_details_page.dart';

class AvailableRidesPage extends StatefulWidget {
  const AvailableRidesPage({super.key});

  @override
  _AvailableRidesPageState createState() => _AvailableRidesPageState();
}

class _AvailableRidesPageState extends State<AvailableRidesPage> {
  late Future<List<Map<String, dynamic>>> ridesFuture;

  @override
  void initState() {
    super.initState();
    ridesFuture = fetchAvailableRidesWithDriver();
  }

  /// Fetch rides with status "available" (excluding current user’s own rides)
  /// and attach the driver details from the Users collection.
  Future<List<Map<String, dynamic>>> fetchAvailableRidesWithDriver() async {
    String currentUserId = FirebaseAuth.instance.currentUser!.uid;

    QuerySnapshot ridesSnapshot =
        await FirebaseFirestore.instance
            .collection('Rides')
            .where('rideStatus', isEqualTo: 'available')
            .get();

    // Use Future.wait with a nullable type.
    List<Map<String, dynamic>?> rides = await Future.wait(
      ridesSnapshot.docs.map<Future<Map<String, dynamic>?>>((rideDoc) async {
        Map<String, dynamic> rideData = {
          'id': rideDoc.id,
          ...rideDoc.data() as Map<String, dynamic>,
        };

        // Exclude rides created by the current user.
        if (rideData['userId'] == currentUserId) return null;

        // Fetch driver details from the Users collection.
        DocumentSnapshot driverDoc =
            await FirebaseFirestore.instance
                .collection('Users')
                .doc(rideData['userId'])
                .get();

        if (driverDoc.exists) {
          rideData['driver'] = driverDoc.data();
        }
        return rideData;
      }),
    );

    // Remove any null rides.
    rides.removeWhere((ride) => ride == null);
    return rides.cast<Map<String, dynamic>>();
  }

  // Launch phone dialer to call the driver.
  void callDriver(String phoneNumber) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to make the call.')));
    }
  }

  // Launch WhatsApp chat with the driver.
  void chatWithDriver(String phoneNumber) async {
    final Uri launchUri = Uri.parse("https://wa.me/$phoneNumber");
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to open WhatsApp.')));
    }
  }

  // Navigate to the full Ride Details Page.
  void navigateToRideDetails(Map<String, dynamic> ride) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => RideDetailPage(ride: ride)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Available Rides'), centerTitle: true),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: ridesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(
              child: Text('No rides available at the moment.'),
            );
          }

          List<Map<String, dynamic>> rides = snapshot.data!;

          return ListView.builder(
            itemCount: rides.length,
            itemBuilder: (context, index) {
              var ride = rides[index];
              Map<String, dynamic>? driver =
                  ride['driver'] as Map<String, dynamic>?;
              return RideCard(
                ride: ride,
                driver: driver,
                onCall: () {
                  if (driver != null &&
                      (driver['phoneNumber'] as String?)?.isNotEmpty == true) {
                    callDriver(driver['phoneNumber'] as String);
                  }
                },
                onChat: () {
                  if (driver != null &&
                      (driver['phoneNumber'] as String?)?.isNotEmpty == true) {
                    chatWithDriver(driver['phoneNumber'] as String);
                  }
                },
                // onDetails is called when the card is tapped.
                onDetails: () => navigateToRideDetails(ride),
              );
            },
          );
        },
      ),
    );
  }
}

/// Custom widget for a ride card with a modern design.
class RideCard extends StatelessWidget {
  final Map<String, dynamic> ride;
  final Map<String, dynamic>? driver;
  final VoidCallback onCall;
  final VoidCallback onChat;
  final VoidCallback onDetails;

  const RideCard({
    super.key,
    required this.ride,
    required this.driver,
    required this.onCall,
    required this.onChat,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    String startingPoint = ride['startingPoint'] as String? ?? 'N/A';
    String destination = ride['destination'] as String? ?? 'N/A';
    int seatsAvailable = ride['seatsAvailable'] as int? ?? 0;
    num seatPrice = ride['seatPrice'] as num? ?? 0;
    String driverName = driver?['displayName'] as String? ?? 'Unknown Driver';
    String driverPhoto =
        driver?['photoURL'] as String? ??
        'https://via.placeholder.com/150'; // default placeholder

    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onDetails,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Driver's image.
              CircleAvatar(
                radius: 30,
                backgroundImage: NetworkImage(driverPhoto),
              ),
              const SizedBox(width: 12),
              // Ride & Driver information.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driverName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$startingPoint → $destination',
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.event_seat,
                          size: 16,
                          color: Colors.grey,
                        ),
                        const SizedBox(width: 4),
                        Text('$seatsAvailable seats'),
                        const SizedBox(width: 16),
                        Icon(
                          Icons.attach_money,
                          size: 16,
                          color: Colors.grey.shade700,
                        ),
                        const SizedBox(width: 4),
                        Text('$seatPrice per seat'),
                      ],
                    ),
                  ],
                ),
              ),
              // Action buttons for call and chat.
              Column(
                children: [
                  IconButton(
                    tooltip: 'Call Driver',
                    icon: const Icon(Icons.phone, color: Colors.green),
                    onPressed: onCall,
                  ),
                  IconButton(
                    tooltip: 'Chat via WhatsApp',
                    icon: const Icon(Icons.chat, color: Colors.blue),
                    onPressed: onChat,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
