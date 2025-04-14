// homepage_functions/permissions_util.dart
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';

/// A simple container for position data
/// so we don't need direct 'Position' objects outside this file if we want.
class PositionData {
  final double latitude;
  final double longitude;
  PositionData(this.latitude, this.longitude);
}

/// Request location permission (WhenInUse)
Future<bool> requestLocationPermission() async {
  final status = await Permission.locationWhenInUse.request();
  return status.isGranted;
}

/// Request notification permission
Future<bool> requestNotificationPermission() async {
  final status = await Permission.notification.request();
  return status.isGranted;
}

/// If granted, fetch user position
Future<PositionData?> getUserPosition() async {
  try {
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    return PositionData(pos.latitude, pos.longitude);
  } catch (e) {
    return null;
  }
}
