import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'add_car.dart' as add_car; // Ensure your add_car.dart exists

// Model representing an OSM place
class OSMPlace {
  final String displayName;
  final String name;
  final LatLng point;

  OSMPlace({
    required this.displayName,
    required this.name,
    required this.point,
  });
}

// ====================== Create Ride Page ======================
class CreateRidePage extends StatefulWidget {
  const CreateRidePage({Key? key}) : super(key: key);

  @override
  _CreateRidePageState createState() => _CreateRidePageState();
}

class _CreateRidePageState extends State<CreateRidePage> {
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final TextEditingController _startController = TextEditingController();
  final TextEditingController _destController = TextEditingController();
  final TextEditingController _seatPriceController = TextEditingController();
  final TextEditingController _dateController = TextEditingController();
  final TextEditingController _timeController = TextEditingController();

  LatLng? _startLatLng;
  LatLng? _destLatLng;

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;

  // “once”, “daily” or “daysOfWeek”
  String _repeatOption = 'once';
  List<bool> _weekdaySelected = List<bool>.filled(7, false);

  // Car data from Firestore
  List<DocumentSnapshot> _cars = [];
  DocumentSnapshot? _selectedCar;
  int _carSeats = 0;
  // Flat seat layout with “offered” toggles
  List<Map<String, dynamic>> _seatLayout = [];

  bool _isLoading = true;
  bool _smokingAllowed = false;

  // For role logic
  String? _currentUserRole;
  bool _allowCreateRide = false; // if user is permitted to create a new ride
  bool _isCheckingRole = true;

  @override
  void initState() {
    super.initState();
    _checkRoleAndActiveRide(); // checks if user can create ride
    _initializeUserLocation();
    _fetchUserCars();
  }

