import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:thesis_web/main_screens/logs/transaction_logs.dart';
import 'package:thesis_web/main_screens/settings/restore_and_backup.dart';
import 'package:thesis_web/main_screens/settings/manage_users.dart';
import 'package:thesis_web/main_screens/profile/profile_admin.dart';
import 'package:thesis_web/main_screens/mapping/mapping_management.dart';
import 'package:thesis_web/main_screens/models/checkpoint_model.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_schedules_list.dart';
import 'package:thesis_web/main_screens/scheduling/assign_schedule.dart';
import 'package:thesis_web/main_screens/scheduling/weekly_schedule_screen.dart';
import 'package:thesis_web/main_screens/scheduling/monthly_schedule_screen.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_list.dart';
import 'package:thesis_web/main_screens/security_guard_management/add_security_guard.dart';
import 'package:thesis_web/main_screens/checkpoint_management/checkpoint_list.dart';
import 'package:thesis_web/main_screens/security_guard_management/guard_schedule_print.dart';
import 'package:thesis_web/main_screens/reports/guard_list_report.dart';
import 'package:thesis_web/main_screens/reports/checkpoint_list_report.dart';
import 'package:thesis_web/main_screens/reports/schedule_checkpoint_summary_report.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'package:thesis_web/services/guard_status_service.dart';

class _MissRateItem {
  final CheckpointModel cp;
  final double missRate; // 0.0 .. 1.0
  final int daysMissed;
  final int windowDays;

  _MissRateItem({
    required this.cp,
    required this.missRate,
    required this.daysMissed,
    required this.windowDays,
  });
}

// This model remains for potential use with DailyPatrolSummaries
class DailyCheckpointStats {
  final int scanned;
  final int totalExpected;
  final DateTime? lastUpdated;

  DailyCheckpointStats({
    required this.scanned,
    required this.totalExpected,
    this.lastUpdated,
  });

  factory DailyCheckpointStats.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) {
      return DailyCheckpointStats(scanned: 0, totalExpected: 0);
    }
    return DailyCheckpointStats(
      scanned: data['totalScannedCheckpoints'] as int? ?? 0,
      totalExpected: data['totalExpectedCheckpoints'] as int? ?? 0,
      lastUpdated: (data['lastUpdated'] as Timestamp?)?.toDate(),
    );
  }

  double get scannedPercentage => totalExpected > 0 ? (scanned / totalExpected) * 100 : 0;
  double get missedPercentage => totalExpected > 0 ? ((totalExpected - scanned) / totalExpected) * 100 : 0;
  int get missedCount => totalExpected > 0 ? totalExpected - scanned : 0;
  bool get hasData => totalExpected > 0 || scanned > 0;
}

// New simple model for direct chart data from 'Checkpoints' collection
class CheckpointChartData {
  final int scannedCount;
  final int notYetScannedCount;
  final int totalCheckpoints;

  CheckpointChartData({
    required this.scannedCount,
    required this.notYetScannedCount,
    required this.totalCheckpoints,
  });

  double get scannedPercentage => totalCheckpoints > 0 ? (scannedCount / totalCheckpoints) * 100 : 0;
  double get notYetScannedPercentage => totalCheckpoints > 0 ? (notYetScannedCount / totalCheckpoints) * 100 : 0;
  bool get hasData => totalCheckpoints > 0;
}

class MostMissedCheckpointInfo {
  final String name;
  final int daysSinceLastScan;
  final bool currentlyNotScanned;

  MostMissedCheckpointInfo({required this.name, required this.daysSinceLastScan, required this.currentlyNotScanned});
}

// New model for Scheduled Guard Information
class ScheduledGuardInfo {
  final String guardId;
  final String guardName; // This will hold the fetched name
  final String date; // yyyy-MM-dd
  final String startTime; // HH:mm
  final String endTime; // HH:mm
  final String? shiftTimeDisplay; // e.g., "08:00 - 17:00"

  ScheduledGuardInfo({
    required this.guardId,
    required this.guardName,
    required this.date,
    required this.startTime,
    required this.endTime,
    this.shiftTimeDisplay,
  });

  factory ScheduledGuardInfo.fromScheduleDoc(
      DocumentSnapshot<Map<String, dynamic>> scheduleDoc,
      String fetchedName,
      ) {
    final data = scheduleDoc.data();

    final String docGuardId = (data?['guard_id'] as String?) ?? 'UNKNOWN_GUARD_ID';
    final String docDate = (data?['date'] as String?) ?? 'UNKNOWN_DATE';
    final String docStartTime = (data?['start_time'] as String?) ?? 'N/A';
    final String docEndTime = (data?['end_time'] as String?) ?? 'N/A';

    return ScheduledGuardInfo(
      guardId: docGuardId,
      guardName: fetchedName,
      date: docDate,
      startTime: docStartTime,
      endTime: docEndTime,
      shiftTimeDisplay: (docStartTime != 'N/A' && docEndTime != 'N/A')
          ? '$docStartTime - $docEndTime'
          : 'Time N/A',
    );
  }
}


