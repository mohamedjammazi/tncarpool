import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';
import 'dart:async'; // For Timer (if used elsewhere)

// --- Ensure these imports point to the correct files ---
// import 'homepage_functions/phone_check.dart'; // No longer needed here as AuthWrapper handles it
import 'homepage_functions/permissions_util.dart'; // Assuming PositionData is defined here
import 'homepage_functions/rides_service.dart'; // Assuming fetchRides and filterAndSort are defined here
import 'add_car.dart' as add_car;
import 'CreateRide.dart';
import 'ride_details_page.dart';
import 'my_cars.dart';
import 'chat_list_page.dart';
import 'get_started_page.dart';
import 'my_ride_page.dart';
import 'account_page.dart'; // <<<< Ensure AccountPage takes profileUserId and displays reviews

/// Enhanced HomePage with Gold System, Rewarded Ads, and Profile Navigation.
/// Assumes user arrives here only after AuthWrapper confirms phone number exists.
class HomePage extends StatefulWidget {
  /// The currently authenticated Firebase user.
  final User user;

  /// Creates the HomePage widget. Requires the authenticated user.
  const HomePage({super.key, required this.user});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ---------------------------------------------------------------------------
  // Dependencies & Services
  // ---------------------------------------------------------------------------
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ---------------------------------------------------------------------------
  // State Variables
  // ---------------------------------------------------------------------------

  // --- Loading & Initialization ---
  bool _isInitialLoading = true;
  bool _isFetchingRides = false;
  String _loadingMessage = 'Initializing...';

  // --- Permissions & Location ---
  bool _locGranted = false;
  bool _notifGranted = false;
  PositionData? _userPosition;

  // --- Rides Data ---
  List<Map<String, dynamic>> _allRides = [];
  List<Map<String, dynamic>> _filteredRides = [];

  // --- Filtering & Sorting ---
  final TextEditingController _searchController = TextEditingController();
  double _distanceKm = 30.0;
  String _sortOption = 'time';

  // --- Navigation ---
  int _currentIndex = 0; // Home tab is index 0

  // --- Gold System ---
  int _userGold = 0;
  bool _isUpdatingGold = false;

  // --- Rewarded Ad & Limit ---
  final String _rewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917'; // Google's Test ID
  // final String _rewardedAdUnitId = 'YOUR_REAL_ANDROID_REWARDED_AD_ID'; // Replace in production
  RewardedAd? _rewardedAd;
  bool _isRewardedAdLoading = false;
  final int _goldRewardAmount = 2;
  final int _maxAdsPerHour = 10;
  List<Timestamp> _rewardedAdTimestamps = [];
  bool _canWatchRewardedAd = true;

