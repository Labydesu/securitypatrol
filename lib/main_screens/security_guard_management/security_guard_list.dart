import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_overview.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:thesis_web/main_screens/security_guard_management/add_edit_guard_screen.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class SecurityGuardListScreen extends StatefulWidget {
  const SecurityGuardListScreen({super.key});

  @override
  State<SecurityGuardListScreen> createState() => _SecurityGuardListScreenState();
}

class _SecurityGuardListScreenState extends State<SecurityGuardListScreen> {
  List<Map<String, dynamic>> _allGuards = [];
  List<Map<String, dynamic>> _filteredGuards = [];
  final TextEditingController _searchController = TextEditingController();
  Timer? _statusUpdateTimer;
  bool _isLoading = true;
  String _errorMessage = '';
  StreamSubscription<QuerySnapshot>? _schedulesSubscription;

  @override
  void initState() {
    super.initState();
    _fetchGuardsAndSetupUpdates();
    _searchController.addListener(_onSearchChanged);
    _setupSchedulesListener();
  }

  void _setupSchedulesListener() {
    _schedulesSubscription = FirebaseFirestore.instance
        .collection('Schedules')
        .snapshots()
        .listen((snapshot) {
      if (mounted && _allGuards.isNotEmpty) {
        _updateStatusesBasedOnSchedule();
      }
    });
  }

  void _onSearchChanged() {
    _filterSearch();
  }

