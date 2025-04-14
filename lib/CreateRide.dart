import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';

// Ensure these imports point to the correct files in your project
import 'add_car.dart' as add_car;
import 'home_page.dart'; // For navigation
import 'my_ride_page.dart';
import 'my_cars.dart';
import 'chat_list_page.dart';
// Import the LocationPickerPage you created
import 'location_picker_page.dart';
// Import the NEW SeatLayoutWidget you just created
import 'widgets/seat_layout_widget.dart'; // Adjust path if needed

// ====================== Create Ride Page ======================
class CreateRidePage extends StatefulWidget {
  const CreateRidePage({super.key});

  @override
  State<CreateRidePage> createState() => _CreateRidePageState();
}

class _CreateRidePageState extends State<CreateRidePage> {
  // --- State Variables and Controllers ---
  final _formKey = GlobalKey<FormState>();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final TextEditingController _startController = TextEditingController();
  final TextEditingController _destController = TextEditingController();
  final TextEditingController _seatPriceController = TextEditingController();
  final TextEditingController _dateController = TextEditingController();
  final TextEditingController _timeController = TextEditingController();
  LatLng? _startLatLng;
  LatLng? _destLatLng;
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  String _repeatOption = 'once';
  final List<bool> _weekdaySelected = List<bool>.filled(7, false);
  List<DocumentSnapshot> _cars = [];
  DocumentSnapshot? _selectedCar;
  int _carSeats = 0;
  List<Map<String, dynamic>> _seatLayout = []; // Still managed here
  bool _smokingAllowed = false;
  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _currentUserRole;
  bool _allowCreateRide = false;
  bool _isCheckingRole = true;
  int _userGold = 0;
  bool _isUpdatingGold = false;
  final String _rewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917'; // Test ID
  RewardedAd? _rewardedAd;
  bool _isRewardedAdLoading = false;
  final int _goldRewardAmount = 2;
  final int _maxAdsPerHour = 10;
  List<Timestamp> _rewardedAdTimestamps = [];
  bool _canWatchRewardedAd = true;
  final int _createRideCost = 5;
  int _currentIndex = 0;

  // Define asset paths (UPDATE THESE TO MATCH YOUR PROJECT AND FILE EXTENSIONS)
  final String _driverSeatImagePath =
      'assets/images/DRIVERSEAT.png'; // Use .png
  final String _passengerSeatImagePath =
      'assets/images/PASSENGER SEAT.png'; // Use .png

  // --- Lifecycle Methods ---
  @override
  void initState() {
    super.initState();
    _initializePageData();
    _loadRewardedAd();
  }

  @override
  void dispose() {
    _startController.dispose();
    _destController.dispose();
    _seatPriceController.dispose();
    _dateController.dispose();
    _timeController.dispose();
    _rewardedAd?.dispose();
    super.dispose();
  }

