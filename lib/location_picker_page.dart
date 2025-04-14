import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'dart:async'; // Import dart:async for Timer

// Model representing an OSM place for search results
class OSMPlace {
  final String displayName;
  final String name; // Often a shorter version or primary name
  final LatLng point;

  OSMPlace({
    required this.displayName,
    required this.name,
    required this.point,
  });

  // Factory constructor to parse JSON from Nominatim search
  factory OSMPlace.fromJsonSearch(Map<String, dynamic> json) {
    final lat = double.tryParse(json['lat']?.toString() ?? '0.0') ?? 0.0;
    final lon = double.tryParse(json['lon']?.toString() ?? '0.0') ?? 0.0;
    final displayName = json['display_name'] as String? ?? 'Unknown';
    // Attempt to get a shorter name from address details if available
    final address = json['address'] as Map<String, dynamic>?;
    String name = displayName; // Default to full display name
    if (address != null) {
      name =
          address['road'] ??
          address['neighbourhood'] ??
          address['suburb'] ??
          address['city'] ??
          address['town'] ??
          address['village'] ??
          displayName;
    }

    return OSMPlace(
      displayName: displayName,
      name: name.split(',')[0], // Often take the first part as a simpler name
      point: LatLng(lat, lon),
    );
  }
}

/// A page allowing users to pick a location using an interactive map and search.
class LocationPickerPage extends StatefulWidget {
  /// Optional initial center point for the map.
  final LatLng? initialCenter;

  const LocationPickerPage({super.key, this.initialCenter});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(); // To control focus

  // State variables
  LatLng? _currentMapCenter; // Tracks the center of the map view
  LatLng? _pickedLocation; // The actual coordinates picked by the user
  String?
  _pickedName; // Name associated with _pickedLocation (from reverse geocode)
  bool _isLoadingName = false; // True while fetching name via reverse geocoding
  bool _isLoadingSearch = false; // True while fetching search results
  List<OSMPlace> _searchResults = []; // List of places found via search

  // Debouncer for search to avoid excessive API calls
  Timer? _debounceTimer; // Use Timer from dart:async

  // Define User-Agent string using provided package name
  final String _userAgent =
      "com.example.carpooling_app/1.0"; // Use your package name

