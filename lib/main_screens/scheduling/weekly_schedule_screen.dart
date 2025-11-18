import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:thesis_web/services/app_logger.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_list.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class WeeklyScheduleScreen extends StatefulWidget {
  const WeeklyScheduleScreen({super.key});

  @override
  State<WeeklyScheduleScreen> createState() => _WeeklyScheduleScreenState();
}

class _WeeklyScheduleScreenState extends State<WeeklyScheduleScreen> {
  DateTime _selectedWeekStart = DateTime.now();
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  List<String> selectedGuardIds = [];
  List<String> _selectedCheckpointIds = [];
  final TextEditingController searchController = TextEditingController();
  final TextEditingController _cpSearchController = TextEditingController();
  
  List<Map<String, dynamic>> allGuards = [];
  List<Map<String, dynamic>> _allCheckpoints = [];
  Map<String, String> _guardIdToName = {};
  bool _isLoadingGuards = true;
  bool _isLoadingCheckpoints = true;
  // Track guards with ongoing schedules (trapper)
  Set<String> _guardsWithOngoingSchedules = {};
  bool _isLoadingGuardSchedules = false;

  @override
  void initState() {
    super.initState();
    _fetchGuards();
    _fetchCheckpoints();
    // Set to Monday of current week
    _selectedWeekStart = _getMondayOfWeek(DateTime.now());
    _fetchGuardsWithOngoingSchedules();
  }

  DateTime _getMondayOfWeek(DateTime date) {
    final int weekday = date.weekday;
    return date.subtract(Duration(days: weekday - 1));
  }

  List<DateTime> _getWeekDates(DateTime weekStart) {
    return List.generate(7, (i) => weekStart.add(Duration(days: i)));
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

  Future<void> _fetchGuardsWithOngoingSchedules() async {
    setState(() {
      _isLoadingGuardSchedules = true;
    });
    try {
      final today = DateTime.now();
      final startOfToday = DateTime(today.year, today.month, today.day);
      final dateStr = DateFormat('yyyy-MM-dd').format(startOfToday);

      final snapshot = await FirebaseFirestore.instance
          .collection('Schedules')
          .where('date', isEqualTo: dateStr)
          .get();

      if (mounted) {
        setState(() {
          _guardsWithOngoingSchedules.clear();
          final now = DateTime.now();
          final currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

          for (final doc in snapshot.docs) {
            final data = doc.data();
            final guardId = data['guard_id'] as String?;
            final startTime = data['start_time'] as String?;
            final endTime = data['end_time'] as String?;
            if (guardId != null && startTime != null && endTime != null) {
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
          SnackBar(content: Text('Error checking ongoing schedules: $e')),
        );
      }
    }
  }

  bool _isTimeInRange(String currentTime, String startTime, String endTime) {
    try {
      int parse(String s) {
        final p = s.split(':');
        return int.parse(p[0]) * 60 + int.parse(p[1]);
      }
      final cur = parse(currentTime);
      final st = parse(startTime);
      final en = parse(endTime);
      if (en < st) {
        return cur >= st || cur <= en;
      }
      return cur >= st && cur <= en;
    } catch (_) {
      return false;
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

  Future<void> _createWeeklySchedule() async {
    if (_startTime == null || _endTime == null || selectedGuardIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all fields.')),
      );
      return;
    }

    // Time validation
    final DateTime selectedStartDate = DateTime(
      _selectedWeekStart.year,
      _selectedWeekStart.month,
      _selectedWeekStart.day,
      _startTime!.hour,
      _startTime!.minute,
    );
    final DateTime selectedEndDate = DateTime(
      _selectedWeekStart.year,
      _selectedWeekStart.month,
      _selectedWeekStart.day,
      _endTime!.hour,
      _endTime!.minute,
    );

    if (selectedEndDate.isAtSameMomentAs(selectedStartDate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must differ from start time.')),
      );
      return;
    }

    final weekDates = _getWeekDates(_selectedWeekStart);
    final startStr = format24Hour(_startTime!);
    final endStr = format24Hour(_endTime!);

    // Show loading indicator
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
                Text("Creating weekly schedule..."),
              ],
            ),
          ),
        );
      },
    );

