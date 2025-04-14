import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Import project pages (ensure paths are correct)
import 'chat_detail_page.dart';
import 'ride_manage_page.dart'; // Expects ride map
import 'ride_details_page.dart'; // Expects rideId string
import 'call_page.dart'; // For WebRTC call screen (Assuming this exists)
import 'get_started_page.dart'; // Fallback navigation

/// Service class for handling Firebase Cloud Messaging (FCM) and local notifications.
class NotificationService {
  static final FirebaseMessaging _firebaseMessaging =
      FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // Keep track of the context passed during initialization
  // Use a GlobalKey<NavigatorState> for more robust navigation from background/terminated state if needed.
  static BuildContext? _appContext;

  // Define Notification Channels
  static const AndroidNotificationChannel _chatChannel =
      AndroidNotificationChannel(
        'chat_messages', // id
        'Chat Notifications', // name
        description: 'Notifications for new chat messages.',
        importance: Importance.high,
        playSound: true,
      );

  static const AndroidNotificationChannel _callChannel =
      AndroidNotificationChannel(
        'call_notifications', // id
        'Call Notifications', // name
        description: 'Notifications for incoming calls.',
        importance: Importance.max, // Use Max importance for calls
        playSound: true,
        // TODO: Add sound file for ringtone if desired
        // sound: RawResourceAndroidNotificationSound('your_ringtone'),
      );

  // --- NEW: Ride Notifications Channel ---
  static const AndroidNotificationChannel _rideChannel =
      AndroidNotificationChannel(
        'ride_notifications', // id
        'Ride Notifications', // name
        description:
            'Notifications for ride bookings, approvals, and status changes.',
        importance: Importance.high,
        playSound: true,
      );

  /// Initializes FCM listeners, permissions, local notifications, and channels.
  /// Call this once, typically in your main app widget or splash screen.
  static Future<void> initialize(BuildContext context) async {
    _appContext =
        context; // Store context (consider GlobalKey<NavigatorState> approach)

    // 1. Request Permissions (iOS requires explicit permission)
    await _requestPermissions();

    // 2. Create Android Notification Channels
    await _createNotificationChannels();

    // 3. Initialize Local Notifications Plugin
    await _initializeLocalNotifications();

    // 4. Setup FCM Message Handlers
    _setupFCMHandlers();

    // 5. Update FCM Token in Firestore
    await _updateFCMToken(); // Update token on initialization
  }

