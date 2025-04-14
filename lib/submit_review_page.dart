import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart'; // For potential date display if needed

class SubmitReviewPage extends StatefulWidget {
  final String userIdToReview; // The ID of the user being reviewed
  final String reviewerId; // The ID of the user writing the review

  const SubmitReviewPage({
    super.key,
    required this.userIdToReview,
    required this.reviewerId,
  });

  @override
  State<SubmitReviewPage> createState() => _SubmitReviewPageState();
}

class _SubmitReviewPageState extends State<SubmitReviewPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _commentController = TextEditingController();

  double _rating = 0.0; // User's selected rating (0 means not selected yet)
  bool _isSubmitting = false;
  String _userNameToReview = 'User'; // Name of the user being reviewed

  @override
  void initState() {
    super.initState();
    _fetchUserName(); // Get the name of the user being reviewed for display
    // Prevent reviewing self (should ideally be checked before navigating here too)
    if (widget.userIdToReview == widget.reviewerId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("You cannot review yourself."),
              backgroundColor: Colors.orange,
            ),
          );
          Navigator.of(context).pop(); // Go back immediately
        }
      });
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  // Fetch the name of the user being reviewed to display it
  Future<void> _fetchUserName() async {
    try {
      final userDoc =
          await _firestore.collection('users').doc(widget.userIdToReview).get();
      if (mounted && userDoc.exists) {
        setState(() {
          _userNameToReview = userDoc.data()?['name'] ?? 'User';
        });
      }
    } catch (e) {
      print("Error fetching user name for review page: $e");
      // Keep default name 'User'
    }
  }

  // Builds the star rating selection widget
  Widget _buildStarRatingSelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        return IconButton(
          icon: Icon(
            index < _rating
                ? Icons.star
                : Icons.star_border, // Filled or empty star
            color: Colors.amber,
            size: 35, // Make stars larger for easier tapping
          ),
          onPressed: () {
            setState(() {
              _rating = index + 1.0; // Set rating (1 to 5)
            });
          },
        );
      }),
    );
  }

  // Handles the submission of the review
  Future<void> _submitReview() async {
    // Basic validation: ensure a rating is selected
    if (_rating == 0.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a star rating.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Optional: Validate comment length if needed using _formKey

    if (_isSubmitting) return; // Prevent double submission
    setState(() => _isSubmitting = true);

    final reviewData = {
      'reviewedUserId': widget.userIdToReview,
      'reviewerId': widget.reviewerId,
      'rating': _rating,
      'comment': _commentController.text.trim(),
      'timestamp': FieldValue.serverTimestamp(), // Use server time
    };

    try {
      // 1. Add the review document to the 'reviews' collection
      await _firestore.collection('reviews').add(reviewData);

      // 2. Update the reviewed user's average rating and count (using a transaction)
      final userRef = _firestore.collection('users').doc(widget.userIdToReview);

      await _firestore.runTransaction((transaction) async {
        final userSnapshot = await transaction.get(userRef);
        if (!userSnapshot.exists) {
          throw Exception(
            "User document not found!",
          ); // Should not happen if navigated correctly
        }

        // Get current rating data, default to 0 if not present
        final currentReviewCount =
            (userSnapshot.data()?['reviewCount'] as int?) ?? 0;
        final currentAverageRating =
            (userSnapshot.data()?['averageRating'] as num?)?.toDouble() ?? 0.0;

        // Calculate new average
        final newReviewCount = currentReviewCount + 1;
        // Formula: newAvg = ((oldAvg * oldCount) + newRating) / newCount
        final newAverageRating =
            ((currentAverageRating * currentReviewCount) + _rating) /
            newReviewCount;

        // Update the user document within the transaction
        transaction.update(userRef, {
          'reviewCount': newReviewCount,
          'averageRating': newAverageRating, // Store the calculated average
        });
      });

      // 3. Show success message and navigate back
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Review submitted successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(
          context,
        ).pop(); // Go back to the previous screen (AccountPage)
      }
    } catch (e) {
      print("Error submitting review: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit review: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isSubmitting = false); // Allow retry on error
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Review $_userNameToReview'), // Show who is being reviewed
      ),
      body: SingleChildScrollView(
        // Allow scrolling if content overflows
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.stretch, // Make button full width
            children: [
              Text(
                'Rate your experience with $_userNameToReview:',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              _buildStarRatingSelector(), // Star rating input
              // Display selected rating numerically (optional)
              if (_rating > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    '${_rating.toStringAsFixed(1)} Stars',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              TextFormField(
                // Comment input field
                controller: _commentController,
                decoration: const InputDecoration(
                  labelText: 'Add a comment (optional)',
                  hintText: 'Share details about your experience...',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true, // Better alignment for multi-line
                ),
                maxLines: 4, // Allow multiple lines for comments
                textCapitalization: TextCapitalization.sentences,
                // Optional validation (e.g., length limit)
                // validator: (value) { ... }
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                // Submit button
                onPressed:
                    _isSubmitting
                        ? null
                        : _submitReview, // Disable while submitting
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                child:
                    _isSubmitting
                        ? const SizedBox(
                          // Show loading indicator inside button
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : const Text('Submit Review'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
