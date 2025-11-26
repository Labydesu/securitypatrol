import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models/checkpoint_model.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'package:thesis_web/utils/guard_name_utils.dart';

String _formatCheckpointStatus(CheckpointScanStatus status) {
  final raw = checkpointScanStatusToString(status);
  switch (raw.toLowerCase()) {
    case 'scanned':
      return 'Inspected';
    case 'not yet scanned':
      return 'Not Yet Inspected';
    default:
      return raw;
  }
}

class SecurityGuardOverviewScreen extends StatefulWidget {
  final Map<String, dynamic> guardData;

  const SecurityGuardOverviewScreen({
    super.key,
    required this.guardData,
  });

  @override
  State<SecurityGuardOverviewScreen> createState() =>
      _SecurityGuardOverviewScreenState();
}

class _SecurityGuardOverviewScreenState
    extends State<SecurityGuardOverviewScreen> {
  String dutyDate = 'No assignment today';
  String dutyShiftTimes = '-';
  String calculatedShiftDuration = '-';
  late String status;
  bool _isLoadingSchedule = true;
  List<String> assignedCheckpointNames = [];
  List<CheckpointModel> assignedCheckpoints = [];

  @override
  void initState() {
    super.initState();
    // It's good practice to ensure widget.guardData itself isn't null if there's any chance
    // it could be, though the `required` keyword makes this less likely for guardData itself.
    // However, fields within guardData can still be null.
    print("Overview initState: Widget received guardData: ${widget.guardData}");

    status = widget.guardData['status'] as String? ?? 'Off Duty';
    print("Overview initState: Initial status from guardData: $status");
    print("Overview initState: Guard Data Received (full map): ${widget.guardData}");

    // Check if guardData contains a user-facing 'guard_id'. This is crucial for schedule matching.
    if (widget.guardData['guard_id'] == null) {
      print("Overview initState ERROR: guardData does NOT contain a 'guard_id' field. Cannot load schedule.");
      // Update state to reflect this error, so UI shows something meaningful.
      // We can't call _loadScheduleStatus if guard ID is missing.
      setState(() {
        dutyDate = 'Error: Guard ID missing in initial data';
        status = 'Unknown';
        _isLoadingSchedule = false;
      });
    } else {
      print("Overview initState: Guard ID seems present. Calling _loadScheduleStatus.");
      _loadScheduleStatus();
    }
  }

  Future<void> _loadScheduleStatus() async {
    print("Overview: _loadScheduleStatus CALLED");
    if (!mounted) {
      print("Overview: _loadScheduleStatus exiting because widget is no longer mounted (called early).");
      return;
    }

    // Initial reset of state for loading, status is kept from initState or previous load
    setState(() {
      _isLoadingSchedule = true;
      dutyDate = 'Loading schedule...'; // Give user feedback
      dutyShiftTimes = '-';
      calculatedShiftDuration = '-';
      // status = widget.guardData['status'] as String? ?? 'Off Duty'; // Status is already initialized
      print("Overview: _loadScheduleStatus - setState called for loading start. Current status: $status");
    });

    // Explicitly check for 'guard_id' key and its type (user-facing ID used in Schedules).
    final dynamic guardIdDynamic = widget.guardData['guard_id'];
    String? guardUserFacingId;

    if (guardIdDynamic is String) {
      guardUserFacingId = guardIdDynamic;
    } else if (guardIdDynamic != null) {
      print("Overview WARNING: guardData['guard_id'] is not a String. It's a ${guardIdDynamic.runtimeType}. Value: $guardIdDynamic");
      print("Overview ERROR: Guard user-facing ID from guardData is not a String. Cannot query schedule.");
      if (mounted) {
        setState(() {
          dutyDate = 'Error: Invalid Guard ID type';
          _isLoadingSchedule = false;
          status = 'Unknown';
        });
      }
      return;
    }

    print("Overview: Extracted guardUserFacingId for query: $guardUserFacingId");

    if (guardUserFacingId == null || guardUserFacingId.isEmpty) {
      print("Overview ERROR: Guard user-facing ID is null or empty. Passed guardData: ${widget.guardData}");
      if (mounted) {
        setState(() {
          dutyDate = 'Error: Missing or empty Guard ID';
          _isLoadingSchedule = false;
          status = 'Unknown';
        });
      }
      return;
    }

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    print("Overview: Today's date for query (todayStr): $todayStr");

    try {
      print("Overview: Querying Schedules for guard_id: $guardUserFacingId AND date: $todayStr");
      final schedulesSnapshot = await FirebaseFirestore.instance
          .collection('Schedules')
          .where('guard_id', isEqualTo: guardUserFacingId)
          .where('date', isEqualTo: todayStr)
          .orderBy('start_time') // Assuming you want the earliest shift if multiple
          .limit(1)
          .get();

      if (!mounted) {
        print("Overview: _loadScheduleStatus exiting because widget is no longer mounted (after query).");
        return;
      }
      print("Overview: Firestore query completed. Found ${schedulesSnapshot.docs.length} schedule documents.");

      if (schedulesSnapshot.docs.isNotEmpty) {
        final doc = schedulesSnapshot.docs.first;
        print("Overview: Processing schedule document ID: ${doc.id}, Data: ${doc.data()}");
        final data = doc.data(); // This is Map<String, dynamic>

        // Defensive casting with checks
        final dateStrFromDb = data['date'] as String?;
        final start = data['start_time'] as String?;
        final end = data['end_time'] as String?;

        print("Overview: Extracted from DB - dateStr: $dateStrFromDb, start_time: $start, end_time: $end");

        String tempDutyDate = 'Error processing date';
        String tempDutyShiftTimes = '-';
        String tempCalculatedShiftDuration = '-';
        // Let's re-evaluate status based on schedule, not just keep initial
        String tempStatus = 'Off Duty'; // Default to Off Duty if schedule found but not current

        // Resolve assigned checkpoints if any
        List<String> cpNamesResolved = [];
        List<CheckpointModel> cpModelsResolved = [];
        try {
          final cpIdsDyn = data['checkpoints'] as List<dynamic>?;
          if (cpIdsDyn != null && cpIdsDyn.isNotEmpty) {
            final ids = cpIdsDyn.map((e) => e.toString()).toList();
            final futures = ids.map((id) => FirebaseFirestore.instance.collection('Checkpoints').doc(id).get());
            final snaps = await Future.wait(futures);
            cpNamesResolved = snaps.map((s) {
              final m = s.data();
              return m != null ? (m['name']?.toString() ?? s.id) : s.id;
            }).toList();
            
            // Also create CheckpointModel objects for detailed display
            cpModelsResolved = snaps.map((s) {
              if (s.exists && s.data() != null) {
                return CheckpointModel.fromFirestore(s);
              }
              return null;
            }).where((cp) => cp != null).cast<CheckpointModel>().toList();
          }
        } catch (e) {
          print('Overview: Error resolving checkpoint names: ' + e.toString());
        }

        if (dateStrFromDb != null && start != null && end != null) {
          print("Overview: Date, start, and end times are NOT NULL. Proceeding with parsing.");
          try {
            try {
              final parsedDate = DateFormat('yyyy-MM-dd').parse(dateStrFromDb);
              tempDutyDate = DateFormat.yMMMMd().format(parsedDate); // e.g., "October 28, 2023"
              print("Overview: Parsed and formatted date: $tempDutyDate");
            } catch (e) {
              tempDutyDate = dateStrFromDb; // Fallback to raw string if parsing fails
              print("Overview WARNING: Could not parse date from DB '$dateStrFromDb': $e. Using raw string.");
            }

            tempDutyShiftTimes = '$start - $end';
            print("Overview: Set tempDutyShiftTimes: $tempDutyShiftTimes");

            final startParts = start.split(':').map((p) => int.tryParse(p)).toList();
            final endParts = end.split(':').map((p) => int.tryParse(p)).toList();
            print("Overview: Parsed time parts - startParts: $startParts, endParts: $endParts");

            if (startParts.length == 2 && endParts.length == 2 &&
                startParts.every((p) => p != null) && endParts.every((p) => p != null)) {
              final startTime = TimeOfDay(hour: startParts[0]!, minute: startParts[1]!);
              final endTime = TimeOfDay(hour: endParts[0]!, minute: endParts[1]!);

              // Calculate duration
              int durationMinutes = (endTime.hour * 60 + endTime.minute) - (startTime.hour * 60 + startTime.minute);
              if (durationMinutes < 0) { // Handles overnight shifts
                durationMinutes += 24 * 60;
              }
              tempCalculatedShiftDuration = '${durationMinutes ~/ 60}h ${durationMinutes % 60}m';
              print("Overview: Calculated shift duration: $tempCalculatedShiftDuration");

              final nowTime = TimeOfDay.fromDateTime(now);
              final nowMinutes = nowTime.hour * 60 + nowTime.minute;
              final scheduleStartMinutes = startTime.hour * 60 + startTime.minute;

              int scheduleEndMinutes = endTime.hour * 60 + endTime.minute;

              if (scheduleEndMinutes < scheduleStartMinutes) {
                if (nowMinutes >= scheduleStartMinutes || nowMinutes < scheduleEndMinutes) {
                  tempStatus = 'On Duty';
                }
              } else {
                if (nowMinutes >= scheduleStartMinutes && nowMinutes < scheduleEndMinutes) {
                  tempStatus = 'On Duty';
                }
              }
              print("Overview: Guard is determined to be $tempStatus for this schedule.");

            } else {
              print("Overview WARNING: Invalid time format in schedule doc ${doc.id}. Start: '$start', End: '$end'. Parts were null or incorrect length after parsing.");
              tempDutyShiftTimes = 'Invalid time format in DB';
              tempCalculatedShiftDuration = '-';
              // tempStatus remains 'Off Duty' or its initial value
            }
          } catch (e, s) {
            print("Overview ERROR: Error parsing schedule times for doc ${doc.id}: $e\n$s");
            tempDutyDate = 'Error parsing schedule data';
            tempDutyShiftTimes = '-';
            tempCalculatedShiftDuration = '-';
            tempStatus = 'Unknown'; // Error occurred
          }
        } else {
          print("Overview WARNING: Schedule data incomplete. date: $dateStrFromDb, start: $start, end: $end");
          tempDutyDate = 'Schedule data incomplete in DB';
          // tempStatus remains 'Off Duty' or its initial value
        }

        print("Overview: Preparing to setState with: date='$tempDutyDate', times='$tempDutyShiftTimes', duration='$tempCalculatedShiftDuration', status='$tempStatus'");
        if (mounted) {
          setState(() {
            dutyDate = tempDutyDate;
            dutyShiftTimes = tempDutyShiftTimes;
            calculatedShiftDuration = tempCalculatedShiftDuration;
            status = tempStatus;
            _isLoadingSchedule = false;
            assignedCheckpointNames = cpNamesResolved;
            assignedCheckpoints = cpModelsResolved;
          });
          print("Overview: setState COMPLETED with schedule details.");
        }
      } else {
        print("Overview: No schedule documents found for today for this guard.");
        if (mounted) {
          setState(() {
            dutyDate = 'No assignment today';
            dutyShiftTimes = '-';
            calculatedShiftDuration = '-';
            status = 'Off Duty'; // Explicitly Off Duty if no schedule
            _isLoadingSchedule = false;
            assignedCheckpointNames = [];
            assignedCheckpoints = [];
          });
          print("Overview: setState COMPLETED - No assignment today.");
        }
      }
    } catch (e, s) {
      print("Overview ERROR: Generic error loading schedule status from Firestore: $e\n$s");
      if (mounted) {
        setState(() {
          dutyDate = 'Error loading schedule from DB';
          dutyShiftTimes = '-';
          calculatedShiftDuration = '-';
          status = 'Unknown';
          _isLoadingSchedule = false;
          assignedCheckpointNames = [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {

    print("Overview BUILD: SecurityGuardOverviewScreen is building. Current status: $status, isLoading: $_isLoadingSchedule");


    final guard = widget.guardData;
    final theme = Theme.of(context);

    final fullName = GuardNameUtils.format(
      firstName: guard['first_name'] as String?,
      lastName: guard['last_name'] as String?,
      fallbackName: guard['name'] as String?,
    );

    final bool isActuallyOnDuty = status == 'On Duty';
    final statusColor = isActuallyOnDuty ? Colors.green.shade700 : Colors.red.shade700;


    final nav = appNavList(context, closeDrawer: true);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text(fullName.isEmpty || fullName == "N/A" ? 'Guard Overview' : fullName),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
      ),
      drawer: Drawer(child: nav),
      body: RefreshIndicator( // Keep RefreshIndicator
        onRefresh: _loadScheduleStatus,
        child: _isLoadingSchedule
            ? const Center(child: CircularProgressIndicator())
            : ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: Column(
                children: [
                  Icon(
                    isActuallyOnDuty ? Icons.shield_rounded : Icons.shield_outlined,
                    size: 80,
                    color: statusColor,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            // Only show schedule details below
            InfoCard(
              title: 'Today\'s Assignment Details',
              children: [
                InfoTile(label: 'Date of Duty', value: dutyDate),
                InfoTile(label: 'Shift Times', value: dutyShiftTimes),
                InfoTile(label: 'Calculated Duration', value: calculatedShiftDuration),
              ],
            ),
            
            // Assigned Checkpoints Section
            if (assignedCheckpoints.isNotEmpty) ...[
              const SizedBox(height: 16),
              InfoCard(
                title: 'Assigned Checkpoints',
                children: [
                  ...assignedCheckpoints.map((checkpoint) => CheckpointCard(checkpoint: checkpoint)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class InfoCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const InfoCard({super.key, this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(
                title!,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Divider(height: 16, thickness: 1),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}


class InfoTile extends StatelessWidget {
  final String label;
  final String? value;
  final IconData? icon;

  const InfoTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, color: theme.textTheme.bodySmall?.color ?? theme.disabledColor, size: 18),
            const SizedBox(width: 8),
          ],
          Text(
            '$label: ',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Text(
              value?.isEmpty ?? true ? 'N/A' : value!,
              style: theme.textTheme.bodyLarge,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

class CheckpointCard extends StatelessWidget {
  final CheckpointModel checkpoint;

  const CheckpointCard({
    super.key,
    required this.checkpoint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isScanned = checkpoint.status == CheckpointScanStatus.scanned;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isScanned 
            ? Colors.green.shade50 
            : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isScanned 
              ? Colors.green.shade200 
              : Colors.orange.shade200,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isScanned 
                      ? Colors.green.shade100 
                      : Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isScanned ? Icons.check_circle : Icons.location_on,
                  color: isScanned 
                      ? Colors.green.shade700 
                      : Colors.orange.shade700,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      checkpoint.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isScanned 
                            ? Colors.green.shade800 
                            : Colors.orange.shade800,
                      ),
                    ),
                    Text(
                      checkpoint.location,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isScanned 
                      ? Colors.green.shade600 
                      : Colors.orange.shade600,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _formatCheckpointStatus(checkpoint.status),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.location_city,
                size: 16,
                color: theme.textTheme.bodySmall?.color,
              ),
              const SizedBox(width: 4),
              Text(
                'Location: ${checkpoint.location}',
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              if (checkpoint.lastScannedAt != null) ...[
                Icon(
                  Icons.access_time,
                  size: 16,
                  color: theme.textTheme.bodySmall?.color,
                ),
                const SizedBox(width: 4),
                Text(
                  'Last scanned: ${DateFormat('MMM dd, HH:mm').format(checkpoint.lastScannedAt!.toDate())}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.comment,
                size: 16,
                color: theme.textTheme.bodySmall?.color,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Remarks: ${checkpoint.remarks?.trim().isNotEmpty == true ? checkpoint.remarks!.trim() : 'No remarks yet'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (checkpoint.notes != null && checkpoint.notes!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.note,
                    size: 16,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      checkpoint.notes!,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