class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  StreamSubscription? _sosAlertsSubscription;
  String? _lastAlertId;
  
  // Custom marker icons for map
  BitmapDescriptor? _iconScanned;
  BitmapDescriptor? _iconNotScanned;
  Timer? _guardStatusTimer;

  @override
  void initState() {
    super.initState();
    _setupSosAlertsListener();
    _prepareMarkerIcons();
    // Trigger guard status sync now and every 5 minutes while dashboard is open
    GuardStatusService.updateStatusesNow();
    _guardStatusTimer?.cancel();
    _guardStatusTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      GuardStatusService.updateStatusesNow();
    });
  }

  @override
  void dispose() {
    _sosAlertsSubscription?.cancel();
    _guardStatusTimer?.cancel();
    super.dispose();
  }

  Future<void> _prepareMarkerIcons({int size = 38}) async {
    try {
      final scanned = await _createMarkerBitmap(color: Colors.green.shade700, size: size);
      final notScanned = await _createMarkerBitmap(color: Colors.red.shade700, size: size);
      if (!mounted) return;
      setState(() {
        _iconScanned = scanned;
        _iconNotScanned = notScanned;
      });
    } catch (_) {}
  }

  Future<BitmapDescriptor> _createMarkerBitmap({required Color color, int size = 38}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final double radius = size / 2.0;

    // Outer white border
    final borderPaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(radius, radius), radius, borderPaint);

    // Inner colored circle
    final fillPaint = Paint()..color = color;
    canvas.drawCircle(Offset(radius, radius), radius - 3, fillPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size, size);
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  void _setupSosAlertsListener() {
    _sosAlertsSubscription = _firestore
        .collection('AdminNotifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      print('AdminNotifications listener triggered: ${snapshot.docs.length} documents');
      
      if (snapshot.docs.isNotEmpty) {
        // Get the most recent alert
        final latestAlert = snapshot.docs.first;
        final alertId = latestAlert.id;
        final alertData = latestAlert.data();
        
        print('Latest alert ID: $alertId');
        print('Alert data: $alertData');
        
        // Check if this is a new alert (not on initial load)
        if (_lastAlertId != null && _lastAlertId != alertId) {
          print('Showing popup for new alert: $alertId');
          _showAlertPopup(alertData, alertId);
        } else if (_lastAlertId == null) {
          print('Initial load - setting lastAlertId to: $alertId');
        }
        _lastAlertId = alertId;
      } else {
        print('No documents in AdminNotifications collection');
      }
    }, onError: (error) {
      print('Error in AdminNotifications listener: $error');
    });
  }

  void _showAlertPopup(Map<String, dynamic> alertData, String alertId) {
    print('_showAlertPopup called with alertId: $alertId');
    print('Alert data received: $alertData');
    
    if (!mounted) {
      print('Widget not mounted, skipping popup');
      return;
    }
    
    final guardName = (alertData['senderName'] ?? alertData['senderFirstName'] ?? alertData['guardName'] ?? alertData['name'] ?? '').toString();
    final guardId = (alertData['senderGuardId'] ?? alertData['guard_id'] ?? alertData['guardId'] ?? '').toString();
    final message = (alertData['message'] ?? alertData['reason'] ?? 'SOS triggered').toString();
    final timestamp = alertData['createdAt'] ?? alertData['timestamp'] ?? alertData['time'];
    
    DateTime? alertTime;
    if (timestamp != null) {
      if (timestamp is Timestamp) {
        alertTime = timestamp.toDate();
      } else if (timestamp is DateTime) {
        alertTime = timestamp;
      } else if (timestamp is int) {
        alertTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      } else if (timestamp is String) {
        alertTime = DateTime.tryParse(timestamp);
      }
    }
    
    final timeString = alertTime != null ? DateFormat.yMd().add_jm().format(alertTime) : 'Unknown time';
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.sos, color: Colors.red.shade700, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('SOS Alert', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(timeString, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Guard: ${guardName.isNotEmpty ? guardName : (guardId.isNotEmpty ? 'Guard $guardId' : 'Unknown Guard')}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Message: $message',
                      style: const TextStyle(fontSize: 14),
                    ),
                    // Guard ID intentionally hidden per request
                    if (alertData['priority'] != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            'Priority: ',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: alertData['priority'] == 'high' ? Colors.red.shade100 : Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              alertData['priority'].toString().toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: alertData['priority'] == 'high' ? Colors.red.shade700 : Colors.orange.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _showSosAlertsSheet(context);
              },
              child: const Text('View All Alerts'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Dismiss'),
            ),
          ],
        );
      },
    );
  }


  Stream<int> _getTotalGuardsStream() {
    return _firestore
        .collection('Accounts')
        .where('role', isEqualTo: 'Security')
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  Stream<int> _getActiveGuardsStream() {
    return _firestore
        .collection('Accounts')
        .where('role', isEqualTo: 'Security')
        .where('status', isEqualTo: 'On Duty')
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  Stream<CheckpointChartData> _getCheckpointStatusCountsStream() {
    return _firestore.collection('Checkpoints').snapshots().map((snapshot) {
      int scannedCount = 0;
      int totalCheckpoints = snapshot.docs.length;

      for (var doc in snapshot.docs) {
        try {
          final checkpoint = CheckpointModel.fromFirestore(doc);
          print("DASHBOARD: Checkpoint ${checkpoint.id} (${checkpoint.name}) -> Status: ${checkpoint.status == CheckpointScanStatus.scanned ? 'SCANNED' : 'NOT_SCANNED'}");
          if (checkpoint.status == CheckpointScanStatus.scanned) {
            scannedCount++;
          }
        } catch (e) {
          print("Error parsing checkpoint ${doc.id}: $e");
          // Fallback to direct status check
          final data = doc.data();
          final statusString = data['status'] as String?;
          print("DASHBOARD FALLBACK: Checkpoint ${doc.id} -> Raw status: '$statusString'");
          if (statusString == 'Scanned' || statusString == 'scanned') {
            scannedCount++;
          }
        }
      }
      return CheckpointChartData(
        scannedCount: scannedCount,
        notYetScannedCount: totalCheckpoints - scannedCount,
        totalCheckpoints: totalCheckpoints,
      );
    }).handleError((error) {
      print("Error fetching checkpoint status counts: $error");
      return CheckpointChartData(scannedCount: 0, notYetScannedCount: 0, totalCheckpoints: 0);
    });
  }


  // Stream on-duty guards directly from Accounts, enrich with today's schedule (if any)
  Stream<List<ScheduledGuardInfo>> _getTodaysScheduledGuardsStream() {
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    return _firestore
        .collection('Accounts')
        .where('role', isEqualTo: 'Security')
        .where('status', isEqualTo: 'On Duty') // Assuming 'On Duty' is the correct status string
        .snapshots()
        .asyncMap((accountsSnap) async {
      final List<ScheduledGuardInfo> result = [];
      for (final accountDoc in accountsSnap.docs) {
        final data = accountDoc.data(); // No need to cast if rules ensure structure
        final String guardIdField = (data['guard_id'] as String?) ?? accountDoc.id; // Fallback to doc ID if guard_id field is missing
        final String firstName = data['first_name'] as String? ?? '';
        final String lastName = data['last_name'] as String? ?? '';
        final String guardName = ('$firstName $lastName').trim().isEmpty
            ? (data['name'] as String?) ?? 'Unnamed Guard' // Fallback to 'name' field
            : ('$firstName $lastName').trim();

        String startTime = 'N/A';
        String endTime = 'N/A';
        String? shiftDisplay;

        // Fetch schedule only if guardIdField (user-facing ID or doc ID) is available
        if (guardIdField.isNotEmpty) {
          try {
            final schedSnap = await _firestore
                .collection('Schedules')
                .where('guard_id', isEqualTo: guardIdField) // Query based on the ID used in Schedules
                .where('date', isEqualTo: todayStr)
                .orderBy('start_time') // Assuming you want the earliest shift if multiple
                .limit(1)
                .get();

            if (schedSnap.docs.isNotEmpty) {
              final schedData = schedSnap.docs.first.data();
              startTime = (schedData['start_time'] as String?) ?? 'N/A';
              endTime = (schedData['end_time'] as String?) ?? 'N/A';
              if (startTime != 'N/A' && endTime != 'N/A') {
                shiftDisplay = '$startTime - $endTime';
              }
            }
          } catch (e) {
            print("[ScheduleLookupForOnDuty] Error looking up schedule for guard $guardIdField: $e");
            // Optionally decide if you want to proceed without schedule info or handle error differently
          }
        }

        result.add(ScheduledGuardInfo(
          guardId: guardIdField, // This is the ID used for the schedule lookup
          guardName: guardName,
          date: todayStr, // All these are for "today" by definition of the stream's base query
          startTime: startTime,
          endTime: endTime,
          shiftTimeDisplay: shiftDisplay ?? (startTime != 'N/A' ? 'Time N/A' : 'No Shift Today'),
        ));
      }
      return result;
    }).handleError((error, stackTrace) {
      print('[OnDutyStream] Error: $error\n$stackTrace');
      return <ScheduledGuardInfo>[]; // Return empty list on error
    });
  }




  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text('Security Tour Patrol Dashboard'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.0),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
        ),
        actions: [
          // SOS Alert Button for Security Guards
          Container(
            margin: const EdgeInsets.only(right: 8),
            child: ElevatedButton.icon(
              onPressed: () => _showSosAlertDialog(context),
              icon: const Icon(Icons.emergency, color: Colors.white),
              label: const Text('SOS ALERT', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                elevation: 4,
                shadowColor: Colors.red.withOpacity(0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
          // View SOS Alerts Button
          IconButton(
            tooltip: 'View SOS Alerts',
            icon: const Icon(Icons.sos),
            onPressed: () => _showSosAlertsSheet(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: _buildNavList(context, closeDrawer: true),
      ),
      body: _buildDashboardScrollBody(colorScheme, screenWidth),
    );
  }

  // ---- SOS Alert Dialog for Security Guards ----
  void _showSosAlertDialog(BuildContext context) {
    final TextEditingController messageController = TextEditingController();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.emergency, color: Colors.red, size: 28),
              const SizedBox(width: 8),
              const Text('SOS Emergency Alert'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Send an emergency alert to all security personnel and administrators.',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: messageController,
                decoration: const InputDecoration(
                  labelText: 'Emergency Message',
                  hintText: 'Describe the emergency situation...',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.message),
                ),
                maxLines: 3,
                maxLength: 200,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                        'This alert will be sent to all security guards and administrators immediately.',
                        style: TextStyle(
                            fontSize: 12,
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.w500,
                          ),
                        ),
                    ),
                  ],
                      ),
                    ),
                ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (messageController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please enter an emergency message'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }
                
                Navigator.of(context).pop();
                await _sendSosAlert(messageController.text.trim());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('SEND SOS ALERT'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendSosAlert(String message) async {
    try {
      // Identify on-duty guards and admins
      final recipients = await _fetchOnDutyGuards();
      if (recipients.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: const Text('No on-duty guards or admins found.'), backgroundColor: Colors.orange.shade700),
          );
        }
        return;
      }

      final currentUser = FirebaseAuth.instance.currentUser;
      String? firstName;
      String? lastName;
      String? senderGuardId;
      String? senderEmail;
      String? senderUid = currentUser?.uid;
      try {
        if (currentUser != null) {
          // Prefer document by uid, fallback to query by uid field
          DocumentSnapshot<Map<String, dynamic>> accDoc = await _firestore.collection('Accounts').doc(currentUser.uid).get();
          Map<String, dynamic>? acc;
          if (!accDoc.exists) {
            final userDoc = await _firestore.collection('Accounts').where('uid', isEqualTo: currentUser.uid).limit(1).get();
            if (userDoc.docs.isNotEmpty) {
              acc = userDoc.docs.first.data();
            }
          } else {
            acc = accDoc.data();
          }
          firstName = acc?['first_name'] as String?;
          lastName = acc?['last_name'] as String?;
          senderGuardId = acc?['guard_id'] as String?;
          senderEmail = currentUser.email;
        }
      } catch (_) {}

      // Create an EmergencyAlerts doc
      final alertRef = await _firestore.collection('EmergencyAlerts').add({
        'type': 'sos',
        'createdAt': FieldValue.serverTimestamp(),
        'createdByUid': senderUid,
        'createdByEmail': senderEmail,
        'createdByFirstName': firstName,
        'createdByLastName': lastName,
        'createdByGuardId': senderGuardId,
        'message': message.trim(),
        'recipients': recipients.map((r) => r['guard_id']).whereType<String>().toList(),
        'status': 'active',
      });

      // Create per-recipient notifications in a batch
      final batch = _firestore.batch();
      for (final r in recipients) {
        final uid = r['uid'] as String?;
        if (uid == null) continue;
        // Skip notifying the sender
        if (senderUid != null && uid == senderUid) continue;

        final rGuardId = r['guard_id'] as String?;
        final rFirstName = r['first_name'];

        if (rGuardId != null && rGuardId.startsWith('ADMIN_')) {
          // Special Admin notification
          final adminNotifRef = _firestore.collection('AdminNotifications').doc();
          final String displayName = ((firstName ?? '').trim().isNotEmpty || (lastName ?? '').trim().isNotEmpty)
              ? '${firstName ?? ''} ${lastName ?? ''}'.trim()
              : (currentUser?.displayName ?? 'Unknown');
          batch.set(adminNotifRef, {
            'type': 'sos',
            'title': 'Emergency Alert',
            'message': message.trim().isNotEmpty
                ? 'SOS: ${message.trim()}'
                : 'Emergency SOS triggered. Please respond immediately.',
            'adminId': uid,
            'adminName': rFirstName,
            'adminNumber': r['admin_number'],
            'adminAddress': r['admin_address'],
            'alertId': alertRef.id,
            'createdAt': FieldValue.serverTimestamp(),
            'read': false,
            'priority': 'high',
            // Sender information
            'senderUid': senderUid,
            'senderEmail': null, // do not expose email
            'senderFirstName': firstName,
            'senderLastName': lastName,
            'senderGuardId': senderGuardId,
            'senderName': displayName,
          });
        } else {
          // Regular notification for non-Admin users
          final notifRef = _firestore.collection('Notifications').doc();
          final String displayName = ((firstName ?? '').trim().isNotEmpty || (lastName ?? '').trim().isNotEmpty)
              ? '${firstName ?? ''} ${lastName ?? ''}'.trim()
              : (currentUser?.displayName ?? 'Unknown');
          batch.set(notifRef, {
            'type': 'sos',
            'title': 'Emergency Alert',
            'message': message.trim().isNotEmpty
                ? 'SOS: ${message.trim()}'
                : 'Emergency SOS triggered. Please respond immediately.',
            'userId': uid,
            'guard_id': rGuardId,
            'alertId': alertRef.id,
            'createdAt': FieldValue.serverTimestamp(),
            'read': false,
            // Sender information
            'senderUid': senderUid,
            'senderEmail': null, // do not expose email
            'senderFirstName': firstName,
            'senderLastName': lastName,
            'senderGuardId': senderGuardId,
            'senderName': displayName,
          });
        }
      }
      await batch.commit();

      // Log to TransactionLogs
      try {
        await _firestore.collection('TransactionLogs').add({
          'type': 'sos',
          'action': 'SOS sent',
          'message': message.trim(),
          'userId': senderUid,
          'userEmail': senderEmail,
          'firstName': firstName,
          'lastName': lastName,
          'guard_id': senderGuardId,
          'recipients': recipients.map((r) => r['guard_id']).whereType<String>().toList(),
          'timestamp': FieldValue.serverTimestamp(),
          'status': 'success',
        });
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SOS sent to on-duty guards.'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      debugPrint('Dashboard: Error sending SOS: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sending SOS: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  // Fetch on-duty guards (Accounts.role == 'Security' and duty == true) and Admins (Accounts.role == 'Admin')
  Future<List<Map<String, dynamic>>> _fetchOnDutyGuards() async {
    try {
      // On-duty security guards
      final guardsSnap = await _firestore
          .collection('Accounts')
          .where('role', isEqualTo: 'Security')
          .where('status', isEqualTo: 'On Duty')
          .get();

      // Admin users
      final adminsSnap = await _firestore
          .collection('Accounts')
          .where('role', isEqualTo: 'Admin')
          .get();

      final List<Map<String, dynamic>> results = [];

      for (final d in guardsSnap.docs) {
        final data = d.data();
        results.add({
          'uid': data['uid'] ?? d.id,
          'guard_id': data['guard_id'],
          'first_name': data['first_name'] ?? data['name'],
        });
      }
      for (final d in adminsSnap.docs) {
        final data = d.data();
        results.add({
          'uid': data['uid'] ?? d.id,
          'guard_id': data['guard_id'] ?? 'ADMIN_${d.id}',
          'first_name': data['first_name'] ?? data['name'],
          'admin_number': data['admin_number'],
          'admin_address': data['admin_address'],
        });
      }

      return results;
    } catch (e) {
      debugPrint('Dashboard: Error fetching on-duty guards/admins: $e');
      return [];
    }
  }

  // ---- SOS Alerts ----
  void _showSosAlertsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        final height = MediaQuery.of(ctx).size.height * 0.7;
        return SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: const [
                    Icon(Icons.sos, color: Colors.red),
                    SizedBox(width: 8),
                    Text('SOS Alerts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _firestore
                      .collection('AdminNotifications')
                      .orderBy('createdAt', descending: true)
                      .limit(50)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text('Error loading SOS alerts: ${snapshot.error}', textAlign: TextAlign.center),
                      ));
                    }
                    final docs = snapshot.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return const Center(child: Text('No SOS alerts.'));
                    }

                    DateTime? parseTs(dynamic v) {
                      try {
                        if (v == null) return null;
                        if (v is Timestamp) return v.toDate();
                        if (v is DateTime) return v;
                        if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
                        if (v is String) return DateTime.tryParse(v);
                      } catch (_) {}
                      return null;
                    }

                    String fmt(DateTime? dt) => dt == null ? 'Unknown time' : DateFormat.yMd().add_jm().format(dt);

                    return ListView.separated(
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final d = docs[index].data();
                        final guardName = (d['senderName'] ?? d['senderFirstName'] ?? d['guardName'] ?? d['name'] ?? '').toString();
                        final message = (d['message'] ?? d['reason'] ?? 'SOS triggered').toString();
                        final when = parseTs(d['createdAt'] ?? d['timestamp'] ?? d['time']);
                        final lat = d['latitude'] ?? d['lat'];
                        final lng = d['longitude'] ?? d['lng'];
                        final hasLoc = lat != null && lng != null;
                        return ListTile(
                          leading: const CircleAvatar(backgroundColor: Color(0xFFFFEBEE), child: Icon(Icons.sos, color: Colors.red)),
                          title: Text(
                            guardName.isNotEmpty ? guardName : 'Unknown Guard',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(message),
                              const SizedBox(height: 2),
                              Text(fmt(when), style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                            ],
                          ),
                          trailing: hasLoc
                              ? IconButton(
                                  tooltip: 'Open on Map',
                                  icon: const Icon(Icons.map_outlined),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    Navigator.push(
                                      this.context,
                                      MaterialPageRoute(builder: (_) => const MappingManagementScreen()),
                                    );
                                  },
                                )
                              : null,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDashboardScrollBody(ColorScheme colorScheme, double screenWidth) {
    final double infoCardWidth = screenWidth > 1200 ? (screenWidth / 4.2 - 16) :
    screenWidth > 800 ? (screenWidth / 3.2 - 16) :
    screenWidth > 550 ? (screenWidth / 2.2 - 20) :
    (screenWidth - 32);

    final double infoCardHeight = screenWidth > 800 ? 140.0 : 120.0;

    return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Welcome Section
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24.0),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colorScheme.primary.withOpacity(0.1),
                    colorScheme.primary.withOpacity(0.05),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome to Security Dashboard',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Monitor your security operations and patrol activities',
                    style: TextStyle(
                      fontSize: 16,
                      color: colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
            
            // Stats Cards Section
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'Overview Statistics',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Wrap(
                      spacing: 16.0,
                      runSpacing: 16.0,
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                      SizedBox(
                        width: infoCardWidth,
                        height: infoCardHeight,
                        child: StreamBuilder<int>(
                          stream: _getTotalGuardsStream(),
                          builder: (context, snapshot) {
                            return _buildModernInfoCard(
                              title: 'Total Guards',
                              value: snapshot.hasData ? snapshot.data.toString() : '...',
                              icon: Icons.shield_outlined,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Colors.blue.shade400, Colors.blue.shade600],
                              ),
                              isLoading: snapshot.connectionState == ConnectionState.waiting,
                              hasError: snapshot.hasError,
                            );
                          },
                        ),
                      ),
                      SizedBox(
                        width: infoCardWidth,
                        height: infoCardHeight,
                        child: StreamBuilder<int>(
                          stream: _getActiveGuardsStream(),
                          builder: (context, snapshot) {
                            return _buildModernInfoCard(
                              title: 'On Duty',
                              value: snapshot.hasData ? snapshot.data.toString() : '...',
                              icon: Icons.security_outlined,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Colors.green.shade400, Colors.green.shade600],
                              ),
                              isLoading: snapshot.connectionState == ConnectionState.waiting,
                              hasError: snapshot.hasError,
                            );
                          },
                        ),
                      ),
                      SizedBox(
                        width: infoCardWidth,
                        height: infoCardHeight,
                        child: StreamBuilder<CheckpointChartData>(
                          stream: _getCheckpointStatusCountsStream(),
                          builder: (context, snapshot) {
                            final chartData = snapshot.data ?? CheckpointChartData(scannedCount: 0, notYetScannedCount: 0, totalCheckpoints: 0);
                            final isLoading = snapshot.connectionState == ConnectionState.waiting && !chartData.hasData;
                            final hasError = snapshot.hasError;
                            final display = () {
                              if (hasError) return 'Error';
                              if (isLoading) return '...';
                              if (!chartData.hasData) return '0%';
                              return '${chartData.scannedPercentage.toStringAsFixed(0)}%';
                            }();
                            return _buildModernInfoCard(
                              title: 'Scanned Checkpoints',
                              value: display,
                              icon: Icons.check_circle_outline,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Colors.green.shade500, Colors.green.shade700],
                              ),
                              isLoading: isLoading,
                              hasError: hasError,
                            );
                          },
                        ),
                      ),
                      SizedBox(
                        width: infoCardWidth,
                        height: infoCardHeight,
                        child: StreamBuilder<CheckpointChartData>(
                          stream: _getCheckpointStatusCountsStream(),
                          builder: (context, snapshot) {
                            final chartData = snapshot.data ?? CheckpointChartData(scannedCount: 0, notYetScannedCount: 0, totalCheckpoints: 0);
                            final isLoading = snapshot.connectionState == ConnectionState.waiting && !chartData.hasData;
                            final hasError = snapshot.hasError;
                            final display = () {
                              if (hasError) return 'Error';
                              if (isLoading) return '...';
                              if (!chartData.hasData) return '0%';
                              return '${chartData.notYetScannedPercentage.toStringAsFixed(0)}%';
                            }();
                            return _buildModernInfoCard(
                              title: 'Missed Checkpoints',
                              value: display,
                              icon: Icons.cancel_outlined,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Colors.red.shade400, Colors.red.shade600],
                              ),
                              isLoading: isLoading,
                              hasError: hasError,
                            );
                          },
                        ),
                      ),
                      SizedBox(
                        width: infoCardWidth,
                        height: infoCardHeight,
                        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _firestore.collection('Checkpoints').snapshots(),
                          builder: (context, cpSnap) {
                            final hasError = cpSnap.hasError;
                            final isLoading = cpSnap.connectionState == ConnectionState.waiting && !cpSnap.hasData;
                            if (hasError) {
                              return _buildModernInfoCard(
                                title: 'Frequently Missed',
                                value: 'Error',
                                icon: Icons.location_off_outlined,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Colors.orange.shade400, Colors.orange.shade600],
                                ),
                                isLoading: false,
                                hasError: true,
                              );
                            }
                            if (!cpSnap.hasData || cpSnap.data!.docs.isEmpty) {
                              return _buildModernInfoCard(
                                title: 'Frequently Missed',
                                value: isLoading ? '…' : 'No data',
                                icon: Icons.location_off_outlined,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Colors.orange.shade400, Colors.orange.shade600],
                                ),
                                isLoading: isLoading,
                                hasError: false,
                              );
                            }

                            final checkpoints = cpSnap.data!.docs.map((d) => CheckpointModel.fromFirestore(d)).toList();

                            return FutureBuilder<_MissRateItem?>(
                              future: () async {
                                final DateTime now = DateTime.now();
                                final int windowDays = 14;
                                final DateTime since = now.subtract(Duration(days: windowDays - 1));
                                final Timestamp sinceTs = Timestamp.fromDate(DateTime(since.year, since.month, since.day));

                                List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = [];
                                try {
                                  final q1 = await FirebaseFirestore.instance
                                      .collection('TransactionLogs')
                                      .where('timestamp', isGreaterThanOrEqualTo: sinceTs)
                                      .get();
                                  docs.addAll(q1.docs);
                                } catch (_) {}
                                try {
                                  final q2 = await FirebaseFirestore.instance
                                      .collection('TransactionLogs')
                                      .where('createdAt', isGreaterThanOrEqualTo: sinceTs)
                                      .get();
                                  docs.addAll(q2.docs);
                                } catch (_) {}

                                final Map<String, Set<String>> checkpointIdToDaysScanned = {};

                                String? _extractCheckpointId(Map<String, dynamic> data) {
                                  final dynamic a = data['checkpointId'] ?? data['checkpoint_id'] ?? data['checkpoint_id_str'];
                                  if (a == null) return null;
                                  return a.toString();
                                }
                                DateTime? _extractWhen(Map<String, dynamic> data) {
                                  final dynamic rawTs = data['timestamp'] ?? data['createdAt'] ?? data['created_at'];
                                  if (rawTs is Timestamp) return rawTs.toDate();
                                  if (rawTs is int) {
                                    if (rawTs > 20000000000) return DateTime.fromMillisecondsSinceEpoch(rawTs);
                                    return DateTime.fromMillisecondsSinceEpoch(rawTs * 1000);
                                  }
                                  if (rawTs is String) return DateTime.tryParse(rawTs);
                                  return null;
                                }
                                String _dayKey(DateTime dt) => '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

                                for (final d in docs) {
                                  final data = d.data();
                                  final cpId = _extractCheckpointId(data);
                                  if (cpId == null || cpId.isEmpty) continue;
                                  final when = _extractWhen(data);
                                  if (when == null) continue;
                                  final dayKey = _dayKey(DateTime(when.year, when.month, when.day));
                                  (checkpointIdToDaysScanned[cpId] ??= <String>{}).add(dayKey);
                                }

                                final Set<String> windowDaysSet = {
                                  for (int i = 0; i < windowDays; i++)
                                    _dayKey(DateTime(now.year, now.month, now.day).subtract(Duration(days: i)))
                                };

                                _MissRateItem? best;
                                for (final cp in checkpoints) {
                                  final daysScanned = checkpointIdToDaysScanned[cp.id] ?? <String>{};
                                  final int daysWithScan = daysScanned.intersection(windowDaysSet).length;
                                  final int daysMissed = windowDays - daysWithScan;
                                  final double missRate = windowDays > 0 ? daysMissed / windowDays : 0.0;
                                  final item = _MissRateItem(cp: cp, missRate: missRate, daysMissed: daysMissed, windowDays: windowDays);
                                  if (best == null || item.missRate > best.missRate) {
                                    if (item.missRate > 0) best = item;
                                  }
                                }
                                return best;
                              }(),
                              builder: (context, missSnap) {
                                final isInnerLoading = missSnap.connectionState == ConnectionState.waiting && !missSnap.hasData;
                                final hasInnerError = missSnap.hasError;
                                final best = missSnap.data;
                            final display = () {
                                  if (hasInnerError) return 'Error';
                                  if (isInnerLoading) return '…';
                                  if (best == null) return 'No data';
                                  final pct = (best.missRate * 100).toStringAsFixed(0);
                                  return '${best.cp.name}\nMiss rate: $pct%';
                            }();
                            return _buildModernInfoCard(
                              title: 'Frequently Missed',
                              value: display,
                              icon: Icons.location_off_outlined,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Colors.orange.shade400, Colors.orange.shade600],
                              ),
                                  isLoading: isInnerLoading,
                                  hasError: hasInnerError,
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 32),
            
            // Map Section
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: _buildModernMapPreview(),
            ),
            
            const SizedBox(height: 32),
            
            // Chart Section
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Checkpoint Status',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: StreamBuilder<CheckpointChartData>(
                          stream: _getCheckpointStatusCountsStream(),
                          builder: (context, snapshot) {
                            final chartData = snapshot.data ?? CheckpointChartData(scannedCount: 0, notYetScannedCount: 0, totalCheckpoints: 0);
                            bool isLoading = snapshot.connectionState == ConnectionState.waiting && !chartData.hasData;
                            bool isRefreshing = snapshot.connectionState == ConnectionState.waiting && chartData.hasData;

                            return _buildModernCheckpointChartCard(
                              title: 'Overall Checkpoint Status',
                              chartData: chartData,
                              isLoading: isLoading,
                              isRefreshing: isRefreshing,
                              hasError: snapshot.hasError,
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: _buildFrequentlyMissedBarChart(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 32),
            
            // Today's Security Guard Schedule Section
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Today\'s Security Guard Schedule',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildTodaysScheduleCard(),
                ],
              ),
            ),
            
            const SizedBox(height: 32),
          ],
        ),
      );
  }

  Widget _buildDrawerSubItem(BuildContext context, String title, Widget Function() screenBuilder, {IconData? icon, bool closeDrawer = true}) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: icon != null ? Icon(icon, size: 20, color: colorScheme.onSurfaceVariant) : const SizedBox(width: 24),
      title: Text(title, style: TextStyle(fontSize: 14.5, color: colorScheme.onSurface)),
      contentPadding: const EdgeInsets.only(left: 40.0, right: 16.0),
      dense: true,
      onTap: () {
        if (closeDrawer) {
          Navigator.pop(context);
        }
        Navigator.push(context, MaterialPageRoute(builder: (context) => screenBuilder()));
      },
    );
  }

  Widget _buildNavList(BuildContext context, {required bool closeDrawer}) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Container(
          height: 200,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.primary,
                colorScheme.primary.withOpacity(0.8),
              ],
            ),
          ),
          child: DrawerHeader(
            decoration: const BoxDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.white.withOpacity(0.2),
                  child: Icon(
                    Icons.security,
                    size: 30,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Security Dashboard',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Tour Patrol System',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Profile'),
          onTap: () {
            if (closeDrawer) Navigator.pop(context);
            Navigator.push(context, MaterialPageRoute(builder: (context) => const ProfileAdminScreen()));
          },
        ),
        ExpansionTile(
          leading: const Icon(Icons.schedule_outlined),
          title: const Text('Schedule Management'),
          children: [
            _buildDrawerSubItem(context, 'Daily Schedule', () => const AssignScheduleScreen(), icon: Icons.calendar_today, closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Weekly Schedule', () => const WeeklyScheduleScreen(), icon: Icons.calendar_view_week, closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Monthly Schedule', () => const MonthlyScheduleScreen(), icon: Icons.calendar_month, closeDrawer: closeDrawer),
          ],
        ),
        ExpansionTile(
          leading: const Icon(Icons.group_outlined),
          title: const Text('Security Guard Management'),
          children: [
            _buildDrawerSubItem(context, 'Security Guard List', () => SecurityGuardListScreen(), closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Security Guard Schedules List', () => const SecurityGuardSchedulesListScreen(), closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Add Security Guard', () => const AddSecurityGuardScreen(), closeDrawer: closeDrawer),
          ],
        ),
        ExpansionTile(
          leading: const Icon(Icons.list_alt_outlined),
          title: const Text('Report Management'),
          children: [
            _buildDrawerSubItem(context, 'Print Security Guard List', () => const GuardListReportScreen(), icon: Icons.people_outline, closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Print Checkpoint List', () => const CheckpointListReportScreen(), icon: Icons.location_on_outlined, closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Print Security Guard Schedules', () => const GuardSchedulePrintScreen(), icon: Icons.schedule_outlined, closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Print Report Schedule Checkpoint Summary', () => const ScheduleCheckpointSummaryReportScreen(), icon: Icons.summarize_outlined, closeDrawer: closeDrawer),
          ],
        ),
        ExpansionTile(
          leading: const Icon(Icons.map_outlined),
          title: const Text('Mapping Management'),
          children: [
            _buildDrawerSubItem(context, 'Open Map', () => const MappingManagementScreen(), closeDrawer: closeDrawer),
          ],
        ),
        ListTile(
          leading: const Icon(Icons.location_on_outlined),
          title: const Text('Checkpoint List'),
          onTap: () {
            if (closeDrawer) Navigator.pop(context);
            Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const CheckpointListScreen()));
          },
        ),
        ExpansionTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          children: [
            _buildDrawerSubItem(context, 'Manage Users', () => const ManageUsersPage(), icon: Icons.manage_accounts_outlined, closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Backup and Restore', () => const BackupRestorePage(), icon: Icons.backup_outlined, closeDrawer: closeDrawer),
            _buildDrawerSubItem(context, 'Transaction Logs', () => const TransactionLogsPage(), icon: Icons.list_alt_outlined, closeDrawer: closeDrawer),
          ],
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
          title: Text('Logout', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: () async {
            await FirebaseAuth.instance.signOut();
            if (!mounted) return;
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => const MappingManagementScreen()),
                  (route) => false,
            );
          },
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildInfoCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    bool isLoading = false,
    bool hasError = false,
  }) {
    return Card(
      elevation: 2.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: hasError ? Colors.red.shade700 : color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(icon, size: 24, color: hasError ? Colors.red.shade700 : color.withOpacity(0.9)),
              ],
            ),
            const Spacer(),
            if (isLoading)
              const Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.5)))
            else if (hasError)
              Center(child: Text('Error', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.red.shade700)))
            else
              Text(
                value,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.9) ?? Colors.black,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildModernInfoCard({
    required String title,
    required String value,
    required IconData icon,
    required Gradient gradient,
    bool isLoading = false,
    bool hasError = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: gradient.colors.first.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isLoading)
              const Center(
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              )
            else if (hasError)
              const Center(
                child: Text(
                  'Error',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              )
            else
              Container(
                width: double.infinity,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: value.contains('\n') ? 14 : 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: value.contains('\n') ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildCheckpointScanPieChartCard({
    required String title,
    required CheckpointChartData chartData,
    bool isLoading = false,
    bool isRefreshing = false,
    bool hasError = false,
  }) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final scannedColor = Colors.green.shade600;
    final notYetScannedColor = Colors.orange.shade700;
    const double defaultRadius = 50.0;
    const TextStyle defaultTitleStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white, shadows: [Shadow(color: Colors.black26, blurRadius: 2)]);

    Widget chartContent;

    if (isLoading) {
      chartContent = const Center(child: CircularProgressIndicator());
    } else if (hasError) {
      chartContent = Center(child: Text("Error loading chart data", style: TextStyle(color: Colors.red.shade700)));
    } else if (!chartData.hasData && !isRefreshing) {
      chartContent = Center(child: Text("No checkpoint data available.", style: TextStyle(color: Colors.grey.shade600, fontSize: 13)));
    } else {
      List<PieChartSectionData> sections = [];
      if (chartData.scannedCount > 0) {
        sections.add(PieChartSectionData(
          color: scannedColor,
          value: chartData.scannedCount.toDouble(),
          title: '${chartData.scannedPercentage.toStringAsFixed(0)}%',
          radius: defaultRadius,
          titleStyle: defaultTitleStyle,
          showTitle: true,
        ));
      }
      if (chartData.notYetScannedCount > 0) {
        sections.add(PieChartSectionData(
          color: notYetScannedColor,
          value: chartData.notYetScannedCount.toDouble(),
          title: '${chartData.notYetScannedPercentage.toStringAsFixed(0)}%',
          radius: defaultRadius,
          titleStyle: defaultTitleStyle,
          showTitle: true,
        ));
      }

      if (sections.isEmpty && chartData.totalCheckpoints > 0) {
        sections.add(PieChartSectionData(
          color: Colors.grey.shade400,
          value: chartData.totalCheckpoints.toDouble(),
          title: '100%',
          radius: defaultRadius,
          titleStyle: defaultTitleStyle,
          showTitle: true,
        ));
      } else if (sections.isEmpty) {
        chartContent = Center(child: Text("No data for chart", style: TextStyle(color: Colors.grey.shade500)));
        return Card(
          elevation: 2.5,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            padding: const EdgeInsets.all(16.0),
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: colorScheme.onSurface)),
                    if (isRefreshing) const SizedBox(height:18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(child: chartContent),
              ],
            ),
          ),
        );
      }

      chartContent = PieChart(
        PieChartData(
          borderData: FlBorderData(show: false),
          sectionsSpace: 2,
          centerSpaceRadius: 40,
          sections: sections,
          startDegreeOffset: -90,
        ),
        swapAnimationDuration: const Duration(milliseconds: 250),
        swapAnimationCurve: Curves.linear,
      );
    }

    return Card(
      elevation: 2.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(16.0),
        height: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: colorScheme.onSurface)),
                if (isRefreshing) const SizedBox(height:18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: chartContent),
            if (!isLoading && !hasError && chartData.hasData) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (chartData.scannedCount > 0) _buildLegendItem(scannedColor, "Scanned (${chartData.scannedCount})"),
                  if (chartData.scannedCount > 0 && chartData.notYetScannedCount > 0) const SizedBox(width: 20),
                  if (chartData.notYetScannedCount > 0) _buildLegendItem(notYetScannedColor, "Not Yet Scanned (${chartData.notYetScannedCount})"),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    "Total Checkpoints: ${chartData.totalCheckpoints}",
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildModernCheckpointChartCard({
    required String title,
    required CheckpointChartData chartData,
    bool isLoading = false,
    bool isRefreshing = false,
    bool hasError = false,
  }) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final scannedColor = Colors.green.shade500;
    final notYetScannedColor = Colors.orange.shade500;
    const double defaultRadius = 60.0;
    const TextStyle defaultTitleStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, shadows: [Shadow(color: Colors.black26, blurRadius: 2)]);

    Widget chartContent;

    if (isLoading) {
      chartContent = const Center(child: CircularProgressIndicator());
    } else if (hasError) {
      chartContent = Center(child: Text("Error loading chart data", style: TextStyle(color: Colors.red.shade700)));
    } else if (!chartData.hasData && !isRefreshing) {
      chartContent = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text("No checkpoint data available.", style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
          ],
        ),
      );
    } else {
      List<PieChartSectionData> sections = [];
      if (chartData.scannedCount > 0) {
        sections.add(PieChartSectionData(
          color: scannedColor,
          value: chartData.scannedCount.toDouble(),
          title: '${chartData.scannedPercentage.toStringAsFixed(0)}%',
          radius: defaultRadius,
          titleStyle: defaultTitleStyle,
          showTitle: true,
        ));
      }
      if (chartData.notYetScannedCount > 0) {
        sections.add(PieChartSectionData(
          color: notYetScannedColor,
          value: chartData.notYetScannedCount.toDouble(),
          title: '${chartData.notYetScannedPercentage.toStringAsFixed(0)}%',
          radius: defaultRadius,
          titleStyle: defaultTitleStyle,
          showTitle: true,
        ));
      }

      if (sections.isEmpty && chartData.totalCheckpoints > 0) {
        sections.add(PieChartSectionData(
          color: Colors.grey.shade400,
          value: chartData.totalCheckpoints.toDouble(),
          title: '100%',
          radius: defaultRadius,
          titleStyle: defaultTitleStyle,
          showTitle: true,
        ));
      } else if (sections.isEmpty) {
        chartContent = Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.pie_chart_outline, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text("No data for chart", style: TextStyle(color: Colors.grey.shade500)),
            ],
          ),
        );
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.all(24.0),
          height: 350,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                  ),
                  if (isRefreshing) const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                ],
              ),
              const SizedBox(height: 16),
              Expanded(child: chartContent),
            ],
          ),
        );
      }

      chartContent = PieChart(
        PieChartData(
          borderData: FlBorderData(show: false),
          sectionsSpace: 3,
          centerSpaceRadius: 50,
          sections: sections,
          startDegreeOffset: -90,
        ),
        swapAnimationDuration: const Duration(milliseconds: 300),
        swapAnimationCurve: Curves.easeInOut,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24.0),
      height: 350,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
              ),
              if (isRefreshing) const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: chartContent),
          if (!isLoading && !hasError && chartData.hasData) ...[
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (chartData.scannedCount > 0) _buildModernLegendItem(scannedColor, "Scanned", chartData.scannedCount),
                if (chartData.scannedCount > 0 && chartData.notYetScannedCount > 0) Container(width: 1, height: 30, color: Colors.grey.shade300),
                if (chartData.notYetScannedCount > 0) _buildModernLegendItem(notYetScannedColor, "Not Scanned", chartData.notYetScannedCount),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "Total: ${chartData.totalCheckpoints} Checkpoints",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            ),
          ]
        ],
      ),
    );
  }

  Widget _buildLegendItem(Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.rectangle, borderRadius: BorderRadius.circular(2.5))),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildModernLegendItem(Color color, String text, int count) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.3),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          text,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildMapPreview() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 2.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.6,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Live Map',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const MappingManagementScreen()),
                    );
                  },
                  icon: const Icon(Icons.open_in_full, size: 16),
                  label: const Text('Open Full Map'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: StreamBuilder<List<CheckpointModel>>(
                stream: FirebaseFirestore.instance
                    .collection('Checkpoints')
                    .snapshots()
                    .map((snap) {
                      final List<CheckpointModel> models = [];
                      for (final d in snap.docs) {
                        try {
                          final m = CheckpointModel.fromFirestore(d);
                          models.add(m);
                        } catch (e) {
                          // Skip malformed documents to avoid breaking the UI
                          debugPrint('Skipping malformed checkpoint ${d.id}: $e');
                        }
                      }
                      return models;
                    }),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        'Error loading map',
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    );
                  }

                  final checkpoints = snapshot.data ?? [];
                  final withGps = checkpoints.where((c) {
                    final lat = c.latitude;
                    final lng = c.longitude;
                    if (lat == null || lng == null) return false;
                    if (lat.isNaN || lng.isNaN) return false;
                    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
                  }).toList();

                  if (withGps.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.map_outlined, size: 48, color: colorScheme.onSurfaceVariant),
                          const SizedBox(height: 8),
                          Text(
                            'No checkpoints with GPS locations',
                            style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    );
                  }

                  final initialTarget = LatLng(withGps.first.latitude!, withGps.first.longitude!);
                  final markers = withGps.map((cp) {
                    final isScanned = cp.status == CheckpointScanStatus.scanned;
                    final hue = isScanned ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed;
                    final statusText = isScanned ? 'Scanned' : 'Not Scanned';
                    return Marker(
                      markerId: MarkerId(cp.id),
                      position: LatLng(cp.latitude!, cp.longitude!),
                      icon: BitmapDescriptor.defaultMarkerWithHue(hue),
                      infoWindow: InfoWindow(
                        title: cp.name,
                        snippet: statusText,
                      ),
                    );
                  }).toSet();

                  return GoogleMap(
                    initialCameraPosition: CameraPosition(target: initialTarget, zoom: 16),
                    markers: markers,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: true,
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildMapLegendItem(Colors.green, 'Scanned'),
                const SizedBox(width: 16),
                _buildMapLegendItem(Colors.red, 'Not Scanned'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapLegendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  // CORRECTED VERSION OF THIS METHOD IS NOW INCLUDED
  // ignore: unused_element
  Widget _buildScheduledGuardsSection() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 0, bottom: 12.0),
          child: Text(
            "Today's On-Duty Guards", // Changed title for clarity with the new stream logic
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface),
          ),
        ),
        StreamBuilder<List<ScheduledGuardInfo>>(
          stream: _getTodaysScheduledGuardsStream(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 30.0),
                    child: CircularProgressIndicator(),
                  ));
            }
            if (snapshot.hasError) {
              print(
                  "Error in StreamBuilder for _getTodaysScheduledGuardsStream: ${snapshot.error}");
              return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Text('Error loading on-duty guards.', // Adjusted message
                        style: TextStyle(color: Colors.red.shade700)),
                  ));
            }
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return Card(
                elevation: 1.5,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Container(
                  width: double.infinity,
                  padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: Center(
                      child: Text(
                        'No guards currently on duty or scheduled for today.', // Adjusted message
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 15,
                            color: colorScheme.onSurfaceVariant.withOpacity(0.8)),
                      )),
                ),
              );
            }

            final scheduledGuards = snapshot.data!;

            return Card(
              elevation: 2.0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTableTheme(
                      data: DataTableThemeData(
                        headingRowColor: MaterialStateProperty.all(colorScheme.surfaceVariant.withOpacity(0.6)),
                        headingTextStyle: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                        dataRowColor: MaterialStateProperty.all(Colors.transparent),
                        dividerThickness: 0.6,
                      ),
                    child: DataTable(
                        headingRowHeight: 42,
                        columnSpacing: 24,
                        dataRowMinHeight: 54,
                        dataRowMaxHeight: 64,
                      columns: const [
                          DataColumn(label: Row(children: [Icon(Icons.badge_outlined, size: 16), SizedBox(width: 6), Text('Guard')])),
                          DataColumn(label: Row(children: [Icon(Icons.schedule_outlined, size: 16), SizedBox(width: 6), Text('Shift Today')])),
                          DataColumn(label: Row(children: [Icon(Icons.tag_outlined, size: 16), SizedBox(width: 6), Text('Guard ID')])),
                        ],
                        rows: [
                          for (int i = 0; i < scheduledGuards.length; i++)
                            (() {
                              final g = scheduledGuards[i];
                        final guardName = (g.guardName.isEmpty) ? 'Unnamed Guard' : g.guardName;
                              final initials = guardName.trim().isNotEmpty
                                  ? guardName.trim().split(RegExp(r'\s+')).map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase()
                                  : '?';
                        final shift = g.shiftTimeDisplay ?? 'No Shift Info';
                              final hasShift = shift.toLowerCase() != 'no shift info' && shift.toLowerCase() != 'no shift today';
                              return DataRow(
                                color: MaterialStateProperty.all(i % 2 == 0 ? colorScheme.surfaceVariant.withOpacity(0.2) : Colors.transparent),
                                cells: [
                          DataCell(Row(
                            children: [
                                      CircleAvatar(
                                        radius: 14,
                                        backgroundColor: colorScheme.primary.withOpacity(0.15),
                                        child: Text(initials, style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 12)),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(guardName, style: const TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          )),
                                  DataCell(Align(
                                    alignment: Alignment.centerLeft,
                                    child: Chip(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                      backgroundColor: hasShift ? Colors.green.withOpacity(0.12) : Colors.orange.withOpacity(0.12),
                                      label: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.access_time, size: 14, color: hasShift ? Colors.green.shade700 : Colors.orange.shade700),
                                          const SizedBox(width: 6),
                                          Text(
                                            shift,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: hasShift ? Colors.green.shade800 : Colors.orange.shade800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )),
                                  DataCell(SelectableText(
                                    g.guardId,
                                    style: const TextStyle(fontFamily: 'monospace', letterSpacing: 0.3),
                                  )),
                                ],
                              );
                            })(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildModernScheduledGuardsSection() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Today's On-Duty Guards",
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        StreamBuilder<List<ScheduledGuardInfo>>(
          stream: _getTodaysScheduledGuardsStream(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Container(
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
                      const SizedBox(height: 8),
                      Text('Error loading guards data', style: TextStyle(color: Colors.red.shade700)),
                    ],
                  ),
                ),
              );
            }
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return Container(
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.people_outline, size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 8),
                      Text('No guards currently on duty', style: TextStyle(fontSize: 16, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
              );
            }

            final scheduledGuards = snapshot.data!;
            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.people, color: colorScheme.primary, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text('${scheduledGuards.length} Guards On Duty', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
                      ],
                    ),
                  ),
                  ...scheduledGuards.map((guard) => _buildModernGuardCard(guard)).toList(),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildModernGuardCard(ScheduledGuardInfo guard) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final guardName = guard.guardName.isEmpty ? 'Unnamed Guard' : guard.guardName;
    final initials = guardName.trim().isNotEmpty
        ? guardName.trim().split(RegExp(r'\s+')).map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase()
        : '?';
    final shift = guard.shiftTimeDisplay ?? 'No Shift Info';
    final hasShift = shift.toLowerCase() != 'no shift info' && shift.toLowerCase() != 'no shift today';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: colorScheme.primary.withOpacity(0.1),
            child: Text(
              initials,
              style: TextStyle(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  guardName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ID: ${guard.guardId}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: hasShift ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.access_time,
                  size: 14,
                  color: hasShift ? Colors.green.shade700 : Colors.orange.shade700,
                ),
                const SizedBox(width: 4),
                Text(
                  shift,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: hasShift ? Colors.green.shade800 : Colors.orange.shade800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModernMapPreview() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Live Map View',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.map, color: colorScheme.primary, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text('Checkpoint Locations', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
                      ],
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const MappingManagementScreen()),
                        );
                      },
                      icon: const Icon(Icons.open_in_full, size: 16),
                      label: const Text('Open Full Map'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 300,
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _buildMapWidget(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildModernMapLegendItem(Colors.green, 'Scanned'),
                    const SizedBox(width: 24),
                    _buildModernMapLegendItem(Colors.red, 'Not Scanned'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModernMapLegendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.3),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildMapWidget() {
    return StreamBuilder<List<CheckpointModel>>(
                    stream: FirebaseFirestore.instance
                        .collection('Checkpoints')
                        .snapshots()
                        .map((snap) {
                          final List<CheckpointModel> models = [];
                          for (final d in snap.docs) {
                            try {
                              final m = CheckpointModel.fromFirestore(d);
                              models.add(m);
                            } catch (e) {
                              debugPrint('Skipping malformed checkpoint ${d.id}: $e');
                            }
                          }
                          return models;
                        }),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
                              const SizedBox(height: 8),
                              Text('Error loading map', style: TextStyle(color: Colors.red.shade700)),
                            ],
                          ),
                        );
                      }

                      final checkpoints = snapshot.data ?? [];
                      final withGps = checkpoints.where((c) {
                        final lat = c.latitude;
                        final lng = c.longitude;
                        if (lat == null || lng == null) return false;
                        if (lat.isNaN || lng.isNaN) return false;
                        return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
                      }).toList();

                      if (withGps.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.map_outlined, size: 48, color: Colors.grey.shade400),
                              const SizedBox(height: 8),
                              Text('No checkpoints with GPS locations', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
                            ],
                          ),
                        );
                      }

                      final initialTarget = LatLng(withGps.first.latitude!, withGps.first.longitude!);
                      final markers = withGps.map((cp) {
          final BitmapDescriptor icon;
          if (_iconScanned != null && _iconNotScanned != null) {
            icon = cp.status == CheckpointScanStatus.scanned ? _iconScanned! : _iconNotScanned!;
          } else {
            final hue = cp.status == CheckpointScanStatus.scanned ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed;
            icon = BitmapDescriptor.defaultMarkerWithHue(hue);
          }
                        return Marker(
                          markerId: MarkerId(cp.id),
                          position: LatLng(cp.latitude!, cp.longitude!),
            icon: icon,
                          infoWindow: InfoWindow(
              title: cp.name,
              snippet: checkpointScanStatusToString(cp.status),
                          ),
                        );
                      }).toSet();

                      return GoogleMap(
                        initialCameraPosition: CameraPosition(target: initialTarget, zoom: 16),
                        markers: markers,
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: true,
                      );
                    },
    );
  }

  Widget _buildFrequentlyMissedBarChart() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16.0),
      height: 350,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Frequently Missed Checkpoints', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colorScheme.onSurface)),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<List<CheckpointModel>>(
              stream: FirebaseFirestore.instance
                  .collection('Checkpoints')
                  .snapshots()
                  .map((snap) {
                    final List<CheckpointModel> models = [];
                    for (final d in snap.docs) {
                      try {
                        final m = CheckpointModel.fromFirestore(d);
                        models.add(m);
                      } catch (e) {
                        debugPrint('Skipping malformed checkpoint ${d.id}: $e');
                      }
                    }
                    return models;
                  }),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error loading checkpoints', style: TextStyle(color: colorScheme.error)));
                }
                final checkpoints = snapshot.data ?? [];
                if (checkpoints.isEmpty) {
                  return Center(
                    child: Text('No checkpoints found', style: TextStyle(color: colorScheme.onSurfaceVariant)),
                  );
                }

                // Compute historical miss rate over last 14 days using TransactionLogs
                return FutureBuilder<List<_MissRateItem>>(
                  future: () async {
                    final DateTime now = DateTime.now();
                    final int windowDays = 14;
                    final DateTime since = now.subtract(Duration(days: windowDays - 1));
                    final Timestamp sinceTs = Timestamp.fromDate(DateTime(since.year, since.month, since.day));

                    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = [];
                    try {
                      final q1 = await FirebaseFirestore.instance
                          .collection('TransactionLogs')
                          .where('timestamp', isGreaterThanOrEqualTo: sinceTs)
                          .get();
                      docs.addAll(q1.docs);
                    } catch (_) {}

                    try {
                      final q2 = await FirebaseFirestore.instance
                          .collection('TransactionLogs')
                          .where('createdAt', isGreaterThanOrEqualTo: sinceTs)
                          .get();
                      docs.addAll(q2.docs);
                    } catch (_) {}

                    // Aggregate scan presence by day per checkpoint
                    final Map<String, Set<String>> checkpointIdToDaysScanned = {};

                    String? _extractCheckpointId(Map<String, dynamic> data) {
                      final dynamic a = data['checkpointId'] ?? data['checkpoint_id'] ?? data['checkpoint_id_str'];
                      if (a == null) return null;
                      return a.toString();
                    }

                    DateTime? _extractWhen(Map<String, dynamic> data) {
                      final dynamic rawTs = data['timestamp'] ?? data['createdAt'] ?? data['created_at'];
                      if (rawTs is Timestamp) return rawTs.toDate();
                      if (rawTs is int) {
                        if (rawTs > 20000000000) return DateTime.fromMillisecondsSinceEpoch(rawTs);
                        return DateTime.fromMillisecondsSinceEpoch(rawTs * 1000);
                      }
                      if (rawTs is String) {
                        return DateTime.tryParse(rawTs);
                      }
                      return null;
                    }

                    String _dayKey(DateTime dt) => '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

                    for (final d in docs) {
                      final data = d.data();
                      final cpId = _extractCheckpointId(data);
                      if (cpId == null || cpId.isEmpty) continue;
                      final when = _extractWhen(data);
                      if (when == null) continue;
                      final dayKey = _dayKey(DateTime(when.year, when.month, when.day));
                      (checkpointIdToDaysScanned[cpId] ??= <String>{}).add(dayKey);
                    }

                    final Set<String> windowDaysSet = {
                      for (int i = 0; i < windowDays; i++)
                        _dayKey(DateTime(now.year, now.month, now.day).subtract(Duration(days: i)))
                    };

                    final List<_MissRateItem> items = [];
                    for (final cp in checkpoints) {
                      final daysScanned = checkpointIdToDaysScanned[cp.id] ?? <String>{};
                      final int daysWithScan = daysScanned.intersection(windowDaysSet).length;
                      final int daysMissed = windowDays - daysWithScan;
                      final double missRate = windowDays > 0 ? daysMissed / windowDays : 0.0;
                      items.add(_MissRateItem(cp: cp, missRate: missRate, daysMissed: daysMissed, windowDays: windowDays));
                    }

                    items.sort((a, b) => b.missRate.compareTo(a.missRate));
                    // Keep only those with missRate > 0, top 5
                    final result = items.where((e) => e.missRate > 0).take(5).toList();
                    return result;
                  }(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return Center(child: Text('Error computing miss rates', style: TextStyle(color: colorScheme.error)));
                    }
                    final items = snap.data ?? const <_MissRateItem>[];
                    if (items.isEmpty) {
                  return Center(
                    child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                        Icon(Icons.check_circle, size: 48, color: Colors.green.shade400),
                        const SizedBox(height: 8),
                            Text('No frequently missed checkpoints.', style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  );
                }

                    return ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 12),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final displayName = item.cp.name.isNotEmpty ? item.cp.name : 'Unnamed Checkpoint';
                        final String ratePct = (item.missRate * 100).toStringAsFixed(0);
                        return Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.trending_down, color: Colors.red.shade400, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    displayName,
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Miss rate: $ratePct% (${item.daysMissed}/${item.windowDays} days)',
                                    style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                '$ratePct%',
                                style: TextStyle(color: Colors.red.shade600, fontWeight: FontWeight.w600, fontSize: 12),
                            ),
                          ),
                        ],
                      );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

 

  Widget _buildTodaysScheduleCard() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16.0),
      height: 350,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Today\'s Security Guard Schedule', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colorScheme.onSurface)),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<List<ScheduledGuardInfo>>(
              stream: _getTodaysScheduledGuardsStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error loading schedule', style: TextStyle(color: colorScheme.error)));
                }
                final guards = snapshot.data ?? [];
                if (guards.isEmpty) {
                  return Center(
                    child: Text('No guards currently on duty', style: TextStyle(color: colorScheme.onSurfaceVariant)),
                  );
                }
                return ListView.separated(
                  itemCount: guards.length,
                  separatorBuilder: (_, __) => const Divider(height: 12),
                  itemBuilder: (context, index) {
                    final g = guards[index];
                    final guardName = g.guardName.isEmpty ? 'Unnamed Guard' : g.guardName;
                    final shift = g.shiftTimeDisplay ?? 'No Shift Info';
                    final hasShift = shift.toLowerCase() != 'no shift info' && shift.toLowerCase() != 'no shift today';
                    return Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: colorScheme.primary.withOpacity(0.1),
                          child: Text(
                            guardName.trim().isNotEmpty ? guardName.trim().split(RegExp(r'\s+')).map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase() : '?',
                            style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(guardName, style: const TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text('ID: ${g.guardId}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                        Chip(
                          backgroundColor: hasShift ? Colors.green.withOpacity(0.12) : Colors.orange.withOpacity(0.12),
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.access_time, size: 14, color: hasShift ? Colors.green.shade700 : Colors.orange.shade700),
                              const SizedBox(width: 6),
                              Text(shift, style: TextStyle(fontWeight: FontWeight.w600, color: hasShift ? Colors.green.shade800 : Colors.orange.shade800)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