  /// Step 1: Check the user role from users doc
  /// If role=passenger, no create. If role=driver, must ensure no scheduled/ongoing rides
  /// If role is empty => allow
  Future<void> _checkRoleAndActiveRide() async {
    setState(() {
      _isLoading = true;
      _isCheckingRole = true;
    });
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        // no user => no creation
        _currentUserRole = "";
        _allowCreateRide = false;
      } else {
        final userDoc =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(currentUser.uid)
                .get();
        if (!userDoc.exists) {
          // no doc => new user
          _currentUserRole = "";
          _allowCreateRide = true;
        } else {
          final data = userDoc.data() as Map<String, dynamic>;
          _currentUserRole = data['role'] as String? ?? "";
          if (_currentUserRole == null || _currentUserRole!.isEmpty) {
            // role empty => can create
            _allowCreateRide = true;
          } else if (_currentUserRole == "passenger") {
            // If they're passenger => can they create a ride? By logic, no
            _allowCreateRide = false;
          } else if (_currentUserRole == "driver") {
            // If they're driver => check if they have an uncompleted ride
            bool hasUnfinishedRide = await _checkUnfinishedRide(
              currentUser.uid,
            );
            if (hasUnfinishedRide) {
              _allowCreateRide = false;
            } else {
              _allowCreateRide = true;
            }
          } else {
            // if there's other role (like "blocked"?), fallback
            _allowCreateRide = false;
          }
        }
      }
    } catch (e) {
      debugPrint("Error checking role: $e");
      _allowCreateRide = false;
    } finally {
      setState(() {
        _isLoading = false;
        _isCheckingRole = false;
      });
    }
  }

  /// Step 2: If user is driver, check if they have a ride with status= "scheduled" or "ongoing"
  Future<bool> _checkUnfinishedRide(String userId) async {
    final query =
        await FirebaseFirestore.instance
            .collection('rides')
            .where('driverId', isEqualTo: userId)
            .where('status', whereIn: ["scheduled", "ongoing"])
            .limit(1)
            .get();
    return query.docs.isNotEmpty;
  }

  Future<void> _initializeUserLocation() async {
    // your existing location logic
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (_) => AlertDialog(
              title: const Text('الخدمات الموقعية غير مفعلة'),
              content: const Text('يرجى تفعيل خدمات تحديد الموقع...'),
              actions: [
                TextButton(
                  onPressed: () async {
                    await Geolocator.openLocationSettings();
                    Navigator.of(context).pop();
                  },
                  child: const Text('افتح الإعدادات'),
                ),
              ],
            ),
      );
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      final currentPoint = LatLng(pos.latitude, pos.longitude);
      final placeName = await _reverseGeocode(currentPoint);
      setState(() {
        _startLatLng = currentPoint;
        _startController.text = placeName ?? "الموقع الحالي";
      });
    } catch (e) {
      debugPrint("Error init location: $e");
    }
  }

  Future<String?> _reverseGeocode(LatLng point) async {
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/reverse?format=json&lat=${point.latitude}&lon=${point.longitude}&accept-language=ar&addressdetails=1",
    );
    try {
      final response = await http.get(
        url,
        headers: {"User-Agent": "FlutterRideApp/1.0"},
      );
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final address = data['address'] ?? {};
        final city =
            address['city'] ??
            address['town'] ??
            address['village'] ??
            address['county'];
        return city ?? data['display_name'];
      }
    } catch (e) {
      debugPrint("Reverse geocoding error: $e");
    }
    return null;
  }

  Future<void> _fetchUserCars() async {
    setState(() {
      _isLoading = true;
    });
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final carSnapshot =
          await FirebaseFirestore.instance
              .collection('cars')
              .where('ownerId', isEqualTo: user.uid)
              .get();
      if (carSnapshot.docs.isEmpty) {
        setState(() {
          _isLoading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) {
              return AlertDialog(
                title: const Text('لم يتم العثور على سيارات'),
                content: const Text('يجب إضافة سيارة قبل إنشاء رحلة.'),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (ctx2) => add_car.AddCarPage(),
                        ),
                      );
                    },
                    child: const Text('إضافة سيارة'),
                  ),
                ],
              );
            },
          );
        });
      } else {
        setState(() {
          _cars = carSnapshot.docs;
          _isLoading = false;
          if (_cars.isNotEmpty) {
            _selectedCar = _cars.first;
            _carSeats = _selectedCar!['seatCount'];
            _seatLayout = _generateFlatSeatLayout(_carSeats);
          }
        });
      }
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _onCarSelected(DocumentSnapshot carDoc) {
    setState(() {
      _selectedCar = carDoc;
      _carSeats = carDoc['seatCount'];
      _seatLayout = _generateFlatSeatLayout(_carSeats);
    });
  }

  /// Generates the seat layout with "offered" field.
  /// This is unchanged from previous seat generation logic
  List<Map<String, dynamic>> _generateFlatSeatLayout(int seats) {
    final Map<int, List<int>> layoutMapping = {
      2: [2],
      4: [2, 2],
      5: [2, 3],
      6: [2, 2, 2],
      7: [2, 3, 2],
      8: [2, 3, 3],
      9: [2, 3, 4],
      10: [2, 4, 4],
    };
    final flatLayout = <Map<String, dynamic>>[];
    final config = layoutMapping[seats] ?? [seats];
    int seatIndex = 0;
    for (int row = 0; row < config.length; row++) {
      final count = config[row];
      for (int col = 0; col < count; col++) {
        if (seatIndex == 0) {
          // driver seat
          flatLayout.add({
            "seatIndex": seatIndex,
            "row": row,
            "col": col,
            "type": "driver",
            "offered": false,
            "bookedBy": null,
            "approvalStatus": "pending",
          });
        } else {
          flatLayout.add({
            "seatIndex": seatIndex,
            "row": row,
            "col": col,
            "type": "share",
            "offered": false, // toggled in UI
            "bookedBy": null,
            "approvalStatus": "pending",
          });
        }
        seatIndex++;
      }
    }
    return flatLayout;
  }

  Future<void> _openLocationPicker({required bool forStart}) async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (ctx) => LocationPickerPage(
              initialCenter: forStart ? _startLatLng : _destLatLng,
            ),
      ),
    );
    if (result != null && result is Map<String, dynamic>) {
      setState(() {
        if (forStart) {
          _startLatLng = LatLng(result['lat'], result['lon']);
          _startController.text = result['name'];
        } else {
          _destLatLng = LatLng(result['lat'], result['lon']);
          _destController.text = result['name'];
        }
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: DateTime(now.year + 5),
      locale: const Locale('ar'),
    );
    if (date != null) {
      setState(() {
        _selectedDate = date;
        _dateController.text = _formatDate(date);
      });
    }
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (ctx, child) {
        return MediaQuery(
          data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
          child: child ?? const SizedBox(),
        );
      },
    );
    if (time != null) {
      setState(() {
        _selectedTime = time;
        _timeController.text = _formatTime(time);
      });
    }
  }

  String _formatDate(DateTime date) {
    return "${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}";
  }

  String _formatTime(TimeOfDay time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return "$h:$m";
  }

  /// UI for seat layout
  Widget _buildSeatLayout() {
    // Group seat layout by row
    final Map<int, List<Map<String, dynamic>>> grouped = {};
    for (var seat in _seatLayout) {
      final row = seat["row"] as int;
      grouped.putIfAbsent(row, () => []);
      grouped[row]!.add(seat);
    }
    final sortedKeys = grouped.keys.toList()..sort();
    final rows = sortedKeys.map((k) => grouped[k]!).toList();

    return Column(
      children:
          rows.map((row) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children:
                    row.map((seat) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: _buildSeatIcon(seat),
                      );
                    }).toList(),
              ),
            );
          }).toList(),
    );
  }

  /// Each seat icon can be toggled "offered" if type=share
  Widget _buildSeatIcon(Map<String, dynamic> seat) {
    final seatIndex = seat["seatIndex"] as int;
    final type = seat["type"] as String;
    final offered = seat["offered"] == true;
    String label;
    IconData icon;
    Color color;

    if (type == "driver") {
      label = "سائق";
      icon = Icons.person;
      color = Colors.blueAccent;
    } else {
      if (offered) {
        label = "معروض";
        icon = Icons.event_seat;
        color = Colors.green;
      } else {
        label = "غير معروض";
        icon = Icons.close;
        color = Colors.grey;
      }
    }

    return InkWell(
      onTap:
          type == "driver"
              ? null
              : () {
                setState(() {
                  seat["offered"] = !seat["offered"];
                });
              },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  /// Submits the ride. Then sets user role=driver if successful
  Future<void> _submitRide() async {
    if (!_allowCreateRide) {
      // If user not allowed to create, show error
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("لا يمكنك إنشاء رحلة الآن.")),
      );
      return;
    }

    if (_startLatLng == null ||
        _destLatLng == null ||
        _selectedDate == null ||
        _selectedTime == null ||
        _selectedCar == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("يرجى تعبئة جميع الحقول المطلوبة")),
      );
      return;
    }

    final departure = DateTime(
      _selectedDate!.year,
      _selectedDate!.month,
      _selectedDate!.day,
      _selectedTime!.hour,
      _selectedTime!.minute,
    );

    String repeat = _repeatOption;
    List<int>? days;
    if (_repeatOption == 'daysOfWeek') {
      days = [];
      for (int i = 0; i < 7; i++) {
        if (_weekdaySelected[i]) days.add(i);
      }
    }

    final rideData = {
      "startLocationName": _startController.text,
      "startLocation": GeoPoint(
        _startLatLng!.latitude,
        _startLatLng!.longitude,
      ),
      "endLocationName": _destController.text,
      "endLocation": GeoPoint(_destLatLng!.latitude, _destLatLng!.longitude),
      "date": Timestamp.fromDate(departure),
      "repeat": repeat,
      if (days != null) "days": days,
      "price": double.tryParse(_seatPriceController.text) ?? 0.0,
      "preferences": {"smoking": _smokingAllowed},
      "seatLayout": _seatLayout,
      "driverId": FirebaseAuth.instance.currentUser?.uid ?? "",
      "carId": _selectedCar!.id,
      "driverPhone": "",
      "status": "scheduled",
      "createdAt": Timestamp.now(),
    };

    try {
      final docRef = await FirebaseFirestore.instance
          .collection("rides")
          .add(rideData);
      // Ride created => update user role=driver
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .update({"role": "driver"});
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("تم إنشاء الرحلة بنجاح")));
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("خطأ أثناء إنشاء الرحلة: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    // If still checking role or fetching cars => show loader
    if (_isLoading || _isCheckingRole) {
      return Scaffold(
        appBar: AppBar(title: const Text("إنشاء رحلة")),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("إنشاء رحلة"),
        actions: [
          IconButton(
            icon: const Icon(Icons.directions_car),
            tooltip: "إضافة سيارة",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (ctx) => add_car.AddCarPage()),
              ).then((_) {
                _fetchUserCars();
              });
            },
          ),
        ],
      ),
      body: _allowCreateRide ? _buildRideForm() : _buildBlockedUi(),
    );
  }

  /// If user is blocked from creating, show a message
  Widget _buildBlockedUi() {
    String reason = "لا يمكنك إنشاء رحلة الآن.";
    if (_currentUserRole == "passenger") {
      reason = "أنت راكب في رحلة أخرى حالياً. لا يمكنك إنشاء رحلة.";
    } else if (_currentUserRole == "driver") {
      reason = "لديك رحلة نشطة بالفعل. أنهيها قبل إنشاء رحلة جديدة.";
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Text(reason, style: const TextStyle(fontSize: 16)),
      ),
    );
  }

  /// The actual form if user is allowed
  Widget _buildRideForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Start
            const Text(
              "نقطة البداية",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            TextFormField(
              controller: _startController,
              readOnly: true,
              decoration: InputDecoration(
                hintText: "اضغط لاختيار نقطة البداية",
                suffixIcon: IconButton(
                  icon: const Icon(Icons.map),
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
            ),
            const SizedBox(height: 16),
            // Destination
            const Text("الوجهة", style: TextStyle(fontWeight: FontWeight.bold)),
            TextFormField(
              controller: _destController,
              readOnly: true,
              decoration: InputDecoration(
                hintText: "اضغط لاختيار الوجهة",
                suffixIcon: IconButton(
                  icon: const Icon(Icons.map),
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
            ),
            const SizedBox(height: 16),
            // Seat Price
            TextFormField(
              controller: _seatPriceController,
              decoration: const InputDecoration(
                labelText: "سعر المقعد",
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator:
                  (val) =>
                      (val == null || val.isEmpty)
                          ? "يرجى إدخال سعر مقعد"
                          : null,
            ),
            const SizedBox(height: 16),
            if (_cars.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    "اختيار السيارة",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  DropdownButtonFormField<DocumentSnapshot>(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    value: _selectedCar,
                    items:
                        _cars.map((car) {
                          return DropdownMenuItem<DocumentSnapshot>(
                            value: car,
                            child: Text(
                              "${car['model']} - ${car['plateNumber']}",
                            ),
                          );
                        }).toList(),
                    onChanged: (newValue) {
                      if (newValue != null) {
                        _onCarSelected(newValue);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            // Smoking
            Row(
              children: [
                const Expanded(
                  child: Text("يسمح بالتدخين", style: TextStyle(fontSize: 16)),
                ),
                IconButton(
                  icon: Icon(
                    _smokingAllowed ? Icons.smoking_rooms : Icons.smoke_free,
                    color: _smokingAllowed ? Colors.green : Colors.red,
                  ),
                  onPressed: () {
                    setState(() {
                      _smokingAllowed = !_smokingAllowed;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Date & Time
            const Text(
              "موعد المغادرة",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _dateController,
                    readOnly: true,
                    decoration: InputDecoration(
                      hintText: "اختر التاريخ",
                      prefixIcon: const Icon(Icons.date_range),
                      border: const OutlineInputBorder(),
                    ),
                    onTap: _pickDate,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _timeController,
                    readOnly: true,
                    decoration: InputDecoration(
                      hintText: "اختر الوقت",
                      prefixIcon: const Icon(Icons.access_time),
                      border: const OutlineInputBorder(),
                    ),
                    onTap: _pickTime,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Repeat
            const Text(
              "التكرار",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(border: OutlineInputBorder()),
              value: _repeatOption,
              items: const [
                DropdownMenuItem(value: 'once', child: Text("مرة واحدة")),
                DropdownMenuItem(value: 'daily', child: Text("يوميًا")),
                DropdownMenuItem(
                  value: 'daysOfWeek',
                  child: Text("تحديد أيام الأسبوع"),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _repeatOption = value;
                  });
                }
              },
            ),
            if (_repeatOption == 'daysOfWeek') ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
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
                  return FilterChip(
                    label: Text(dayNames[index]),
                    selected: _weekdaySelected[index],
                    onSelected: (selected) {
                      setState(() {
                        _weekdaySelected[index] = selected;
                      });
                    },
                  );
                }),
              ),
            ],
            const SizedBox(height: 16),
            // Seat layout
            const Text(
              "تخطيط المقاعد",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: TextDirection.ltr,
              child: _buildSeatLayout(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _submitRide,
              child: const Text("إنشاء الرحلة", style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

// ====================== LocationPickerPage with Integrated Search Bar ======================
class LocationPickerPage extends StatefulWidget {
  final LatLng? initialCenter;
  const LocationPickerPage({this.initialCenter});

  @override
  _LocationPickerPageState createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final MapController _mapController = MapController();
  LatLng _center = LatLng(0, 0);
  LatLng? _pickedLocation;
  bool _loadingName = false;
  String? _pickedName;
  final TextEditingController _searchController = TextEditingController();

  // Holds search results.
  List<OSMPlace> _searchResults = [];

  @override
  void initState() {
    super.initState();
    if (widget.initialCenter != null) {
      _center = widget.initialCenter!;
      _pickedLocation = _center;
      _fetchLocationName(_center);
    } else {
      _initCurrentLocation();
    }
  }

  Future<void> _initCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
      setState(() {
        _center = LatLng(pos.latitude, pos.longitude);
        _pickedLocation = _center;
      });
      _fetchLocationName(_center);
    } catch (e) {
      debugPrint("Error getting current location: $e");
    }
  }

  Future<List<OSMPlace>> _searchPlaces(String query) async {
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/search?format=json&accept-language=ar&q=$query",
    );
    final response = await http.get(
      url,
      headers: {"User-Agent": "FlutterRideApp/1.0"},
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List;
      return data.map<OSMPlace>((item) {
        final lat = double.tryParse(item['lat']) ?? 0.0;
        final lon = double.tryParse(item['lon']) ?? 0.0;
        return OSMPlace(
          displayName: item['display_name'],
          name: item['display_name'],
          point: LatLng(lat, lon),
        );
      }).toList();
    } else {
      return [];
    }
  }

  Future<void> _fetchLocationName(LatLng point) async {
    setState(() {
      _loadingName = true;
      _pickedName = null;
    });
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/reverse?format=json&lat=${point.latitude}&lon=${point.longitude}&accept-language=ar&addressdetails=1",
    );
    try {
      final response = await http.get(
        url,
        headers: {"User-Agent": "FlutterRideApp/1.0"},
      );
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final displayName = data['display_name'] ?? "";
        setState(() {
          _pickedName = displayName.split(',')[0];
        });
      }
    } catch (e) {
      debugPrint("Error fetching location name: $e");
    } finally {
      setState(() {
        _loadingName = false;
      });
    }
  }

  void _onMapTap(TapPosition tapPos, LatLng latlng) {
    setState(() {
      _pickedLocation = latlng;
      _searchResults.clear();
      _searchController.clear();
    });
    _fetchLocationName(latlng);
  }

  void _confirmLocation() {
    if (_pickedLocation != null && _pickedName != null) {
      Navigator.pop(context, {
        "lat": _pickedLocation!.latitude,
        "lon": _pickedLocation!.longitude,
        "name": _pickedName!,
      });
    } else {
      Navigator.pop(context);
    }
  }

  void _onSearchChanged(String query) async {
    if (query.isEmpty) {
      setState(() {
        _searchResults.clear();
      });
      return;
    }
    final results = await _searchPlaces(query);
    setState(() {
      _searchResults = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("اختر الموقع على الخريطة")),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 13.0,
              onTap: _onMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                subdomains: ['a', 'b', 'c'],
              ),
              if (_pickedLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _pickedLocation!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_pin,
                        color: Colors.red,
                        size: 40,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          // search bar
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: "ابحث عن موقع...",
                  border: InputBorder.none,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _searchResults.clear();
                      });
                    },
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          ),
          if (_searchResults.isNotEmpty)
            Positioned(
              top: 60,
              left: 10,
              right: 10,
              child: Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _searchResults.length,
                  itemBuilder: (context, index) {
                    final suggestion = _searchResults[index];
                    return ListTile(
                      title: Text(
                        suggestion.displayName,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () {
                        setState(() {
                          _pickedLocation = suggestion.point;
                          _center = suggestion.point;
                          _mapController.move(suggestion.point, 13.0);
                          _searchController.text = suggestion.displayName;
                          _searchResults.clear();
                        });
                        _fetchLocationName(suggestion.point);
                      },
                    );
                  },
                ),
              ),
            ),
          // city name
          Positioned(
            top: 270,
            left: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child:
                    _loadingName
                        ? const Text("جارٍ تحديد اسم الموقع...")
                        : Text(
                          _pickedName ?? "اضغط على الخريطة لاختيار موقع",
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14),
                        ),
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: ElevatedButton.icon(
              onPressed: _confirmLocation,
              icon: const Icon(Icons.check),
              label: const Text("تأكيد الموقع"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