  /// Requests notification permissions from the user.
  static Future<void> _requestPermissions() async {
    try {
      NotificationSettings
      settings = await _firebaseMessaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert:
            false, // Request critical alert permission for calls if needed (iOS)
        provisional: false,
        sound: true,
      );
      print('Notification Permissions Status: ${settings.authorizationStatus}');
    } catch (e) {
      print("Error requesting notification permissions: $e");
    }
  }

  /// Creates necessary Android notification channels.
  static Future<void> _createNotificationChannels() async {
    final androidPlugin =
        _localNotifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
    if (androidPlugin != null) {
      try {
        await androidPlugin.createNotificationChannel(_chatChannel);
        await androidPlugin.createNotificationChannel(_callChannel);
        await androidPlugin.createNotificationChannel(
          _rideChannel,
        ); // Create ride channel
        print("Notification channels created.");
      } catch (e) {
        print("Error creating notification channels: $e");
      }
    }
  }

  /// Initializes the FlutterLocalNotificationsPlugin.
  static Future<void> _initializeLocalNotifications() async {
    // TODO: Replace '@mipmap/ic_launcher' with your actual app icon path
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    // TODO: Add iOS/macOS initialization settings if needed
    // final DarwinInitializationSettings initializationSettingsDarwin = DarwinInitializationSettings(...);
    // final LinuxInitializationSettings initializationSettingsLinux = LinuxInitializationSettings(...);

    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          // iOS: initializationSettingsDarwin,
          // macOS: initializationSettingsDarwin,
          // linux: initializationSettingsLinux,
        );

    try {
      await _localNotifications.initialize(
        initializationSettings,
        // Callback when notification is tapped while app is in foreground/background (not terminated)
        onDidReceiveNotificationResponse: (NotificationResponse details) {
          print("Local Notification tapped with payload: ${details.payload}");
          if (_appContext != null && details.payload != null) {
            _handleNotificationTap(details.payload!, _appContext!);
          }
        },
        // Callback for receiving notification while app is in foreground (iOS only)
        // onDidReceiveBackgroundNotificationResponse: ...
      );
      print("Local notifications initialized.");
    } catch (e) {
      print("Error initializing local notifications: $e");
    }
  }

  /// Sets up listeners for incoming FCM messages (foreground, background tap, terminated tap).
  static void _setupFCMHandlers() {
    // --- Handle Foreground Messages ---
    // Displayed using flutter_local_notifications
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('Foreground FCM message received: ${message.messageId}');
      // Show local notification for foreground messages
      _showLocalNotification(message);

      // Specific foreground handling (e.g., immediate action for calls)
      if (_appContext != null && message.data['call'] == 'true') {
        print("Foreground message is a call, navigating to CallPage...");
        _openCallPage(message.data, _appContext!); // Use data payload
      }
    });

    // --- Handle Background/Terminated Tapped Notifications ---
    // When user taps notification and app opens from background/terminated state
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print(
        'Background/Terminated FCM notification tapped: ${message.messageId}',
      );
      if (_appContext != null) {
        // Consolidate navigation logic here
        _handleNotificationTap(
          jsonEncode(message.data),
          _appContext!,
        ); // Pass data payload as JSON string
      } else {
        print(
          "Warning: App context not available for background tap navigation.",
        );
        // Consider using a GlobalKey<NavigatorState> for reliable navigation
      }
    });

    // Check if app was opened from terminated state via notification
    FirebaseMessaging.instance.getInitialMessage().then((
      RemoteMessage? message,
    ) {
      if (message != null) {
        print(
          'App opened from terminated state via initial message: ${message.messageId}',
        );
        // Use a slight delay to ensure the Flutter view is ready
        Future.delayed(const Duration(milliseconds: 500), () {
          if (_appContext != null) {
            _handleNotificationTap(
              jsonEncode(message.data),
              _appContext!,
            ); // Pass data payload as JSON string
          } else {
            print(
              "Warning: App context not available for terminated tap navigation.",
            );
            // Consider using a GlobalKey<NavigatorState>
          }
        });
      }
    });
  }

  /// Shows a local notification using FlutterLocalNotificationsPlugin.
  static Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    final android = message.notification?.android;
    final data = message.data; // Use data payload for richer info

    if (notification == null) return; // Only show if notification part exists

    // Determine channel based on data payload type
    String channelId = _chatChannel.id; // Default to chat
    if (data['call'] == 'true') {
      channelId = _callChannel.id;
    } else if (data['notificationType']?.startsWith('ride_') ?? false) {
      channelId = _rideChannel.id; // Use ride channel
    } else if (data['notificationType'] == 'approval_update') {
      channelId = _rideChannel.id; // Use ride channel
    }

    // Use platform-specific details
    final AndroidNotificationDetails
    androidDetails = AndroidNotificationDetails(
      channelId, // Use determined channel ID
      channelId == _chatChannel.id
          ? _chatChannel.name
          : (channelId == _callChannel.id
              ? _callChannel.name
              : _rideChannel.name), // Use correct channel name
      channelDescription:
          channelId == _chatChannel.id
              ? _chatChannel.description
              : (channelId == _callChannel.id
                  ? _callChannel.description
                  : _rideChannel.description), // Use correct description
      importance:
          channelId == _callChannel.id
              ? Importance.max
              : Importance.high, // Max importance for calls
      priority:
          channelId == _callChannel.id
              ? Priority.high
              : Priority.defaultPriority,
      // TODO: Add specific icons, sounds if needed
      // icon: android?.smallIcon,
      // sound: RawResourceAndroidNotificationSound('notification_sound'), // Example sound
    );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      // TODO: Add iOS/macOS details if needed
      // iOS: DarwinNotificationDetails(...)
    );

    try {
      await _localNotifications.show(
        notification.hashCode, // Use hashcode of notification as ID
        notification.title ?? 'Notification',
        notification.body ?? '',
        notificationDetails,
        // --- IMPORTANT: Pass message.data as JSON string payload ---
        // This payload is received by onDidReceiveNotificationResponse when tapped
        payload: jsonEncode(message.data),
      );
    } catch (e) {
      print("Error showing local notification: $e");
    }
  }

  /// Centralized handler for navigating when a notification is tapped
  /// (either local notification or background/terminated FCM message).
  static void _handleNotificationTap(String payload, BuildContext context) {
    print("Handling notification tap with payload: $payload");
    try {
      final Map<String, dynamic> data = jsonDecode(payload);

      // --- Call Notification ---
      if (data['call'] == 'true') {
        _openCallPage(data, context);
        return; // Stop further processing
      }

      // --- Ride Booking Notification (for Driver) ---
      if (data['notificationType'] == 'ride_booking' &&
          data.containsKey('rideId')) {
        final rideId = data['rideId'] as String?;
        if (rideId != null && rideId.isNotEmpty) {
          // Navigate to RideManagePage (needs ride data)
          _navigateToRideManagePage(rideId, context);
        }
        return; // Stop further processing
      }

      // --- Ride Approval/Status Update Notification (for Passenger) ---
      if ((data['notificationType'] == 'approval_update' ||
              data['notificationType'] == 'ride_status_update') &&
          data.containsKey('rideId')) {
        final rideId = data['rideId'] as String?;
        if (rideId != null && rideId.isNotEmpty) {
          // Navigate to RideDetailPage (needs rideId)
          _navigateToRideDetailsPage(rideId, context);
        }
        return; // Stop further processing
      }

      // --- Chat Notification ---
      if (data.containsKey('chatId') && data.containsKey('senderId')) {
        final chatId = data['chatId'] as String?;
        final senderId = data['senderId'] as String?;
        if (chatId != null && senderId != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder:
                  (context) =>
                      ChatDetailPage(chatId: chatId, otherUserId: senderId),
            ),
          );
        }
        return; // Stop further processing
      }

      // --- Fallback/Unknown Notification Type ---
      print("Unknown notification type or missing data in payload: $payload");
      // Optionally navigate to a default page like HomePage
      // final user = FirebaseAuth.instance.currentUser;
      // if (user != null) {
      //   Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => HomePage(user: user)), (route) => false);
      // }
    } catch (e) {
      print('Error decoding or handling notification payload: $e');
      // Handle JSON decode error or other issues
    }
  }

  /// Navigates to CallPage.
  static void _openCallPage(Map<String, dynamic> data, BuildContext context) {
    final callerId = data['callerId'] as String?;
    final channelId =
        data['channelId'] as String?; // Usually the callId/documentId
    if (callerId != null && channelId != null && context.mounted) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => CallPage(channelId: channelId)));
    } else {
      print("Missing callerId or channelId for call navigation.");
    }
  }

  /// Navigates to RideManagePage. Requires fetching ride data first.
  static Future<void> _navigateToRideManagePage(
    String rideId,
    BuildContext context,
  ) async {
    if (rideId.isEmpty) {
      print("Cannot navigate to RideManagePage: Empty rideId.");
      return;
    }
    print("Navigating to RideManagePage for rideId: $rideId");
    try {
      // Fetch the ride data as RideManagePage expects the full map
      DocumentSnapshot rideDoc =
          await FirebaseFirestore.instance
              .collection('rides')
              .doc(rideId)
              .get();

      if (!context.mounted) return; // Check mounted after await

      if (!rideDoc.exists) {
        print("Ride $rideId not found for RideManagePage navigation.");
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Ride details not found.")),
        );
        return;
      }
      Map<String, dynamic> rideData = {
        'id': rideDoc.id,
        ...rideDoc.data() as Map<String, dynamic>,
      }; // Include ID

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RideManagePage(ride: rideData),
        ), // Pass the map
      );
    } catch (e) {
      print("Error navigating to RideManagePage: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error opening ride management: $e")),
        );
      }
    }
  }

  /// Navigates to RideDetailPage using rideId.
  static Future<void> _navigateToRideDetailsPage(
    String rideId,
    BuildContext context,
  ) async {
    if (rideId.isEmpty) {
      print("Cannot navigate to RideDetailPage: Empty rideId.");
      return;
    }
    print("Navigating to RideDetailPage for rideId: $rideId");
    try {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RideDetailPage(rideId: rideId),
        ), // Pass rideId
      );
    } catch (e) {
      print(
        "Error navigating to RideDetailPage: $e",
      ); /* Optional: Show SnackBar */
    }
  }

  /// Updates or clears the FCM token in the user's Firestore document.
  static Future<void> _updateFCMToken({bool clear = false}) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return; // No user logged in

    String? token;
    if (!clear) {
      try {
        token = await _firebaseMessaging.getToken();
      } catch (e) {
        print('Error getting FCM token: $e');
        return; // Exit if token cannot be retrieved
      }
    }

    // Prepare data: set token to null if clearing, otherwise use retrieved token
    final Map<String, dynamic> updateData = {
      'fcmToken': clear ? null : token,
      'fcmTokenTimestamp':
          FieldValue.serverTimestamp(), // Always update timestamp
    };

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .set(updateData, SetOptions(merge: true)); // Use set with merge

      if (clear) {
        print('FCM Token cleared for user ${currentUser.uid}');
      } else if (token != null) {
        print('FCM Token updated for user ${currentUser.uid}: $token');
      } else {
        print(
          'FCM Token is null, clearing from Firestore for user ${currentUser.uid}',
        );
        // Ensure null is explicitly set if getToken returns null
        await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .set({'fcmToken': null}, SetOptions(merge: true));
      }
    } catch (e) {
      print('Error updating/clearing FCM token in Firestore: $e');
    }
  }

  /// Clears the FCM token (e.g., on logout).
  static Future<void> clearFCMToken() async {
    await _updateFCMToken(clear: true);
  }
} // End of NotificationService class

// --- Add required dependencies to pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   firebase_messaging: ^...
//   cloud_firestore: ^...
//   flutter_local_notifications: ^...
//   url_launcher: ^... # If used in navigated pages
//   # Add imports for pages used in navigation (HomePage, RideDetailPage, RideManagePage, ChatDetailPage, CallPage etc.)

// --- Android Setup ---
// 1. Add Notification Channels to AndroidManifest.xml (Optional but recommended for older Android versions)
//    Inside <application> tag:
//    <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="chat_messages" />
// 2. Ensure you have a default notification icon (e.g., @mipmap/ic_launcher).

// --- iOS Setup ---
// 1. Follow Firebase documentation for setting up FCM on iOS (APNs certificates/keys).
// 2. Configure background modes and push notifications capabilities in Xcode.
