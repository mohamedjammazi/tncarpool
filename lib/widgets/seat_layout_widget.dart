import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:math'; // Import math for max function

// Enum to define the interaction mode of the seat layout
enum SeatLayoutMode {
  driverOffer, // Driver toggling 'offered' status (CreateRidePage)
  passengerSelect, // Passenger selecting an available seat (RideDetailPage)
  driverManage, // Driver approving/declining requests (RideManagePage)
  displayOnly, // Just displaying the current state, no interaction
}

/// A reusable widget to display a schematic car seat layout using images.
/// Allows interaction based on the specified mode.
class SeatLayoutWidget extends StatelessWidget {
  final int seatCount;
  final List<Map<String, dynamic>> seatLayoutData;
  final Function(int seatIndex)? onSeatOfferedToggle; // Used in driverOffer
  final Function(int seatIndex)? onSeatSelected; // Used in passengerSelect
  final Function(Map<String, dynamic> seatData)?
  onPendingSeatTap; // Used in driverManage
  final SeatLayoutMode mode;
  final String driverSeatAssetPath;
  final String passengerSeatAssetPath;
  final Set<int>? selectedSeatsIndices; // Used in passengerSelect
  final String? currentUserId; // Used in passengerSelect & driverManage

  const SeatLayoutWidget({
    super.key,
    required this.seatCount,
    required this.seatLayoutData,
    required this.mode,
    required this.driverSeatAssetPath,
    required this.passengerSeatAssetPath,
    this.onSeatOfferedToggle,
    this.onSeatSelected,
    this.onPendingSeatTap,
    this.selectedSeatsIndices,
    this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    // Define row configurations based on seat count
    final Map<int, List<int>> rowConfigs = {
      2: [2],
      4: [2, 2],
      5: [2, 3],
      6: [2, 2, 2],
      7: [2, 3, 2],
      8: [2, 3, 3],
      9: [2, 2, 2, 3],
    };
    List<int> config =
        rowConfigs[seatCount] ?? _generateDefaultConfig(seatCount);
    if (seatCount <= 0) return const SizedBox.shrink();

    List<Widget> rows = [];
    int currentSeatIndex = 0;

    // Build rows based on the configuration
    for (int seatsInRow in config) {
      if (currentSeatIndex >= seatCount) break;
      List<Widget> rowSeats = [];
      for (int i = 0; i < seatsInRow && currentSeatIndex < seatCount; i++) {
        final seatData =
            (currentSeatIndex < seatLayoutData.length &&
                    seatLayoutData[currentSeatIndex]['seatIndex'] ==
                        currentSeatIndex)
                ? seatLayoutData[currentSeatIndex]
                : {
                  'seatIndex': currentSeatIndex,
                  'type': (currentSeatIndex == 0 ? 'driver' : 'share'),
                  'offered': false,
                  'bookedBy': 'n/a',
                  'approvalStatus': 'pending',
                };
        rowSeats.add(_buildSeatImageWidget(context, seatData));
        if (i < seatsInRow - 1) {
          rowSeats.add(const SizedBox(width: 12.0));
        }
        currentSeatIndex++;
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: rowSeats,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(children: rows),
    );
  }

  List<int> _generateDefaultConfig(int totalSeats) {
    if (totalSeats <= 0) return [];
    List<int> config = [];
    int remaining = totalSeats;
    config.add(1);
    remaining--;
    if (remaining > 0) {
      config[0]++;
      remaining--;
    }
    while (remaining > 0) {
      int seatsInRow = (remaining >= 4) ? 4 : remaining;
      if (seatsInRow == 0) break;
      config.add(seatsInRow);
      remaining -= seatsInRow;
    }
    return config;
  }

  /// Builds the widget for a single seat (Image + optional overlay button).
  Widget _buildSeatImageWidget(
    BuildContext context,
    Map<String, dynamic> seatData,
  ) {
    final String type = seatData['type'] as String? ?? 'share';
    final int seatIndex = seatData['seatIndex'] as int? ?? -1;
    final bool isOffered = seatData['offered'] as bool? ?? false;
    final String bookedBy = seatData['bookedBy'] as String? ?? 'n/a';
    final String approvalStatus =
        seatData['approvalStatus'] as String? ?? 'pending';
    final bool isBookedByCurrentUser =
        (currentUserId != null && bookedBy == currentUserId);
    final bool isBookedByAnyone = bookedBy != 'n/a';

    final double seatWidth = 75.0;
    final double seatHeight = 85.0;
    final String imagePath =
        (type == 'driver') ? driverSeatAssetPath : passengerSeatAssetPath;

    Widget seatImage = Image.asset(
      imagePath,
      width: seatWidth,
      height: seatHeight,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: seatWidth,
          height: seatHeight,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            type == 'driver' ? Icons.person : Icons.event_seat,
            color: Colors.grey.shade600,
            size: 35,
          ),
        );
      },
    );

    if (type == 'driver') {
      return Tooltip(message: "Driver's Seat", child: seatImage);
    }

    String tooltip = "Seat ${seatIndex + 1}";
    Widget overlayWidget = const SizedBox.shrink();
    VoidCallback? onTapAction;
    bool interactionAllowed = false;

