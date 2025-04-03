import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class RideDetailPage extends StatefulWidget {
  final Map<String, dynamic> ride;
  const RideDetailPage({Key? key, required this.ride}) : super(key: key);

  @override
  _RideDetailPageState createState() => _RideDetailPageState();
}

class _RideDetailPageState extends State<RideDetailPage> {
  late List<Map<String, dynamic>> seatLayout;

  @override
  void initState() {
    super.initState();
    // Make a local copy of seatLayout from the ride data
    seatLayout = List<Map<String, dynamic>>.from(widget.ride['seatLayout']);
  }

  /// Groups the flat seat layout by the "row" field for row-based display
  List<List<Map<String, dynamic>>> groupSeatLayoutByRow() {
    final Map<int, List<Map<String, dynamic>>> grouped = {};
    for (var seat in seatLayout) {
      final row = seat["row"] as int;
      grouped.putIfAbsent(row, () => []);
      grouped[row]!.add(seat);
    }

    final sortedKeys = grouped.keys.toList()..sort();
    return sortedKeys.map((row) => grouped[row]!).toList();
  }

  /// A user can tap a seat to either book or unbook
  Future<void> onSeatTap(Map<String, dynamic> seat) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final currentUserId = currentUser.uid;
    final driverId = widget.ride['driverId'] as String;

    if (seat['type'] == 'driver') {
      // It's the driver's seat, do nothing
      return;
    }

