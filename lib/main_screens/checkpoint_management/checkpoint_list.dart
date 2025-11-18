import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:thesis_web/main_screens/checkpoint_management/add_checkpoint.dart';
import 'package:thesis_web/main_screens/models/checkpoint_model.dart';
import 'package:thesis_web/services/app_logger.dart';
import 'package:thesis_web/widgets/app_nav.dart';


class CheckpointListScreen extends StatefulWidget {
  const CheckpointListScreen({super.key});

  @override
  State<CheckpointListScreen> createState() => _CheckpointListScreenState();
}

class _CheckpointListScreenState extends State<CheckpointListScreen> {
  String _searchQuery = '';
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Map<String, String?> _scannerCache = {};
  final Map<String, String?> _guardNameCache = {};

  Future<String?> _resolveGuardNameFromId(String? guardId) async {
    if (guardId == null || guardId.isEmpty) return null;
    if (_guardNameCache.containsKey(guardId)) return _guardNameCache[guardId];
    try {
      // Guards are stored in Accounts with field guard_id
      final snap = await _firestore
          .collection('Accounts')
          .where('guard_id', isEqualTo: guardId)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) {
        _guardNameCache[guardId] = null;
        return null;
      }
      final data = snap.docs.first.data();
      final first = (data['first_name'] as String?) ?? '';
      final last = (data['last_name'] as String?) ?? '';
      final fallback = (data['name'] as String?) ?? '';
      final name = ('$first $last').trim().isNotEmpty ? ('$first $last').trim() : (fallback.isNotEmpty ? fallback : null);
      _guardNameCache[guardId] = name;
      return name;
    } catch (_) {
      _guardNameCache[guardId] = null;
      return null;
    }
  }

  int _extractMillis(Map<String, dynamic> m) {
    try {
      final sa = m['scannedAt'];
      final ts = m['timestamp'];
      final ca = m['createdAt'];
      DateTime? d;
      if (sa is Timestamp) d = sa.toDate();
      d ??= (ts is Timestamp) ? ts.toDate() : null;
      d ??= (ca is Timestamp) ? ca.toDate() : null;
      return d?.millisecondsSinceEpoch ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<String?> _fetchLatestScannerFromCheckpointScans(String checkpointId) async {
    if (_scannerCache.containsKey('CS::$checkpointId')) {
      return _scannerCache['CS::$checkpointId'];
    }
    try {
      Query<Map<String, dynamic>> base = _firestore
          .collection('CheckpointScans')
          .where('checkpointId', isEqualTo: checkpointId);
      QuerySnapshot<Map<String, dynamic>> snap;
      try {
        snap = await base.orderBy('scannedAt', descending: true).limit(1).get();
      } catch (_) {
        try {
          snap = await base.orderBy('timestamp', descending: true).limit(1).get();
        } catch (_) {
          try {
            snap = await base.orderBy('createdAt', descending: true).limit(1).get();
          } catch (_) {
            // Fallback: no composite index available; fetch and pick latest client-side
            final noOrder = await base.get();
            if (noOrder.docs.isEmpty) {
              snap = noOrder; // remain empty
            } else {
              QueryDocumentSnapshot<Map<String, dynamic>> latest = noOrder.docs.first;
              int best = _extractMillis(latest.data());
              for (final d in noOrder.docs.skip(1)) {
                final ms = _extractMillis(d.data());
                if (ms > best) {
                  best = ms;
                  latest = d;
                }
              }
              // Directly compute and return from latest
              final data = latest.data();
              String? name = (data['guardName'] ?? data['securityGuardName'] ?? data['scannedByName'] ?? data['scannerName'] ?? data['guard_name'])?.toString();
              if (name == null || name.isEmpty) {
                final guardId = (data['guardId'] ?? data['guard_id'] ?? data['securityGuardId'] ?? data['scannerId'] ?? data['uid'])?.toString();
                name = await _resolveGuardNameFromId(guardId);
              }
              _scannerCache['CS::$checkpointId'] = name;
              return name;
            }
          }
        }
      }
      if (snap.docs.isEmpty) {
        // try alt key name for checkpoint id
        Query<Map<String, dynamic>> altBase = _firestore
            .collection('CheckpointScans')
            .where('checkpoint_id', isEqualTo: checkpointId);
        try {
          snap = await altBase.orderBy('scannedAt', descending: true).limit(1).get();
        } catch (_) {
          try {
            snap = await altBase.orderBy('timestamp', descending: true).limit(1).get();
          } catch (_) {
            snap = await altBase.orderBy('createdAt', descending: true).limit(1).get();
          }
        }
      }

      if (snap.docs.isEmpty) {
        _scannerCache['CS::$checkpointId'] = null;
        return null;
      }
      final data = snap.docs.first.data();
      String? name = (data['guardName'] ??
              data['securityGuardName'] ??
              data['scannedByName'] ??
              data['scannerName'] ??
              data['guard_name'])
          ?.toString();
      if (name == null || name.isEmpty) {
        final guardId = (data['guardId'] ?? data['guard_id'] ?? data['securityGuardId'] ?? data['scannerId'] ?? data['uid'])?.toString();
        name = await _resolveGuardNameFromId(guardId);
      }
      _scannerCache['CS::$checkpointId'] = name;
      return name;
    } catch (_) {
      _scannerCache['CS::$checkpointId'] = null;
      return null;
    }
  }

  Future<String?> _fetchLatestScannerFromSchedules(String checkpointId) async {
    if (_scannerCache.containsKey(checkpointId)) {
      return _scannerCache[checkpointId];
    }
    try {
      // Prefer TransactionLogs as source of scan events
      final query = await _firestore
          .collection('TransactionLogs')
          .where('checkpointId', isEqualTo: checkpointId)
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();
      if (query.docs.isEmpty) {
        // try alternate key names
        final alt = await _firestore
            .collection('TransactionLogs')
            .where('checkpoint_id', isEqualTo: checkpointId)
            .orderBy('timestamp', descending: true)
            .limit(1)
            .get();
        if (alt.docs.isEmpty) {
          // Last fallback: use createdAt if timestamp missing
          final alt2 = await _firestore
              .collection('TransactionLogs')
              .where('checkpointId', isEqualTo: checkpointId)
              .orderBy('createdAt', descending: true)
              .limit(1)
              .get();
          if (alt2.docs.isEmpty) {
            _scannerCache[checkpointId] = null;
            return null;
          } else {
            final data = alt2.docs.first.data();
            final name = (data['guardName'] ?? data['securityGuardName'] ?? data['scannedByName'] ?? data['scannerName'] ?? data['guard_name'])?.toString();
            _scannerCache[checkpointId] = name;
            return name;
          }
        } else {
          final data = alt.docs.first.data();
          final name = (data['guardName'] ?? data['securityGuardName'] ?? data['scannedByName'] ?? data['scannerName'] ?? data['guard_name'])?.toString();
          _scannerCache[checkpointId] = name;
          return name;
        }
      }
      final data = query.docs.first.data();
      final name = (data['guardName'] ?? data['securityGuardName'] ?? data['scannedByName'] ?? data['scannerName'] ?? data['guard_name'])?.toString();
      _scannerCache[checkpointId] = name;
      return name;
    } catch (e) {
      try {
        // fallback: order by createdAt if timestamp missing
        final query = await _firestore
            .collection('TransactionLogs')
            .where('checkpointId', isEqualTo: checkpointId)
            .orderBy('createdAt', descending: true)
            .limit(1)
            .get();
        if (query.docs.isEmpty) {
          _scannerCache[checkpointId] = null;
          return null;
        }
        final data = query.docs.first.data();
        final name = (data['guardName'] ?? data['securityGuardName'] ?? data['scannedByName'] ?? data['scannerName'] ?? data['guard_name'])?.toString();
        _scannerCache[checkpointId] = name;
        return name;
      } catch (_) {
        _scannerCache[checkpointId] = null;
        return null;
      }
    }
  }

  Future<void> _deleteCheckpoint(String id, String name) async {
    bool? confirmDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Deletion'),
        content: Text('Are you sure you want to delete checkpoint "$name"? This action cannot be undone.'),
        actions: <Widget>[
          TextButton(
            child: const Text('Cancel'),
            onPressed: () {
              Navigator.of(ctx).pop(false);
            },
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
            onPressed: () {
              Navigator.of(ctx).pop(true);
            },
          ),
        ],
      ),
    );

    if (confirmDelete == true) {
      try {
        await _firestore.collection('Checkpoints').doc(id).delete();
        await AppLogger.log(
          type: 'Checkpoint',
          message: 'Checkpoint deleted',
          metadata: {'checkpointId': id, 'name': name},
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Checkpoint "$name" deleted successfully.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting checkpoint: $e')),
          );
        }
        debugPrint("Error deleting checkpoint: $e");
      }
    }
  }

  void _navigateToEditScreen(CheckpointModel checkpoint) async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AddCheckpointScreen(checkpointToEdit: checkpoint),
      ),
    );
    if (result == true && mounted) {
    }
  }

  void _navigateToCreateScreen() async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const AddCheckpointScreen()),
    );
    if (result == true && mounted) {
    }
  }

  Widget _buildCheckpointCard(CheckpointModel cp) {
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: cp.status == CheckpointScanStatus.scanned 
                                ? Colors.green.shade100 
                                : Colors.orange.shade100,
                            child: Icon(
                              cp.status == CheckpointScanStatus.scanned 
                                  ? Icons.check_circle_outline 
                                  : Icons.location_city_outlined,
                              color: cp.status == CheckpointScanStatus.scanned 
                                  ? Colors.green.shade700 
                                  : Colors.orange.shade700,
                            ),
                          ),
        title: Text(cp.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('ID: ${cp.id}'),
                              Text('Location: ${cp.location}'),
                              if (cp.status == CheckpointScanStatus.scanned)
                                FutureBuilder<String?>(
                                  future: () async {
                                    final direct = cp.lastScannedByName ?? cp.lastScannedById;
                                    if (direct != null && direct.isNotEmpty) return direct;
                                    final cs = await _fetchLatestScannerFromCheckpointScans(cp.id);
                                    if (cs != null && cs.isNotEmpty) return cs;
                                    return _fetchLatestScannerFromSchedules(cp.id);
                                  }(),
                                  builder: (context, snap) {
                                    final name = snap.data;
                                    return Text(
                                      'Inspected by: ${name ?? 'Unknown'}',
                                      style: TextStyle(color: Colors.grey.shade700),
                                    );
                                  },
                                ),
                            ],
                          ),
                          isThreeLine: false,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (cp.notes != null && cp.notes!.isNotEmpty)
                                Tooltip(
                                  message: cp.notes!,
                                  child: Icon(Icons.comment_outlined, color: Colors.grey.shade600),
                                ),
                              IconButton(
                                icon: Icon(Icons.edit_note_outlined, color: Theme.of(context).colorScheme.primary),
                                onPressed: () {
                                  _navigateToEditScreen(cp);
                                },
                                tooltip: 'Edit Checkpoint',
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                                onPressed: () {
                                  _deleteCheckpoint(cp.id, cp.name);
                                },
                                tooltip: 'Delete Checkpoint',
                              ),
                            ],
                          ),
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text(cp.name),
                                content: SingleChildScrollView(
                                  child: ListBody(
                                    children: <Widget>[
                                      SelectableText('ID: ${cp.id}'),
                                      SelectableText('Location: ${cp.location}'),
                                      SelectableText('Notes: ${cp.notes != null && cp.notes!.isNotEmpty ? cp.notes! : 'N/A'}'),
                                      SelectableText('Remarks: ${cp.remarks != null && cp.remarks!.isNotEmpty ? cp.remarks! : 'N/A'}'),
                                      SelectableText('Status: ${checkpointScanStatusToString(cp.status)}'),
                                      SelectableText(
                                        'Created: ${DateFormat.yMd().add_jm().format(cp.createdAt.toDate())}',
                                      ),
                                      if (cp.lastAdminUpdate != null)
                                        SelectableText(
                                          'Last Updated: ${DateFormat.yMd().add_jm().format(cp.lastAdminUpdate!.toDate())}',
                                        ),
                                      if (cp.lastScannedAt != null)
                                        SelectableText(
                                          'Last Scanned: ${DateFormat.yMd().add_jm().format(cp.lastScannedAt!.toDate())}',
                                        ),
                                      // Inspected by (resolve from latest scan if needed)
                                      FutureBuilder<String?>(
                                        future: () async {
                                          final direct = cp.lastScannedByName ?? cp.lastScannedById;
                                          if (direct != null && direct.isNotEmpty) return direct;
                                          final cs = await _fetchLatestScannerFromCheckpointScans(cp.id);
                                          if (cs != null && cs.isNotEmpty) return cs;
                                          return _fetchLatestScannerFromSchedules(cp.id);
                                        }(),
                                        builder: (context, snap) {
                                          final name = snap.data;
                                          return SelectableText('Inspected by: ${name ?? 'Unknown'}');
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                actions: <Widget>[
                                  TextButton(
                                    child: const Text('Close'),
                                    onPressed: () {
                                      Navigator.of(ctx).pop();
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      );
  }

  @override
  Widget build(BuildContext context) {
    final nav = appNavList(context, closeDrawer: true);
    final body = Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              onChanged: (val) {
                setState(() {
                  _searchQuery = val.toLowerCase();
                });
              },
              decoration: InputDecoration(
                hintText: 'Search checkpoint by name...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _firestore.collection('Checkpoints').orderBy('createdAt', descending: true).snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return const Center(child: Text('No checkpoints found. Add one to get started!'));
                  }
                  if (snapshot.hasError) {
                    debugPrint("Error fetching checkpoints: ${snapshot.error}");
                    return Center(child: Text('Error loading checkpoints: ${snapshot.error}'));
                  }

                  List<CheckpointModel> allCheckpoints = snapshot.data!.docs
                      .map((doc) {
                        final checkpoint = CheckpointModel.fromFirestore(doc);
                        print("OVERVIEW: Checkpoint ${checkpoint.id} (${checkpoint.name}) -> Status: ${checkpoint.status == CheckpointScanStatus.scanned ? 'SCANNED' : 'NOT_SCANNED'}");
                        return checkpoint;
                      })
                      .toList();

                  final List<CheckpointModel> filteredCheckpoints = allCheckpoints.where((cp) {
                    return cp.name.toLowerCase().contains(_searchQuery) ||
                        cp.id.toLowerCase().contains(_searchQuery) ||
                        cp.location.toLowerCase().contains(_searchQuery);
                  }).toList();

                  if (filteredCheckpoints.isEmpty && _searchQuery.isNotEmpty) {
                    return const Center(child: Text('No checkpoints match your search.'));
                  } else if (filteredCheckpoints.isEmpty) {
                    return const Center(child: Text('No checkpoints available.'));
                  }

                  // Separate checkpoints by status
                  final List<CheckpointModel> inspectedCheckpoints = filteredCheckpoints
                      .where((cp) => cp.status == CheckpointScanStatus.scanned)
                      .toList();
                  final List<CheckpointModel> notInspectedCheckpoints = filteredCheckpoints
                      .where((cp) => cp.status != CheckpointScanStatus.scanned)
                      .toList();

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Not Yet Inspected Column
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade100,
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(12),
                                  topRight: Radius.circular(12),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.location_city_outlined, color: Colors.orange.shade800, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Not Yet Inspected (${notInspectedCheckpoints.length})',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.orange.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: notInspectedCheckpoints.isEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(16.0),
                                        child: Text(
                                          'No uninspected checkpoints',
                                          style: TextStyle(color: Colors.grey.shade600),
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: notInspectedCheckpoints.length,
                                      itemBuilder: (context, index) {
                                        return _buildCheckpointCard(notInspectedCheckpoints[index]);
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Inspected Column
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.green.shade100,
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(12),
                                  topRight: Radius.circular(12),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.check_circle_outline, color: Colors.green.shade800, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Inspected (${inspectedCheckpoints.length})',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.green.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: inspectedCheckpoints.isEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(16.0),
                                        child: Text(
                                          'No inspected checkpoints',
                                          style: TextStyle(color: Colors.grey.shade600),
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: inspectedCheckpoints.length,
                                      itemBuilder: (context, index) {
                                        return _buildCheckpointCard(inspectedCheckpoints[index]);
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Checkpoint List'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              onPressed: _navigateToCreateScreen,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Add Checkpoint'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.onPrimary,
                foregroundColor: colorScheme.primary,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
      drawer: Drawer(child: nav),
      body: body,
    );
  }
}