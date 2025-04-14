import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shimmer/shimmer.dart'; // For review loading shimmer

// Import project pages & widgets
import 'home_page.dart';
import 'my_ride_page.dart';
import 'my_cars.dart';
import 'chat_list_page.dart';
import 'get_started_page.dart';
import 'submit_review_page.dart'; // <<< Import the review submission page

/// Displays user profile information, stats, and reviews.
/// Allows editing for the current user's profile.
class AccountPage extends StatefulWidget {
  /// The User ID of the profile to display.
  final String profileUserId;

  const AccountPage({super.key, required this.profileUserId});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  // Firebase Services
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Form Key for editing
  final _formKey = GlobalKey<FormState>();

  // --- State Variables ---
  // Loading states
  bool _isLoading = true; // Overall page loading
  bool _isEditing = false; // Profile edit mode toggle
  bool _isSaving = false; // While saving profile edits
  bool _isStatsLoading =
      true; // Separate flag for stats loading (can be combined if preferred)
  bool _isLoadingReviews = true; // Separate flag for reviews loading

  // Profile identification
  bool _isCurrentUserProfile = false; // Is this the logged-in user's profile?
  String? _currentUserId; // Logged-in user's ID

  // User Data
  Map<String, dynamic> _userData =
      {}; // Data fetched from Firestore for profileUserId
  double _averageRating = 0.0; // User's average rating
  int _reviewCount = 0; // Number of reviews received

  // Statistics Data
  int _ridesAsDriverCount = 0;
  int _ridesAsPassengerCount = 0; // Note: Still an approximate count

  // Reviews Data
  List<Map<String, dynamic>> _reviewsList = []; // List of reviews fetched

  // Editing Controllers (only used if _isCurrentUserProfile)
  late TextEditingController _nameController;
  late TextEditingController _phoneController;

  // Bottom Navigation State (only used if _isCurrentUserProfile)
  int _currentIndex = 4; // Default index for Account tab

  @override
  void initState() {
    super.initState();
    _currentUserId = _auth.currentUser?.uid;
    _isCurrentUserProfile = widget.profileUserId == _currentUserId;

    // Initialize controllers (will be populated later if editing)
    _nameController = TextEditingController();
    _phoneController = TextEditingController();

    // Redirect to start if user is not logged in
    if (_currentUserId == null) {
      _handleLogoutNavigation();
    } else {
      // Load all necessary data for the profile
      _loadAllAccountData();
    }
  }