  @override
  void initState() {
    super.initState();
    _initializeMapCenter();
    // Add listener for search input changes
    _searchController.addListener(() {
      _debounceTimer?.cancel(); // Cancel previous timer if user types quickly
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        // Wait 500ms after user stops typing
        if (mounted) {
          _performSearch(_searchController.text);
        }
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel(); // Cancel timer on dispose
    super.dispose();
  }

  /// Sets the initial center of the map, either from input or current location.
  Future<void> _initializeMapCenter() async {
    if (widget.initialCenter != null) {
      setState(() {
        _currentMapCenter = widget.initialCenter!;
        _pickedLocation = _currentMapCenter;
      });
      await _fetchLocationName(_currentMapCenter!);
    } else {
      await _initCurrentLocation();
    }
  }

  /// Fetches the user's current GPS location.
  Future<void> _initCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled && mounted) {
      /* ... handle disabled ... */
      setState(() => _currentMapCenter = const LatLng(36.8, 10.18));
      return;
    }
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied && mounted) {
        /* ... handle denied ... */
        setState(() => _currentMapCenter = const LatLng(36.8, 10.18));
        return;
      }
    }
    if (permission == LocationPermission.deniedForever && mounted) {
      /* ... handle denied forever ... */
      setState(() => _currentMapCenter = const LatLng(36.8, 10.18));
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() {
          _currentMapCenter = LatLng(pos.latitude, pos.longitude);
          _pickedLocation = _currentMapCenter;
        });
        await _fetchLocationName(_currentMapCenter!);
      }
    } catch (e) {
      /* ... handle error ... */
      if (mounted)
        setState(() => _currentMapCenter = const LatLng(36.8, 10.18));
    }
  }

  /// Performs search using Nominatim API based on the query.
  Future<void> _performSearch(String query) async {
    if (query.trim().length < 3) {
      if (mounted) setState(() => _searchResults = []);
      return;
    }
    if (!mounted) return;
    setState(() => _isLoadingSearch = true);
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(query)}&limit=10&accept-language=ar,en&addressdetails=1",
    );
    try {
      // ** Use updated User-Agent **
      final response = await http.get(url, headers: {"User-Agent": _userAgent});
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body) as List;
        setState(
          () =>
              _searchResults =
                  data.map((item) => OSMPlace.fromJsonSearch(item)).toList(),
        );
      } else {
        if (mounted) setState(() => _searchResults = []);
      }
    } catch (e) {
      if (mounted) setState(() => _searchResults = []);
    } finally {
      if (mounted) setState(() => _isLoadingSearch = false);
    }
  }

  /// Fetches a human-readable name for a given LatLng point using Nominatim reverse geocoding.
  Future<void> _fetchLocationName(LatLng point) async {
    if (!mounted) return;
    setState(() {
      _isLoadingName = true;
      _pickedName = null;
    });
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/reverse?format=json&lat=${point.latitude}&lon=${point.longitude}&accept-language=ar,en&addressdetails=1",
    );
    try {
      // ** Use updated User-Agent **
      final response = await http.get(url, headers: {"User-Agent": _userAgent});
      if (response.statusCode == 200 && mounted) {
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
        if (name.isEmpty) name = data['display_name'] ?? 'Selected Location';
        setState(() => _pickedName = name.split(',')[0].trim());
      } else {
        if (mounted) setState(() => _pickedName = 'Unknown Location');
      }
    } catch (e) {
      if (mounted) setState(() => _pickedName = 'Error fetching name');
    } finally {
      if (mounted) setState(() => _isLoadingName = false);
    }
  }

  /// Handles map tap events to select a location.
  void _onMapTap(TapPosition tapPos, LatLng latlng) {
    if (!mounted) return;
    setState(() {
      _pickedLocation = latlng;
      _searchResults = [];
      _searchController.clear();
      _searchFocusNode.unfocus();
    });
    _fetchLocationName(latlng);
  }

  /// Handles map position changes (e.g., user panning/zooming).
  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    _currentMapCenter = camera.center;
    // Optional: Fetch name on gesture end
    // if (!hasGesture) { _fetchLocationName(camera.center); }
  }

  /// Selects a place from the search results list.
  void _selectSearchResult(OSMPlace place) {
    if (!mounted) return;
    setState(() {
      _pickedLocation = place.point;
      _pickedName = place.name;
      _currentMapCenter = place.point;
      _mapController.move(place.point, 15.0);
      _searchController.text = place.displayName;
      _searchResults = [];
      _searchFocusNode.unfocus();
      _isLoadingName = false;
    });
  }

  /// Confirms the selected location and returns it to the previous page.
  void _confirmLocation() {
    if (_pickedLocation != null &&
        _pickedName != null &&
        _pickedName!.isNotEmpty) {
      Navigator.pop(context, {
        "lat": _pickedLocation!.latitude,
        "lon": _pickedLocation!.longitude,
        "name": _pickedName!,
      });
    } else {
      /* ... show error snackbar ... */
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("اختر الموقع"),
        actions: [
          IconButton(
            tooltip: "Go to My Location",
            icon: const Icon(Icons.my_location),
            onPressed: _initCurrentLocation,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Map View
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentMapCenter ?? const LatLng(36.8, 10.18),
              initialZoom: 14.0,
              onTap: _onMapTap,
              onPositionChanged: _onPositionChanged,
              minZoom: 5.0,
              maxZoom: 18.0,
            ),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
              ),
              if (_pickedLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _pickedLocation!,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
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
          // Search Bar
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Material(
              elevation: 4.0,
              borderRadius: BorderRadius.circular(8.0),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8.0),
                      child: Icon(Icons.search, color: Colors.grey),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        decoration: const InputDecoration(
                          hintText: "ابحث عن مكان...",
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 14.0),
                        ),
                      ),
                    ),
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        tooltip: "Clear Search",
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchResults = []);
                          _searchFocusNode.unfocus();
                        },
                      ),
                    if (_isLoadingSearch)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8.0),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Search Results List
          if (_searchResults.isNotEmpty)
            Positioned(
              top: 70,
              left: 10,
              right: 10,
              child: Material(
                elevation: 4.0,
                borderRadius: BorderRadius.circular(8.0),
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final place = _searchResults[index];
                      return ListTile(
                        leading: const Icon(
                          Icons.place_outlined,
                          color: Colors.blueGrey,
                        ),
                        title: Text(
                          place.displayName,
                          style: const TextStyle(fontSize: 14),
                        ),
                        dense: true,
                        onTap: () => _selectSearchResult(place),
                      );
                    },
                  ),
                ),
              ),
            ),
          // Bottom Info/Confirm Bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Material(
              elevation: 6.0,
              child: Container(
                padding: const EdgeInsets.all(16.0),
                color: Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.location_pin,
                          color: Colors.red,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _isLoadingName
                                ? "جارٍ تحديد اسم الموقع..."
                                : (_pickedName ??
                                    "اضغط على الخريطة لاختيار موقع"),
                            style: Theme.of(context).textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed:
                            (_pickedLocation == null || _isLoadingName)
                                ? null
                                : _confirmLocation,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text("تأكيد هذا الموقع"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Debouncer Class ---
/// Utility class to debounce function calls.
class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }

  void dispose() {
    _timer?.cancel();
  }
}

// --- Add these dependencies to your pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   flutter_map: ^...      # Check latest version
//   latlong2: ^...         # Check latest version
//   geolocator: ^...       # Check latest version
//   http: ^...             # Check latest version
//   # Add other necessary dependencies

// --- IMPORTANT ---
// * User-Agent: The User-Agent string has been updated to use "com.example.carpooling_app/1.0".
// * API Usage Limits: Be mindful of Nominatim's usage limits.
