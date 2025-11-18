import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:thesis_web/services/app_logger.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_list.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class AssignScheduleScreen extends StatefulWidget {
  const AssignScheduleScreen({super.key});

  @override
  State<AssignScheduleScreen> createState() => _AssignScheduleScreenState();
}

class _AssignScheduleScreenState extends State<AssignScheduleScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  // Period selection for daily assignment
  String _periodType = 'Single Day'; // Single Day, Range
  DateTimeRange? _customRange;
  final List<DateTime> _selectedDates = [];
  // Stores selected user-facing guard IDs (Accounts.guard_id)
  List<String> selectedGuardIds = [];
  final TextEditingController searchController = TextEditingController();
  // Checkpoint selection state
  final TextEditingController _cpSearchController = TextEditingController();
  List<Map<String, dynamic>> _allCheckpoints = [];
  List<String> _selectedCheckpointIds = [];

  List<Map<String, dynamic>> allGuards = [];
  bool _isLoadingGuards = true;
  bool _isLoadingCheckpoints = true;
  // Fast lookup map for logging and UI: guard_id -> name
  Map<String, String> _guardIdToName = {};
  // Track already assigned checkpoints for the selected date
  Set<String> _assignedCheckpointIds = {};
  bool _isLoadingAssignedCheckpoints = false;
  // Track guards with ongoing schedules
  Set<String> _guardsWithOngoingSchedules = {};
  bool _isLoadingGuardSchedules = false;

  @override
  void initState() {
    super.initState();
    _fetchGuards();
    _fetchCheckpoints();
    // Default to today and prefetch assigned checkpoints and guard schedules to prevent duplicates
    _selectedDay = DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDay!);
    _fetchAssignedCheckpoints(dateStr);
    _fetchGuardsWithOngoingSchedules(dateStr);
  }

  // Utilities to compute dates for daily scheduling

  void _populateSelectedDates() {
    _selectedDates.clear();
    final base = _selectedDay ?? DateTime.now();
    if (_periodType == 'Single Day') {
      _selectedDates.add(DateTime(base.year, base.month, base.day));
    } else if (_periodType == 'Range' && _customRange != null) {
      DateTime d = DateTime(_customRange!.start.year, _customRange!.start.month, _customRange!.start.day);
      final DateTime end = DateTime(_customRange!.end.year, _customRange!.end.month, _customRange!.end.day);
      while (!d.isAfter(end)) {
        _selectedDates.add(d);
        d = d.add(const Duration(days: 1));
      }
    }
    setState(() {});
  }

  Future<void> _fetchGuards() async {
    setState(() {
      _isLoadingGuards = true;
    });
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('Accounts')
          .where('role', isEqualTo: 'Security')
          .get();

      if (mounted) {
        setState(() {
          allGuards = snapshot.docs
              .map((doc) => {
                    'doc_id': doc.id,
                    'guard_id': (doc.data()['guard_id'] ?? '').toString(),
                    'name': '${doc['first_name'] ?? ''} ${doc['last_name'] ?? ''}'.trim(),
                  })
              .where((guard) => guard['name'].toString().isNotEmpty)
              .toList();
          // Build lookup map for reliable name resolution during logging
          _guardIdToName = {
            for (final g in allGuards)
              if ((g['guard_id'] ?? '').toString().isNotEmpty)
                (g['guard_id'] as String): (g['name'] as String)
          };
          _isLoadingGuards = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingGuards = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching guards: $e')),
        );
      }
      print("Error fetching guards: $e");
    }
  }

  Future<void> _fetchCheckpoints() async {
    setState(() {
      _isLoadingCheckpoints = true;
    });
    try {
      final snap = await FirebaseFirestore.instance.collection('Checkpoints').get();
      if (mounted) {
        setState(() {
          _allCheckpoints = snap.docs
              .map((d) => {
                    'id': d.id,
                    'name': (d.data()['name'] ?? '').toString(),
                  })
              .where((c) => c['name'].toString().isNotEmpty)
              .toList();
          _isLoadingCheckpoints = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingCheckpoints = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching checkpoints: $e')),
        );
      }
    }
  }

  Future<void> _fetchAssignedCheckpoints(String dateStr) async {
    if (dateStr.isEmpty) return;
    
    setState(() {
      _isLoadingAssignedCheckpoints = true;
    });
    
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('Schedules')
          .where('date', isEqualTo: dateStr)
          .get();
      
      if (mounted) {
        setState(() {
          _assignedCheckpointIds.clear();
          final now = DateTime.now();
          final currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          
          for (var doc in snapshot.docs) {
            final data = doc.data();
            final startTime = data['start_time'] as String?;
            final endTime = data['end_time'] as String?;
            final checkpoints = data['checkpoints'] as List<dynamic>?;
            
            // Only consider checkpoints as "assigned" if the schedule is currently active
            if (startTime != null && endTime != null && checkpoints != null) {
              // Check if current time is within the schedule's time range
              if (_isTimeInRange(currentTime, startTime, endTime)) {
                for (var checkpointId in checkpoints) {
                  _assignedCheckpointIds.add(checkpointId.toString());
                }
              }
            }
          }
          _isLoadingAssignedCheckpoints = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingAssignedCheckpoints = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching assigned checkpoints: $e')),
        );
      }
      print("Error fetching assigned checkpoints: $e");
    }
  }

  Future<void> _fetchGuardsWithOngoingSchedules(String dateStr) async {
    if (dateStr.isEmpty) return;
    
    setState(() {
      _isLoadingGuardSchedules = true;
    });
    
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('Schedules')
          .where('date', isEqualTo: dateStr)
          .get();
      
      if (mounted) {
        setState(() {
          _guardsWithOngoingSchedules.clear();
          final now = DateTime.now();
          final currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          
          for (var doc in snapshot.docs) {
            final data = doc.data();
            final guardId = data['guard_id'] as String?;
            final startTime = data['start_time'] as String?;
            final endTime = data['end_time'] as String?;
            
            // Only consider guards as "busy" if they have an ongoing schedule
            if (guardId != null && startTime != null && endTime != null) {
              // Check if current time is within the schedule's time range
              if (_isTimeInRange(currentTime, startTime, endTime)) {
                _guardsWithOngoingSchedules.add(guardId);
              }
            }
          }
          _isLoadingGuardSchedules = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingGuardSchedules = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching guard schedules: $e')),
        );
      }
      print("Error fetching guard schedules: $e");
    }
  }

  Future<void> _selectTime(BuildContext context, bool isStart) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: isStart
          ? (_startTime ?? TimeOfDay.now())
          : (_endTime ?? TimeOfDay.now()),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
    }
  }

  String format24Hour(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  // Helper function to check if a time is within a given range
  bool _isTimeInRange(String currentTime, String startTime, String endTime) {
    try {
      // Parse time strings to minutes since midnight
      int parseTime(String timeStr) {
        final parts = timeStr.split(':');
        return int.parse(parts[0]) * 60 + int.parse(parts[1]);
      }
      
      final current = parseTime(currentTime);
      final start = parseTime(startTime);
      final end = parseTime(endTime);
      
      // Handle overnight shifts (end time is next day)
      if (end < start) {
        // Overnight shift: current time should be >= start OR <= end
        return current >= start || current <= end;
      } else {
        // Normal shift: current time should be >= start AND <= end
        return current >= start && current <= end;
      }
    } catch (e) {
      // If parsing fails, assume not in range to be safe
      return false;
    }
  }

  // Helper function to check if two time ranges overlap
  bool _timesOverlap(String start1, String end1, String start2, String end2) {
    try {
      // Parse time strings to minutes since midnight
      int parseTime(String timeStr) {
        final parts = timeStr.split(':');
        return int.parse(parts[0]) * 60 + int.parse(parts[1]);
      }
      
      final s1 = parseTime(start1);
      final e1 = parseTime(end1);
      final s2 = parseTime(start2);
      final e2 = parseTime(end2);
      
      // Handle overnight shifts (end time is next day)
      final e1Adjusted = e1 < s1 ? e1 + 24 * 60 : e1;
      final e2Adjusted = e2 < s2 ? e2 + 24 * 60 : e2;
      
      // Check for overlap: two ranges overlap if one starts before the other ends
      return s1 < e2Adjusted && s2 < e1Adjusted;
    } catch (e) {
      // If parsing fails, assume no overlap to be safe
      return false;
    }
  }

  Future<void> assignSchedule() async {
    if ((_selectedDay == null && _periodType != 'Range') ||
        _startTime == null ||
        _endTime == null ||
        selectedGuardIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all fields.')),
      );
      return;
    }

    // Build selected dates based on period
    _populateSelectedDates();
    if (_selectedDates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one date to assign.')),
      );
      return;
    }

    // Re-check conflicts from Firestore to avoid race conditions
    // For batch: check conflicts per date considering time overlap
    for (final d in _selectedDates) {
      final String dateStrForConflict = DateFormat('yyyy-MM-dd').format(d);
      try {
        final existingForDate = await FirebaseFirestore.instance
            .collection('Schedules')
            .where('date', isEqualTo: dateStrForConflict)
            .get();
        
        // Check for time overlaps with existing schedules
        final startStr = format24Hour(_startTime!);
        final endStr = format24Hour(_endTime!);
        
        final Set<String> conflictingCheckpoints = {};
        
        for (final doc in existingForDate.docs) {
          final data = doc.data();
          final existingStartTime = data['start_time'] as String?;
          final existingEndTime = data['end_time'] as String?;
          final existingCheckpoints = (data['checkpoints'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const <String>[];
          
          // Check if times overlap
          if (existingStartTime != null && existingEndTime != null) {
            if (_timesOverlap(startStr, endStr, existingStartTime, existingEndTime)) {
              // Only consider checkpoints that are in both schedules
              for (final checkpointId in _selectedCheckpointIds) {
                if (existingCheckpoints.contains(checkpointId)) {
                  conflictingCheckpoints.add(checkpointId);
                }
              }
            }
          }
        }
        
        if (conflictingCheckpoints.isNotEmpty) {
          final checkpointNames = conflictingCheckpoints
              .map((id) => _allCheckpoints.firstWhere((cp) => cp['id'] == id)['name'])
              .join(', ');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Cannot assign on $dateStrForConflict; time conflict with existing assignment: $checkpointNames'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
      } catch (_) {/* ignore; best effort */}
    }

    // Time validation
    final DateTime selectedStartDate = DateTime(
      (_selectedDay ?? DateTime.now()).year,
      (_selectedDay ?? DateTime.now()).month,
      (_selectedDay ?? DateTime.now()).day,
      _startTime!.hour,
      _startTime!.minute,
    );
    final DateTime selectedEndDate = DateTime(
      (_selectedDay ?? DateTime.now()).year,
      (_selectedDay ?? DateTime.now()).month,
      (_selectedDay ?? DateTime.now()).day,
      _endTime!.hour,
      _endTime!.minute,
    );

    // Allow overnight shifts (end before start). Only disallow equal times.
    if (selectedEndDate.isAtSameMomentAs(selectedStartDate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must differ from start time.')),
      );
      return;
    }

    final firestore = FirebaseFirestore.instance;
    final List<String> dateStrings = _selectedDates.map((d) => DateFormat('yyyy-MM-dd').format(d)).toList();
    final startStr = format24Hour(_startTime!);
    final endStr = format24Hour(_endTime!);

    // Show a loading indicator while assigning
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Dialog(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("Assigning..."),
              ],
            ),
          ),
        );
      },
    );

    try {
      int created = 0; // kept for potential UI messages
      for (final dateStr in dateStrings) {
        WriteBatch batch = firestore.batch();
        for (String guardId in selectedGuardIds) {
          DocumentReference scheduleRef = firestore.collection('Schedules').doc();
          batch.set(scheduleRef, {
            'guard_id': guardId,
            'date': dateStr,
            'start_time': startStr,
            'end_time': endStr,
            'duty': true,
            'created_at': FieldValue.serverTimestamp(),
            'checkpoints': _selectedCheckpointIds,
          });
        }
        await batch.commit();
        created += selectedGuardIds.length;
      }

      // Log each assignment to TransactionLogs
      for (final dateStr in dateStrings) {
        for (final guardId in selectedGuardIds) {
          final String guardName = _guardIdToName[guardId] ?? 'Unknown Security Guard';
          await AppLogger.log(
            type: 'Schedule',
            message: 'Assigned schedule to security guard $guardName ($guardId)',
            userId: null,
            metadata: {
              'guard_id': guardId,
              'guard_name': guardName,
              'date': dateStr,
              'start_time': startStr,
              'end_time': endStr,
              'checkpoints': _selectedCheckpointIds,
            },
          );
        }
      }

      if (mounted) {
        Navigator.of(context).pop(); // Dismiss loading dialog
        final String createdMsg = 'Assigned ${selectedGuardIds.length} guard(s) across ${dateStrings.length} day(s). (records: $created)';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(createdMsg)));
        // Navigate to Security Guard List after successful assignment
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => SecurityGuardListScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Dismiss loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error assigning schedule: $e')),
        );
      }
      print("Error assigning schedule: $e");
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    _cpSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = appNavList(context, closeDrawer: true);
    List<Map<String, dynamic>> filteredGuards = allGuards
        .where((g) => g['name']
            .toString()
            .toLowerCase()
            .contains(searchController.text.toLowerCase()))
        .toList();

    List<Map<String, dynamic>> filteredCheckpoints = _allCheckpoints
        .where((c) => c['name']
            .toString()
            .toLowerCase()
            .contains(_cpSearchController.text.toLowerCase()))
        .toList();
    
    // Separate available and assigned checkpoints
    List<Map<String, dynamic>> availableCheckpoints = filteredCheckpoints
        .where((c) => !_assignedCheckpointIds.contains(c['id']))
        .toList();
    
    List<Map<String, dynamic>> assignedCheckpoints = filteredCheckpoints
        .where((c) => _assignedCheckpointIds.contains(c['id']))
        .toList();

    final body = _isLoadingGuards
          ? const Center(child: CircularProgressIndicator())
          : allGuards.isEmpty && !_isLoadingGuards
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'No security guards found. Ensure they are added with the role "Security" in the database.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Daily Schedule Assignment', 
                       style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text('Create individual daily schedules or date ranges',
                       style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                         color: Colors.grey.shade600,
                       )),
                  const SizedBox(height: 16),
                  Text('Select Date:', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  TableCalendar(
                    firstDay: DateTime.utc(DateTime.now().year, DateTime.now().month, DateTime.now().day),
                    lastDay: DateTime.utc(2100, 12, 31),
                    focusedDay: _focusedDay,
                    selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                    onDaySelected: (selectedDay, focusedDay) {
                      final today = DateTime.now();
                      final startOfToday = DateTime(today.year, today.month, today.day);
                      if (!selectedDay.isBefore(startOfToday)) {
                        setState(() {
                          _selectedDay = selectedDay;
                          _focusedDay = focusedDay;
                        });
                        // Fetch assigned checkpoints and guard schedules for the selected date
                        final dateStr = DateFormat('yyyy-MM-dd').format(selectedDay);
                        _fetchAssignedCheckpoints(dateStr);
                        _fetchGuardsWithOngoingSchedules(dateStr);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Cannot select a past date.')),
                        );
                      }
                    },
                    calendarStyle: CalendarStyle(
                      todayDecoration: BoxDecoration(
                          color: Colors.orange.shade300, shape: BoxShape.circle),
                      selectedDecoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
                    ),
                    headerStyle: const HeaderStyle(
                      formatButtonVisible: false,
                      titleCentered: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Period selector - Only Single Day and Range for daily scheduling
                  Text('Select Period:', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Single Day'),
                        selected: _periodType == 'Single Day',
                        onSelected: (_) { setState(() { _periodType = 'Single Day'; _populateSelectedDates(); }); },
                      ),
                      ChoiceChip(
                        label: const Text('Date Range'),
                        selected: _periodType == 'Range',
                        onSelected: (_) async {
                          _periodType = 'Range';
                          final now = DateTime.now();
                          final picked = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(now.year, now.month, now.day),
                            lastDate: DateTime(now.year + 3),
                          );
                          if (picked != null) {
                            setState(() { _customRange = picked; _populateSelectedDates(); });
                          } else {
                            setState(() { _periodType = 'Single Day'; _customRange = null; _populateSelectedDates(); });
                          }
                        },
                      ),
                    ],
                  ),
                  if (_selectedDates.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Selected days: ${_selectedDates.length}', style: Theme.of(context).textTheme.bodyMedium),
                  ],
                  Text('Select Time:', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () => _selectTime(context, true),
                        child: Text(_startTime == null
                            ? 'Start Time'
                            : _startTime!.format(context)),
                      ),
                      const Text("to"),
                      ElevatedButton(
                        onPressed: () => _selectTime(context, false),
                        child: Text(_endTime == null
                            ? 'End Time'
                            : _endTime!.format(context)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  
                  // Guards and Checkpoints Section - Side by Side
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Security Guards Section
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Search Security Guard:', style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            TextField(
                              controller: searchController,
                              decoration: InputDecoration(
                                hintText: 'Enter security guard name...',
                                prefixIcon: const Icon(Icons.search),
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    searchController.clear();
                                  },
                                ),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            const SizedBox(height: 16),
                            Text('Select Security Guards (${selectedGuardIds.length} selected):',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            if (filteredGuards.isEmpty && searchController.text.isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 20.0),
                                child: Center(child: Text("No guards match your search.")),
                              )
                            else if (filteredGuards.isEmpty && allGuards.isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 20.0),
                                child: Center(child: Text("No guards available to select.")),
                              )
                            else
                              SizedBox(
                                height: 300,
                                child: ListView.builder(
                                  itemCount: filteredGuards.length,
                                  itemBuilder: (context, index) {
                                    final guard = filteredGuards[index];
                                    final String guardUserFacingId = (guard['guard_id'] ?? '').toString();
                                    final hasOngoingSchedule = _guardsWithOngoingSchedules.contains(guardUserFacingId);
                                    
                                    return CheckboxListTile(
                                      title: Text(
                                        guard['name'] ?? 'Unnamed Guard',
                                        style: TextStyle(
                                          color: hasOngoingSchedule ? Colors.grey.shade600 : null,
                                          decoration: hasOngoingSchedule ? TextDecoration.lineThrough : null,
                                        ),
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (guardUserFacingId.isEmpty) 
                                            const Text('No Guard ID')
                                          else 
                                            Text('ID: $guardUserFacingId'),
                                          if (hasOngoingSchedule)
                                            Text(
                                              'Currently on duty',
                                              style: TextStyle(
                                                color: Colors.orange.shade600,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                        ],
                                      ),
                                      value: guardUserFacingId.isNotEmpty && selectedGuardIds.contains(guardUserFacingId) && !hasOngoingSchedule,
                                      onChanged: hasOngoingSchedule ? null : (bool? value) {
                                        setState(() {
                                          if (guardUserFacingId.isEmpty) return;
                                          if (value == true) {
                                            if (!selectedGuardIds.contains(guardUserFacingId)) {
                                              selectedGuardIds.add(guardUserFacingId);
                                            }
                                          } else {
                                            selectedGuardIds.remove(guardUserFacingId);
                                          }
                                        });
                                      },
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(width: 16),
                      
                      // Checkpoints Section
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Assign Checkpoints (${_selectedCheckpointIds.length} selected):',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _cpSearchController,
                              decoration: const InputDecoration(
                                hintText: 'Search checkpoint by name...',
                                prefixIcon: Icon(Icons.search),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            const SizedBox(height: 8),
                            if (_isLoadingCheckpoints || _isLoadingAssignedCheckpoints)
                              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
                            else
                              SizedBox(
                                height: 300,
                                child: Column(
                                  children: [
                                    // Available Checkpoints Section
                                    if (availableCheckpoints.isNotEmpty) ...[
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.green.shade200),
                                        ),
                                        child: Text(
                                          'Available Checkpoints (${availableCheckpoints.length})',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green.shade800,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Expanded(
                                        flex: 2,
                                        child: ListView.builder(
                                          itemCount: availableCheckpoints.length,
                                          itemBuilder: (context, index) {
                                            final cp = availableCheckpoints[index];
                                            final id = cp['id'] as String;
                                            return CheckboxListTile(
                                              title: Text(cp['name'] ?? 'Unnamed Checkpoint'),
                                              subtitle: Text('ID: $id'),
                                              value: _selectedCheckpointIds.contains(id),
                                              onChanged: (v) {
                                                setState(() {
                                                  if (v == true) {
                                                    if (!_selectedCheckpointIds.contains(id)) _selectedCheckpointIds.add(id);
                                                  } else {
                                                    _selectedCheckpointIds.remove(id);
                                                  }
                                                });
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                    
                                    // Assigned Checkpoints Section
                                    if (assignedCheckpoints.isNotEmpty) ...[
                                      if (availableCheckpoints.isNotEmpty) const SizedBox(height: 16),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.shade50,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.orange.shade200),
                                        ),
                                        child: Text(
                                          'Already Assigned Checkpoints (${assignedCheckpoints.length})',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.orange.shade800,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Expanded(
                                        flex: 1,
                                        child: ListView.builder(
                                          itemCount: assignedCheckpoints.length,
                                          itemBuilder: (context, index) {
                                            final cp = assignedCheckpoints[index];
                                            final id = cp['id'] as String;
                                            return ListTile(
                                              leading: Icon(
                                                Icons.check_circle,
                                                color: Colors.orange.shade600,
                                              ),
                                              title: Text(
                                                cp['name'] ?? 'Unnamed Checkpoint',
                                                style: TextStyle(
                                                  color: Colors.grey.shade600,
                                                  decoration: TextDecoration.lineThrough,
                                                ),
                                              ),
                                              subtitle: Text(
                                                'ID: $id - Already assigned',
                                                style: TextStyle(color: Colors.grey.shade500),
                                              ),
                                              enabled: false,
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                    
                                    // No checkpoints message
                                    if (availableCheckpoints.isEmpty && assignedCheckpoints.isEmpty)
                                      Expanded(
                                        child: Center(
                                          child: Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                Icons.location_off,
                                                size: 48,
                                                color: Colors.grey.shade400,
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                'No checkpoints found',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  color: Colors.grey.shade600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: ElevatedButton(
                      onPressed: assignSchedule,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      child: const Text('Assign Schedule'),
                    ),
                  )
                ],
              ),
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text('Daily Schedule'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      drawer: Drawer(child: nav),
      body: body,
    );
  }
}