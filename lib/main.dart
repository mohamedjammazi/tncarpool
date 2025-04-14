import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'auth_wrapper.dart';
import 'notification_service.dart';
import 'call_page.dart'; // Ensure this file exists and is properly implemented

// Top-level background handler for Firebase push messages
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('Background message received: ${message.messageId}');

  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // Create the notification channel
  const channel = AndroidNotificationChannel(
    'high_importance_channel',
    'High Importance Notifications',
    description: 'This channel is used for important notifications.',
    importance: Importance.high,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  // Show the notification when the message includes a notification payload.
  if (message.notification != null) {
    final androidDetails = AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: Importance.high,
      priority: Priority.high,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    // Use jsonEncode to encode the data payload as JSON.
    await flutterLocalNotificationsPlugin.show(
      message.notification.hashCode,
      message.notification?.title ?? 'رسالة جديدة',
      message.notification?.body ?? 'لديك رسالة جديدة',
      notificationDetails,
      payload: jsonEncode(message.data),
    );
  }
}

Future<void> main() async {
  // Ensures binding is initialized before calling any plugins
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();

  // Register the background message handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Initialize Google Mobile Ads (AdMob)
  await MobileAds.instance.initialize();

  // Run the app
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Carpooling App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.green, fontFamily: 'Roboto'),
      home: const NotificationInitializer(),
    );
  }
}

class NotificationInitializer extends StatefulWidget {
  const NotificationInitializer({super.key});

  @override
  State<NotificationInitializer> createState() =>
      _NotificationInitializerState();
}

class _NotificationInitializerState extends State<NotificationInitializer> {
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      // Initialize local notifications or other services
      await NotificationService.initialize(context);

      // Listen for messages when the app is opened from a terminated state
      FirebaseMessaging.instance.getInitialMessage().then((
        RemoteMessage? message,
      ) {
        if (message != null && message.data['call'] == 'true') {
          final callerId = message.data['callerId'];
          final channelId = message.data['channelId'];

          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => CallPage(channelId: channelId)),
          );
        }
      });

      // Listen for messages when the app is in the background but not terminated
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        if (message.data['call'] == 'true') {
          final callerId = message.data['callerId'];
          final channelId = message.data['channelId'];

          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => CallPage(channelId: channelId)),
          );
        }
      });
    } catch (e) {
      print('Error initializing notifications: $e');
    } finally {
      // Proceed to main app UI even if notifications setup fails
      if (mounted) {
        setState(() => _initializing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return const AuthWrapper();
  }
}
