import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
// Import PositionData definition if it's in a separate file
import 'permissions_util.dart'; // Assuming PositionData is defined here

/// Fetches rides from Firestore where status == 'scheduled' and driverId != currentUserId.
/// Also fetches relevant driver info (including averageRating) from 'users' collection
/// and attaches it to each ride.
Future<List<Map<String, dynamic>>> fetchRides(String currentUserId) async {
  // Get rides that are scheduled
  final ridesSnapshot =
      await FirebaseFirestore.instance
          .collection('rides')
          .where('status', isEqualTo: 'scheduled')
          // Optionally add .orderBy('date') if needed, but sorting happens later too
          .get();

  List<Map<String, dynamic>> ridesWithDriverInfo = [];

  // Use Future.wait for potentially faster driver info fetching (optional optimization)
  List<Future<Map<String, dynamic>?>> driverFetchFutures = [];

  // Create a list of ride data and futures to fetch driver info
  List<Map<String, dynamic>> initialRides = [];
  for (var doc in ridesSnapshot.docs) {
    final data = doc.data();
    // Skip rides created by the current user
    if (data['driverId'] == currentUserId) {
      continue;
    }
    final ride = {'id': doc.id, ...data};
    initialRides.add(ride);

    // Add a future to fetch driver data for this ride's driverId
    driverFetchFutures.add(_fetchDriverInfo(data['driverId']));
  }

  // Wait for all driver info fetches to complete
  final driverInfos = await Future.wait(driverFetchFutures);

  // Combine ride data with fetched driver info
  for (int i = 0; i < initialRides.length; i++) {
    final ride = initialRides[i];
    final driverInfo = driverInfos[i]; // Get corresponding driver info
    if (driverInfo != null) {
      ride['driver'] = driverInfo; // Attach the fetched driver info map
      ridesWithDriverInfo.add(ride); // Add ride to the final list
    } else {
      // Handle cases where driver info couldn't be fetched (optional)
      // You might want to still include the ride but with default driver info
      print(
        "Warning: Could not fetch driver info for driverId: ${ride['driverId']}",
      );
      // Example: Add ride with placeholder driver data
      // ride['driver'] = {'name': 'Unknown Driver', 'averageRating': 0.0};
      // ridesWithDriverInfo.add(ride);
    }
  }

  return ridesWithDriverInfo;
}

/// Helper function to fetch specific driver details.
Future<Map<String, dynamic>?> _fetchDriverInfo(String driverId) async {
  try {
    final driverDoc =
        await FirebaseFirestore.instance
            .collection('users')
            .doc(driverId)
            .get();
    if (driverDoc.exists) {
      final driverData = driverDoc.data()!;
      // Return only the necessary fields to avoid large data transfer
      return {
        'name': driverData['name'] ?? 'Unknown Driver',
        'imageUrl': driverData['imageUrl'] ?? '',
        'phone': driverData['phone'] ?? '', // Include phone if needed by UI
        // *** Include averageRating ***
        'averageRating':
            (driverData['averageRating'] as num?)?.toDouble() ?? 0.0,
        // Add any other essential driver fields needed in the ride card/details
      };
    } else {
      return null; // Driver not found
    }
  } catch (e) {
    print("Error fetching driver info for $driverId: $e");
    return null; // Return null on error
  }
}

/// Filter and sort rides based on distance, search query, and chosen sort option.
List<Map<String, dynamic>> filterAndSort({
  required List<Map<String, dynamic>> allRides,
  required PositionData?
  userPosition, // Make sure PositionData is defined/imported
  required bool locationGranted,
  required double distanceKm,
  required String searchQuery,
  required String sortOption,
}) {
  // 1. Create a mutable copy of the list
  List<Map<String, dynamic>> result = List.from(allRides);

  // 2. Filter by Distance (if location is available)
  if (locationGranted && userPosition != null) {
    result =
        result.where((ride) {
          final startLocationData = ride['startLocation'];
          // Check if startLocation is a GeoPoint
          if (startLocationData is GeoPoint) {
            final distanceInMeters = Geolocator.distanceBetween(
              userPosition.latitude,
              userPosition.longitude,
              startLocationData.latitude,
              startLocationData.longitude,
            );
            final distanceInKm = distanceInMeters / 1000.0;
            // Keep ride if within the specified distance
            return distanceInKm <= distanceKm;
          }
          // If startLocation is not a GeoPoint, exclude it from distance filtering
          return false;
        }).toList();
  }

  // 3. Filter by Search Query
  if (searchQuery.isNotEmpty) {
    final lowerCaseQuery = searchQuery.toLowerCase();
    result =
        result.where((ride) {
          // Check driver name (safe access)
          final driverInfo = ride['driver'] as Map<String, dynamic>?;
          final driverName =
              driverInfo?['name']?.toString().toLowerCase() ?? '';
          // Check start location name
          final startName =
              (ride['startLocationName'] ?? '').toString().toLowerCase();
          // Check end location name
          final endName =
              (ride['endLocationName'] ?? '').toString().toLowerCase();

          // Return true if query matches any of these fields
          return driverName.contains(lowerCaseQuery) ||
              startName.contains(lowerCaseQuery) ||
              endName.contains(lowerCaseQuery);
        }).toList();
  }

  // 4. Sort the results
  switch (sortOption) {
    case 'price':
      result.sort((a, b) {
        // Safely parse price, default to 0 if null or invalid
        final priceA = (a['price'] as num?)?.toDouble() ?? 0.0;
        final priceB = (b['price'] as num?)?.toDouble() ?? 0.0;
        return priceA.compareTo(priceB); // Sort ascending by price
      });
      break;
    case 'distance':
      // Only sort by distance if location is available
      if (locationGranted && userPosition != null) {
        result.sort((a, b) {
          final geoA = a['startLocation'];
          final geoB = b['startLocation'];
          // Ensure both locations are GeoPoints before calculating distance
          if (geoA is GeoPoint && geoB is GeoPoint) {
            final distA = Geolocator.distanceBetween(
              userPosition.latitude,
              userPosition.longitude,
              geoA.latitude,
              geoA.longitude,
            );
            final distB = Geolocator.distanceBetween(
              userPosition.latitude,
              userPosition.longitude,
              geoB.latitude,
              geoB.longitude,
            );
            return distA.compareTo(distB); // Sort ascending by distance
          } else if (geoA is GeoPoint) {
            return -1; // Place rides with valid location first
          } else if (geoB is GeoPoint) {
            return 1; // Place rides with valid location first
          } else {
            return 0; // Keep relative order if neither has location
          }
        });
      }
      break;
    default: // 'time' or any other case defaults to time sorting
      result.sort((a, b) {
        // Safely get timestamp, default to epoch 0 if null
        final timeA = (a['date'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
        final timeB = (b['date'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
        return timeA.compareTo(timeB); // Sort ascending by time
      });
      break;
  }

  return result;
}
