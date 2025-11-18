import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class TransactionLogsPage extends StatelessWidget {
  const TransactionLogsPage({super.key});

  @override
  Widget build(BuildContext context) {
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
        title: const Text('Transaction Logs'),
      ),
      drawer: Drawer(child: nav),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('TransactionLogs')
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error loading logs: ${snapshot.error}'));
            }
            final rawDocs = snapshot.data?.docs ?? [];
            if (rawDocs.isEmpty) {
              return const Center(child: Text('No transaction logs available.'));
            }

            // Map and sort locally by timestamp/createdAt/created_at (Timestamp | String | int)
            final docs = [...rawDocs];
            docs.sort((a, b) {
              final aWhen = _safeParseWhen(a.data());
              final bWhen = _safeParseWhen(b.data());
              // Descending
              if (aWhen == null && bWhen == null) return 0;
              if (aWhen == null) return 1;
              if (bWhen == null) return -1;
              return bWhen.compareTo(aWhen);
            });
            // Limit after sorting for performance
            final limited = docs.take(300).toList();

            return ListView.separated(
              itemCount: limited.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final data = limited[index].data();
                final type = (data['type'] as String?) ?? 'General';
                final message = (data['message'] as String?) ?? (data['action'] as String?) ?? 'No details';
                final when = _safeParseWhen(data);
                final whenText = when != null ? _formatDateTime(when) : 'Unknown time';

                return ListTile(
                  leading: Icon(_getIconForType(type), color: _getIconColor(type)),
                  title: Text(message),
                  subtitle: Text(whenText),
                  trailing: Chip(
                    label: Text(type),
                    backgroundColor: _getColorForType(type),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
  DateTime? _safeParseWhen(Map<String, dynamic> data) {
    try {
      final dynamic rawTs = data['timestamp'] ?? data['createdAt'] ?? data['created_at'];
      if (rawTs is Timestamp) {
        return rawTs.toDate();
      } else if (rawTs is String) {
        try {
          return DateTime.parse(rawTs);
        } catch (_) {
          return null;
        }
      } else if (rawTs is int) {
        // Detect seconds vs millis by magnitude
        if (rawTs > 20000000000) {
          return DateTime.fromMillisecondsSinceEpoch(rawTs);
        } else {
          return DateTime.fromMillisecondsSinceEpoch(rawTs * 1000);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _formatDateTime(DateTime dt) {
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'Patrol':
        return Icons.security;
      case 'Login':
        return Icons.login;
      case 'Account':
      case 'UserAccount':
        return Icons.manage_accounts_outlined;
      case 'Report':
        return Icons.note_alt;
      case 'Schedule':
        return Icons.schedule_outlined;
      case 'Checkpoint':
        return Icons.place_outlined;
      case 'Backup':
        return Icons.backup_outlined;
      case 'Restore':
        return Icons.restore_outlined;
      default:
        return Icons.receipt_long;
    }
  }

  Color _getColorForType(String type) {
    switch (type) {
      case 'Patrol':
        return Colors.blue.shade100;
      case 'Login':
        return Colors.orange.shade100;
      case 'Account':
      case 'UserAccount':
        return Colors.green.shade100;
      case 'Report':
        return Colors.purple.shade100;
      case 'Schedule':
        return Colors.blueGrey.shade100;
      case 'Backup':
        return Colors.teal.shade100;
      case 'Restore':
        return Colors.amber.shade100;
      default:
        return Colors.grey.shade300;
    }
  }

  Color _getIconColor(String type) {
    switch (type) {
      case 'Schedule':
        return Colors.blueGrey;
      case 'UserAccount':
        return Colors.green;
      case 'Backup':
        return Colors.teal;
      case 'Restore':
        return Colors.orange;
      default:
        return Colors.grey.shade700;
    }
  }
}
