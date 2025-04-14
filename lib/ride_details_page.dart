import 'dart:math'; // For max function
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'; // For Rewarded Ads
import 'package:intl/intl.dart'; // For Date Formatting
import 'package:url_launcher/url_launcher.dart';
import 'chat_list_page.dart';
// Import Helpers and Pages
import 'chat_helpers.dart'; // Assuming this file exists and defines createOrGetChatRoom
import 'chat_detail_page.dart';
import 'home_page.dart';
import 'my_ride_page.dart';
import 'my_cars.dart';
import 'get_started_page.dart'; // For navigation fallback
// Import the reusable SeatLayoutWidget
import 'widgets/seat_layout_widget.dart'; // Adjust path if needed

class RideDetailPage extends StatefulWidget {
  final String rideId;

  const RideDetailPage({super.key, required this.rideId});

  @override
  State<RideDetailPage> createState() => _RideDetailPageState();
}

class _RideDetailPageState extends State<RideDetailPage> {
  // --- State Variables ---
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  String? _currentUserId;

  // Ride Header Data (fetched once)
  Map<String, dynamic>? _driverData;
  Map<String, dynamic>? _carData;
  Map<String, dynamic>? _ridePreferences;
  Timestamp? _rideDepartureTimestamp;
  String _rideStartLocationName = '';
  String _rideEndLocationName = '';
  String _rideRepeatInfo = '';
  double _ridePrice = 0.0;
  int _carSeatCount = 0;

  bool _isHeaderLoading = true;
  bool _isBookingSeat = false; // Used for both booking and unbooking

  // Gold & Ad State
  int _userGold = 0;
  bool _isUpdatingGold =
      false; // Indicator specifically for gold updates (grant/deduct/refund)
  final String _rewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917'; // Test ID
  RewardedAd? _rewardedAd;
  bool _isRewardedAdLoading = false;
  final int _goldRewardAmount = 2;
  final int _maxAdsPerHour = 10;
  List<Timestamp> _rewardedAdTimestamps = [];
  bool _canWatchRewardedAd = true;
  final int _bookSeatCost = 2;

  // Seat Selection State
  Set<int> _myBookedSeatIndices = {};

  // Bottom Nav State
  int _currentIndex = 0; // Default to Home index visually

  // Asset Paths
  final String _driverSeatImagePath = 'assets/images/DRIVERSEAT.png';
  final String _passengerSeatImagePath = 'assets/images/PASSENGER SEAT.png';

  @override
  void initState() {
    super.initState();
    _currentUserId = _auth.currentUser?.uid;
    _loadInitialData();
    _loadRewardedAd();
  }

  @override
  void dispose() {
    // Dispose resources
    _rewardedAd?.dispose();
    super.dispose();
  }

  // --- Data Fetching ---

  Future<void> _loadInitialData() async {
    if (!mounted) return;
    setState(() => _isHeaderLoading = true);
    try {
      // Fetch user data (gold, timestamps) first
      await _fetchUserData();

      // Fetch ride document to get driverId, carId etc.
      final rideDoc =
          await _firestore.collection('rides').doc(widget.rideId).get();
      if (!mounted || !rideDoc.exists) {
        throw Exception("Ride not found.");
      }
      final rideData = rideDoc.data() as Map<String, dynamic>;

      // Fetch driver and car details based on IDs from rideData
      await _fetchRideHeaderDetails(rideData);
    } catch (e) {
      debugPrint("Error loading initial ride details data: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error loading ride details: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
        // Optionally pop the page if essential data fails to load
        // Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() => _isHeaderLoading = false);
      }
    }
  }