    switch (mode) {
      case SeatLayoutMode.driverOffer:
        IconData buttonIcon =
            isOffered ? Icons.check_circle : Icons.add_circle_outline;
        Color buttonIconColor =
            isOffered ? Colors.white : Colors.white.withOpacity(0.9);
        Color buttonBackColor =
            isOffered
                ? Colors.green.withOpacity(0.8)
                : Colors.black.withOpacity(0.5);
        tooltip =
            isOffered
                ? "Seat ${seatIndex + 1}: Offered (Click to unoffer)"
                : "Seat ${seatIndex + 1}: Not Offered (Click to offer)";
        onTapAction = () => onSeatOfferedToggle?.call(seatIndex);
        overlayWidget = _buildOverlayButton(
          buttonIcon,
          buttonIconColor,
          buttonBackColor,
        );
        interactionAllowed = true;
        break;

      case SeatLayoutMode.passengerSelect:
        if (isBookedByCurrentUser) {
          tooltip = "Seat ${seatIndex + 1}: Booked by You (Click to unbook)";
          overlayWidget = _buildOverlayButton(
            Icons.person_pin,
            Colors.white,
            Colors.blue.withOpacity(0.8),
          );
          onTapAction = () => onSeatSelected?.call(seatIndex);
          interactionAllowed = true;
        } else if (isBookedByAnyone) {
          tooltip = "Seat ${seatIndex + 1}: Booked";
          overlayWidget = Icon(
            Icons.lock_person,
            color: Colors.red.shade700.withOpacity(0.8),
            size: 32,
          );
          onTapAction = null;
          interactionAllowed = false;
        } else if (!isOffered) {
          tooltip = "Seat ${seatIndex + 1}: Not Available";
          overlayWidget = Icon(
            Icons.remove_circle_outline,
            color: Colors.grey.withOpacity(0.8),
            size: 32,
          );
          onTapAction = null;
          interactionAllowed = false;
        } else {
          // Offered and Available
          tooltip = "Seat ${seatIndex + 1}: Available (Click to book)";
          overlayWidget = _buildOverlayButton(
            Icons.add_circle_outline,
            Colors.white.withOpacity(0.9),
            Colors.black.withOpacity(0.5),
          );
          onTapAction = () => onSeatSelected?.call(seatIndex);
          interactionAllowed = true;
        }
        break;

      case SeatLayoutMode.driverManage:
        if (isBookedByAnyone) {
          // Seat has a booking request/status
          if (approvalStatus == 'pending') {
            tooltip =
                "Seat ${seatIndex + 1}: Pending Approval (Click to manage)";
            overlayWidget = _buildOverlayButton(
              Icons.hourglass_empty,
              Colors.white,
              Colors.orange.withOpacity(0.8),
            );
            onTapAction =
                () => onPendingSeatTap?.call(seatData); // Pass full seat data
            interactionAllowed = true;
          } else if (approvalStatus == 'approved') {
            tooltip = "Seat ${seatIndex + 1}: Booking Approved (Click to view)";
            overlayWidget = _buildOverlayButton(
              Icons.check_circle,
              Colors.white,
              Colors.green.withOpacity(0.8),
            );
            onTapAction =
                () =>
                    onPendingSeatTap?.call(seatData); // Allow tap to view info
            interactionAllowed = true;
          } else {
            // Declined
            tooltip = "Seat ${seatIndex + 1}: Booking Declined";
            overlayWidget = Icon(
              Icons.cancel,
              color: Colors.red.withOpacity(0.8),
              size: 32,
            );
            onTapAction = null;
            interactionAllowed = false;
          }
        } else if (isOffered) {
          // Offered but not booked
          tooltip = "Seat ${seatIndex + 1}: Offered (No booking)";
          overlayWidget = Icon(
            Icons.event_seat,
            color: Colors.green.withOpacity(0.7),
            size: 32,
          );
          onTapAction = null;
          interactionAllowed = false;
        } else {
          // Not offered
          tooltip = "Seat ${seatIndex + 1}: Not Offered by You";
          overlayWidget = Icon(
            Icons.event_seat_outlined,
            color: Colors.grey.withOpacity(0.7),
            size: 32,
          );
          onTapAction = null;
          interactionAllowed = false;
        }
        break;

      case SeatLayoutMode.displayOnly:
      default:
        if (isBookedByAnyone) {
          tooltip = "Seat ${seatIndex + 1}: Booked";
          overlayWidget = Icon(
            Icons.lock_person,
            color: Colors.red.shade700.withOpacity(0.7),
            size: 32,
          );
        } else if (isOffered) {
          tooltip = "Seat ${seatIndex + 1}: Offered";
          overlayWidget = Icon(
            Icons.check_circle,
            color: Colors.green.withOpacity(0.7),
            size: 32,
          );
        } else {
          tooltip = "Seat ${seatIndex + 1}: Not Offered";
          overlayWidget = Icon(
            Icons.remove_circle_outline,
            color: Colors.grey.withOpacity(0.7),
            size: 32,
          );
        }
        onTapAction = null;
        interactionAllowed = false;
        break;
    }

    return Tooltip(
      message: tooltip,
      child: Stack(
        alignment: Alignment.center,
        children: [
          seatImage,
          if (interactionAllowed)
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTapAction,
                  borderRadius: BorderRadius.circular(seatWidth / 2),
                  child: Center(child: overlayWidget),
                ),
              ),
            )
          else
            Center(child: overlayWidget),
        ],
      ),
    );
  }

  Widget _buildOverlayButton(
    IconData icon,
    Color iconColor,
    Color backgroundColor,
  ) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 3,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Icon(icon, size: 28, color: iconColor),
      ),
    );
  }
} // End of SeatLayoutWidget class

// --- Add required dependencies to pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   cloud_firestore: ^... # Needed for Timestamp
//   latlong2: ^...        # Needed for LatLng
//   # Add other necessary dependencies like firebase_core if used directly

// --- Asset Setup (Required by Parent Widget) ---
// The parent widget using SeatLayoutWidget needs to ensure:
// 1. Images (e.g., DRIVERSEAT.png, PASSENGER SEAT.png) are in assets folder.
// 2. Assets folder is declared in pubspec.yaml.
