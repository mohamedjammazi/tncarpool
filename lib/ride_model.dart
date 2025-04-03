// ride_model.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class Ride {
  final String rideId;
  final String userId;
  final String startingPoint;
  final String destination;
  final DateTime date;
  final String time;
  final int seatsAvailable;
  final double seatPrice;
  final GeoPoint startCoordinates;
  final GeoPoint destinationCoordinates;

  Ride({
    required this.rideId,
    required this.userId,
    required this.startingPoint,
    required this.destination,
    required this.date,
    required this.time,
    required this.seatsAvailable,
    required this.seatPrice,
    required this.startCoordinates,
    required this.destinationCoordinates,
  });

  factory Ride.fromSnapshot(DocumentSnapshot snapshot) {
    try {
      final data = snapshot.data() as Map<String, dynamic>? ?? {};

      return Ride(
        rideId: snapshot.id,
        userId: data['userId']?.toString() ?? 'unknown_user',
        startingPoint: data['startingPoint']?.toString() ?? 'Unknown Location',
        destination: data['destination']?.toString() ?? 'Unknown Destination',
        date: (data['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
        time: data['time']?.toString() ?? '00:00',
        seatsAvailable: (data['seatsAvailable'] as num?)?.toInt() ?? 0,
        seatPrice: (data['seatPrice'] as num?)?.toDouble() ?? 0.0,
        startCoordinates: data['startCoordinates'] ?? const GeoPoint(0, 0),
        destinationCoordinates:
            data['destinationCoordinates'] ?? const GeoPoint(0, 0),
      );
    } catch (e) {
      return Ride(
        rideId: 'error_${DateTime.now().millisecondsSinceEpoch}',
        userId: 'error_user',
        startingPoint: 'Error Loading Location',
        destination: 'Error Loading Destination',
        date: DateTime.now(),
        time: '00:00',
        seatsAvailable: 0,
        seatPrice: 0.0,
        startCoordinates: const GeoPoint(0, 0),
        destinationCoordinates: const GeoPoint(0, 0),
      );
    }
  }
}