  /// Fetches Driver and Car details based on IDs in rideData
  Future<void> _fetchRideHeaderDetails(Map<String, dynamic> rideData) async {
    final driverId = rideData['driverId'] as String?;
    final carId = rideData['carId'] as String?;

    if (driverId == null || driverId.isEmpty) {
      throw Exception("Ride data missing driverId.");
    }

    // Fetch driver and car docs concurrently
    final results = await Future.wait([
      _firestore.collection('users').doc(driverId).get(), // Always fetch driver
      if (carId != null && carId.isNotEmpty)
        _firestore.collection('cars').doc(carId).get()
      else
        Future.value(null), // Fetch car only if ID exists
    ]);

    if (!mounted) return;

    // Process Driver Data
    final driverDoc = results[0] as DocumentSnapshot?; // First result is driver
    _driverData =
        driverDoc?.exists ?? false
            ? driverDoc!.data() as Map<String, dynamic>?
            : {
              'name': 'Unknown Driver',
              'id': driverId,
            }; // Store ID even if doc missing

    // Process Car Data
    final carDoc =
        (results.length > 1 ? results[1] : null)
            as DocumentSnapshot?; // Second result is car (if fetched)
    _carData =
        carDoc?.exists ?? false
            ? carDoc!.data() as Map<String, dynamic>?
            : {'plateNumber': 'Unknown Car'};
    _carSeatCount =
        (_carData?['seatCount'] as int?) ?? 0; // Get seat count from car

    // Store other ride details in state
    _ridePreferences = rideData['preferences'] as Map<String, dynamic>? ?? {};
    _rideDepartureTimestamp = rideData['date'] as Timestamp?;
    _rideStartLocationName = rideData['startLocationName'] as String? ?? 'N/A';
    _rideEndLocationName = rideData['endLocationName'] as String? ?? 'N/A';
    _ridePrice = (rideData['price'] as num?)?.toDouble() ?? 0.0;
    _rideRepeatInfo = _formatRepeatInfo(rideData['repeat'], rideData['days']);

    // Trigger rebuild with fetched data
    setState(() {});
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

  /// Fetches user's gold and ad timestamps.
  Future<void> _fetchUserData() async {
    try {
      if (_currentUserId == null) {
        print("FetchUserData: No user logged in.");
        if (mounted) {
          setState(() {
            _userGold = 0;
            _rewardedAdTimestamps = [];
            _checkAdLimit();
          });
        }
        return;
      }
      final userDoc =
          await _firestore.collection('users').doc(_currentUserId!).get();
      if (mounted && userDoc.exists) {
        final data = userDoc.data() ?? {};
        final fetchedGold = (data['gold'] ?? 0).toInt();
        final fetchedTimestamps = List<Timestamp>.from(
          data['rewardedAdTimestamps'] ?? [],
        );
        if (mounted) {
          setState(() {
            _userGold = fetchedGold;
            _rewardedAdTimestamps = fetchedTimestamps;
          });
          _checkAdLimit();
        }
      } else if (mounted) {
        print("FetchUserData: User document not found for $_currentUserId.");
        setState(() {
          _userGold = 0;
          _rewardedAdTimestamps = [];
          _checkAdLimit();
        });
      }
    } catch (e) {
      debugPrint("Error fetching user data: $e");
      if (mounted) {
        // Optionally show an error message
        _checkAdLimit(); // Check limit even on error with potentially stale data
      }
    }
  }

  /// Fetches info for a specific occupant (used in old layout, potentially reusable).
  Future<Map<String, dynamic>?> _fetchOccupantInfo(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      return doc.exists ? doc.data() as Map<String, dynamic> : null;
    } catch (e) {
      debugPrint("Error fetching occupant info for $userId: $e");
      return null;
    }
  }

  // --- Gold & Rewarded Ad Methods ---
  void _checkAdLimit() {
    if (!mounted) return;
    final now = DateTime.now();
    final oneHourAgo = now.subtract(const Duration(hours: 1));
    final recentTimestamps =
        _rewardedAdTimestamps
            .where((ts) => ts.toDate().isAfter(oneHourAgo))
            .toList();
    final bool canWatch = recentTimestamps.length < _maxAdsPerHour;
    if (_canWatchRewardedAd != canWatch) {
      setState(() => _canWatchRewardedAd = canWatch);
    }
    debugPrint(
      'Ad Limit Check: ${recentTimestamps.length}/$_maxAdsPerHour ads watched. Can watch: $_canWatchRewardedAd',
    );
  }