  // ---------------------------------------------------------------------------
  // Initialization & Data Fetching Methods
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _initializeHomePage();
    _loadRewardedAd();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _rewardedAd?.dispose();
    super.dispose();
  }

  Future<void> _initializeHomePage() async {
    if (!mounted) return;
    print("HomePage: Initializing...");
    setState(() => _isInitialLoading = true);

    // Fetch user-specific data first
    await _fetchUserData();
    // Perform checks for permissions and location
    await _performInitialChecks();

    // Proceed to fetch rides only if initialization is still considered ongoing
    // (e.g., permission checks didn't cause an early exit or state change)
    if (mounted && _isInitialLoading) {
      print("HomePage: Initial checks complete, fetching rides...");
      setState(() {
        _loadingMessage = 'Loading rides...';
        // _isFetchingRides = true; // Handled by _fetchAndFilterRides
      });
      await _fetchAndFilterRides();
      // Fetching rides state is handled within that function
    } else {
      print(
        "HomePage: Initial checks failed or component unmounted, skipping ride fetch.",
      );
    }

    // Ensure loading is set to false after all initial async operations
    if (mounted) {
      print("HomePage: Initialization sequence finished.");
      setState(() => _isInitialLoading = false);
    }
  }

  /// Performs initial checks for Permissions and Location.
  /// Phone check is removed as AuthWrapper handles it before navigating here.
  Future<void> _performInitialChecks() async {
    if (!mounted) return;
    print("HomePage: Performing initial checks (Permissions, Location)...");

    // --- Phone Check Removed ---
    // This check is redundant because AuthWrapper guarantees the user
    // has a phone number before navigating to HomePage.
    // --- End Phone Check Removed ---

    setState(() => _loadingMessage = 'Requesting permissions...');
    try {
      _locGranted = await requestLocationPermission();
      _notifGranted = await requestNotificationPermission();
      print(
        "HomePage: Location granted: $_locGranted, Notifications granted: $_notifGranted",
      );

      if (_locGranted && mounted) {
        setState(() => _loadingMessage = 'Fetching location...');
        _userPosition = await getUserPosition();
        print(
          "HomePage: User position fetched: ${_userPosition?.latitude}, ${_userPosition?.longitude}",
        );
      }
    } catch (e) {
      print("HomePage: Error during initial checks: $e");
      // Decide how to handle permission/location errors (e.g., show message)
      // Setting _isInitialLoading to false will allow build method to show main UI
      // but features depending on location might be disabled or show prompts.
    }
    print("HomePage: Initial checks function finished.");
    // Note: _isInitialLoading is set to false in _initializeHomePage after this completes
  }

  Future<void> _fetchUserData() async {
    // Fetches user's gold and ad timestamps from Firestore
    if (!mounted) return;
    print("HomePage: Fetching user data (gold, ad timestamps)...");
    try {
      final userDoc =
          await _firestore.collection('users').doc(widget.user.uid).get();
      if (mounted && userDoc.exists) {
        final data = userDoc.data() ?? {};
        final fetchedGold = (data['gold'] ?? 0).toInt();
        final fetchedTimestamps = List<Timestamp>.from(
          data['rewardedAdTimestamps'] ?? [],
        );

        if (mounted) {
          // Check mounted again after await
          setState(() {
            _userGold = fetchedGold;
            _rewardedAdTimestamps = fetchedTimestamps;
          });
          _checkAdLimit();
          print("HomePage: User data fetched. Gold: $_userGold");
        }
      } else if (mounted) {
        print(
          "HomePage WARNING: User document not found (UID: ${widget.user.uid}). Using defaults.",
        );
        setState(() {
          _userGold = 0;
          _rewardedAdTimestamps = [];
          _canWatchRewardedAd = true;
        });
      }
    } catch (e) {
      print("HomePage: Error fetching user data: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not fetch user data: ${e.toString()}')),
        );
        _checkAdLimit();
      }
    }
  }

  Future<void> _fetchAndFilterRides() async {
    // Fetches rides and applies filters
    if (!mounted) return;
    print("HomePage: Fetching and filtering rides...");
    setState(() => _isFetchingRides = true);

    try {
      // Ensure fetchRides includes driverId AND driver details like name, imageUrl, averageRating
      _allRides = await fetchRides(widget.user.uid);
      print("HomePage: Fetched ${_allRides.length} potential rides.");
      if (mounted) {
        _applyFilters(); // Apply filters immediately
        print(
          "HomePage: Applied filters, ${_filteredRides.length} rides displayed.",
        );
      }
    } catch (e) {
      print("HomePage: Error fetching rides: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load rides: ${e.toString()}')),
        );
        _allRides = [];
        _filteredRides = [];
        setState(() {}); // Update UI to show empty list due to error
      }
    } finally {
      if (mounted) {
        setState(() => _isFetchingRides = false);
        print("HomePage: Finished fetching rides.");
      }
    }
  }

  Future<void> _onRefresh() async {
    // Pull-to-refresh handler
    if (!mounted) return;
    print("HomePage: Refresh triggered.");
    // Refresh both rides and user data concurrently
    await Future.wait([
      _fetchAndFilterRides(), // This handles its own loading state
      _fetchUserData(),
    ]);
    print("HomePage: Refresh complete.");
  }

  // ---------------------------------------------------------------------------
  // Filtering & Sorting Logic
  // ---------------------------------------------------------------------------

  void _onSearchChanged() {
    // Debounce search? For now, filter on every change.
    if (mounted) _applyFilters();
  }

  void _applyFilters() {
    print(
      "HomePage: Applying filters. Query: '${_searchController.text}', Sort: $_sortOption, Dist: $_distanceKm",
    );
    _filteredRides = filterAndSort(
      allRides: _allRides,
      userPosition: _userPosition,
      locationGranted: _locGranted,
      distanceKm: _distanceKm,
      searchQuery: _searchController.text,
      sortOption: _sortOption,
    );
    if (mounted) setState(() {}); // Update UI with filtered list
  }

  // ---------------------------------------------------------------------------
  // Rewarded Ad Logic (Keep as is)
  // ---------------------------------------------------------------------------
  void _checkAdLimit() {
    /* ... Ad limit check logic ... */
    if (!mounted) return;
    final now = DateTime.now();
    final oneHourAgo = now.subtract(const Duration(hours: 1));
    final recentTimestamps =
        _rewardedAdTimestamps
            .where((ts) => ts.toDate().isAfter(oneHourAgo))
            .toList();
    final bool canWatch = recentTimestamps.length < _maxAdsPerHour;
    if (_canWatchRewardedAd != canWatch && mounted) {
      setState(() => _canWatchRewardedAd = canWatch);
    }
    // print('Ad Limit Check: ${recentTimestamps.length}/$_maxAdsPerHour ads watched. Can watch: $_canWatchRewardedAd'); // Less frequent logging maybe
  }

  void _loadRewardedAd() {
    /* ... Ad loading logic ... */
    if (_isRewardedAdLoading || !mounted) return;
    setState(() => _isRewardedAdLoading = true);
    print('HomePage: Loading Rewarded Ad...');
    RewardedAd.load(
      adUnitId: _rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          print('HomePage: Rewarded Ad loaded.');
          if (!mounted) {
            ad.dispose();
            return;
          }
          _rewardedAd?.dispose();
          _rewardedAd = ad;
          _isRewardedAdLoading = false;
          _setRewardedAdCallbacks();
        },
        onAdFailedToLoad: (LoadAdError error) {
          print('HomePage: Rewarded Ad failed load: $error');
          if (!mounted) return;
          _rewardedAd = null;
          _isRewardedAdLoading = false;
        },
      ),
    );
  }

  void _setRewardedAdCallbacks() {
    /* ... Ad callbacks logic ... */
    _rewardedAd?.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) => print('HomePage: Ad showed.'),
      onAdDismissedFullScreenContent: (ad) {
        print('HomePage: Ad dismissed.');
        ad.dispose();
        _rewardedAd = null;
        if (mounted) _loadRewardedAd();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        print('HomePage: Ad failed show: $error');
        ad.dispose();
        _rewardedAd = null;
        if (mounted) _loadRewardedAd();
      },
      onAdImpression: (ad) => print('HomePage: Ad impression.'),
    );
  }

  void _showRewardedAd() {
    /* ... Show ad logic ... */
    _checkAdLimit();
    if (!_canWatchRewardedAd) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hourly ad limit reached ($_maxAdsPerHour/hour).'),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      return;
    }
    if (_rewardedAd == null) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reward ad not ready. Loading...')),
        );
      if (!_isRewardedAdLoading) _loadRewardedAd();
      return;
    }
    _setRewardedAdCallbacks();
    _rewardedAd!.show(
      onUserEarnedReward: (ad, reward) {
        _grantGoldReward();
      },
    );
    _rewardedAd = null;
  }

  Future<void> _grantGoldReward() async {
    /* ... Grant reward logic ... */
    if (!mounted) return;
    setState(() => _isUpdatingGold = true);
    final Timestamp currentTime = Timestamp.now();
    try {
      final userRef = _firestore.collection('users').doc(widget.user.uid);
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
      print("HomePage: Error updating gold/timestamp: $e");
      if (mounted) setState(() => _isUpdatingGold = false);
      _fetchUserData(); // Refetch on error
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving reward: ${e.toString()}')),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation & Actions (Keep as is)
  // ---------------------------------------------------------------------------
  void _onBottomNavTapped(int index) {
    if (!mounted || index == _currentIndex) return;
    _navigateToIndex(index);
  }

  Future<void> _navigateCreateRide() async {
    _pushPage(CreateRidePage());
  }

  void _navigateAddCar() => _pushPage(const add_car.AddCarPage());
  void _navigateMyCars() => _pushPage(const MyCarsPage());
  void _navigateChatList() => _pushPage(const ChatListPage());

  void _pushPage(Widget page) {
    if (mounted)
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _signOut() async {
    /* ... Keep sign out logic ... */
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Confirm Sign Out'),
            content: const Text('Are you sure?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Sign Out'),
              ),
            ],
          ),
    );
    if (confirm == true && mounted) {
      try {
        await _googleSignIn.signOut();
        await _auth.signOut();
        if (mounted)
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const GetStartedPage()),
            (route) => false,
          );
      } catch (e) {
        print("HomePage: Error signing out: $e");
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error signing out: ${e.toString()}')),
          );
      }
    }
  }

  void _callDriver(String? phone) async {
    /* ... Keep call driver logic ... */
    if (phone == null || phone.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Driver phone unavailable.')),
        );
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not call $phone.')));
      }
    } catch (e) {
      print("HomePage: Could not launch call: $e");
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error making call: ${e.toString()}')),
        );
    }
  }

  void _goToRideDetails(Map<String, dynamic> ride) {
    /* ... Keep go to ride details logic ... */
    final String? rideId = ride['id'] as String?;
    if (rideId == null || rideId.isEmpty) {
      print("HomePage Error: Ride ID missing.");
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot open details: Missing ID.')),
        );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RideDetailPage(rideId: rideId)),
    );
  }

  // ---------------------------------------------------------------------------
  // Build Method (Keep as is)
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    print(
      "HomePage: Build method called. isInitialLoading: $_isInitialLoading",
    );
    if (_isInitialLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(
                _loadingMessage,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    // Main UI
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        tooltip: 'Create Ride',
        onPressed: _navigateCreateRide,
        child: const Icon(Icons.add_road),
      ),
      body: NestedScrollView(
        headerSliverBuilder:
            (context, innerBoxIsScrolled) => [_buildSliverAppBar()],
        body: RefreshIndicator(
          onRefresh: _onRefresh,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 0),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    _buildUserProfileCard(),
                    const SizedBox(height: 30),
                    _buildQuickActions(),
                    const SizedBox(height: 20),
                    _buildSearchField(),
                    const SizedBox(height: 16),
                    _buildSortDistanceRow(),
                    const SizedBox(height: 24),
                    const Text(
                      'Available Rides',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ]),
                ),
              ),
              _isFetchingRides ? _buildShimmerList() : _buildRidesListSliver(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNavigationBar(),
    );
  }

  // ---------------------------------------------------------------------------
  // UI Widget Builder Methods (Keep as is, including updated _buildRideCard)
  // ---------------------------------------------------------------------------

  Widget _buildSliverAppBar() {
    return SliverAppBar(
      /* ... AppBar structure ... */
      expandedHeight: 230.0,
      floating: false,
      pinned: true,
      snap: false,
      backgroundColor: Colors.green.shade700,
      iconTheme: const IconThemeData(color: Colors.white),
      actionsIconTheme: const IconThemeData(color: Colors.white),
      flexibleSpace: FlexibleSpaceBar(
        centerTitle: true,
        titlePadding: const EdgeInsets.symmetric(
          horizontal: 16.0,
          vertical: 12.0,
        ),
        title: Text(
          'Available Rides',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16.0,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(blurRadius: 2.0, color: Colors.black.withOpacity(0.5)),
            ],
          ),
        ),
        background: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              'https://images.unsplash.com/photo-1449965408869-eaa3f722e40d?crop=entropy&cs=tinysrgb&fit=crop&fm=jpg&h=900&w=1600',
              fit: BoxFit.cover,
              loadingBuilder:
                  (context, child, progress) =>
                      progress == null
                          ? child
                          : Container(color: Colors.green.shade600),
              errorBuilder:
                  (context, error, stack) => Container(
                    color: Colors.green.shade500,
                    child: const Icon(
                      Icons.error_outline,
                      color: Colors.white70,
                      size: 40,
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
                    Colors.transparent,
                    Colors.black.withOpacity(0.5),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor:
                _canWatchRewardedAd ? Colors.white : Colors.grey.shade400,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          icon: Icon(
            Icons.monetization_on,
            color:
                _canWatchRewardedAd
                    ? Colors.yellow.shade600
                    : Colors.grey.shade400,
            size: 20,
          ),
          label: Text(
            'Earn Gold',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: _canWatchRewardedAd ? Colors.white : Colors.grey.shade400,
            ),
          ),
          onPressed: _canWatchRewardedAd ? _showRewardedAd : null,
        ),
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Sign Out',
          onPressed: _signOut,
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildUserProfileCard() {
    return Stack(
      /* ... User profile card structure ... */
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 35),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.green.shade600, Colors.green.shade800],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.green.withOpacity(0.4),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 35,
                backgroundColor: Colors.white.withOpacity(0.9),
                backgroundImage:
                    (widget.user.photoURL != null &&
                            widget.user.photoURL!.isNotEmpty)
                        ? NetworkImage(widget.user.photoURL!)
                        : null,
                child:
                    (widget.user.photoURL == null ||
                            widget.user.photoURL!.isEmpty)
                        ? Icon(
                          Icons.person,
                          size: 35,
                          color: Colors.green.shade700,
                        )
                        : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Welcome, ${widget.user.displayName ?? 'User'}!',
                  style: const TextStyle(
                    fontSize: 22,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          bottom: -15,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
              border: Border.all(color: Colors.yellow.shade700, width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.monetization_on,
                  color: Colors.yellow.shade700,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '$_userGold Gold',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.brown.shade800,
                  ),
                ),
                if (_isUpdatingGold)
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.brown.shade800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActions() {
    return SizedBox(
      /* ... Quick actions list view ... */
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          _actionItem(
            icon: Icons.add_circle_outline,
            label: 'Add Car',
            color: Colors.blue.shade600,
            onTap: _navigateAddCar,
          ),
          _actionItem(
            icon: Icons.directions_car,
            label: 'My Cars',
            color: Colors.orange.shade700,
            onTap: _navigateMyCars,
          ),
          _actionItem(
            icon: Icons.message_outlined,
            label: 'Messages',
            color: Colors.purple.shade500,
            onTap: _navigateChatList,
          ),
          _actionItem(
            icon: Icons.add_road_outlined,
            label: 'Create Ride',
            color: Colors.teal.shade600,
            onTap: _navigateCreateRide,
          ),
        ],
      ),
    );
  }

  Widget _actionItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Padding(
      /* ... Single action item structure ... */
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 85,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.2),
                blurRadius: 6,
                spreadRadius: 1,
                offset: const Offset(0, 3),
              ),
            ],
            border: Border.all(color: Colors.grey.shade200, width: 0.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: color.withOpacity(0.15),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade800,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      /* ... Search field structure ... */
      controller: _searchController,
      decoration: InputDecoration(
        hintText: 'Search by destination or start point...',
        prefixIcon: const Icon(Icons.search, color: Colors.grey),
        filled: true,
        fillColor: Colors.grey.shade100,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 14.0,
          horizontal: 16.0,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.green.shade600, width: 1.5),
        ),
        suffixIcon:
            _searchController.text.isNotEmpty
                ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey),
                  tooltip: 'Clear Search',
                  onPressed: () {
                    _searchController.clear();
                  },
                )
                : null,
      ),
    );
  }

  Widget _buildSortDistanceRow() {
    return Row(
      /* ... Sort/Distance row structure ... */
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            value: _sortOption,
            items: const [
              DropdownMenuItem(value: 'time', child: Text('Departure Time')),
              DropdownMenuItem(value: 'price', child: Text('Price')),
              DropdownMenuItem(value: 'distance', child: Text('Distance')),
            ],
            onChanged: (value) {
              if (value != null && mounted) {
                setState(() => _sortOption = value);
                _applyFilters();
              }
            },
            decoration: InputDecoration(
              labelText: 'Sort By',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300, width: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300, width: 0.5),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            style: const TextStyle(color: Colors.black87, fontSize: 14),
            icon: Icon(Icons.sort, color: Colors.grey.shade600),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 0),
                child: Text(
                  'Max Distance: ${_distanceKm.toInt()} km',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.green.shade500,
                  inactiveTrackColor: Colors.green.shade100,
                  thumbColor: Colors.green.shade700,
                  overlayColor: Colors.green.withOpacity(0.2),
                  trackHeight: 2.0,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8.0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16.0,
                  ),
                ),
                child: Slider(
                  value: _distanceKm,
                  min: 5,
                  max: 150,
                  divisions: 29,
                  onChanged:
                      !_locGranted
                          ? null
                          : (value) {
                            if (mounted) {
                              setState(() => _distanceKm = value);
                              _applyFilters();
                            }
                          },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRidesListSliver() {
    if (_filteredRides.isEmpty) return _buildNoRidesSliver();
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildRideCard(_filteredRides[index]),
          childCount: _filteredRides.length,
        ),
      ),
    );
  }

  Widget _buildShimmerList() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildShimmerCard(),
          childCount: 5,
        ),
      ),
    );
  }

  Widget _buildShimmerCard() {
    return Shimmer.fromColors(
      /* ... Shimmer card structure ... */
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Card(
        margin: const EdgeInsets.only(bottom: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const CircleAvatar(radius: 28, backgroundColor: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(width: 120, height: 18, color: Colors.white),
                        const SizedBox(height: 6),
                        Container(width: 180, height: 14, color: Colors.white),
                      ],
                    ),
                  ),
                  Container(width: 30, height: 30, color: Colors.white),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 120,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  Container(
                    width: 90,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoRidesSliver() {
    return SliverFillRemaining(
      /* ... No rides structure ... */
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.explore_off_outlined,
                size: 80,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 16),
              Text(
                'No Rides Found',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _searchController.text.isNotEmpty
                    ? 'Try adjusting your search or distance filter.'
                    : 'No rides match your criteria. Try refreshing or create one!',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh Rides'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  textStyle: const TextStyle(fontSize: 16),
                ),
                onPressed: _onRefresh,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- UPDATED _buildRideCard to use averageRating ---
  Widget _buildRideCard(Map<String, dynamic> ride) {
    final driverData = ride['driver'] as Map<String, dynamic>? ?? {};
    final driverName = driverData['name'] as String? ?? 'Unknown Driver';
    final driverPhotoUrl = driverData['imageUrl'] as String? ?? '';
    final driverPhone = driverData['phone'] as String?;
    final driverId = ride['driverId'] as String?;
    // *** USE averageRating field from driver data ***
    final driverAvgRatingNum =
        driverData['averageRating'] as num?; // Get average rating
    final driverAvgRating =
        driverAvgRatingNum?.toDouble() ?? 0.0; // Convert, default 0.0

    int availableSeats = 0;
    final seatLayout = ride['seatLayout'];
    if (seatLayout is List) {
      availableSeats =
          seatLayout
              .where(
                (s) =>
                    s is Map &&
                    s['type'] == 'share' &&
                    s['bookedBy'] == "n/a" &&
                    s['offered'] == true,
              )
              .length;
    }
    String departureTimeStr = 'N/A';
    final timestamp = ride['date'] as Timestamp?;
    if (timestamp != null) {
      departureTimeStr = DateFormat(
        'MMM d, hh:mm a',
      ).format(timestamp.toDate());
    }
    final startLocation =
        ride['startLocationName'] as String? ?? 'Not specified';
    final endLocation = ride['endLocationName'] as String? ?? 'Not specified';
    final price = ride['price']?.toString() ?? 'N/A';

    return Card(
      /* ... Card structure ... */
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 4,
      shadowColor: Colors.grey.withOpacity(0.3),
      child: InkWell(
        onTap: () => _goToRideDetails(ride),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InkWell(
                    onTap: () {
                      if (driverId != null && driverId.isNotEmpty) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (_) => AccountPage(profileUserId: driverId),
                          ),
                        );
                      } else {
                        print("Error: Driver ID missing.");
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Cannot open driver profile: ID missing.',
                            ),
                          ),
                        );
                      }
                    },
                    child: CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.grey.shade200,
                      backgroundImage:
                          driverPhotoUrl.isNotEmpty
                              ? NetworkImage(driverPhotoUrl)
                              : null,
                      child:
                          driverPhotoUrl.isEmpty
                              ? const Icon(
                                Icons.person,
                                size: 30,
                                color: Colors.grey,
                              )
                              : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          driverName,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.star,
                              size: 16,
                              color: Colors.amber,
                            ),
                            const SizedBox(width: 3),
                            // --- Display fetched averageRating ---
                            Text(
                              driverAvgRating.toStringAsFixed(1),
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontSize: 13,
                              ),
                            ),
                            // --- End Display ---
                            const SizedBox(width: 10),
                            Icon(
                              Icons.access_time,
                              size: 16,
                              color: Colors.grey.shade600,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              departureTimeStr,
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (driverPhone != null && driverPhone.isNotEmpty)
                    IconButton(
                      icon: const Icon(
                        Icons.phone_outlined,
                        color: Colors.green,
                      ),
                      tooltip: 'Call Driver',
                      onPressed: () => _callDriver(driverPhone),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _infoChip(
                    icon: Icons.event_seat_outlined,
                    label:
                        '$availableSeats Seat${availableSeats != 1 ? 's' : ''} Available',
                    color: Colors.blue.shade700,
                  ),
                  _infoChip(
                    icon: Icons.local_offer_outlined,
                    label: '$price DZD',
                    color: Colors.orange.shade800,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                /* ... Location box ... */ padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200, width: 0.5),
                ),
                child: Row(
                  children: [
                    Column(
                      children: [
                        Icon(
                          Icons.trip_origin,
                          size: 18,
                          color: Colors.green.shade700,
                        ),
                        Container(
                          height: 35,
                          width: 1,
                          color: Colors.grey.shade300,
                        ),
                        Icon(
                          Icons.location_on,
                          size: 18,
                          color: Colors.red.shade600,
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            startLocation,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            endLocation,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('View Details'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _goToRideDetails(ride),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      /* ... Info chip structure ... */ padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return BottomNavigationBar(
      /* ... Bottom nav structure ... */ currentIndex: _currentIndex,
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

  // Navigation logic remains the same
  void _navigateToIndex(int index) {
    if (index == _currentIndex) return;
    Widget? targetPage;
    bool removeUntil = true;
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
        return; // Already home
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
        targetPage = AccountPage(profileUserId: currentUser.uid);
        break; // Navigate to own profile
      default:
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
    }
  }
} // End of _HomePageState