    // If seat not offered, do nothing
    final bool offered = seat['offered'] == true;
    if (!offered) {
      await showDialog(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text("المقعد غير متاح"),
              content: const Text("هذا المقعد غير معروض للمشاركة."),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("حسنًا"),
                ),
              ],
            ),
      );
      return;
    }

    // If user is the driver, do not allow booking
    if (driverId == currentUserId) {
      await showDialog(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text("لا يمكنك حجز مقعد"),
              content: const Text("أنت السائق لهذه الرحلة."),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("حسنًا"),
                ),
              ],
            ),
      );
      return;
    }

    // Check if seat is already booked by current user -> unbook scenario
    if (seat['bookedBy'] == currentUserId) {
      // Prompt user to confirm unbooking
      final confirmUnbook = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text("إلغاء الحجز؟"),
              content: const Text("هل تريد إلغاء حجز هذا المقعد؟"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text("لا"),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text("نعم"),
                ),
              ],
            ),
      );
      if (confirmUnbook != true) return;

      await _runBookingTransaction(seatIndex: seat['seatIndex'], unbook: true);
      return;
    }

    // If seat is booked by someone else
    if (seat['bookedBy'] != null && seat['bookedBy'] != currentUserId) {
      await showDialog(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text("المقعد محجوز"),
              content: const Text("هذا المقعد محجوز من قبل شخص آخر."),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("حسنًا"),
                ),
              ],
            ),
      );
      return;
    }

    // Check if user already booked a seat
    bool alreadyBooked = seatLayout.any((s) => s['bookedBy'] == currentUserId);
    if (alreadyBooked) {
      await showDialog(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text("حجز مسبق"),
              content: const Text("لقد قمت بحجز مقعد بالفعل في هذه الرحلة."),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("حسنًا"),
                ),
              ],
            ),
      );
      return;
    }

    // Prompt user to confirm booking
    final confirmBook = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text("تأكيد الحجز"),
            content: const Text("هل تريد حجز هذا المقعد؟"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("لا"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("نعم"),
              ),
            ],
          ),
    );
    if (confirmBook != true) return;

    // Book seat via concurrency-safe transaction
    await _runBookingTransaction(seatIndex: seat['seatIndex'], unbook: false);
  }

  /// Use a Firestore transaction to handle concurrency
  Future<void> _runBookingTransaction({
    required int seatIndex,
    required bool unbook,
  }) async {
    final rideId = widget.ride['id'];
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;

    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final docRef = FirebaseFirestore.instance
            .collection('rides')
            .doc(rideId);
        final snapshot = await transaction.get(docRef);

        if (!snapshot.exists) {
          throw Exception("Ride no longer exists.");
        }

        final data = snapshot.data() as Map<String, dynamic>;
        List<dynamic> updatedLayout = data['seatLayout'];

        // Find seat in the updated layout
        final seat = updatedLayout.firstWhere(
          (s) => s['seatIndex'] == seatIndex,
          orElse: () => null,
        );
        if (seat == null) {
          throw Exception("Seat not found in layout.");
        }

        if (unbook) {
          // If unbooking
          if (seat['bookedBy'] == currentUserId) {
            seat['bookedBy'] = null;
            seat['approvalStatus'] = "pending";
          } else {
            throw Exception("Cannot unbook a seat that you haven't booked.");
          }
        } else {
          // If booking
          // Check if seat is free
          if (seat['bookedBy'] != null) {
            throw Exception("This seat has just been booked. Try again.");
          }
          seat['bookedBy'] = currentUserId;
          seat['approvalStatus'] = "pending";
        }

        transaction.update(docRef, {'seatLayout': updatedLayout});
      });
      if (unbook) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("تم إلغاء الحجز بنجاح.")));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("تم حجز المقعد بنجاح. ينتظر السائق الموافقة."),
          ),
        );
      }

      // Locally update seatLayout as well
      setState(() {
        final seat = seatLayout.firstWhere((s) => s['seatIndex'] == seatIndex);
        if (unbook) {
          seat['bookedBy'] = null;
          seat['approvalStatus'] = "pending";
        } else {
          seat['bookedBy'] = currentUserId;
          seat['approvalStatus'] = "pending";
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("خطأ في المعاملة: $e")));
    }
  }

  /// Fetch occupant info (name, image) from users collection
  Future<Map<String, dynamic>?> fetchOccupantInfo(String userId) async {
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(userId).get();
    if (!doc.exists) return null;
    return doc.data();
  }

  /// This method returns a FutureBuilder that fetches occupant info and displays a mini avatar
  Widget occupantAvatar(String occupantId) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: fetchOccupantInfo(occupantId),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }
        if (!snap.hasData || snap.data == null) {
          return const Icon(Icons.person, size: 24, color: Colors.grey);
        }
        final occupantData = snap.data!;
        final occupantName = occupantData['name'] as String? ?? '???';
        final occupantImage = occupantData['imageUrl'] as String? ?? '';
        return Row(
          children: [
            occupantImage.isNotEmpty
                ? CircleAvatar(
                  radius: 12,
                  backgroundImage: NetworkImage(occupantImage),
                )
                : const Icon(Icons.person, size: 24, color: Colors.grey),
            const SizedBox(width: 4),
            Text(occupantName, style: const TextStyle(fontSize: 12)),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Group seat layout by row
    final groupedLayout = groupSeatLayoutByRow();

    // Build ride repetition info
    String repeatInfo = "مرة واحدة";
    if (widget.ride['repeat'] == 'daily') {
      repeatInfo = "يوميًا";
    } else if (widget.ride['repeat'] == 'daysOfWeek') {
      final daysList = widget.ride['days'] as List<dynamic>? ?? [];
      // E.g. 0=Sun, 1=Mon, ... or however you handle day indexing
      const dayNames = [
        "الأحد",
        "الاثنين",
        "الثلاثاء",
        "الأربعاء",
        "الخميس",
        "الجمعة",
        "السبت",
      ];
      List<String> selectedDays = [];
      for (var d in daysList) {
        if (d is int && d >= 0 && d < dayNames.length) {
          selectedDays.add(dayNames[d]);
        }
      }
      repeatInfo = "أيام الأسبوع: ${selectedDays.join(', ')}";
    }

    // Smoking preference
    final bool smokingAllowed = widget.ride['preferences']?['smoking'] == true;

    return Scaffold(
      appBar: AppBar(title: const Text("تفاصيل الرحلة")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Basic ride info
            Text(
              "السائق: ${widget.ride['driverId']}",
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              "السيارة: ${widget.ride['carId']}",
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              "سعر المقعد: ${widget.ride['price']}",
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              "التدخين: ${smokingAllowed ? 'مسموح' : 'غير مسموح'}",
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              "نقطة البداية: ${widget.ride['startLocationName']}",
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              "الوجهة: ${widget.ride['endLocationName']}",
              style: const TextStyle(fontSize: 16),
            ),
            Text("التكرار: $repeatInfo", style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            if (widget.ride['date'] != null)
              Text(
                "تاريخ المغادرة: ${widget.ride['date'].toDate().toString()}",
                style: const TextStyle(fontSize: 16),
              ),
            const SizedBox(height: 16),

            // Title for seat layout
            const Text(
              "تخطيط المقاعد:",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            // Interactive seat layout
            Column(
              children:
                  groupedLayout.map((row) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children:
                            row.map((seat) {
                              final seatIndex = seat['seatIndex'] as int;
                              final type = seat['type'] as String? ?? 'share';
                              final occupantId = seat['bookedBy'] as String?;
                              final occupantWidget =
                                  occupantId != null
                                      ? occupantAvatar(occupantId)
                                      : const SizedBox();

                              String label;
                              IconData icon;
                              Color color;

                              if (type == "driver") {
                                label = "سائق";
                                icon = Icons.person;
                                color = Colors.blueAccent;
                              } else {
                                // offered?
                                final bool isOffered =
                                    (seat['offered'] == true);
                                if (!isOffered) {
                                  label = "غير متاح";
                                  icon = Icons.close;
                                  color = Colors.grey;
                                } else if (occupantId != null) {
                                  label = "محجوز";
                                  icon = Icons.event_seat;
                                  color = Colors.grey;
                                } else {
                                  label = "مشاركة";
                                  icon = Icons.event_seat;
                                  color = Theme.of(context).primaryColor;
                                }
                              }

                              return InkWell(
                                onTap:
                                    type == "driver"
                                        ? null
                                        : () => onSeatTap(seat),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8.0,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(icon, color: color, size: 32),
                                      const SizedBox(height: 4),
                                      Text(
                                        label,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      const SizedBox(height: 4),
                                      occupantWidget, // shows occupant name & image if booked
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                      ),
                    );
                  }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