  Future<void> _fetchGuardsAndSetupUpdates() async {
    await _fetchGuards();
    if (_errorMessage.isEmpty && mounted) {
      _updateStatusesBasedOnSchedule();
      _statusUpdateTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
        if (mounted) {
          _updateStatusesBasedOnSchedule();
        } else {
          timer.cancel();
        }
      });
    }
  }

  Future<void> _fetchGuards() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('Accounts')
          .where('role', isEqualTo: 'Security')
          .get();

      final guards = snapshot.docs.map((doc) {
        final data = doc.data();
        data['status'] = data['status'] as String? ?? 'Off Duty';
        return {
          'id': doc.id,
          ...data,
        };
      }).toList();

      if (mounted) {
        setState(() {
          _allGuards = guards;
          _filterSearch();
          _isLoading = false;
        });
      }
    } catch (e) {
      print("Error fetching guards: $e");
      if (mounted) {
        setState(() {
          _errorMessage = 'Error fetching guards: $e';
          _isLoading = false;
          _allGuards = [];
          _filteredGuards = [];
        });
        _showErrorSnackbar(_errorMessage);
      }
    }
  }

  void _filterSearch() {
    if (!mounted) return;
    final query = _searchController.text.toLowerCase().trim();
    setState(() {
      if (query.isEmpty) {
        _filteredGuards = List.from(_allGuards);
      } else {
        _filteredGuards = _allGuards.where((guard) {
          final fullName =
          '${guard['first_name'] as String? ?? ''} ${guard['last_name'] as String? ?? ''}'
              .toLowerCase()
              .trim();
          final guardDocumentId = (guard['id'] as String? ?? '').toLowerCase();
          final userFacingGuardId = (guard['guard_id'] as String? ?? '').toLowerCase();

          return fullName.contains(query) ||
              guardDocumentId.contains(query) ||
              userFacingGuardId.contains(query);
        }).toList();
      }
    });
  }

  Future<void> _updateStatusesBasedOnSchedule() async {
    if (_allGuards.isEmpty || !mounted) return;

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final currentMinutes = now.hour * 60 + now.minute;

    try {
      final scheduleSnapshot = await FirebaseFirestore.instance
          .collection('Schedules')
          .where('date', isEqualTo: todayStr)
          .get();

      if (!mounted) return;

      final schedulesByGuardId = <String, List<Map<String, dynamic>>>{};
      for (var doc in scheduleSnapshot.docs) {
        final data = doc.data();
        final guardId = data['guard_id'] as String?;
        if (guardId != null) {
          schedulesByGuardId.putIfAbsent(guardId, () => []).add({
            'start_time': data['start_time'] as String?,
            'end_time': data['end_time'] as String?,
          });
        }
      }

      WriteBatch batch = FirebaseFirestore.instance.batch();
      bool needsFirestoreUpdate = false;
      List<Map<String, dynamic>> updatedGuardsList = List.from(_allGuards);

      for (int i = 0; i < updatedGuardsList.length; i++) {
        final guard = updatedGuardsList[i];
        final guardDocumentId = guard['id'] as String;
        final String? guardUserFacingId = guard['guard_id'] as String?;
        final currentStatus = guard['status'] as String?;
        String newStatus = 'Off Duty';

        // Match schedules using the user-facing guard_id, not the document ID.
        final guardSchedules = guardUserFacingId != null && guardUserFacingId.isNotEmpty
            ? schedulesByGuardId[guardUserFacingId]
            : null;

        if (guardSchedules != null && guardSchedules.isNotEmpty) {
          for (var sched in guardSchedules) {
            final startTimeStr = sched['start_time'];
            final endTimeStr = sched['end_time'];

            if (startTimeStr != null && endTimeStr != null) {
              try {
                final startParts = startTimeStr.split(':').map(int.parse).toList();
                final endParts = endTimeStr.split(':').map(int.parse).toList();

                if (startParts.length == 2 && endParts.length == 2) {
                  final startMinutes = startParts[0] * 60 + startParts[1];
                  final endMinutes = endParts[0] * 60 + endParts[1];

                  // Handle both same-day and overnight shifts (end < start)
                  final bool isOvernight = endMinutes <= startMinutes;
                  final bool isWithinSameDay = !isOvernight &&
                      currentMinutes >= startMinutes && currentMinutes < endMinutes;
                  final bool isWithinOvernight = isOvernight &&
                      (currentMinutes >= startMinutes || currentMinutes < endMinutes);

                  if (isWithinSameDay || isWithinOvernight) {
                    newStatus = 'On Duty';
                    break;
                  }
                } else {
                  print("Warning: Invalid time format for guard $guardDocumentId on $todayStr. Start: $startTimeStr, End: $endTimeStr");
                }
              } catch (e) {
                print("Error parsing time for guard $guardDocumentId schedule: $e. Start: $startTimeStr, End: $endTimeStr");
              }
            }
          }
        }

        if (currentStatus != newStatus) {
          DocumentReference guardRef = FirebaseFirestore.instance.collection('Accounts').doc(guardDocumentId);
          batch.update(guardRef, {'status': newStatus});
          updatedGuardsList[i] = {...guard, 'status': newStatus};
          needsFirestoreUpdate = true;
        }
      }

      if (needsFirestoreUpdate) {
        await batch.commit();
        if (mounted) {
          setState(() {
            _allGuards = updatedGuardsList;
            _filterSearch();
          });
        }
      }
    } catch (e) {
      print("Error in _updateStatusesBasedOnSchedule: $e");
      if (mounted) {
        _showErrorSnackbar('Error updating statuses silently: $e');
      }
    }
  }

  void _showErrorSnackbar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _navigateToEditGuardScreen(Map<String, dynamic> guardData) {
    final String guardDocumentId = guardData['id'] as String;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddEditGuardScreen(
          guardDocumentId: guardDocumentId,
          initialData: guardData,
        ),
      ),
    ).then((result) {
      if (result == true && mounted) {
        _fetchGuards();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Guard details processed successfully!')),
        );
      }
    });
  }

  Future<void> _deleteGuard(String guardDocumentId, String guardName) async {
    if (!mounted) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Delete Guard: $guardName'),
          content: const Text('Are you sure you want to delete this guard? This action cannot be undone.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop(false);
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      setState(() {
        _isLoading = true;
      });
      try {
        await FirebaseFirestore.instance.collection('Accounts').doc(guardDocumentId).delete();

        if (mounted) {
          _allGuards.removeWhere((guard) => guard['id'] == guardDocumentId);
          _filterSearch();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Guard "$guardName" deleted successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          _showErrorSnackbar('Error deleting guard "$guardName": $e');
        }
        print('Error deleting guard $guardDocumentId: $e');
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  void _showNotImplementedDialog(String action, String content) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(action),
        content: Text(content),
        actions: [
          TextButton(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          )
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _statusUpdateTimer?.cancel();
    _schedulesSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        title: const Text('Security Guard Management'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
      ),
      drawer: Drawer(child: nav),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by Name or Guard ID',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: theme.colorScheme.outline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                  },
                )
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _buildBody(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage.isNotEmpty && _allGuards.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 48),
            const SizedBox(height: 16),
            Text(
              'Failed to load guards.',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: _fetchGuardsAndSetupUpdates,
            ),
          ],
        ),
      );
    }

    if (_allGuards.isEmpty) {
      return Center(
        child: Text(
          'No security guards found.',
          style: theme.textTheme.titleMedium,
        ),
      );
    }

    if (_filteredGuards.isEmpty && _searchController.text.isNotEmpty) {
      return Center(
        child: Text(
          'No guards match your search for "${_searchController.text}".',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await _fetchGuards();
        if (_errorMessage.isEmpty && mounted) {
          await _updateStatusesBasedOnSchedule();
        }
      },
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: MediaQuery.of(context).size.width - 32, // Account for padding
            ),
            child: DataTable(
              headingRowHeight: 56,
              dataRowMinHeight: 64,
              dataRowMaxHeight: 72,
              columnSpacing: 0,
              horizontalMargin: 24,
            columns: [
              DataColumn(
                label: SizedBox(
                  width: (MediaQuery.of(context).size.width - 100) / 5, // Equal width for each column
                  child: const Text(
                    'Name',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              DataColumn(
                label: SizedBox(
                  width: (MediaQuery.of(context).size.width - 100) / 5,
                  child: const Text(
                    'Guard ID',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              DataColumn(
                label: SizedBox(
                  width: (MediaQuery.of(context).size.width - 100) / 5,
                  child: const Text(
                    'Position',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              DataColumn(
                label: SizedBox(
                  width: (MediaQuery.of(context).size.width - 100) / 5,
                  child: const Text(
                    'Status',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              DataColumn(
                label: SizedBox(
                  width: (MediaQuery.of(context).size.width - 100) / 5,
                  child: const Text(
                    'Actions',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
            rows: _filteredGuards.map((guard) {
              final fullName = '${guard['first_name'] as String? ?? 'N/A'} ${guard['last_name'] as String? ?? ''}'.trim();
              final status = guard['status'] as String? ?? 'Unknown';
              final guardDisplayId = guard['guard_id'] as String? ?? 'N/A';
              final guardDocumentId = guard['id'] as String;
              final position = guard['position'] as String? ?? 'Security Guard';
              final columnWidth = (MediaQuery.of(context).size.width - 100) / 5;

              final bool isOnDuty = status == 'On Duty';
              final statusColor = isOnDuty ? Colors.green.shade700 : Colors.red.shade700;

              return DataRow(
                cells: [
                  DataCell(
                    SizedBox(
                      width: columnWidth,
                      child: Row(
                        children: [
                          Icon(
                            Icons.security_rounded,
                            color: statusColor,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              fullName.isEmpty ? 'Unnamed Guard' : fullName,
                              style: const TextStyle(fontWeight: FontWeight.w500),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: columnWidth,
                      child: Text(
                        guardDisplayId,
                        style: const TextStyle(fontFamily: 'monospace'),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: columnWidth,
                      child: Text(
                        position,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: columnWidth,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: statusColor.withOpacity(0.3)),
                          ),
                          child: Text(
                            status,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: columnWidth,
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit, color: Colors.orange.shade700),
                              onPressed: () => _navigateToEditGuardScreen(guard),
                              tooltip: 'Edit Guard',
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              padding: EdgeInsets.zero,
                            ),
                            IconButton(
                              icon: Icon(Icons.delete, color: Colors.red.shade700),
                              onPressed: () => _deleteGuard(guardDocumentId, fullName.isEmpty ? guardDisplayId : fullName),
                              tooltip: 'Delete Guard',
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}