  void _loadRewardedAd() {
    if (_isRewardedAdLoading) return;
    setState(() => _isRewardedAdLoading = true);
    debugPrint('Loading Rewarded Ad...');
    RewardedAd.load(
      adUnitId: _rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          debugPrint('Rewarded Ad loaded.');
          _rewardedAd?.dispose();
          _rewardedAd = ad;
          _isRewardedAdLoading = false;
          _setRewardedAdCallbacks();
        },
        onAdFailedToLoad: (LoadAdError error) {
          debugPrint('Rewarded Ad failed load: $error');
          _rewardedAd = null;
          _isRewardedAdLoading = false;
        },
      ),
    );
  }

  void _setRewardedAdCallbacks() {
    _rewardedAd?.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (RewardedAd ad) {
        print('Ad showed.');
      },
      onAdDismissedFullScreenContent: (RewardedAd ad) {
        print('Ad dismissed.');
        ad.dispose();
        _rewardedAd = null;
        _loadRewardedAd(); // Load next ad
      },
      onAdFailedToShowFullScreenContent: (RewardedAd ad, AdError error) {
        print('Ad failed show: $error'); // Use 'error' here
        ad.dispose();
        _rewardedAd = null;
        _loadRewardedAd(); // Load next ad
      },
      onAdImpression: (RewardedAd ad) {
        print('Ad impression.');
      },
    );
  }

  void _showRewardedAd() {
    _checkAdLimit();
    if (!_canWatchRewardedAd) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'You have reached the limit of $_maxAdsPerHour rewarded ads per hour. Please try again later.',
            ),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      return;
    }
    if (_rewardedAd == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Reward ad not ready. Loading... Please try again shortly.',
            ),
          ),
        );
      }
      if (!_isRewardedAdLoading) {
        _loadRewardedAd();
      }
      return;
    }
    _setRewardedAdCallbacks();
    _rewardedAd!.show(
      onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {
        print('User earned reward: ${reward.amount} ${reward.type}');
        _grantGoldReward();
      },
    );
    _rewardedAd = null; // Consume ad
  }

  Future<void> _grantGoldReward() async {
    if (!mounted || _currentUserId == null) return;
    setState(() => _isUpdatingGold = true);
    final Timestamp currentTime = Timestamp.now();
    try {
      final userRef = _firestore.collection('users').doc(_currentUserId!);
      await userRef.update({
        'gold': FieldValue.increment(_goldRewardAmount),
        'rewardedAdTimestamps': FieldValue.arrayUnion([currentTime]),
      });
      if (mounted) {
        setState(() {
          _userGold += _goldRewardAmount;
          _rewardedAdTimestamps.add(currentTime); // Update local list too
          _isUpdatingGold = false;
        });
        _checkAdLimit(); // Re-check limit immediately
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$_goldRewardAmount Gold Added! Total: $_userGold'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error updating gold/timestamp after reward: $e");
      if (mounted) {
        setState(() => _isUpdatingGold = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update gold: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
        _fetchUserData(); // Re-sync on error
      }
    }
  }

  // --- Seat Booking Logic ---

  /// Handles the gold cost check and deduction for booking a seat.
  Future<bool> _handleBookSeatGoldCost() async {
    if (_userGold < _bookSeatCost) {
      if (!mounted) return false;
      final watchAd = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => AlertDialog(
              title: const Text('Insufficient Gold'),
              content: Text(
                'Booking a seat costs $_bookSeatCost gold. You have $_userGold.\n\nWatch an ad to earn $_goldRewardAmount gold?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.green),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Watch Ad & Earn'),
                ),
              ],
            ),
      );
      if (watchAd == true && mounted) {
        _showRewardedAd();
      }
      return false;
    } else {
      if (!mounted) return false;
      setState(() => _isUpdatingGold = true);
      try {
        if (_currentUserId == null) throw Exception("User not logged in");
        final userRef = _firestore.collection('users').doc(_currentUserId!);
        await userRef.update({'gold': FieldValue.increment(-_bookSeatCost)});
        if (mounted) {
          setState(() {
            _userGold -= _bookSeatCost;
            _isUpdatingGold = false;
          });
          return true;
        }
        return false;
      } catch (e) {
        debugPrint("Error deducting gold for booking: $e");
        if (mounted) {
          setState(() => _isUpdatingGold = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error processing payment: $e'),
              backgroundColor: Colors.red,
            ),
          );
          _fetchUserData();
        }
        return false;
      }
    }
  }

  /// Refunds gold after a successful unbooking.
  Future<void> _refundBookingGold() async {
    if (!mounted || _currentUserId == null) return;
    setState(() => _isUpdatingGold = true);
    try {
      final userRef = _firestore.collection('users').doc(_currentUserId!);
      await userRef.update({
        'gold': FieldValue.increment(_bookSeatCost),
      }); // Add gold back
      if (mounted) {
        setState(() {
          _userGold += _bookSeatCost;
          _isUpdatingGold = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("$_bookSeatCost Gold refunded for unbooking."),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error refunding gold: $e");
      if (mounted) {
        setState(() => _isUpdatingGold = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error processing refund: $e"),
            backgroundColor: Colors.red,
          ),
        );
        _fetchUserData(); // Re-sync gold on error
      }
    }
  }

  Future<bool> _checkDriverRideConflict(DateTime rideToBookStartTime) async {
    if (_currentUserId == null) return false;
    try {
      final threeHours = const Duration(hours: 3);
      final query =
          await _firestore
              .collection('rides')
              .where('driverId', isEqualTo: _currentUserId)
              .where('status', whereIn: ['scheduled', 'ongoing'])
              .where(
                'date',
                isGreaterThanOrEqualTo: Timestamp.fromDate(
                  DateTime.now().subtract(const Duration(hours: 1)),
                ),
              )
              .get();
      if (query.docs.isEmpty) return false;
      for (var doc in query.docs) {
        final driverRideStartTimeStamp = doc.data()['date'] as Timestamp?;
        if (driverRideStartTimeStamp != null) {
          final driverRideStartTime = driverRideStartTimeStamp.toDate();
          final difference =
              rideToBookStartTime.difference(driverRideStartTime).abs();
          if (difference < threeHours) {
            debugPrint(
              "Conflict found: User is driving ride ${doc.id} starting at $driverRideStartTime which is within 3 hours of $rideToBookStartTime.",
            );
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint("Error checking driver ride conflict: $e");
      return false;
    }
  }

  /// Handles seat tap: unbooking own seat or booking an available seat.
  Future<void> _handleSeatSelection(int seatIndex) async {
    if (_currentUserId == null || _isBookingSeat) return;

    final rideSnapshot =
        await _firestore.collection('rides').doc(widget.rideId).get();
    if (!rideSnapshot.exists || !mounted) return;
    final rideData = rideSnapshot.data() as Map<String, dynamic>;
    final seatLayout = List<Map<String, dynamic>>.from(
      rideData['seatLayout'] ?? [],
    );
    final seat = seatLayout.firstWhere(
      (s) => s['seatIndex'] == seatIndex,
      orElse: () => {},
    );

    if (seat.isEmpty) {
      print("Seat index $seatIndex not found in layout.");
      return;
    }

    final String type = seat['type'] as String? ?? '';
    final bool isOffered = seat['offered'] as bool? ?? false;
    final String bookedBy =
        seat['bookedBy'] as String? ?? 'n/a'; // Use "n/a" as empty

    // 1. Tapped own booked seat: Start Unbooking Flow
    if (bookedBy == _currentUserId) {
      final unbookChoice = await showDialog<String>(
        // Return 'unbook_only', 'unbook_ad', or null
        context: context,
        barrierDismissible: false,
        builder:
            (ctx) => AlertDialog(
              title: const Text("إلغاء الحجز؟"),
              content: Text(
                "هل أنت متأكد من رغبتك في إلغاء حجز هذا المقعد؟\n\n يمكنك مشاهدة إعلان الآن لكسب $_goldRewardAmount ذهب بدلاً من الاسترداد.",
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text("إبقاء الحجز"),
                ), // Cancel
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'unbook_only'),
                  child: const Text("نعم، إلغاء فقط"),
                ), // Unbook without ad
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.green),
                  onPressed:
                      _canWatchRewardedAd
                          ? () => Navigator.pop(ctx, 'unbook_ad')
                          : null, // Disable if ad limit reached
                  child: Text(
                    _canWatchRewardedAd
                        ? "إلغاء + مشاهدة إعلان للكسب"
                        : "تم الوصول للحد الأقصى للإعلانات",
                  ),
                ), // Unbook AND watch ad
              ],
            ),
      );

      if (unbookChoice == 'unbook_only' || unbookChoice == 'unbook_ad') {
        setState(() => _isBookingSeat = true); // Show loading
        bool success = await _runBookingTransaction(seatIndex, unbook: true);
        if (success && unbookChoice == 'unbook_ad' && mounted) {
          // If unbooking succeeded AND user chose to watch ad, show the ad
          _showRewardedAd(); // This will grant 2 gold via _grantGoldReward if watched
        }
        if (mounted) {
          setState(() => _isBookingSeat = false);
        } // Hide loading
      }
    }
    // 2. Tapped an available seat: Try to book
    else if (type == 'share' && isOffered && bookedBy == "n/a") {
      setState(() => _isBookingSeat = true);
      bool goldOk = false;
      bool bookingSuccess = false;
      try {
        final rideStartTime = (rideData['date'] as Timestamp?)?.toDate();
        if (rideStartTime == null)
          throw Exception("Ride departure time missing.");
        bool hasConflict = await _checkDriverRideConflict(rideStartTime);
        if (hasConflict) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "لا يمكنك حجز مقعد قريب جداً من وقت رحلة تقودها.",
                ),
                backgroundColor: Colors.orange,
              ),
            );
          }
        } else {
          goldOk = await _handleBookSeatGoldCost(); // Check/Deduct gold
          if (goldOk) {
            bookingSuccess = await _runBookingTransaction(
              seatIndex,
              unbook: false,
            );
            // Attempt refund ONLY if booking failed AFTER gold was deducted
            if (!bookingSuccess && mounted) {
              print(
                "Booking transaction failed after gold deduction. Attempting refund.",
              );
              await _refundBookingGold(); // Use the refund function here
            }
          }
        }
      } catch (e) {
        debugPrint("Error during booking process: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Booking failed: $e"),
              backgroundColor: Colors.red,
            ),
          );
        }
        // Attempt refund if error occurred after potential gold deduction but before success flag set
        if (goldOk && !bookingSuccess && mounted) {
          print("Error occurred after gold deduction. Attempting refund.");
          await _refundBookingGold();
        }
      } finally {
        if (mounted) {
          setState(() => _isBookingSeat = false);
        }
      }
    }
    // 3. Tapped unavailable/booked by other/driver seat: Show message
    else {
      String message = "لا يمكن تحديد هذا المقعد.";
      if (type == 'driver') {
        message = "هذا مقعد السائق.";
      } else if (!isOffered) {
        message = "هذا المقعد غير معروض.";
      } else if (bookedBy != "n/a") {
        message = "هذا المقعد محجوز بالفعل.";
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Runs the Firestore transaction to book or unbook a seat.
  /// Returns true on success, false on failure.
  Future<bool> _runBookingTransaction(
    int seatIndex, {
    required bool unbook,
  }) async {
    if (_currentUserId == null) return false;
    final rideDocRef = _firestore.collection('rides').doc(widget.rideId);
    bool success = false;

    try {
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(rideDocRef);
        if (!snapshot.exists) throw Exception("Ride no longer exists.");

        final data = snapshot.data() as Map<String, dynamic>;
        final List<dynamic> layout = List.from(data['seatLayout'] ?? []);
        final int seatListIndex = layout.indexWhere(
          (s) => s is Map && s['seatIndex'] == seatIndex,
        );

        if (seatListIndex == -1)
          throw Exception("Seat not found in layout during transaction.");
        final seat = Map<String, dynamic>.from(layout[seatListIndex]);

        if (unbook) {
          if (seat['bookedBy'] == _currentUserId) {
            seat['bookedBy'] = "n/a"; // Set back to "n/a"
            seat['approvalStatus'] =
                "pending"; // Reset status? Or maybe 'cancelled'?
          } else {
            throw Exception("Cannot unbook a seat you haven't booked.");
          }
        } else {
          // Booking
          if (seat['type'] != 'share' || !(seat['offered'] as bool? ?? false)) {
            throw Exception("Seat is not offered for booking.");
          }
          if (seat['bookedBy'] != null && seat['bookedBy'] != "n/a") {
            throw Exception("Seat was booked by someone else just now.");
          } // Check against "n/a"
          seat['bookedBy'] = _currentUserId;
          seat['approvalStatus'] = "pending";
        }
        layout[seatListIndex] = seat;
        transaction.update(rideDocRef, {'seatLayout': layout});
      });

      success = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              unbook
                  ? "تم إلغاء الحجز بنجاح."
                  : "تم حجز المقعد بنجاح. ينتظر السائق الموافقة.",
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      success = false;
      debugPrint("Booking transaction error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ في الحجز: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
      }
      // Gold refund attempt happens in _handleSeatSelection if needed
    }
    return success; // Return status
  }

  // --- Build Methods ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("تفاصيل الرحلة"),
        actions: [
          // --- Display Gold ---
          if (_currentUserId != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Center(
                child: Tooltip(
                  message: "Your Gold Balance",
                  child: Chip(
                    avatar: Icon(
                      Icons.monetization_on,
                      color: Colors.yellow.shade700,
                      size: 18,
                    ),
                    label: Text(
                      '$_userGold',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    backgroundColor: Colors.white,
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
              ),
            ),
          // --- Earn Gold Button ---
          if (_currentUserId != null)
            IconButton(
              tooltip: "Earn Gold (Watch Ad)",
              icon: Icon(
                Icons.control_point_duplicate,
                color:
                    _canWatchRewardedAd ? Colors.amber.shade700 : Colors.grey,
              ),
              onPressed: _canWatchRewardedAd ? _showRewardedAd : null,
            ),
        ],
      ),
      bottomNavigationBar: _buildBottomNavigationBar(),
      body:
          _isHeaderLoading
              ? const Center(child: CircularProgressIndicator())
              : StreamBuilder<DocumentSnapshot>(
                stream:
                    _firestore
                        .collection('rides')
                        .doc(widget.rideId)
                        .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !_isHeaderLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }
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
                  final driverId = rideData['driverId'] as String? ?? '';

                  _myBookedSeatIndices =
                      seatLayout
                          .where((s) => s['bookedBy'] == _currentUserId)
                          .map((s) => s['seatIndex'] as int)
                          .toSet();
                  int seatCount = _carSeatCount;
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
                  if (seatCount <= 0) seatCount = 1;

                  return RefreshIndicator(
                    onRefresh: _loadInitialData,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _buildRideHeaderCard(),
                        const SizedBox(height: 8),
                        _buildDriverContactCard(driverId),
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 16),
                        Text(
                          "تخطيط المقاعد (تكلفة الحجز: $_bookSeatCost ذهب)",
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        if (seatCount > 0)
                          AbsorbPointer(
                            absorbing: _isBookingSeat,
                            child: SeatLayoutWidget(
                              key: ValueKey(
                                widget.rideId + seatLayout.hashCode.toString(),
                              ),
                              seatCount: seatCount,
                              seatLayoutData: seatLayout,
                              mode: SeatLayoutMode.passengerSelect,
                              driverSeatAssetPath: _driverSeatImagePath,
                              passengerSeatAssetPath: _passengerSeatImagePath,
                              onSeatSelected: _handleSeatSelection,
                              selectedSeatsIndices: _myBookedSeatIndices,
                              currentUserId: _currentUserId,
                            ),
                          ) // Pass currentUserId
                        else
                          const Text(
                            "لم يتم تحديد تخطيط المقاعد لهذه السيارة.",
                          ),
                        if (_isBookingSeat || _isUpdatingGold)
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

  Widget _buildRideHeaderCard() {
    final bool smokingAllowed = _ridePreferences?['smoking'] == true;
    final String departureFormatted =
        _rideDepartureTimestamp != null
            ? DateFormat(
              'EEE, MMM d, yyyy - hh:mm a',
              'en_US',
            ).format(_rideDepartureTimestamp!.toDate())
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
            _buildDetailRow(
              Icons.directions_car,
              "السيارة:",
              "${_carData?['brand'] ?? ''} ${_carData?['model'] ?? ''} (${_carData?['plateNumber'] ?? 'N/A'})",
            ),
            _buildDetailRow(
              Icons.person,
              "السائق:",
              _driverData?['name'] ?? 'N/A',
            ),
            _buildDetailRow(
              Icons.pin_drop_outlined,
              "من:",
              _rideStartLocationName,
            ),
            _buildDetailRow(Icons.location_on, "إلى:", _rideEndLocationName),
            _buildDetailRow(
              Icons.calendar_today,
              "المغادرة:",
              departureFormatted,
            ),
            _buildDetailRow(Icons.repeat, "التكرار:", _rideRepeatInfo),
            _buildDetailRow(
              Icons.attach_money,
              "سعر المقعد:",
              "${_ridePrice.toStringAsFixed(0)} DZD",
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

  Widget _buildDriverContactCard(String driverId) {
    final driverPhone = _driverData?['phone'] as String? ?? '';
    final driverImageUrl = _driverData?['imageUrl'] as String? ?? '';
    final driverName = _driverData?['name'] ?? 'السائق';
    if (driverId.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundImage:
                    (driverImageUrl.isNotEmpty)
                        ? NetworkImage(driverImageUrl)
                        : null,
                child:
                    (driverImageUrl.isEmpty) ? const Icon(Icons.person) : null,
              ),
              title: Text(
                driverName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 8.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.call_outlined),
                    label: const Text('اتصال'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green.shade700,
                    ),
                    onPressed:
                        (driverPhone.isNotEmpty)
                            ? () async {
                              final callUri = Uri(
                                scheme: 'tel',
                                path: driverPhone,
                              );
                              if (await canLaunchUrl(callUri))
                                await launchUrl(callUri);
                              else if (mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      "Could not launch phone dialer.",
                                    ),
                                  ),
                                );
                            }
                            : null,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.message_outlined),
                    label: const Text('دردشة'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.blue.shade700,
                    ),
                    onPressed: () async {
                      if (_currentUserId == null) return;
                      final chatId = await createOrGetChatRoom(
                        _currentUserId!,
                        driverId,
                      );
                      if (!mounted) return;
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (_) => ChatDetailPage(
                                chatId: chatId,
                                otherUserId: driverId,
                              ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
    if (!mounted || index == _currentIndex) return;
    // TODO: Consider adding check if booking is in progress (_isBookingSeat)
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
} // End of _RideDetailPageState class

// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   google_mobile_ads: ^... # For rewarded ads
//   intl: ^...             # For date formatting
//   url_launcher: ^...     # For phone calls
//   # Add SeatLayoutWidget dependency (if published) or ensure file import is correct
//   # Add other necessary dependencies

// --- Firestore Setup ---
// * Ensure 'users' collection has: 'gold' (Number), 'rewardedAdTimestamps' (Array<Timestamp>), 'phone' (String), 'role' (String), 'name', 'imageUrl'
// * Ensure 'cars' collection has: 'ownerId', 'seatCount', 'brand', 'model', 'plateNumber', etc.
// * Ensure 'rides' collection schema matches the data being read/updated.

// --- Asset Setup (Required by SeatLayoutWidget) ---
// 1. Create folder: `assets/images/`
// 2. Add Images: Copy `DRIVERSEAT.png` and `PASSENGER SEAT.png` into `assets/images/`.
// 3. Declare in pubspec.yaml:
//    flutter:
//      assets:
//        - assets/images/
