import 'dart:async';
import 'dart:convert'; // For JSON decoding if needed elsewhere
import 'dart:math'; // For pow function

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Import for PlatformException
import 'package:flutter_webrtc/flutter_webrtc.dart'; // WebRTC
import 'package:intl/intl.dart'; // For Timer Formatting
import 'package:permission_handler/permission_handler.dart'; // Permissions
import 'package:wakelock_plus/wakelock_plus.dart'; // Keep screen awake
import 'package:connectivity_plus/connectivity_plus.dart'; // Network status

// Assuming GetStartedPage is your login/entry point if user becomes null
import 'get_started_page.dart';

/// WebRTC Call Page using Firestore for signaling.
class CallPage extends StatefulWidget {
  /// The Firestore document ID for the call session.
  final String channelId;

  const CallPage({Key? key, required this.channelId}) : super(key: key);

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> with WidgetsBindingObserver {
  // WebRTC Objects
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;

  // UI State
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;
  bool _isMuted = false;
  bool _isVideoEnabled = true;
  bool _isCallConnected = false;
  bool _isCallAccepted = false;
  bool _isIncomingCall = false;
  String _otherUserName = "User"; // Initialized
  String _otherUserImageUrl = "";
  bool _isVideoCall = true;
  bool _isCallInitialized = false;
  bool _isReconnecting = false;
  bool _isSpeakerOn = true;
  Duration _callDuration = Duration.zero;
  Timer? _callTimer;

  // Connection management
  Timer? _reconnectTimer;
  Timer? _connectionTimeoutTimer;
  int _reconnectAttempts = 0;
  final int _maxReconnectAttempts = 5;
  final Duration _callTimeoutDuration = const Duration(seconds: 60);

  // Firestore & Auth
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late DocumentReference<Map<String, dynamic>> _callDoc;
  StreamSubscription? _callSubscription;
  StreamSubscription? _candidatesSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  String? _currentUserId;
  String? _otherUserId;

  // --- WebRTC Configuration ---
  // ** IMPORTANT **
  // Using only STUN servers will likely FAIL in many real-world network conditions.
  // You MUST configure your own TURN server(s) for reliable connections.
  final Map<String, dynamic> _peerConfiguration = {
    'iceServers': [
      // Google STUN servers (use as fallback)
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      // --- Add your TURN server configuration here ---
      /*
      {
        'urls': 'turn:YOUR_TURN_SERVER_ADDRESS:PORT', // e.g., turn:myturn.example.com:3478
        'username': 'YOUR_TURN_USERNAME',
        'credential': 'YOUR_TURN_PASSWORD',
      },
      {
        'urls': 'turn:YOUR_TURN_SERVER_ADDRESS:PORT?transport=tcp', // Optional: TCP transport
        'username': 'YOUR_TURN_USERNAME',
        'credential': 'YOUR_TURN_PASSWORD',
      },
      */
      // --- End TURN server configuration ---
    ],
    // Standard WebRTC configuration options
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': 'all', // Allow STUN and TURN
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 10, // Optional: Control candidate pool size
  };

  @override
  void initState() {
    super.initState();
    print("CallPage initState: Channel ID = ${widget.channelId}");
    _currentUserId = _auth.currentUser?.uid;
    if (_currentUserId == null || widget.channelId.isEmpty) {
      _handleInitializationError(
        "Authentication error or invalid call session.",
      );
      return;
    }
    WidgetsBinding.instance.addObserver(this); // Observe app lifecycle
    _initializeApp();
  }

  @override
  void dispose() {
    print("--- Disposing CallPage State ---");
    WidgetsBinding.instance.removeObserver(this);
    _callTimer?.cancel(); // Cancel call timer
    _hideControlsTimer?.cancel();
    _cleanupResources(); // Ensure cleanup on dispose
    super.dispose();
    print("--- CallPage State disposed ---");
  }

  /// Handles fatal errors during initialization by showing a message and popping the page.
  void _handleInitializationError(String message) {
    // Use WidgetsBinding to safely interact with context after build phase
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showToast(message, isError: true);
        // Try to pop back after showing the message
        if (Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("App Lifecycle State Changed: $state");
    switch (state) {
      case AppLifecycleState.resumed:
        // Re-enable video if it was active before pausing
        if (_isCallConnected && _isVideoCall && !_isVideoEnabled) {
          print("Resuming app, re-enabling video.");
          _toggleCamera(forceEnable: true);
        }
        // Ensure screen stays awake
        WakelockPlus.enable().catchError(
          (e) => print("Error re-enabling wakelock: $e"),
        );
        break;
      case AppLifecycleState.paused:
        // Disable video track temporarily when app is paused to save resources/privacy
        if (_isCallConnected && _isVideoCall && _isVideoEnabled) {
          print("Pausing app, disabling video track.");
          _toggleCamera(
            forceDisable: true,
          ); // Disable video track but keep state _isVideoEnabled true
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // App is closing or going fully into background, end the call
        print("App detached/inactive/hidden, ensuring call cleanup.");
        _endCall(navigate: false); // Clean up resources without navigation
        break;
    }
  }

  /// Main initialization sequence: Enables wakelock, sets up connectivity listener, initializes renderers, requests permissions, and initializes Firestore listeners.
  Future<void> _initializeApp() async {
    print("Initializing Call Page...");
    try {
      await WakelockPlus.enable(); // Keep screen awake during call
      print('Wakelock enabled.');
    } catch (e) {
      print('Error enabling wakelock: $e');
    }

    // Listen to connectivity changes
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _handleConnectivityChange,
      onError: (e) => print("Connectivity listener error: $e"),
    );

    // Initialize WebRTC renderers first
    await _initializeRenderers();
    if (!mounted) return; // Check mounted after async gap

    // Request Camera/Mic permissions
    await _requestPermissions();
    if (!mounted) return;
    bool cameraGranted = await Permission.camera.isGranted;
    bool micGranted = await Permission.microphone.isGranted;

    // Handle permission denial
    // Check initial isVideoCall state which should be fetched soon
    // For now, assume video might be needed if permissions aren't granted yet
    if (!micGranted || !cameraGranted) {
      // Check again after fetching call type
      print(
        "Initial permission check failed, will re-check after fetching call type.",
      );
    }

    // Initialize Firestore document reference and start listening
    _initializeCallDocAndListeners();
  }

  /// Handles changes in network connectivity and attempts reconnection if needed.
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    if (!mounted) return;
    final result = results.isNotEmpty ? results.last : ConnectivityResult.none;
    print("Connectivity changed: $result");
    if (result == ConnectivityResult.none) {
      _showToast('Connection lost...');
      // If call was active, enter reconnecting state
      if ((_isCallConnected || _isCallAccepted) && !_isReconnecting) {
        setState(() => _isReconnecting = true);
        _tryReconnect(); // Start reconnection attempts immediately
      }
    } else {
      // Connection restored
      if (_isReconnecting) {
        _showToast('Network available. Re-establishing call...');
        // Reconnection might happen automatically via ICE restarts triggered by the other peer
        // Or we can trigger it manually if needed after a delay
        // _tryReconnect() handles the retry logic with backoff
      }
    }
  }

  /// Requests Camera and Microphone permissions.
  Future<void> _requestPermissions() async {
    print("Requesting Camera and Microphone permissions...");
    try {
      Map<Permission, PermissionStatus> statuses =
          await [Permission.camera, Permission.microphone].request();
      print("Permission statuses: $statuses");
      // Handle specific statuses if needed (e.g., permanently denied)
      if (statuses[Permission.camera] == PermissionStatus.permanentlyDenied ||
          statuses[Permission.microphone] ==
              PermissionStatus.permanentlyDenied) {
        _showPermissionPermanentlyDeniedDialog();
      }
    } catch (e) {
      print("Error requesting permissions: $e");
    }
  }

  /// Handles permission denial after request, potentially guiding user to settings.
  void _handlePermissionDenial() {
    print("Handling permission denial.");
    _showToast("Permissions denied. Cannot start call.", isError: true);
    // Optionally show a dialog guiding user to app settings
    // showDialog(...)
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    });
  }

  /// Shows dialog if permissions are permanently denied.
  void _showPermissionPermanentlyDeniedDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text("Permissions Required"),
            content: const Text(
              "Camera and Microphone permissions are permanently denied. Please enable them in your app settings to make calls.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () => openAppSettings(),
                child: const Text("Open Settings"),
              ), // From permission_handler
            ],
          ),
    ).then((_) {
      // End call if dialog is dismissed after showing permanent denial message
      _endCall(navigate: true);
    });
  }

  /// Initializes Firestore document reference and listeners for call and candidates.
  /// Fetches initial call state and determines role (caller/callee).
  void _initializeCallDocAndListeners() {
    if (!mounted || _currentUserId == null || widget.channelId.isEmpty) return;
    print("Initializing Call Document Reference: ${widget.channelId}");
    _callDoc = _firestore.collection('calls').doc(widget.channelId);

    // --- Initial Fetch and Setup ---
    _callDoc
        .get(const GetOptions(source: Source.serverAndCache))
        .then((snapshot) async {
          // Make async
          if (!mounted) return;
          print("Initial call document fetched. Exists: ${snapshot.exists}");
          if (snapshot.exists) {
            final data = snapshot.data();
            if (data == null) {
              _handleInitializationError('Invalid call data.');
              return;
            }
            print("Initial call data: $data");

            // Determine if video call BEFORE requesting permissions again
            _isVideoCall = data['isVideoCall'] ?? true;

            // Re-check permissions based on actual call type
            bool cameraGranted = await Permission.camera.isGranted;
            bool micGranted = await Permission.microphone.isGranted;
            if (!micGranted || (_isVideoCall && !cameraGranted)) {
              _showToast(
                "Camera/Microphone permissions required.",
                isError: true,
              );
              _handlePermissionDenial();
              return; // Stop initialization if needed permissions are missing
            }

            // Proceed with setting up call state
            final callerId = data['callerId'] as String?;
            final calleeId = data['calleeId'] as String?;
            if (callerId == null || calleeId == null) {
              _handleInitializationError('Invalid participants.');
              return;
            }

            _isIncomingCall = (_currentUserId == calleeId);
            _otherUserId = _isIncomingCall ? callerId : calleeId;
            print(
              "Is Incoming: $_isIncomingCall, Other User ID: $_otherUserId",
            );

            _fetchOtherUserInfo(); // Fetch display name/image

            final callStatus = data['status'] as String?;
            print("Initial Status: $callStatus");

            if (callStatus == 'ended' || callStatus == 'declined') {
              _showToast('Call has already ended or was declined.');
              _endCall(navigate: true);
              return;
            }

            bool alreadyAccepted =
                (callStatus == 'accepted' || callStatus == 'connected');
            if (alreadyAccepted) {
              print("Call already accepted/connected.");
              setState(() => _isCallAccepted = true);
              _getUserMedia().then((success) {
                // Get media immediately
                if (success == true && mounted)
                  _setupPeerConnection();
                else if (mounted)
                  _handleInitializationError("Failed to get media.");
              });
            } else if (!_isIncomingCall) {
              print("Outgoing call, getting media proactively...");
              _getUserMedia(); // Start getting media early for caller
            }

            setState(() => _isCallInitialized = true); // Mark basic init done
            _listenToCallChanges(); // Start listening for further updates
            if (!alreadyAccepted) {
              _startConnectionTimeoutTimer(); // Start timeout for non-accepted calls
            }
          } else {
            _handleInitializationError('Call session not found.');
          }
        })
        .catchError((error) {
          print('FATAL: Error fetching initial call doc: $error');
          _handleInitializationError('Error connecting to call session.');
        });
  }

  /// Fetches the other user's display name and image URL from Firestore.
  Future<void> _fetchOtherUserInfo() async {
    if (_otherUserId == null) return;
    print("Fetching user info for ID: $_otherUserId");
    try {
      final userDoc =
          await _firestore.collection('users').doc(_otherUserId!).get();
      if (mounted && userDoc.exists) {
        final userData = userDoc.data();
        final name = userData?['displayName'] ?? userData?['name'] ?? "User";
        final img = userData?['imageUrl'] ?? '';
        print("Found user name: $name, Image: $img");
        if (mounted) {
          setState(() {
            _otherUserName = name;
            _otherUserImageUrl = img;
          });
        }
      } else if (mounted) {
        print("Other user document not found.");
        setState(() {
          _otherUserName = "User";
          _otherUserImageUrl = '';
        });
      }
    } catch (e) {
      print("Error fetching other user info: $e");
      if (mounted) {
        setState(() {
          _otherUserName = "User";
          _otherUserImageUrl = '';
        });
      }
    }
  }

  /// Listens for real-time changes to the call document (status, offer, answer).
  void _listenToCallChanges() {
    _callSubscription?.cancel(); // Cancel previous listener if any
    print("Starting listener for call document changes...");
    _callSubscription = _callDoc.snapshots().listen(
      (snapshot) {
        if (!mounted) return;
        print("Call doc update received. Exists: ${snapshot.exists}");
        if (!snapshot.exists) {
          _showToast('Call session removed.');
          _endCall(navigate: true);
          return;
        }

        final data = snapshot.data();
        if (data == null) {
          print("Call data null in listener.");
          return;
        }
        print("Call data update: $data");

        final callStatus = data['status'] as String?;
        print("Received Status Update: $callStatus");

        // Handle Call Ending
        if (callStatus == 'ended' || callStatus == 'declined') {
          bool alreadyCleaningUp =
              (_peerConnection == null && _localStream == null);
          if (!alreadyCleaningUp) {
            _showToast(
              callStatus == 'declined' ? 'Call declined' : 'Call ended',
            );
            _endCall(navigate: true);
          } else {
            print("Ignoring '$callStatus' as cleanup done.");
          }
          return;
        }
        // Handle Call Acceptance
        if (callStatus == 'accepted' && !_isCallAccepted) {
          print("Call accepted by other user!");
          setState(() => _isCallAccepted = true);
          _resetConnectionTimeoutTimer(); // Reset timeout for peer connection
          _getUserMedia().then((success) {
            if (success == true && mounted) {
              print("Media ready, setting up PC...");
              _setupPeerConnection();
            } else if (mounted) {
              _showToast("Media failed after accept.");
              _endCall(navigate: true);
            }
          });
        }
        // Handle SDP Offer (for Callee)
        if (_isIncomingCall && _isCallAccepted && data.containsKey('offer')) {
          final offerData = data['offer'] as Map<String, dynamic>?;
          // Rely on signaling state check within handleReceivedOffer if needed
          if (offerData != null && _peerConnection != null) {
            print("Received Offer, handling...");
            _handleReceivedOffer(offerData);
          }
        }
        // Handle SDP Answer (for Caller)
        if (!_isIncomingCall && data.containsKey('answer')) {
          final answerData = data['answer'] as Map<String, dynamic>?;
          // Rely on signaling state check within handleReceivedAnswer if needed
          if (answerData != null && _peerConnection != null) {
            print("Received Answer, handling...");
            _handleReceivedAnswer(answerData);
          }
        }
      },
      onError: (error) {
        print('FATAL: Call subscription error: $error');
        if (mounted) {
          _showToast('Session connection lost.');
          if (_isCallConnected || _isCallAccepted) {
            if (!_isReconnecting) setState(() => _isReconnecting = true);
            _tryReconnect();
          } else {
            _endCall(navigate: true);
          }
        }
      },
      onDone: () {
        print("Call subscription closed.");
        if (mounted && (_isCallConnected || _isCallAccepted)) {
          _showToast("Session listener closed.");
          if (!_isReconnecting) setState(() => _isReconnecting = true);
          _tryReconnect();
        }
      },
    );
  }

  /// Starts a timer that ends the call if not connected/accepted within a duration.
  void _startConnectionTimeoutTimer() {
    _connectionTimeoutTimer?.cancel();
    print(
      "Starting connection timeout timer (${_callTimeoutDuration.inSeconds}s).",
    );
    _connectionTimeoutTimer = Timer(_callTimeoutDuration, () {
      if (!mounted) return;
      if (!_isCallConnected && !_isCallAccepted) {
        print("TIMEOUT: No answer/acceptance.");
        _showToast('Call timed out (No Answer).');
        _endCall(navigate: true);
      } else if (_isCallAccepted && !_isCallConnected) {
        print("TIMEOUT: Connection failed post-acceptance.");
        _showToast('Connection failed.');
        _endCall(navigate: true);
      }
    });
  }

  /// Resets the connection timeout timer (e.g., after acceptance).
  void _resetConnectionTimeoutTimer() {
    _connectionTimeoutTimer?.cancel();
    print("Connection timeout timer cancelled (call accepted/connected).");
    // Optional: Could start a longer timeout specifically for peer connection establishment
  }

  /// Shows a SnackBar message.
  void _showToast(String message, {bool isError = false}) {
    if (mounted) {
      print("Toast: $message");
      final scaffoldMessenger = ScaffoldMessenger.maybeOf(context);
      scaffoldMessenger?.removeCurrentSnackBar(); // Remove previous snackbar
      scaffoldMessenger?.showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          backgroundColor: isError ? Colors.redAccent : Colors.black87,
          behavior: SnackBarBehavior.floating, // Make it float
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          margin: const EdgeInsets.all(10),
        ),
      );
    } else {
      print("Toast skipped (unmounted): $message");
    }
  }

  /// Initializes the local and remote RTCVideoRenderers.
  Future<void> _initializeRenderers() async {
    print("Initializing RTC Video Renderers...");
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      print("Renderers initialized successfully.");
    } catch (e) {
      print("FATAL: Error initializing renderers: $e");
      _handleInitializationError("Video display error.");
    }
  }

  /// Gets user media (camera and/or microphone).
  Future<bool> _getUserMedia() async {
    if (_localStream != null && _localStream!.getTracks().isNotEmpty) {
      print("Media stream already available.");
      if (_localRenderer.srcObject == null && _isVideoCall) {
        _localRenderer.srcObject = _localStream;
      }
      return true;
    }
    if (!mounted) return false;
    print("Requesting User Media (Audio: true, Video: $_isVideoCall)...");

    final Map<String, dynamic> constraints = {
      'audio': true, // Always request audio
      'video':
          _isVideoCall
              ? {'facingMode': 'user'}
              : false, // Request video only if needed
    };
    print("Media constraints: $constraints");

    try {
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      if (!mounted) {
        stream.getTracks().forEach((t) => t.stop());
        return false;
      }
      print("Media stream acquired: ${stream.id}");
      await _cleanupLocalStream(); // Clean up previous stream if any
      _localStream = stream;
      if (_isVideoCall) {
        _localRenderer.srcObject =
            _localStream; // Assign to local preview only if video call
      } else {
        _localRenderer.srcObject =
            null; // Ensure no local preview for audio call
      }
      await _updateAudioOutput(); // Set initial speaker/earpiece state
      if (mounted) setState(() {}); // Update UI if needed
      return true; // Success
    } catch (e) {
      print('ERROR accessing media devices: $e');
      if (!mounted) return false;
      String errorMsg = 'Could not access camera/microphone.';
      if (e is PlatformException) {
        errorMsg = e.message ?? errorMsg;
        if (e.code == 'PermissionDenied')
          errorMsg = 'Permissions denied.';
        else if (e.code == 'NotFound')
          errorMsg = 'Camera/microphone not found.';
      } else if (e.toString().contains('NotAllowedError'))
        errorMsg = 'Permissions denied.';
      _showToast(errorMsg, isError: true);

      // Fallback to Audio-Only (Only if initial request was for video)
      if (_isVideoCall) {
        print("Attempting audio-only fallback...");
        try {
          final audioStream = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': false,
          });
          if (!mounted) {
            audioStream.getTracks().forEach((t) => t.stop());
            return false;
          }
          print("Audio-only fallback successful: ${audioStream.id}");
          await _cleanupLocalStream();
          _localStream = audioStream;
          _localRenderer.srcObject = null;
          setState(() {
            _isVideoCall = false;
            _isVideoEnabled = false;
            _isSpeakerOn = false;
          });
          await _updateAudioOutput();
          _showToast('Video unavailable. Switched to audio only.');
          return true; // Success (audio-only)
        } catch (audioError) {
          print("Audio fallback failed: $audioError");
          if (!mounted) return false;
          _showToast('Microphone access failed.', isError: true);
          _endCall(navigate: true);
          return false;
        }
      } else {
        // If initial request was already audio-only and failed
        _endCall(navigate: true);
        return false;
      }
    }
  }

  /// Stops and disposes the local media stream and tracks.
  Future<void> _cleanupLocalStream() async {
    if (_localStream != null) {
      print("Cleaning up previous local stream...");
      final tracks = _localStream!.getTracks();
      for (var track in tracks) {
        try {
          await track.stop();
          print("  Stopped track: ${track.kind}");
        } catch (e) {
          print("  Error stopping track: $e");
        }
      }
      try {
        await _localStream!.dispose();
        print("Previous stream disposed.");
      } catch (e) {
        print("Error disposing stream: $e");
      }
      _localStream = null;
      if (mounted) _localRenderer.srcObject = null; // Clear renderer too
    }
  }

  /// Sets the audio output device (speaker or earpiece).
  Future<void> _updateAudioOutput() async {
    if (!mounted) return;
    try {
      final bool useSpeaker = _isSpeakerOn;
      // Use the Helper method provided by flutter_webrtc
      final String targetOutput = useSpeaker ? 'speaker' : 'earpiece';
      print("Setting audio output to: $targetOutput");
      await Helper.selectAudioOutput(targetOutput);
    } catch (e) {
      print("Error setting audio output: $e");
      // Might fail on web or if Helper isn't correctly implemented
    }
  }

  /// Creates the RTCPeerConnection object.
  Future<void> _createPeerConnection() async {
    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }
    if (!mounted) return;

    if (_localStream == null || _localStream!.getTracks().isEmpty) {
      print(
        "ERROR: _createPeerConnection called but local stream is not ready.",
      );
      _showToast("Media stream failed.", isError: true);
      _endCall(navigate: true);
      return;
    }

    print("Creating Peer Connection with config: $_peerConfiguration");
    try {
      _peerConnection = await createPeerConnection(_peerConfiguration);
      print('Peer connection created successfully.');
      if (!mounted) {
        await _peerConnection?.close();
        _peerConnection = null;
        return;
      }

      print("Adding local tracks to PeerConnection...");
      int tracksAdded = 0;
      for (var track in _localStream!.getTracks()) {
        try {
          print("  Adding track: ${track.id} (${track.kind})");
          await _peerConnection!.addTrack(track, _localStream!);
          print("    -> Successfully added track: ${track.id}");
          tracksAdded++;
        } catch (e) {
          print("    -> ERROR adding track ${track.id} (${track.kind}): $e");
        }
      }
      if (tracksAdded == 0)
        throw Exception("Failed to add any tracks to PeerConnection.");

      _setupPeerConnectionListeners();
      _listenForRemoteCandidates();
    } catch (e) {
      print('FATAL: Error creating/setting up peer connection: $e');
      if (mounted) {
        _showToast('Call setup failed.', isError: true);
        _endCall(navigate: true);
      }
    }
  }

  /// Sets up listeners for PeerConnection events.
  void _setupPeerConnectionListeners() {
    if (_peerConnection == null) {
      print("Error: PC null in setup listeners.");
      return;
    }
    print("Setting up Peer Connection event listeners...");

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (!mounted) return;
      if (candidate.candidate != null) {
        print('--> Generated ICE candidate: ${candidate.sdpMid}');
        if (_currentUserId != null) {
          _callDoc
              .collection('candidates')
              .doc(_currentUserId)
              .collection('candidates')
              .add({
                ...candidate.toMap(),
                'timestamp': FieldValue.serverTimestamp(),
              })
              .then((_) => print("    ICE sent."))
              .catchError((e) => print("    Error sending ICE: $e"));
        }
      } else {
        print("--> End of ICE candidates.");
      }
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      print('==> PC state: $state');
      if (!mounted) return;
      bool connected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      bool reconnecting =
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;
      bool failedOrClosed =
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed;

      if (connected && _callTimer == null) {
        _startCallTimer();
      }
      if (!connected && _callTimer != null) {
        _stopCallTimer();
      }

      if (_isCallConnected != connected || _isReconnecting != reconnecting) {
        setState(() {
          _isCallConnected = connected;
          _isReconnecting = reconnecting;
        });
      }
      if (connected) {
        _showToast('Connected');
        _reconnectAttempts = 0;
        _connectionTimeoutTimer?.cancel();
      } else if (reconnecting) {
        _showToast('Connection lost, reconnecting...');
        _tryReconnect();
      } else if (failedOrClosed) {
        _showToast(
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed
              ? 'Connection failed.'
              : 'Call closed.',
          isError: failedOrClosed,
        );
        _endCall(navigate: true);
      }
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      print('==> ICE state: $state');
      if (!mounted) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _showToast('Network connection failed (ICE).', isError: true);
        if (!_isReconnecting && (_isCallConnected || _isCallAccepted)) {
          setState(() => _isReconnecting = true);
          _tryReconnect();
        }
      }
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      print(
        '<-- Remote track received: ${event.track.kind} [${event.track.id}]',
      );
      if (!mounted) return;
      if (event.streams.isNotEmpty) {
        final stream = event.streams[0];
        if (event.track.kind == 'video') {
          print("    Assigning remote video stream ${stream.id} to renderer.");
          setState(() => _remoteRenderer.srcObject = stream);
        } else if (event.track.kind == 'audio' &&
            _remoteRenderer.srcObject == null) {
          print(
            "    Assigning stream ${stream.id} to remote renderer (audio track).",
          );
          setState(() => _remoteRenderer.srcObject = stream);
        }
      } else {
        print("    WARN: Received track without streams.");
      }
    };

    _peerConnection!.onRemoveTrack = (
      MediaStream stream,
      MediaStreamTrack track,
    ) {
      print(
        '<-- Remote track removed: ${track.kind} [${track.id}] from stream ${stream.id}',
      );
      if (!mounted) return;
      final remoteStream = _remoteRenderer.srcObject;
      if (remoteStream != null &&
          remoteStream.id == stream.id &&
          track.kind == 'video') {
        bool hasOtherVideoTracks = remoteStream.getVideoTracks().any(
          (t) => t.id != track.id && t.enabled == true,
        );
        if (!hasOtherVideoTracks) {
          print(
            "    Last video track removed/disabled. Clearing remote renderer.",
          );
          setState(() => _remoteRenderer.srcObject = null);
        }
      }
    };

    _peerConnection!.onSignalingState =
        (RTCSignalingState state) => print('==> Signaling state: $state');
    _peerConnection!.onIceGatheringState =
        (RTCIceGatheringState state) =>
            print('==> ICE Gathering state: $state');
    print("Peer Connection listeners set up.");
  }

  /// Listens for ICE candidates added by the remote peer in Firestore.
  void _listenForRemoteCandidates() {
    if (_otherUserId == null || _currentUserId == null) {
      print("Error: User IDs missing for candidate listener.");
      return;
    }
    _candidatesSubscription?.cancel();
    print("Listening for remote ICE candidates from $_otherUserId...");
    final candidatesCollection = _callDoc
        .collection('candidates')
        .doc(_otherUserId)
        .collection('candidates');

    _candidatesSubscription = candidatesCollection
        .orderBy('timestamp')
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || _peerConnection == null) return;
            print(
              "Remote candidates snapshot: ${snapshot.docChanges.length} changes.",
            );
            for (var change in snapshot.docChanges) {
              if (change.type == DocumentChangeType.added) {
                final data = change.doc.data() as Map<String, dynamic>?;
                if (data != null) {
                  print('<-- Received remote ICE candidate: ${data['sdpMid']}');
                  try {
                    final candidate = RTCIceCandidate(
                      data['candidate'],
                      data['sdpMid'],
                      data['sdpMLineIndex'],
                    );
                    if (_peerConnection!.signalingState !=
                        RTCSignalingState.RTCSignalingStateClosed) {
                      print("    Adding remote candidate...");
                      _peerConnection!
                          .addCandidate(candidate)
                          .then((_) => print("      -> Candidate added."))
                          .catchError(
                            (e) => print("      -> Error adding candidate: $e"),
                          );
                    } else {
                      print("    Skipping add candidate (PC closed).");
                    }
                  } catch (e) {
                    print("    Error parsing received candidate: $e");
                  }
                }
              }
            }
          },
          onError: (e) {
            print("FATAL: Candidate listener error: $e");
            _showToast("Connection data error.", isError: true);
          },
          onDone: () => print("Remote candidate listener closed."),
        );
  }

  /// Attempts to reconnect the call, typically after network loss.
  void _tryReconnect() {
    if (!mounted) {
      print("Reconnect skipped: Unmounted.");
      return;
    }
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      print("Reconnect failed: Max attempts.");
      _showToast('Failed to reconnect.');
      _endCall(navigate: true);
      return;
    }
    if (!_isCallAccepted) {
      print("Reconnect skipped: Call not accepted.");
      if (_isReconnecting) setState(() => _isReconnecting = false);
      return;
    }
    if (!_isReconnecting) setState(() => _isReconnecting = true);

    _reconnectAttempts++;
    _showToast('Reconnecting... ($_reconnectAttempts/$_maxReconnectAttempts)');

    Connectivity().checkConnectivity().then((connectivityResult) {
      if (!mounted) return;
      if (connectivityResult.contains(ConnectivityResult.none)) {
        _showToast('No network. Retrying in 5s...');
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(seconds: 5), _tryReconnect);
        return;
      }

      // Use pow from dart:math for exponential backoff
      final reconnectDelay = Duration(
        seconds: pow(2, _reconnectAttempts).toInt(),
      );
      print(
        "Scheduling reconnect attempt #${_reconnectAttempts} in ${reconnectDelay.inSeconds}s.",
      );
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(reconnectDelay, () async {
        if (!mounted || !_isReconnecting) {
          print("Reconnect attempt cancelled.");
          return;
        }
        print("Executing reconnect attempt #$_reconnectAttempts...");
        try {
          if (_peerConnection != null && !_isIncomingCall) {
            await _createOffer(iceRestart: true);
          } else if (_peerConnection != null && _isIncomingCall) {
            print("    Waiting for remote peer to initiate ICE restart.");
          } else {
            _showToast('Cannot reconnect session.');
            _endCall(navigate: true);
          }
        } catch (e) {
          print('Error during reconnect attempt: $e');
          if (mounted && _isReconnecting) {
            _tryReconnect();
          }
        }
      });
    });
  }

  // --- SDP Offer/Answer Handling ---
  Future<void> _handleReceivedOffer(Map<String, dynamic> offerData) async {
    if (!mounted || _peerConnection == null) {
      print("Cannot handle offer: Unmounted or PC null.");
      return;
    }
    if (offerData['sdp'] == null || offerData['type'] == null) {
      print("Invalid offer data.");
      return;
    }

    try {
      final offer = RTCSessionDescription(offerData['sdp'], offerData['type']);
      print('<-- Handling Received Offer: type=${offer.type}');
      // Relying on signaling state check before setting
      if (_peerConnection!.signalingState ==
              RTCSignalingState.RTCSignalingStateStable ||
          _peerConnection!.signalingState ==
              RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        // Check if polite rollback needed?
        await _peerConnection!.setRemoteDescription(offer);
        print('    Remote description (offer) set.');
        // Create answer only if state becomes HaveRemoteOffer
        if (_peerConnection!.signalingState ==
            RTCSignalingState.RTCSignalingStateHaveRemoteOffer) {
          await _createAnswer();
        }
      } else {
        print(
          "WARN: Received offer in unexpected state: ${_peerConnection!.signalingState}. Ignoring for now.",
        );
        // Handle glare more robustly if needed
      }
    } catch (e) {
      print('ERROR handling offer: $e');
      _showToast('Error processing call data.');
    }
  }

  Future<void> _handleReceivedAnswer(Map<String, dynamic> answerData) async {
    if (!mounted || _peerConnection == null) {
      print("Cannot handle answer: Unmounted or PC null.");
      return;
    }
    if (answerData['sdp'] == null || answerData['type'] == null) {
      print("Invalid answer data.");
      return;
    }

    try {
      final answer = RTCSessionDescription(
        answerData['sdp'],
        answerData['type'],
      );
      print('<-- Handling Received Answer: type=${answer.type}');
      // Set remote description only if we have a local offer pending
      if (_peerConnection!.signalingState ==
          RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        await _peerConnection!.setRemoteDescription(answer);
        print("    Remote description (answer) set.");
      } else {
        print(
          "WARN: Received answer in unexpected state: ${_peerConnection!.signalingState}.",
        );
      }
    } catch (e) {
      print('ERROR handling answer: $e');
      _showToast('Error processing response.');
    }
  }

  Future<void> _createOffer({bool iceRestart = false}) async {
    if (!mounted || _peerConnection == null) {
      print("Cannot create offer: Unmounted or PC null.");
      return;
    }
    try {
      print('--> Creating offer (iceRestart: $iceRestart)...');
      final constraints = <String, dynamic>{
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': _isVideoCall,
        },
        'optional': [],
      };
      if (iceRestart) {
        constraints['mandatory']['IceRestart'] = true;
      }
      RTCSessionDescription description = await _peerConnection!.createOffer(
        constraints,
      );
      print('--> Setting local description (offer)...');
      await _peerConnection!.setLocalDescription(description);
      print('    Local description (offer) set.');
      print('--> Saving offer to Firestore...');
      await _callDoc
          .set({
            'offer': {'type': description.type, 'sdp': description.sdp},
            'timestamp': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .catchError((e) {
            print("    Error saving offer: $e");
            _showToast('Error initiating call');
          });
    } catch (e) {
      print('ERROR creating/setting offer: $e');
      _showToast('Error setting up call');
    }
  }

  Future<void> _createAnswer() async {
    if (!mounted || _peerConnection == null) {
      print("Cannot create answer: Unmounted or PC null.");
      return;
    }
    try {
      print('--> Creating answer...');
      RTCSessionDescription description = await _peerConnection!.createAnswer(
        {},
      );
      print('--> Setting local description (answer)...');
      await _peerConnection!.setLocalDescription(description);
      print('    Local description (answer) set.');
      print('--> Saving answer to Firestore...');
      await _callDoc
          .update({
            'answer': {'type': description.type, 'sdp': description.sdp},
            'timestamp': FieldValue.serverTimestamp(),
          })
          .catchError((e) {
            print("    Error saving answer: $e");
            _showToast('Error accepting call');
          });
    } catch (e) {
      print('ERROR creating/setting answer: $e');
      _showToast('Error accepting call');
    }
  }

  /// Sets up the peer connection after media is acquired.
  Future<void> _setupPeerConnection() async {
    print("Setting up peer connection sequence...");
    if (_localStream == null || _localStream!.getTracks().isEmpty) {
      print("    Media stream not ready. Aborting setup.");
      _showToast("Camera/mic failed.", isError: true);
      _endCall(navigate: true);
      return;
    }
    await _createPeerConnection();
    if (!mounted || _peerConnection == null) {
      print("PC setup aborted.");
      return;
    }

    if (!_isIncomingCall) {
      print("    Caller initiating offer...");
      await _createOffer();
    } else {
      print("    Callee waiting for offer...");
    }
  }

  // --- Call Actions ---
  void _acceptCall() async {
    if (!mounted) return;
    print("Accept button pressed.");
    try {
      // Update status first
      await _callDoc.update({'status': 'accepted'});
      setState(() => _isCallAccepted = true);
      print(
        "Status updated to accepted. Getting media and setting up connection...",
      );
      // Get media and set up connection AFTER accepting
      bool mediaSuccess = await _getUserMedia();
      if (mediaSuccess && mounted) {
        await _setupPeerConnection();
      } else if (mounted) {
        _showToast("Media failed.", isError: true);
        _endCall(navigate: true);
      }
    } catch (e) {
      print('Error accepting call: $e');
      _showToast('Accept failed.');
    }
  }

  void _declineCall() async {
    if (!mounted) return;
    print("Decline button pressed.");
    try {
      await _callDoc.update({'status': 'declined'});
    } catch (e) {
      print('Error declining call: $e');
    } finally {
      _endCall(navigate: true);
    }
  }

  void _toggleMute() {
    if (!mounted || _localStream == null) return;
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isNotEmpty) {
      bool targetMuteState = !_isMuted;
      print("Toggling mute -> ${targetMuteState ? 'MUTED' : 'UNMUTED'}");
      for (var track in audioTracks) {
        track.enabled = !targetMuteState;
      }
      setState(() => _isMuted = targetMuteState);
    } else {
      print("No local audio track to toggle mute.");
    }
  }

  void _toggleCamera({
    bool forceEnable = false,
    bool forceDisable = false,
  }) async {
    if (!mounted || _localStream == null || !_isVideoCall) {
      print("Toggle camera skipped.");
      return;
    }
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      bool targetEnableState =
          forceEnable ? true : (forceDisable ? false : !_isVideoEnabled);
      print(
        "Toggling camera track -> ${targetEnableState ? 'ENABLED' : 'DISABLED'}",
      );
      for (var track in videoTracks) {
        track.enabled = targetEnableState;
      }
      setState(() => _isVideoEnabled = targetEnableState);
    } else {
      print("No local video track to toggle camera.");
    }
  }

  void _toggleSpeaker() async {
    if (!mounted) return;
    bool targetSpeakerState = !_isSpeakerOn;
    print("Toggling speaker -> ${targetSpeakerState ? 'SPEAKER' : 'EARPIECE'}");
    try {
      await Helper.selectAudioOutput(
        targetSpeakerState ? 'speaker' : 'earpiece',
      );
      if (mounted) {
        setState(() => _isSpeakerOn = targetSpeakerState);
      }
    } catch (e) {
      print('Error toggling speaker: $e');
      _showToast('Audio output switch failed.');
    }
  }

  void _switchCamera() async {
    if (!mounted || _localStream == null || !_isVideoCall || !_isVideoEnabled) {
      print("Switch camera skipped.");
      if (mounted && _isVideoCall && !_isVideoEnabled) {
        _showToast('Turn camera on first.');
      }
      return;
    }
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      print("Attempting camera switch...");
      try {
        bool success = await videoTracks[0].switchCamera();
        print(
          success ? "Camera switched." : "Switch failed (no other camera?).",
        );
        if (!success && mounted) _showToast('Failed to switch camera.');
      } catch (e) {
        print('Error switching camera: $e');
        if (mounted) _showToast('Switch camera error.');
      }
    } else {
      print("No local video track to switch.");
    }
  }

  Future<void> _cleanupResources() async {
    print("--- Cleaning up call resources ---");
    bool cleaned = false;
    // Cancel Subscriptions & Timers
    if (_callSubscription != null ||
        _candidatesSubscription != null ||
        _connectivitySubscription != null ||
        _reconnectTimer != null ||
        _connectionTimeoutTimer != null) {
      print("Cancelling subs/timers...");
      cleaned = true;
    }
    await _callSubscription?.cancel();
    _callSubscription = null;
    await _candidatesSubscription?.cancel();
    _candidatesSubscription = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectionTimeoutTimer?.cancel();
    _connectionTimeoutTimer = null;

    // Stop Media Stream Tracks & Dispose Stream
    await _cleanupLocalStream();
    if (_localStream == null) cleaned = true;

    // Close Peer Connection
    if (_peerConnection != null) {
      print("Closing peer connection...");
      cleaned = true;
      try {
        await _peerConnection!.close();
        print("Peer connection closed.");
      } catch (e) {
        print("Error closing PC: $e");
      }
      _peerConnection = null;
    }

    // Dispose Renderers
    if (_localRenderer.textureId != null || _remoteRenderer.textureId != null) {
      print("Disposing renderers...");
      cleaned = true;
    }
    try {
      await _localRenderer.dispose();
    } catch (e) {
      print("Error disposing local renderer: $e");
    }
    try {
      await _remoteRenderer.dispose();
    } catch (e) {
      print("Error disposing remote renderer: $e");
    }

    // Disable Wakelock
    try {
      print("Disabling wakelock...");
      cleaned = true;
      await WakelockPlus.disable();
    } catch (e) {
      print('Error disabling wakelock: $e');
    }

    if (cleaned)
      print("--- Resource cleanup complete ---");
    else
      print("--- No resources needed cleanup ---");
  }

  Future<void> _endCall({
    bool navigate = false,
    String status = 'ended',
  }) async {
    print("Initiating end call (status: $status, navigate: $navigate)...");
    bool wasConnectedOrAccepted = _isCallConnected || _isCallAccepted;

    // Update Firestore status first (best effort, ignore errors)
    try {
      final DocumentSnapshot<Map<String, dynamic>> docSnapshot = await _callDoc
          .get(const GetOptions(source: Source.server));
      final currentStatus = docSnapshot.data()?['status'];
      if (docSnapshot.exists &&
          currentStatus != 'ended' &&
          currentStatus != 'declined') {
        print("Updating call status to '$status'.");
        await _callDoc.update({'status': status});
      } else {
        print(
          "Skipping status update (current: $currentStatus or doc doesn't exist).",
        );
      }
    } catch (e) {
      print('Error updating call status on end: $e');
    }

    // Clean up local resources
    await _cleanupResources();

    // Navigate back if requested and still mounted
    if (navigate && mounted) {
      print("Navigating back...");
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      });
    } else if (navigate) {
      print("Navigation skipped: Unmounted.");
    }
    print("End call sequence finished.");
  }

  /// Toggles the visibility of the control buttons.
  void _toggleControls() {
    if (!mounted) return;
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (_controlsVisible) {
        _hideControlsTimer?.cancel();
        _hideControlsTimer = Timer(const Duration(seconds: 5), () {
          if (mounted && _controlsVisible) {
            setState(() => _controlsVisible = false);
          }
        });
      } else {
        _hideControlsTimer?.cancel();
      }
    });
  }

  // --- Call Timer ---
  void _startCallTimer() {
    _callTimer?.cancel();
    _callDuration = Duration.zero;
    print("Starting call timer.");
    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _callDuration = Duration(seconds: _callDuration.inSeconds + 1);
      });
    });
  }

  void _stopCallTimer() {
    print("Stopping call timer.");
    _callTimer?.cancel();
    _callTimer = null;
    // Reset duration display if needed when timer stops (e.g., on disconnect)
    // if (mounted) setState(() => _callDuration = Duration.zero);
  }

  // --- Build Methods ---
  @override
  Widget build(BuildContext context) {
    // Show initial loading screen
    if (!_isCallInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 20),
              Text(
                "Loading Call...",
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
        ),
      );
    }
    // Show incoming call screen if applicable
    if (_isIncomingCall && !_isCallAccepted) {
      return _buildIncomingCallScreen();
    }
    // Show main call UI
    return Scaffold(
      backgroundColor: Colors.blueGrey.shade900, // Dark background
      body: GestureDetector(
        // Tap anywhere to toggle controls
        onTap: _toggleControls,
        child: SafeArea(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Main View (Remote Video or Placeholder)
              Positioned.fill(child: _buildMainView()),
              // Local Video Preview (Picture-in-Picture style)
              if (_isVideoCall && _localStream != null && _isVideoEnabled)
                _buildLocalPreview(),
              // Status Indicator (Connecting, Reconnecting)
              _buildStatusIndicator(),
              // Control Buttons (Bottom) - Animated visibility
              Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControlButtons(),
                  ),
                ),
              ),
              // Call Timer (Top) - Animated visibility
              Align(
                alignment: Alignment.topCenter,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildCallInfoBar(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the main view area (remote video or placeholder).
  Widget _buildMainView() {
    bool showRemoteVideo = _isVideoCall && _remoteRenderer.textureId != null;
    return Container(
      color: Colors.black, // Fallback background
      child:
          showRemoteVideo
              ? RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: false,
                placeholderBuilder:
                    (context) => _buildPlaceholderView(showStatus: true),
              )
              : _buildPlaceholderView(
                showStatus: true,
              ), // Show placeholder if no remote video
    );
  }

  /// Builds the placeholder view shown when remote video isn't available.
  Widget _buildPlaceholderView({bool showStatus = false}) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.blueGrey.shade900, Colors.black],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 60,
                backgroundColor: Colors.white.withOpacity(0.1),
                backgroundImage:
                    _otherUserImageUrl.isNotEmpty
                        ? NetworkImage(_otherUserImageUrl)
                        : null,
                child:
                    _otherUserImageUrl.isEmpty
                        ? Icon(
                          _isVideoCall
                              ? Icons.videocam_off_outlined
                              : Icons.person,
                          size: 50,
                          color: Colors.white70,
                        )
                        : null,
              ),
              const SizedBox(height: 24),
              Text(
                _otherUserName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      blurRadius: 4.0,
                      color: Colors.black38,
                      offset: Offset(1.0, 1.0),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (showStatus)
                _buildDynamicStatusText(), // Show status text here
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the text/indicator showing the current call status.
  Widget _buildDynamicStatusText() {
    String statusText;
    Widget? statusIndicator;
    if (_isReconnecting) {
      statusText = "Reconnecting...";
      statusIndicator = const SizedBox(
        height: 16,
        width: 16,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    } else if (_isCallConnected) {
      statusText = "Connected";
    } // Timer shown separately
    else if (_isCallAccepted) {
      statusText = "Connecting...";
      statusIndicator = const SizedBox(
        height: 16,
        width: 16,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    } else if (!_isIncomingCall) {
      statusText = "Calling...";
    } else {
      statusText = "Incoming Call";
    } // Should be on incoming screen

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (statusIndicator != null) statusIndicator,
        if (statusIndicator != null) const SizedBox(width: 8),
        Text(
          statusText,
          style: const TextStyle(color: Colors.white70, fontSize: 18),
        ),
      ],
    );
  }

  /// Builds the small local video preview window.
  Widget _buildLocalPreview() {
    if (_localRenderer.textureId == null) return const SizedBox.shrink();
    return Positioned(
      right: 16,
      top:
          16 +
          kToolbarHeight, // Position below potential status bar/appbar area
      width: 100,
      height: 150,
      child: GestureDetector(
        onTap: _switchCamera, // Tap preview to switch camera
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7), // Clip inner view
            child: RTCVideoView(
              _localRenderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              placeholderBuilder: (context) => Container(color: Colors.black54),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds the top bar showing call duration and other user info.
  Widget _buildCallInfoBar() {
    // Format duration H:MM:SS or MM:SS
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(_callDuration.inMinutes.remainder(60));
    final seconds = twoDigits(_callDuration.inSeconds.remainder(60));
    final hours = twoDigits(_callDuration.inHours);
    final durationString =
        _callDuration.inHours > 0
            ? "$hours:$minutes:$seconds"
            : "$minutes:$seconds";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(0.6), Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Colors.grey.shade700,
                backgroundImage:
                    _otherUserImageUrl.isNotEmpty
                        ? NetworkImage(_otherUserImageUrl)
                        : null,
                child:
                    _otherUserImageUrl.isEmpty
                        ? const Icon(
                          Icons.person,
                          size: 16,
                          color: Colors.white70,
                        )
                        : null,
              ),
              const SizedBox(width: 8),
              Text(
                _otherUserName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (_isCallConnected)
            Text(
              durationString,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }

  /// Builds the status indicator shown when connecting/reconnecting.
  Widget _buildStatusIndicator() {
    String statusText = "";
    Widget? leadingWidget;
    bool showIndicator = false;
    if (_isReconnecting) {
      statusText = "Reconnecting...";
      leadingWidget = const SizedBox(
        height: 12,
        width: 12,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 1.5),
      );
      showIndicator = true;
    } else if (!_isCallConnected && _isCallAccepted) {
      statusText = "Connecting...";
      leadingWidget = const SizedBox(
        height: 12,
        width: 12,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 1.5),
      );
      showIndicator = true;
    } else if (!_isCallConnected && !_isCallAccepted && !_isIncomingCall) {
      statusText = "Calling...";
      showIndicator = true;
    }

    if (!showIndicator) return const SizedBox.shrink();

    return Positioned(
      top: kToolbarHeight + 10,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leadingWidget != null) leadingWidget,
              if (leadingWidget != null) const SizedBox(width: 8),
              Text(
                statusText,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the row of control buttons (Mute, Speaker, Video, End Call, etc.).
  Widget _buildControlButtons() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.7), Colors.transparent],
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 16.0,
        runSpacing: 16.0,
        children:
            [
              _controlButton(
                icon: _isMuted ? Icons.mic_off : Icons.mic,
                backgroundColor:
                    _isMuted
                        ? Colors.white.withOpacity(0.3)
                        : Colors.blueGrey.withOpacity(0.5),
                iconColor: Colors.white,
                onPressed: _toggleMute,
                tooltip: _isMuted ? 'Unmute' : 'Mute',
              ),
              _controlButton(
                icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                backgroundColor: Colors.blueGrey.withOpacity(0.5),
                iconColor: Colors.white,
                onPressed: _toggleSpeaker,
                tooltip: _isSpeakerOn ? 'Earpiece' : 'Speaker',
              ),
              if (_isVideoCall)
                _controlButton(
                  icon: _isVideoEnabled ? Icons.videocam : Icons.videocam_off,
                  backgroundColor:
                      _isVideoEnabled
                          ? Colors.blueGrey.withOpacity(0.5)
                          : Colors.white.withOpacity(0.3),
                  iconColor: Colors.white,
                  onPressed: () => _toggleCamera(),
                  tooltip: _isVideoEnabled ? 'Video Off' : 'Video On',
                ),
              if (_isVideoCall && _isVideoEnabled)
                _controlButton(
                  icon: Icons.flip_camera_ios,
                  backgroundColor: Colors.blueGrey.withOpacity(0.5),
                  iconColor: Colors.white,
                  onPressed: _switchCamera,
                  tooltip: 'Switch Cam',
                ),
              _controlButton(
                icon: Icons.call_end,
                backgroundColor: Colors.red.shade700,
                iconColor: Colors.white,
                onPressed: () => _endCall(navigate: true),
                tooltip: 'End Call',
                size: 70,
              ), // Larger end call button
            ].where((widget) => widget != null).toList(),
      ),
    );
  }

  /// Helper to build a single circular control button.
  Widget _controlButton({
    required IconData icon,
    required Color backgroundColor,
    required Color iconColor,
    required VoidCallback? onPressed,
    required String tooltip,
    double size = 60,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: backgroundColor,
        shape: const CircleBorder(),
        elevation: 3.0,
        shadowColor: Colors.black45,
        child: InkWell(
          borderRadius: BorderRadius.circular(size / 2),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: iconColor, size: size * 0.5),
          ),
        ),
      ),
    );
  }

  /// Builds the UI shown for an incoming call before it's accepted.
  Widget _buildIncomingCallScreen() {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.deepPurple.shade700, Colors.blue.shade800],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 32.0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  children: [
                    const SizedBox(height: 40),
                    Text(
                      _isVideoCall
                          ? "Incoming Video Call"
                          : "Incoming Voice Call",
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.white.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _otherUserName,
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            blurRadius: 8.0,
                            color: Colors.black26,
                            offset: Offset(1.0, 1.0),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
                CircleAvatar(
                  radius: 80,
                  backgroundColor: Colors.white.withOpacity(0.15),
                  backgroundImage:
                      _otherUserImageUrl.isNotEmpty
                          ? NetworkImage(_otherUserImageUrl)
                          : null,
                  child:
                      _otherUserImageUrl.isEmpty
                          ? Icon(
                            _isVideoCall
                                ? Icons.videocam_rounded
                                : Icons.call_rounded,
                            size: 70,
                            color: Colors.white,
                          )
                          : null,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _actionButton(
                      icon: Icons.call_end,
                      backgroundColor: Colors.red.shade600,
                      iconColor: Colors.white,
                      label: "Decline",
                      onPressed: _declineCall,
                    ),
                    _actionButton(
                      icon: _isVideoCall ? Icons.videocam : Icons.call,
                      backgroundColor: Colors.green.shade600,
                      iconColor: Colors.white,
                      label: "Accept",
                      onPressed: _acceptCall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Helper to build Accept/Decline action buttons.
  Widget _actionButton({
    required IconData icon,
    required Color backgroundColor,
    required Color iconColor,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: label,
          backgroundColor: backgroundColor,
          elevation: 5.0,
          child: Icon(icon, color: iconColor, size: 32),
          onPressed: onPressed,
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
} // End of _CallPageState class

// --- Add required dependencies to pubspec.yaml ---
// dependencies:
//   flutter:
//     sdk: flutter
//   firebase_core: ^...
//   firebase_auth: ^...
//   cloud_firestore: ^...
//   flutter_webrtc: ^...    # Core WebRTC package
//   permission_handler: ^... # For Camera/Mic permissions
//   wakelock_plus: ^...      # Keep screen awake
//   connectivity_plus: ^... # Check network status
//   intl: ^...             # For call timer formatting
//   # Add other necessary dependencies (e.g., url_launcher if used)

// --- Platform Setup (IMPORTANT) ---
// * Android:
//   - Add permissions to AndroidManifest.xml: CAMERA, RECORD_AUDIO, MODIFY_AUDIO_SETTINGS, BLUETOOTH (optional but recommended)
//   - Ensure minSdkVersion is high enough for flutter_webrtc (check package docs).
// * iOS:
//   - Add keys to Info.plist: NSCameraUsageDescription, NSMicrophoneUsageDescription.
//   - Enable Background Modes: Voice over IP, Audio (if needed).

// --- Firestore Setup ---
// * Ensure 'calls' collection exists for signaling (documents contain callerId, calleeId, status, isVideoCall, offer, answer, timestamp).
// * Ensure 'calls/{callId}/candidates/{userId}/candidates' subcollection path is used for ICE candidates.
// * Ensure 'users' collection has 'fcmToken', 'displayName', 'name', 'imageUrl'.

// --- TURN Server (CRITICAL FOR REAL-WORLD USE) ---
// * The current configuration ONLY uses Google's STUN servers. This WILL NOT work reliably for many users behind certain firewalls/NATs.
// * You MUST set up and configure your own TURN server (e.g., using Coturn) or use a paid TURN service (like Twilio).
// * Replace the placeholder comments in the `_peerConfiguration` map with your actual TURN server URL(s), username, and credential.