    try {
      final firestore = FirebaseFirestore.instance;
      
      // Create weekly schedule document
      final weeklyScheduleRef = firestore.collection('WeeklySchedules').doc();
      await weeklyScheduleRef.set({
        'week_start_date': DateFormat('yyyy-MM-dd').format(_selectedWeekStart),
        'start_time': startStr,
        'end_time': endStr,
        'guard_ids': selectedGuardIds,
        'checkpoints': _selectedCheckpointIds,
        'created_at': FieldValue.serverTimestamp(),
        'schedule_type': 'weekly',
        'is_active': true,
      });

      // Create individual daily schedules for each day of the week (excluding past dates)
      WriteBatch batch = firestore.batch();
      final today = DateTime.now();
      final startOfToday = DateTime(today.year, today.month, today.day);
      
      for (final date in weekDates) {
        // Skip past dates
        if (date.isBefore(startOfToday)) {
          continue;
        }
        
        final dateStr = DateFormat('yyyy-MM-dd').format(date);
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
            'parent_weekly_schedule_id': weeklyScheduleRef.id,
            'schedule_type': 'weekly',
          });
        }
      }
      await batch.commit();

      // Log the weekly schedule creation
      for (final guardId in selectedGuardIds) {
        final String guardName = _guardIdToName[guardId] ?? 'Unknown Security Guard';
        await AppLogger.log(
          type: 'Weekly Schedule',
          message: 'Created weekly schedule for security guard $guardName ($guardId)',
          userId: null,
          metadata: {
            'guard_id': guardId,
            'guard_name': guardName,
            'week_start_date': DateFormat('yyyy-MM-dd').format(_selectedWeekStart),
            'start_time': startStr,
            'end_time': endStr,
            'checkpoints': _selectedCheckpointIds,
            'weekly_schedule_id': weeklyScheduleRef.id,
          },
        );
      }

      if (mounted) {
        Navigator.of(context).pop(); // Dismiss loading dialog
        
        // Count how many future dates were actually scheduled
        final futureDates = weekDates.where((date) => !date.isBefore(startOfToday)).length;
        final totalDates = weekDates.length;
        final skippedDates = totalDates - futureDates;
        
        String message = 'Weekly schedule created for ${selectedGuardIds.length} guard(s)';
        if (skippedDates > 0) {
          message += ' (${skippedDates} past date(s) excluded)';
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => SecurityGuardListScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Dismiss loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating weekly schedule: $e')),
        );
      }
      print("Error creating weekly schedule: $e");
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
    final weekDates = _getWeekDates(_selectedWeekStart);
    
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
                Text('Weekly Schedule Creation', 
                     style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 16),
                
                // Week Selection
                Text('Select Week:', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Week of ${DateFormat('MMM dd, yyyy').format(_selectedWeekStart)}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _selectedWeekStart = _selectedWeekStart.subtract(const Duration(days: 7));
                        });
                      },
                      icon: const Icon(Icons.chevron_left),
                    ),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _selectedWeekStart = _selectedWeekStart.add(const Duration(days: 7));
                        });
                      },
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                
                // Week days display
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Week Days:', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: weekDates.map((date) {
                          final dayName = DateFormat('EEE').format(date);
                          final dayNumber = date.day;
                          return Chip(
                            label: Text('$dayName $dayNumber'),
                            backgroundColor: Colors.blue.shade100,
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 24),
                
                // Time Selection
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
                    // Guards
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
                                onPressed: () { searchController.clear(); },
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 16),
                          Text('Select Security Guards (${selectedGuardIds.length} selected):', style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 220,
                            child: ListView.builder(
                              itemCount: filteredGuards.length,
                              itemBuilder: (context, index) {
                                final guard = filteredGuards[index];
                                final String guardUserFacingId = (guard['guard_id'] ?? '').toString();
                                final hasOngoing = _guardsWithOngoingSchedules.contains(guardUserFacingId);
                                return CheckboxListTile(
                                  title: Text(
                                    guard['name'] ?? 'Unnamed Guard',
                                    style: TextStyle(
                                      color: hasOngoing ? Colors.grey.shade600 : null,
                                      decoration: hasOngoing ? TextDecoration.lineThrough : null,
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (guardUserFacingId.isEmpty) const Text('No Guard ID') else Text('ID: $guardUserFacingId'),
                                      if (hasOngoing)
                                        Text('Currently on duty', style: TextStyle(color: Colors.orange.shade600, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  value: guardUserFacingId.isNotEmpty && selectedGuardIds.contains(guardUserFacingId) && !hasOngoing,
                                  onChanged: hasOngoing ? null : (bool? v) {
                                    setState(() {
                                      if (guardUserFacingId.isEmpty) return;
                                      if (v == true) {
                                        if (!selectedGuardIds.contains(guardUserFacingId)) selectedGuardIds.add(guardUserFacingId);
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
                    // Checkpoints
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Assign Checkpoints (${_selectedCheckpointIds.length} selected):', style: Theme.of(context).textTheme.titleLarge),
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
                          SizedBox(
                            height: 220,
                            child: ListView.builder(
                              itemCount: filteredCheckpoints.length,
                              itemBuilder: (context, index) {
                                final cp = filteredCheckpoints[index];
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
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 20),
                Center(
                  child: ElevatedButton(
                    onPressed: _createWeeklySchedule,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                      textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    child: const Text('Create Weekly Schedule'),
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
        title: const Text('Weekly Schedule'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      drawer: Drawer(child: nav),
      body: body,
    );
  }
}


