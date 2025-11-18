import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:thesis_web/services/app_logger.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_list.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class MonthlyScheduleScreen extends StatefulWidget {
  const MonthlyScheduleScreen({super.key});

  @override
  State<MonthlyScheduleScreen> createState() => _MonthlyScheduleScreenState();
}

class _MonthlyScheduleScreenState extends State<MonthlyScheduleScreen> {
  DateTime _selectedMonth = DateTime.now();
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
  // Track guards with ongoing schedules
  Set<String> _guardsWithOngoingSchedules = {};
  bool _isLoadingGuardSchedules = false;

  @override
  void initState() {
    super.initState();
    _fetchGuards();
    _fetchCheckpoints();
    _fetchGuardsWithOngoingSchedules();
  }

  List<DateTime> _getMonthDates(DateTime month) {
    final lastDay = DateTime(month.year, month.month + 1, 0);
    final daysInMonth = lastDay.day;
    return List.generate(daysInMonth, (i) => DateTime(month.year, month.month, i + 1));
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

  Future<void> _createMonthlySchedule() async {
    if (_startTime == null || _endTime == null || selectedGuardIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all fields.')),
      );
      return;
    }

    // Time validation
    final DateTime selectedStartDate = DateTime(
      _selectedMonth.year,
      _selectedMonth.month,
      _selectedMonth.day,
      _startTime!.hour,
      _startTime!.minute,
    );
    final DateTime selectedEndDate = DateTime(
      _selectedMonth.year,
      _selectedMonth.month,
      _selectedMonth.day,
      _endTime!.hour,
      _endTime!.minute,
    );

    if (selectedEndDate.isAtSameMomentAs(selectedStartDate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must differ from start time.')),
      );
      return;
    }

    final monthDates = _getMonthDates(_selectedMonth);
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
                Text("Creating monthly schedule..."),
              ],
            ),
          ),
        );
      },
    );

    try {
      final firestore = FirebaseFirestore.instance;
      
      // Create monthly schedule document
      final monthlyScheduleRef = firestore.collection('MonthlySchedules').doc();
      await monthlyScheduleRef.set({
        'month_year': DateFormat('yyyy-MM').format(_selectedMonth),
        'start_time': startStr,
        'end_time': endStr,
        'guard_ids': selectedGuardIds,
        'checkpoints': _selectedCheckpointIds,
        'created_at': FieldValue.serverTimestamp(),
        'schedule_type': 'monthly',
        'is_active': true,
      });

      // Create individual daily schedules for each day of the month (excluding past dates)
      WriteBatch batch = firestore.batch();
      final today = DateTime.now();
      final startOfToday = DateTime(today.year, today.month, today.day);
      
      for (final date in monthDates) {
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
            'parent_monthly_schedule_id': monthlyScheduleRef.id,
            'schedule_type': 'monthly',
          });
        }
      }
      await batch.commit();

      // Log the monthly schedule creation
      for (final guardId in selectedGuardIds) {
        final String guardName = _guardIdToName[guardId] ?? 'Unknown Security Guard';
        await AppLogger.log(
          type: 'Monthly Schedule',
          message: 'Created monthly schedule for security guard $guardName ($guardId)',
          userId: null,
          metadata: {
            'guard_id': guardId,
            'guard_name': guardName,
            'month_year': DateFormat('yyyy-MM').format(_selectedMonth),
            'start_time': startStr,
            'end_time': endStr,
            'checkpoints': _selectedCheckpointIds,
            'monthly_schedule_id': monthlyScheduleRef.id,
          },
        );
      }

      if (mounted) {
        Navigator.of(context).pop(); // Dismiss loading dialog
        
        // Count how many future dates were actually scheduled
        final futureDates = monthDates.where((date) => !date.isBefore(startOfToday)).length;
        final totalDates = monthDates.length;
        final skippedDates = totalDates - futureDates;
        
        String message = 'Monthly schedule created for ${selectedGuardIds.length} guard(s)';
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
          SnackBar(content: Text('Error creating monthly schedule: $e')),
        );
      }
      print("Error creating monthly schedule: $e");
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
    final monthDates = _getMonthDates(_selectedMonth);
    
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
                Text('Monthly Schedule Creation', 
                     style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 16),
                
                // Month Selection
                Text('Select Month:', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        DateFormat('MMMM yyyy').format(_selectedMonth),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1);
                        });
                      },
                      icon: const Icon(Icons.chevron_left),
                    ),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1);
                        });
                      },
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                
                // Month info display
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Month Info:', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Text('Days in month: ${monthDates.length}'),
                      Text('First day: ${DateFormat('MMM dd, yyyy').format(monthDates.first)}'),
                      Text('Last day: ${DateFormat('MMM dd, yyyy').format(monthDates.last)}'),
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
                              height: 200,
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
                          if (_isLoadingCheckpoints)
                            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
                          else
                            SizedBox(
                              height: 200,
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
                    onPressed: _createMonthlySchedule,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                      textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    child: const Text('Create Monthly Schedule'),
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
        title: const Text('Monthly Schedule'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      drawer: Drawer(child: nav),
      body: body,
    );
  }
}