  // --- Initialization Methods ---
  Future<void> _initializePageData() async {
    setState(() {
      _isLoading = true;
      _isCheckingRole = true;
    });
    try {
      // Run checks and fetches concurrently where possible
      await Future.wait([
        _checkRoleAndActiveRide(), // Checks role and if driver has active ride
        _fetchUserCars(), // Fetches user's cars
        _fetchUserData(), // Fetches gold and ad timestamps
      ]);
      // Fetch initial location after core data is loaded
      if (mounted) {
        await _initializeUserLocation();
      }
    } catch (e) {
      debugPrint("Error initializing page data: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error loading page data: ${e.toString()}")),
        );
        // Handle error state appropriately, maybe block ride creation
        setState(() => _allowCreateRide = false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isCheckingRole = false; // Ensure this is set false even on error
        });
      }
    }
  }

  Future<void> _checkRoleAndActiveRide() async {
    bool canCreate = false;
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        _currentUserRole = ""; // No user logged in
      } else {
        final userDoc =
            await _firestore.collection('users').doc(currentUser.uid).get();
        if (!userDoc.exists) {
          _currentUserRole = ""; // User doc doesn't exist yet
          canCreate =
              true; // Allow creation for new users (assuming they add car)
        } else {
          final data = userDoc.data() as Map<String, dynamic>;
          _currentUserRole = data['role'] as String? ?? "";

          if (_currentUserRole!.isEmpty) {
            canCreate = true; // Role not set, allow creation
          } else if (_currentUserRole == "passenger") {
            canCreate = false; // Passengers cannot create rides
          } else if (_currentUserRole == "driver") {
            // Drivers can create only if they don't have an active ride
            bool hasUnfinishedRide = await _checkUnfinishedRide(
              currentUser.uid,
            );
            canCreate = !hasUnfinishedRide;
          } else {
            canCreate = false; // Other roles (e.g., 'blocked') cannot create
          }
        }
      }
    } catch (e) {
      debugPrint("Error checking role/active ride: $e");
      canCreate = false; // Default to false on error
    } finally {
      if (mounted) {
        setState(() {
          _allowCreateRide = canCreate;
        });
      }
    }
  }

  Future<bool> _checkUnfinishedRide(String userId) async {
    try {
      final query =
          await _firestore
              .collection('rides')
              .where('driverId', isEqualTo: userId)
              .where('status', whereIn: ["scheduled", "ongoing"])
              .limit(1)
              .get();
      return query.docs.isNotEmpty;
    } catch (e) {
      debugPrint("Error checking unfinished ride: $e");
      return true; // Assume unfinished ride exists on error to be safe
    }
  }

  Future<void> _fetchUserCars() async {
    final user = _auth.currentUser;
    if (user == null) {
      if (mounted) setState(() => _cars = []);
      return;
    }
    try {
      final carSnapshot =
          await _firestore
              .collection('cars')
              .where('ownerId', isEqualTo: user.uid)
              .get();
      if (!mounted) return;
      if (carSnapshot.docs.isEmpty) {
        setState(() => _cars = []);
        _promptToAddCar();
      } else {
        setState(() {
          _cars = carSnapshot.docs;
          if (_cars.isNotEmpty) {
            _selectedCar = _cars.first;
            _updateSeatLayoutFromSelectedCar();
          }
        });
      }
    } catch (e) {
      debugPrint("Error fetching user cars: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error fetching cars: ${e.toString()}")),
        );
        setState(() => _cars = []);
      }
    }
  }

  Future<void> _fetchUserData() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        if (mounted)
          setState(() {
            _userGold = 0;
            _rewardedAdTimestamps = [];
            _checkAdLimit();
          });
        return;
      }
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
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
        setState(() {
          _userGold = 0;
          _rewardedAdTimestamps = [];
          _checkAdLimit();
        });
      }
    } catch (e) {
      debugPrint("Error fetching user data (gold/timestamps): $e");
      if (mounted) {
        /* Optional: Show error */
        _checkAdLimit();
      }
    }
  }

  void _promptToAddCar() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (ctx) => AlertDialog(
              title: const Text('لم يتم العثور على سيارات'),
              content: const Text('يجب إضافة سيارة قبل إنشاء رحلة.'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const add_car.AddCarPage(),
                      ),
                    ).then((_) => _fetchUserCars());
                  },
                  child: const Text('إضافة سيارة'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).pop();
                  },
                  child: const Text('إلغاء'),
                ),
              ],
            ),
      );
    });
  }

  Future<void> _initializeUserLocation() async {
    bool serviceEnabled;
    LocationPermission permission;
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enable location services.')),
      );
      return;
    }
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permissions denied.')),
        );
        return;
      }
    }
    if (permission == LocationPermission.deniedForever && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location permissions permanently denied.'),
        ),
      );
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final currentPoint = LatLng(pos.latitude, pos.longitude);
      final placeName = await _reverseGeocode(currentPoint);
      setState(() {
        _startLatLng = currentPoint;
        _startController.text = placeName ?? "Current Location";
      });
    } catch (e) {
      debugPrint("Error getting initial location: $e");
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get current location: $e')),
        );
    }
  }

  Future<String?> _reverseGeocode(LatLng point) async {
    // ** IMPORTANT: Replace User-Agent **
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/reverse?format=json&lat=${point.latitude}&lon=${point.longitude}&accept-language=ar,en&addressdetails=1",
    );
    try {
      final response = await http.get(
        url,
        headers: {"User-Agent": "com.example.carpooling_app/1.0"},
      ); // ** USE YOURS **
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final address = data['address'] as Map<String, dynamic>? ?? {};
        String name =
            address['road'] ??
            address['neighbourhood'] ??
            address['suburb'] ??
            address['city'] ??
            address['town'] ??
            address['village'] ??
            '';
        if (name.isEmpty) name = data['display_name'] ?? 'Unknown Location';
        return name.split(',')[0].trim();
      } else {
        debugPrint("Reverse geocoding failed: Status ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Reverse geocoding error: $e");
    }
    return null;
  }

  // --- Form Input Handlers ---
  Future<void> _openLocationPicker({required bool forStart}) async {
    if (!mounted) return;
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (ctx) => LocationPickerPage(
              initialCenter: forStart ? _startLatLng : _destLatLng,
            ),
      ),
    );
    if (result != null && result is Map<String, dynamic> && mounted) {
      final lat = result['lat'] as double?;
      final lon = result['lon'] as double?;
      final name = result['name'] as String?;
      if (lat != null && lon != null && name != null) {
        setState(() {
          final pickedLatLng = LatLng(lat, lon);
          if (forStart) {
            _startLatLng = pickedLatLng;
            _startController.text = name;
          } else {
            _destLatLng = pickedLatLng;
            _destController.text = name;
          }
        });
      }
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: now,
      lastDate: DateTime(now.year + 1),
      locale: const Locale('en', 'US'),
    );
    if (date != null && mounted) {
      setState(() {
        _selectedDate = date;
        _dateController.text = DateFormat('yyyy/MM/dd').format(date);
      });
    }
  }

  Future<void> _pickTime() async {
    final now = TimeOfDay.now();
    final time = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? now,
      builder:
          (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
            child: child ?? const SizedBox(),
          ),
    );
    if (time != null && mounted) {
      setState(() {
        _selectedTime = time;
        final hour = time.hour.toString().padLeft(2, '0');
        final minute = time.minute.toString().padLeft(2, '0');
        _timeController.text = '$hour:$minute';
      });
    }
  }

  void _onCarSelected(DocumentSnapshot? carDoc) {
    if (carDoc == null) return;
    setState(() {
      _selectedCar = carDoc;
      _updateSeatLayoutFromSelectedCar();
    });
  }

  void _updateSeatLayoutFromSelectedCar() {
    if (_selectedCar == null) return;
    final data = _selectedCar!.data() as Map<String, dynamic>? ?? {};
    _carSeats = (data['seatCount'] as int?) ?? 0;
    _seatLayout = _generateFlatSeatLayout(_carSeats);
  }

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

  // --- Rewarded Ad Methods ---
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
  }

  void _loadRewardedAd() {
    if (_isRewardedAdLoading) return;
    setState(() => _isRewardedAdLoading = true);
    RewardedAd.load(
      adUnitId: _rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
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
      onAdShowedFullScreenContent: (ad) => print('Ad showed.'),
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _rewardedAd = null;
        _loadRewardedAd();
      },
      onAdFailedToShowFullScreenContent: (ad, err) {
        print('Ad failed show: $err');
        ad.dispose();
        _rewardedAd = null;
        _loadRewardedAd();
      },
      onAdImpression: (ad) => print('Ad impression.'),
    );
  }

  void _showRewardedAd() {
    _checkAdLimit();
    if (!_canWatchRewardedAd) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'You have reached the limit of $_maxAdsPerHour rewarded ads per hour. Please try again later.',
          ),
          backgroundColor: Colors.orange.shade800,
        ),
      );
      return;
    }
    if (_rewardedAd == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Reward ad not ready. Loading... Please try again shortly.',
          ),
        ),
      );
      if (!_isRewardedAdLoading) _loadRewardedAd();
      return;
    }
    _setRewardedAdCallbacks();
    _rewardedAd!.show(onUserEarnedReward: (ad, reward) => _grantGoldReward());
    _rewardedAd = null;
  }

  Future<void> _grantGoldReward() async {
    if (!mounted) return;
    setState(() => _isUpdatingGold = true);
    final Timestamp currentTime = Timestamp.now();
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception("User not logged in");
      final userRef = _firestore.collection('users').doc(user.uid);
      await userRef.update({
        'gold': FieldValue.increment(_goldRewardAmount),
        'rewardedAdTimestamps': FieldValue.arrayUnion([currentTime]),
      });
      if (mounted) {
        setState(() {
          _userGold += _goldRewardAmount;
          _rewardedAdTimestamps.add(currentTime);
          _isUpdatingGold = false;
        });
        _checkAdLimit();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$_goldRewardAmount Gold Added! Total: $_userGold'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error updating gold/timestamp after reward: $e");
      if (mounted) setState(() => _isUpdatingGold = false);
      _fetchUserData();
    }
  }

  // --- Gold Cost Handling ---
  Future<bool> _handleCreateRideGoldCost() async {
    if (_userGold < _createRideCost) {
      if (!mounted) return false;
      final watchAd = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => AlertDialog(
              title: const Text('Insufficient Gold'),
              content: Text(
                'Creating a ride costs $_createRideCost gold. You have $_userGold.\n\nWatch an ad to earn $_goldRewardAmount gold?',
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
        final user = _auth.currentUser;
        if (user == null) throw Exception("User not logged in");
        final userRef = _firestore.collection('users').doc(user.uid);
        await userRef.update({'gold': FieldValue.increment(-_createRideCost)});
        if (mounted) {
          setState(() {
            _userGold -= _createRideCost;
            _isUpdatingGold = false;
          });
          return true;
        }
        return false;
      } catch (e) {
        debugPrint("Error deducting gold for ride creation: $e");
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

  // --- Ride Submission ---
  Future<void> _submitRide() async {
    // 1. Validate Form
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("يرجى تعبئة جميع الحقول المطلوبة بشكل صحيح"),
        ),
      );
      return;
    }
    if (_startLatLng == null ||
        _destLatLng == null ||
        _selectedDate == null ||
        _selectedTime == null ||
        _selectedCar == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("بيانات الموقع أو الوقت أو السيارة مفقودة"),
        ),
      );
      return;
    }
    final offeredSeatsCount =
        _seatLayout
            .where((s) => s['type'] == 'share' && s['offered'] == true)
            .length;
    if (offeredSeatsCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("يرجى عرض مقعد واحد على الأقل للركاب")),
      );
      return;
    }
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    // 2. Handle Gold Cost
    final bool goldCostCovered = await _handleCreateRideGoldCost();
    if (!goldCostCovered) {
      setState(() => _isSubmitting = false);
      return;
    }
    // 3. Fetch Driver Phone
    String driverPhone = '';
    final currentUser = _auth.currentUser;
    if (currentUser != null) {
      try {
        final userDoc =
            await _firestore.collection('users').doc(currentUser.uid).get();
        if (userDoc.exists)
          driverPhone = (userDoc.data()?['phone'] as String?) ?? '';
        if (driverPhone.isEmpty)
          throw Exception("Driver phone number is missing.");
      } catch (e) {
        debugPrint("Error fetching driver phone: $e");
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Error fetching driver phone: $e"),
              backgroundColor: Colors.red,
            ),
          );
        setState(() => _isSubmitting = false);
        return;
      }
    } else {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("User not logged in."),
            backgroundColor: Colors.red,
          ),
        );
      setState(() => _isSubmitting = false);
      return;
    }
    // 4. Prepare Ride Data
    final departureDateTime = DateTime(
      _selectedDate!.year,
      _selectedDate!.month,
      _selectedDate!.day,
      _selectedTime!.hour,
      _selectedTime!.minute,
    );
    final Timestamp departureTimestamp = Timestamp.fromDate(departureDateTime);
    String repeatType = _repeatOption;
    List<int>? repeatDays;
    if (_repeatOption == 'daysOfWeek') {
      repeatDays = [];
      for (int i = 0; i < 7; i++) {
        if (_weekdaySelected[i]) repeatDays.add(i);
      }
      if (repeatDays.isEmpty) {
        repeatType = 'once';
        repeatDays = null;
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("No repeat days selected, setting ride to 'once'."),
            ),
          );
      }
    }
    final rideData = {
      "startLocationName": _startController.text.trim(),
      "startLocation": GeoPoint(
        _startLatLng!.latitude,
        _startLatLng!.longitude,
      ),
      "endLocationName": _destController.text.trim(),
      "endLocation": GeoPoint(_destLatLng!.latitude, _destLatLng!.longitude),
      "date": departureTimestamp,
      "repeat": repeatType,
      if (repeatDays != null) "days": repeatDays,
      "price": double.tryParse(_seatPriceController.text) ?? 0.0,
      "preferences": {"smoking": _smokingAllowed},
      "seatLayout": _seatLayout,
      "driverId": currentUser?.uid ?? "",
      "carId": _selectedCar!.id,
      "driverPhone": driverPhone,
      "status": "scheduled",
      "createdAt": FieldValue.serverTimestamp(),
    };
    // 5. Add Ride & Update Role
    try {
      await _firestore.collection("rides").add(rideData);
      if (_currentUserRole != "driver" && currentUser != null) {
        await _firestore.collection('users').doc(currentUser.uid).update({
          "role": "driver",
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("تم إنشاء الرحلة بنجاح"),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint("Error creating ride: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ أثناء إنشاء الرحلة: $e"),
            backgroundColor: Colors.red,
          ),
        );
        _fetchUserData();
      }
    } // Consider refunding gold
    finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // --- Build Methods ---
  @override
  Widget build(BuildContext context) {
    if (_isLoading)
      return Scaffold(
        appBar: AppBar(title: const Text("إنشاء رحلة")),
        body: const Center(child: CircularProgressIndicator()),
        bottomNavigationBar: _buildBottomNavigationBar(),
      );
    if (!_allowCreateRide)
      return Scaffold(
        appBar: AppBar(title: const Text("إنشاء رحلة")),
        body: _buildBlockedUi(),
        bottomNavigationBar: _buildBottomNavigationBar(),
      );
    return Scaffold(
      appBar: AppBar(
        title: const Text("إنشاء رحلة"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
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
        ],
      ),
      body: _buildRideForm(),
      bottomNavigationBar: _buildBottomNavigationBar(),
    );
  }

  Widget _buildBlockedUi() {
    String reason = "لا يمكنك إنشاء رحلة الآن.";
    if (_currentUserRole == "passenger")
      reason = "أنت راكب حالياً ولا يمكنك إنشاء رحلة جديدة.";
    else if (_currentUserRole == "driver" && !_allowCreateRide)
      reason = "لديك رحلة نشطة بالفعل. أنهِ رحلتك الحالية أولاً.";
    else if (_cars.isEmpty)
      reason = "يجب إضافة سيارة أولاً قبل إنشاء رحلة.";
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.block, color: Colors.red.shade700, size: 60),
            const SizedBox(height: 16),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            if (_cars.isEmpty)
              ElevatedButton.icon(
                // --- Highlight: Required arguments for ElevatedButton.icon ---
                icon: const Icon(Icons.add),
                label: const Text('إضافة سيارة'), // Required 'label' is present
                onPressed:
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const add_car.AddCarPage(),
                      ),
                    ).then(
                      (_) => _fetchUserCars(),
                    ), // Required 'onPressed' is present
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRideForm() {
    // Main form structure using Cards
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              // Location Card
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
                      "المسار",
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _startController,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: "نقطة البداية",
                        hintText: "اضغط لاختيار نقطة البداية",
                        prefixIcon: Icon(
                          Icons.trip_origin,
                          color: Colors.green.shade700,
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.map_outlined),
                          tooltip: "اختر من الخريطة",
                          onPressed: () => _openLocationPicker(forStart: true),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      validator:
                          (value) =>
                              (value == null || value.isEmpty)
                                  ? "يرجى اختيار نقطة البداية"
                                  : null,
                      onTap: () => _openLocationPicker(forStart: true),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _destController,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: "الوجهة",
                        hintText: "اضغط لاختيار الوجهة",
                        prefixIcon: Icon(
                          Icons.location_on,
                          color: Colors.red.shade700,
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.map_outlined),
                          tooltip: "اختر من الخريطة",
                          onPressed: () => _openLocationPicker(forStart: false),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      validator:
                          (value) =>
                              (value == null || value.isEmpty)
                                  ? "يرجى اختيار الوجهة"
                                  : null,
                      onTap: () => _openLocationPicker(forStart: false),
                    ),
                    if (_startLatLng != null || _destLatLng != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        height: 150,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter:
                                  _startLatLng ??
                                  _destLatLng ??
                                  LatLng(36.8, 10.18),
                              initialZoom: 11.0,
                              interactionOptions: const InteractionOptions(
                                flags: InteractiveFlag.none,
                              ),
                            ),
                            children: [
                              TileLayer(
                                urlTemplate:
                                    "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                              ),
                              MarkerLayer(
                                markers: [
                                  if (_startLatLng != null)
                                    Marker(
                                      point: _startLatLng!,
                                      width: 30,
                                      height: 30,
                                      alignment: Alignment.topCenter,
                                      child: Icon(
                                        Icons.trip_origin,
                                        color: Colors.green.shade700,
                                        size: 30,
                                      ),
                                    ),
                                  if (_destLatLng != null)
                                    Marker(
                                      point: _destLatLng!,
                                      width: 30,
                                      height: 30,
                                      alignment: Alignment.topCenter,
                                      child: Icon(
                                        Icons.location_on,
                                        color: Colors.red.shade700,
                                        size: 30,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Card(
              // Date, Time, Repetition Card
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
                      "الوقت والتكرار",
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _dateController,
                            readOnly: true,
                            decoration: const InputDecoration(
                              labelText: "التاريخ",
                              hintText: "اختر التاريخ",
                              prefixIcon: Icon(Icons.date_range),
                              border: OutlineInputBorder(),
                            ),
                            onTap: _pickDate,
                            validator:
                                (v) =>
                                    (v == null || v.isEmpty)
                                        ? 'حدد التاريخ'
                                        : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _timeController,
                            readOnly: true,
                            decoration: const InputDecoration(
                              labelText: "الوقت",
                              hintText: "اختر الوقت",
                              prefixIcon: Icon(Icons.access_time),
                              border: OutlineInputBorder(),
                            ),
                            onTap: _pickTime,
                            validator:
                                (v) =>
                                    (v == null || v.isEmpty)
                                        ? 'حدد الوقت'
                                        : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      // Repeat Dropdown
                      decoration: const InputDecoration(
                        labelText: "التكرار",
                        border: OutlineInputBorder(),
                      ),
                      value: _repeatOption,
                      // --- Highlight: Required arguments for DropdownButtonFormField ---
                      items: const [
                        // Required 'items' is present
                        DropdownMenuItem(
                          value: 'once',
                          child: Text("مرة واحدة"),
                        ),
                        DropdownMenuItem(value: 'daily', child: Text("يوميًا")),
                        DropdownMenuItem(
                          value: 'daysOfWeek',
                          child: Text("تحديد أيام الأسبوع"),
                        ),
                      ],
                      onChanged: (value) {
                        // Required 'onChanged' is present
                        if (value != null && mounted)
                          setState(() => _repeatOption = value);
                      },
                    ),
                    if (_repeatOption == 'daysOfWeek') ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8.0,
                        runSpacing: 4.0,
                        children: List.generate(7, (index) {
                          const dayNames = [
                            "الأحد",
                            "الاثنين",
                            "الثلاثاء",
                            "الأربعاء",
                            "الخميس",
                            "الجمعة",
                            "السبت",
                          ];
                          int weekdayIndex = index;
                          return FilterChip(
                            label: Text(dayNames[weekdayIndex]),
                            selected: _weekdaySelected[weekdayIndex],
                            onSelected: (selected) {
                              setState(
                                () => _weekdaySelected[weekdayIndex] = selected,
                              );
                            },
                            selectedColor: Colors.green.shade100,
                            checkmarkColor: Colors.green.shade800,
                          );
                        }),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Card(
              // Car & Seats Card
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "السيارة والمقاعد",
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        TextButton.icon(
                          // --- Highlight: Required arguments for TextButton.icon ---
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text(
                            "إضافة سيارة",
                          ), // Required 'label' is present
                          onPressed:
                              () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const add_car.AddCarPage(),
                                ),
                              ).then(
                                (_) => _fetchUserCars(),
                              ), // Required 'onPressed' is present
                          style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_cars.isNotEmpty)
                      DropdownButtonFormField<DocumentSnapshot>(
                        // Car Dropdown
                        decoration: const InputDecoration(
                          labelText: "اختيار السيارة",
                          border: OutlineInputBorder(),
                        ),
                        value: _selectedCar,
                        // --- Highlight: Required arguments for DropdownButtonFormField ---
                        items:
                            _cars.map((car) {
                              // Required 'items' is present
                              final carData =
                                  car.data() as Map<String, dynamic>? ?? {};
                              return DropdownMenuItem<DocumentSnapshot>(
                                value: car,
                                child: Text(
                                  "${carData['brand']} ${carData['model']} - ${carData['plateNumber']}",
                                ),
                              );
                            }).toList(),
                        onChanged:
                            _onCarSelected, // Required 'onChanged' is present
                        validator: (val) => val == null ? 'اختر سيارة' : null,
                      )
                    else
                      const Text(
                        "لم يتم العثور على سيارات. يرجى إضافة سيارة أولاً.",
                        style: TextStyle(color: Colors.red),
                      ),
                    const SizedBox(height: 20),
                    const Text(
                      "تحديد المقاعد المعروضة للركاب:",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    // Use the Reusable SeatLayoutWidget
                    if (_selectedCar != null)
                      SeatLayoutWidget(
                        key: ValueKey(_selectedCar!.id),
                        seatCount: _carSeats,
                        seatLayoutData: _seatLayout,
                        mode: SeatLayoutMode.driverOffer,
                        driverSeatAssetPath: _driverSeatImagePath,
                        passengerSeatAssetPath: _passengerSeatImagePath,
                        onSeatOfferedToggle: (seatIndex) {
                          setState(() {
                            final index = _seatLayout.indexWhere(
                              (s) => s['seatIndex'] == seatIndex,
                            );
                            if (index != -1 &&
                                _seatLayout[index]['type'] == 'share') {
                              bool currentStatus =
                                  _seatLayout[index]['offered'] ?? false;
                              _seatLayout[index]['offered'] = !currentStatus;
                            }
                          });
                        },
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Text("اختر سيارة لعرض المقاعد."),
                      ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _seatPriceController,
                      decoration: const InputDecoration(
                        labelText: "سعر المقعد الواحد (DZD)",
                        prefixIcon: Icon(Icons.attach_money),
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (val) {
                        if (val == null || val.isEmpty)
                          return "يرجى إدخال سعر المقعد";
                        if ((double.tryParse(val) ?? -1) < 0)
                          return "أدخل سعرًا صالحًا";
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ),
            Card(
              // Preferences Card
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
                      "التفضيلات",
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      // Smoking Preference
                      title: const Text("السماح بالتدخين"),
                      // --- Highlight: Required arguments for SwitchListTile ---
                      value: _smokingAllowed, // Required 'value' is present
                      onChanged:
                          (value) => setState(
                            () => _smokingAllowed = value,
                          ), // Required 'onChanged' is present
                      secondary: Icon(
                        _smokingAllowed
                            ? Icons.smoking_rooms
                            : Icons.smoke_free,
                      ),
                      activeColor: Colors.green,
                    ),
                  ],
                ),
              ),
            ),
            ElevatedButton.icon(
              // Submit Button
              // --- Highlight: Required arguments for ElevatedButton.icon ---
              onPressed:
                  _isSubmitting
                      ? null
                      : _submitRide, // Required 'onPressed' is present
              icon:
                  _isSubmitting
                      ? Container(
                        width: 24,
                        height: 24,
                        padding: const EdgeInsets.all(2.0),
                        child: const CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 3,
                        ),
                      )
                      : const Icon(
                        Icons.add_road,
                      ), // Required 'icon' is present
              label: Text(
                _isSubmitting
                    ? "جارٍ الإنشاء..."
                    : "إنشاء الرحلة (تكلفة: $_createRideCost ذهب)",
                style: const TextStyle(fontSize: 16),
              ), // Required 'label' is present
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // --- REMOVED Seat Layout Builders ---

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
    if (!mounted || index == _currentIndex) return;
    // TODO: Add form dirty check
    _navigateToIndex(index);
  }

  void _navigateToIndex(int index) {
    Widget? targetPage;
    bool removeUntil = false;
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      /* handle error */
      return;
    }
    switch (index) {
      case 0:
        targetPage = HomePage(user: currentUser);
        removeUntil = true;
        break;
      case 1:
        targetPage = MyRidePage(user: currentUser);
        break;
      case 2:
        targetPage = const MyCarsPage();
        break;
      case 3:
        targetPage = const ChatListPage();
        break;
      case 4:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account page not implemented yet.')),
        );
        return;
    }
    // --- Includes FIX: Check if targetPage is not null before navigating ---
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
      if (mounted && !removeUntil) {
        setState(() => _currentIndex = index);
      }
    } else {
      print("Error: Target page was null for index $index");
    }
  }
} // End of _CreateRidePageState class

// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   google_mobile_ads: ^... # Ensure this is added
//   http: ^...             # For Nominatim API calls
//   geolocator: ^...       # For current location
//   flutter_map: ^...      # For map display
//   latlong2: ^...         # LatLng class for flutter_map
//   intl: ^...             # For date/time formatting
//   # Add other necessary dependencies

// --- Asset Setup (IMPORTANT) ---
// 1. Create folder: `assets/images/` in your project root (if it doesn't exist).
// 2. Add Images: Copy `DRIVERSEAT.png` and `PASSENGER SEAT.png` (use correct names/extensions!) into `assets/images/`.
// 3. Declare in pubspec.yaml:
//    flutter:
//      uses-material-design: true
//      assets:
//        - assets/images/ # Make sure this line exists and is correctly indented

// --- Firestore Setup ---
// * Ensure 'users' collection has: 'gold' (Number), 'rewardedAdTimestamps' (Array<Timestamp>), 'phone' (String), 'role' (String)
// * Ensure 'cars' collection has: 'ownerId' (String), 'seatCount' (Number), etc.
// * Ensure 'rides' collection schema matches the data being saved in `_submitRide`.

// --- Important Notes ---
// * SeatLayoutWidget: This code now IMPORTS and USES 'widgets/seat_layout_widget.dart'.
//   Make sure you have created that file with the code from the previous response.
// * Booking Cost (2 Gold): The logic to check/deduct gold for BOOKING a seat
//   still needs to be implemented in your `RideDetailPage`. You can reuse the
//   `SeatLayoutWidget` there in `SeatLayoutMode.passengerSelect` mode.