  @override
  void dispose() {
    // Dispose controllers to free resources
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// Handles navigation to the GetStartedPage if the user is logged out.
  void _handleLogoutNavigation() {
    // Ensure navigation happens after the build cycle
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const GetStartedPage()),
          (Route<dynamic> route) => false,
        );
      }
    });
  }

  /// Fetches all data needed for the account page concurrently.
  Future<void> _loadAllAccountData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _isStatsLoading = true; // Reset loading states
      _isLoadingReviews = true;
    });

    try {
      // Run data fetching operations in parallel
      await Future.wait([
        _loadUserDataAndStats(), // Fetches user doc, rating, count, and ride stats
        _fetchReviews(), // Fetches reviews
      ]);
    } catch (e) {
      print("Error loading account data: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error loading profile: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
        // Set error state for UI
        _userData = {'name': 'Error Loading', 'email': ''};
        _averageRating = 0.0;
        _reviewCount = 0;
      }
    } finally {
      // Ensure all loading indicators are turned off, even if errors occurred
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isStatsLoading = false; // Assume stats finish with user data
          _isLoadingReviews = false;
        });
      }
    }
  }

  /// Fetches the main user document, rating info, and ride counts.
  Future<void> _loadUserDataAndStats() async {
    try {
      final userDoc =
          await _firestore.collection('users').doc(widget.profileUserId).get();

      if (!mounted) return; // Check mounted after await

      if (userDoc.exists) {
        _userData = userDoc.data() ?? {};
        // Extract rating and review count directly from user document
        _averageRating =
            (_userData['averageRating'] as num?)?.toDouble() ?? 0.0;
        _reviewCount = (_userData['reviewCount'] as int?) ?? 0;

        // Initialize controllers only if viewing own profile
        if (_isCurrentUserProfile) {
          _nameController.text = _userData['name'] ?? '';
          _phoneController.text = _userData['phone'] ?? '';
        }
      } else {
        // Handle case where user document doesn't exist
        print("User document not found for UID: ${widget.profileUserId}");
        _userData = {'name': 'User Not Found', 'email': ''};
        _averageRating = 0.0;
        _reviewCount = 0;
        if (_isCurrentUserProfile) {
          // Fallback to auth data if it's the current user
          _userData['name'] = _auth.currentUser?.displayName ?? 'Error';
          _userData['email'] = _auth.currentUser?.email ?? 'Error';
          _nameController.text = _userData['name'];
          _phoneController.text = '';
        }
      }

      // Fetch ride counts (can be kept separate or combined)
      // Note: Passenger count remains approximate due to Firestore limitations
      final results = await Future.wait([
        _fetchRideCount('driverId', widget.profileUserId),
        _fetchRideCount('seatLayout.bookedBy', widget.profileUserId),
      ]);

      if (mounted) {
        _ridesAsDriverCount = results[0];
        _ridesAsPassengerCount = results[1];
      }
    } catch (e) {
      print("Error in _loadUserDataAndStats for ${widget.profileUserId}: $e");
      rethrow; // Rethrow to be caught by _loadAllAccountData
    }
  }

  /// Fetches reviews for the currently displayed user profile.
  Future<void> _fetchReviews() async {
    try {
      final querySnapshot =
          await _firestore
              .collection('reviews')
              .where('reviewedUserId', isEqualTo: widget.profileUserId)
              .orderBy(
                'timestamp',
                descending: true,
              ) // Show newest reviews first
              .limit(20) // Limit initial fetch for performance
              .get();

      if (mounted) {
        _reviewsList =
            querySnapshot.docs.map((doc) {
              final data = doc.data();
              data['id'] = doc.id; // Include document ID if needed
              // Consider fetching/storing reviewer name/pic URL here or during submission
              return data;
            }).toList();
      }
    } catch (e) {
      print("Error fetching reviews for ${widget.profileUserId}: $e");
      if (mounted) {
        // Optionally show a specific error for reviews
        // ScaffoldMessenger.of(context).showSnackBar(
        //   SnackBar(content: Text("Could not load reviews: ${e.toString()}")),
        // );
      }
      rethrow; // Rethrow to be caught by _loadAllAccountData
    }
  }

  /// Helper to count rides based on a specific field matching the user ID.
  Future<int> _fetchRideCount(String field, String userId) async {
    try {
      Query query = _firestore.collection('rides');
      if (field == 'seatLayout.bookedBy') {
        // Firestore limitation: Cannot efficiently query/count based on array elements directly.
        print(
          "Warning: Rides as passenger count is currently a placeholder (0). Implement accurate counting if needed.",
        );
        return 0; // Return placeholder
      } else {
        // Count rides where the user is the driver
        query = query.where(field, isEqualTo: userId);
      }
      // Use count() aggregation for efficiency
      final snapshot = await query.count().get();
      return snapshot.count ?? 0;
    } catch (e) {
      print("Error counting rides for field $field: $e");
      return 0; // Return 0 on error
    }
  }

  /// Toggles the profile editing mode (only for the current user).
  void _toggleEdit() {
    if (!_isCurrentUserProfile) return; // Only current user can edit
    setState(() {
      _isEditing = !_isEditing;
      // Reset form fields if cancelling edit
      if (!_isEditing) {
        _nameController.text = _userData['name'] ?? '';
        _phoneController.text = _userData['phone'] ?? '';
        _formKey.currentState?.reset(); // Reset validation state
      }
    });
  }

  /// Saves updated profile information to Firestore (only for the current user).
  Future<void> _saveProfile() async {
    // Validate input and check permissions
    if (!_isCurrentUserProfile ||
        !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (_isSaving) return; // Prevent double submission
    setState(() => _isSaving = true);

    final newName = _nameController.text.trim();
    final newPhone = _phoneController.text.trim();
    final Map<String, dynamic> updates = {};

    // Check if values actually changed
    if (newName != (_userData['name'] ?? '')) updates['name'] = newName;
    if (newPhone != (_userData['phone'] ?? '')) {
      updates['phone'] = newPhone;
      // TODO: Implement phone number verification flow here if required
      print("Warning: Phone number updated without verification.");
    }

    // If nothing changed, just exit edit mode
    if (updates.isEmpty) {
      setState(() {
        _isSaving = false;
        _isEditing = false;
      });
      return;
    }

    // Attempt to update Firestore
    try {
      await _firestore.collection('users').doc(_currentUserId).update(updates);
      if (mounted) {
        // Update local state optimistically
        setState(() {
          _isSaving = false;
          _isEditing = false;
          _userData.addAll(updates); // Update local data map
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Profile updated!"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print("Error updating profile: $e");
      if (mounted) {
        setState(() => _isSaving = false); // Allow retry
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to update profile: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Launches a URL (e.g., for Google Account settings).
  Future<void> _launchURL(String urlString) async {
    final Uri url = Uri.parse(urlString);
    try {
      if (!await canLaunchUrl(url)) throw 'Could not launch $url';
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      print('Error launching URL: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open link: $e')));
      }
    }
  }

  /// Signs the current user out after confirmation.
  Future<void> _signOut() async {
    if (!_isCurrentUserProfile) return; // Can only sign out from own profile

    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Confirm Sign Out'),
            content: const Text('Are you sure you want to sign out?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text(
                  'Sign Out',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );

    if (confirm == true && mounted) {
      try {
        await _auth.signOut();
        _handleLogoutNavigation(); // Navigate to GetStartedPage
      } catch (e) {
        print("Error signing out: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error signing out: ${e.toString()}')),
          );
        }
      }
    }
  }

  /// Navigates to the SubmitReviewPage for the displayed user.
  void _navigateToReviewPage() {
    // Prevent reviewing self or if current user ID is somehow null
    if (_isCurrentUserProfile || _currentUserId == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => SubmitReviewPage(
              userIdToReview:
                  widget
                      .profileUserId, // Pass the ID of the profile being viewed
              reviewerId: _currentUserId!, // Pass the logged-in user's ID
            ),
      ),
    ).then((_) {
      // After returning from the review page, refresh data to show new review/rating
      if (mounted) {
        print("Returned from review page, refreshing account data...");
        _loadAllAccountData(); // Refresh profile, stats, and reviews
      }
    });
  }

  // --- Build Method ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isCurrentUserProfile ? "My Account" : "User Profile"),
        actions: [
          // Show Edit/Cancel button only for the current user's profile when not loading
          if (_isCurrentUserProfile && !_isLoading)
            IconButton(
              icon: Icon(
                _isEditing ? Icons.cancel_outlined : Icons.edit_outlined,
              ),
              tooltip: _isEditing ? "Cancel Edit" : "Edit Profile",
              onPressed: _toggleEdit,
            ),
        ],
      ),
      // Show BottomNav only when viewing own profile
      bottomNavigationBar:
          _isCurrentUserProfile ? _buildBottomNavigationBar() : null,
      body:
          _isLoading
              ? const Center(
                child: CircularProgressIndicator(),
              ) // Show loading indicator initially
              : RefreshIndicator(
                onRefresh: _loadAllAccountData, // Allow pull-to-refresh
                child: ListView(
                  // Use ListView for scrollable content
                  padding: const EdgeInsets.all(16.0),
                  children: [
                    // --- Profile Header (Avatar, Name, Rating) ---
                    _buildProfileHeader(),
                    const SizedBox(height: 20),

                    // --- Edit Form or Display Info ---
                    // Show edit form only if editing own profile
                    if (_isCurrentUserProfile && _isEditing)
                      _buildEditForm()
                    // Show display info if not editing OR viewing another user
                    else
                      _buildDisplayInfo(),

                    const SizedBox(height: 20),

                    // --- Statistics Card ---
                    _buildStatsCard(),
                    const SizedBox(height: 20),

                    // --- Reviews Section ---
                    _buildReviewsSection(), // Display fetched reviews
                    const SizedBox(height: 20),

                    // --- Action Buttons (Review/Sign Out) ---
                    // Show "Review" button only when viewing another user's profile
                    if (!_isCurrentUserProfile)
                      ElevatedButton.icon(
                        icon: const Icon(Icons.rate_review_outlined),
                        label: Text("Review ${_userData['name'] ?? 'User'}"),
                        onPressed:
                            _navigateToReviewPage, // Navigate to submit review page
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orangeAccent,
                          foregroundColor: Colors.black87,
                        ),
                      ),

                    // Show "Sign Out" button only for the current user's profile AND when not editing
                    if (_isCurrentUserProfile && !_isEditing) ...[
                      const SizedBox(height: 10), // Spacing
                      ElevatedButton.icon(
                        icon: const Icon(Icons.logout),
                        label: const Text("تسجيل الخروج"),
                        onPressed: _signOut,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent.shade100,
                          foregroundColor: Colors.red.shade900,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
    );
  }

  // --- UI Builder Widgets ---

  /// Builds the header section with Avatar, Name, Email, Rating, and Change Picture button.
  Widget _buildProfileHeader() {
    // Use _userData fetched for profileUserId
    String? photoURL = _userData['imageUrl'];
    // Fallback to auth photo URL if viewing own profile and Firestore URL is missing
    if (_isCurrentUserProfile && (photoURL == null || photoURL.isEmpty)) {
      photoURL = _auth.currentUser?.photoURL;
    }
    String displayName = _userData['name'] ?? 'User';
    String email =
        _userData['email'] ?? ''; // Email might not always be present

    return Column(
      children: [
        CircleAvatar(
          radius: 50,
          backgroundColor: Colors.grey.shade300,
          backgroundImage:
              (photoURL != null && photoURL.isNotEmpty)
                  ? NetworkImage(photoURL)
                  : null,
          child:
              (photoURL == null || photoURL.isEmpty)
                  ? const Icon(Icons.person, size: 50, color: Colors.grey)
                  : null,
        ),
        const SizedBox(height: 12),
        Text(
          displayName,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        // Show email only for the current user's profile
        if (_isCurrentUserProfile && email.isNotEmpty)
          Text(
            email,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
          ),
        const SizedBox(height: 12),
        // Display Average Rating and Review Count prominently
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildRatingStars(_averageRating), // Use the fetched average rating
            const SizedBox(width: 8),
            // Display review count, handle pluralization
            Text(
              '($_reviewCount review${_reviewCount != 1 ? 's' : ''})',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Show "Change Profile Picture" button only for the current user
        if (_isCurrentUserProfile) ...[
          TextButton.icon(
            icon: const Icon(Icons.camera_alt_outlined, size: 18),
            label: const Text("Change Profile Picture"),
            onPressed:
                () => _launchURL(
                  'https://myaccount.google.com/personal-info',
                ), // Link to Google settings
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).primaryColor,
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
          Text(
            "(Opens Google Account settings)",
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ],
      ],
    );
  }

  /// Builds the form for editing profile information.
  Widget _buildEditForm() {
    // Only built when _isCurrentUserProfile and _isEditing are true
    return Form(
      key: _formKey,
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "تعديل الملف الشخصي",
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              // Name Field
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: "الاسم",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator:
                    (v) =>
                        (v == null || v.trim().isEmpty)
                            ? 'Please enter name'
                            : null,
              ),
              const SizedBox(height: 12),
              // Phone Field
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: "رقم الهاتف",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
                keyboardType: TextInputType.phone,
                validator:
                    (v) =>
                        (v == null || v.trim().isEmpty)
                            ? 'Please enter phone'
                            : null,
              ),
              const SizedBox(height: 8),
              Text(
                "(Note: Changing phone might require re-verification)",
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 20),
              // Save/Cancel Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : _toggleEdit,
                    child: const Text("إلغاء"),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon:
                        _isSaving
                            ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                            : const Icon(Icons.save),
                    label: Text(_isSaving ? "جار الحفظ..." : "حفظ"),
                    onPressed: _isSaving ? null : _saveProfile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the section displaying non-editable profile information.
  Widget _buildDisplayInfo() {
    // Uses _userData fetched for profileUserId
    String role = _userData['role'] as String? ?? 'Passenger';
    int gold = _userData['gold'] as int? ?? 0;
    Timestamp? createdAt = _userData['createdAt'] as Timestamp?;
    String memberSince =
        createdAt != null
            ? DateFormat.yMMMd().format(createdAt.toDate())
            : 'N/A';
    String phone = _userData['phone'] as String? ?? 'Not Set';

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Column(
          children: [
            // Phone Number
            ListTile(
              leading: const Icon(Icons.phone, color: Colors.grey),
              title: const Text("رقم الهاتف"),
              // Consider masking phone number if viewing others for privacy
              subtitle: Text(
                phone,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // Rating is now shown in the header (_buildProfileHeader)
            // Gold
            ListTile(
              leading: Icon(
                Icons.monetization_on,
                color: Colors.yellow.shade700,
              ),
              title: const Text("الذهب"),
              subtitle: Text(
                '$gold Gold',
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // Role
            ListTile(
              leading: Icon(
                role == 'driver' ? Icons.directions_car : Icons.person,
                color: Colors.grey,
              ),
              title: const Text("الدور الحالي"),
              subtitle: Text(
                role.isNotEmpty
                    ? role[0].toUpperCase() + role.substring(1)
                    : 'Passenger',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // Member Since
            ListTile(
              leading: const Icon(Icons.calendar_month, color: Colors.grey),
              title: const Text("عضو منذ"),
              subtitle: Text(
                memberSince,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the star rating display widget.
  Widget _buildRatingStars(double rating) {
    int numberOfStars = 5;
    // Clamp rating to be between 0 and 5
    double clampedRating = rating.clamp(0.0, 5.0);
    int fullStars = clampedRating.floor();
    // Determine if there's a half star (adjust threshold as needed)
    bool hasHalfStar =
        (clampedRating - fullStars) >= 0.25 &&
        (clampedRating - fullStars) < 0.75;
    // Determine if it should round up to a full star
    bool fullStarInsteadOfHalf = (clampedRating - fullStars) >= 0.75;

    List<Widget> stars = List.generate(numberOfStars, (index) {
      IconData iconData = Icons.star_border; // Default empty star
      Color color = Colors.grey.shade400;
      if (index < fullStars) {
        // Full stars
        iconData = Icons.star;
        color = Colors.amber;
      } else if (index == fullStars && hasHalfStar) {
        // Half star
        iconData = Icons.star_half;
        color = Colors.amber;
      } else if (index == fullStars && fullStarInsteadOfHalf) {
        // Round up to full star
        iconData = Icons.star;
        color = Colors.amber;
      }
      // Adjust star size based on where it's used (e.g., smaller in review list items)
      return Icon(iconData, color: color, size: 20);
    });

    // Return the row of star icons
    return Row(mainAxisSize: MainAxisSize.min, children: stars);
  }

  /// Builds the card displaying user ride statistics.
  Widget _buildStatsCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("الإحصائيات", style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (_isStatsLoading) // Show loading indicator for stats
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              // Display stats once loaded
              ListTile(
                leading: const Icon(
                  Icons.drive_eta_rounded,
                  color: Colors.teal,
                ),
                title: Text("$_ridesAsDriverCount"),
                subtitle: const Text("رحلات قمت بقيادتها"),
                dense: true,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(
                  Icons.person_pin_circle_rounded,
                  color: Colors.indigo,
                ),
                title: Text("$_ridesAsPassengerCount"),
                subtitle: const Text("رحلات قمت بها كراكب (تقريبي)"),
                dense: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the section displaying reviews.
  Widget _buildReviewsSection() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Reviews (${_reviewsList.length})",
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (_isLoadingReviews)
              _buildReviewShimmerList() // Show shimmer while loading
            else if (_reviewsList.isEmpty)
              const Center(
                // Message if no reviews
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24.0),
                  child: Text(
                    "No reviews yet.",
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ),
              )
            else
              // Build the list of reviews
              ListView.separated(
                shrinkWrap:
                    true, // Essential inside a scrolling parent (ListView)
                physics:
                    const NeverScrollableScrollPhysics(), // Disable nested scrolling
                itemCount: _reviewsList.length,
                itemBuilder:
                    (context, index) => _buildReviewItem(_reviewsList[index]),
                separatorBuilder:
                    (context, index) =>
                        const Divider(height: 1, indent: 16, endIndent: 16),
              ),
          ],
        ),
      ),
    );
  }

  /// Builds a single review item widget.
  Widget _buildReviewItem(Map<String, dynamic> review) {
    final double rating = (review['rating'] as num?)?.toDouble() ?? 0.0;
    final String comment = review['comment'] as String? ?? '';
    final Timestamp? timestamp = review['timestamp'] as Timestamp?;
    final String dateStr =
        timestamp != null
            ? DateFormat.yMMMd().format(timestamp.toDate())
            : 'Unknown date';
    // TODO: Fetch/Display reviewer's name/avatar based on review['reviewerId']
    final String reviewerName = "Anonymous Reviewer"; // Placeholder

    return ListTile(
      // leading: CircleAvatar(child: Icon(Icons.person)), // Placeholder for reviewer avatar
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            reviewerName,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            dateStr,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRatingStars(rating), // Show stars for this specific review
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              comment,
              style: const TextStyle(color: Colors.black87),
            ), // Display comment text
          ],
        ],
      ),
      isThreeLine:
          comment.isNotEmpty, // Adjust list tile height if comment exists
      dense: true, // Make list items more compact
    );
  }

  /// Builds a list of shimmer placeholders for the reviews section.
  Widget _buildReviewShimmerList() {
    return Column(
      children: List.generate(
        3,
        (index) => _buildReviewShimmerItem(),
      ), // Show 3 shimmer items
    );
  }

  /// Builds a single shimmer placeholder for a review item.
  Widget _buildReviewShimmerItem() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              // Mimic title row
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 100,
                  height: 14,
                  color: Colors.white,
                ), // Name placeholder
                Container(
                  width: 60,
                  height: 12,
                  color: Colors.white,
                ), // Date placeholder
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: 80,
              height: 16,
              color: Colors.white,
            ), // Rating placeholder
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              height: 12,
              color: Colors.white,
            ), // Comment line 1
            const SizedBox(height: 4),
            Container(
              width: 150,
              height: 12,
              color: Colors.white,
            ), // Comment line 2
          ],
        ),
      ),
    );
  }

  /// Builds the bottom navigation bar (only shown for current user).
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

  /// Handles taps on the bottom navigation bar items.
  void _onBottomNavTapped(int index) {
    if (!mounted || index == _currentIndex) return;
    if (_isEditing) {
      // Prevent navigation while editing
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please save or cancel changes first.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    _navigateToIndex(index);
  }

  /// Navigates to the selected page from the bottom navigation bar.
  void _navigateToIndex(int index) {
    if (index == _currentIndex) return; // Already on this page

    Widget? targetPage;
    bool removeUntil = true; // Replace stack for main tabs
    final loggedInUser = _auth.currentUser;
    if (loggedInUser == null) {
      _handleLogoutNavigation();
      return;
    } // Safety check

    switch (index) {
      case 0:
        targetPage = HomePage(user: loggedInUser);
        break;
      case 1:
        targetPage = MyRidePage(user: loggedInUser);
        break;
      case 2:
        targetPage = const MyCarsPage();
        break;
      case 3:
        targetPage = const ChatListPage();
        break;
      case 4:
        return; // Already on Account page
      default:
        return; // Invalid index
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
}
