import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'security_guard_overview.dart';

class SecurityGuardSchedulesListScreen extends StatelessWidget {
  const SecurityGuardSchedulesListScreen({super.key});

  Stream<List<Map<String, dynamic>>> _onDutyGuardsStream() {
    final firestore = FirebaseFirestore.instance;
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    // Stream on-duty guards; enrich with today's schedule (if any)
    return firestore
        .collection('Accounts')
        .where('role', isEqualTo: 'Security')
        .where('status', isEqualTo: 'On Duty')
        .snapshots()
        .asyncMap((snapshot) async {
      final List<Map<String, dynamic>> results = [];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        data['id'] = doc.id;
        final guardId = data['guard_id'] as String?;
        String? start;
        String? end;
        if (guardId != null && guardId.isNotEmpty) {
          try {
            final schedSnap = await firestore
                .collection('Schedules')
                .where('guard_id', isEqualTo: guardId)
                .where('date', isEqualTo: todayStr)
                .orderBy('start_time')
                .limit(1)
                .get();
            if (schedSnap.docs.isNotEmpty) {
              final s = schedSnap.docs.first.data();
              start = s['start_time'] as String?;
              end = s['end_time'] as String?;
            }
          } catch (_) {}
        }
        results.add({
          ...data,
          'today_start_time': start,
          'today_end_time': end,
        });
      }
      return results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Security Guard Schedules'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _onDutyGuardsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final guards = snapshot.data ?? [];
          if (guards.isEmpty) {
            return const Center(child: Text('No security guards are currently On Duty.'));
          }
          return ListView.builder(
            itemCount: guards.length,
            itemBuilder: (context, index) {
              final g = guards[index];
              final fullName =
                  '${(g['first_name'] as String?) ?? 'N/A'} ${(g['last_name'] as String?) ?? ''}'.trim();
              final pos = (g['position'] as String?) ?? 'N/A';
              final guardDisplayId = (g['guard_id'] as String?) ?? 'N/A';
              final shift = (g['today_start_time'] != null && g['today_end_time'] != null)
                  ? '${g['today_start_time']} - ${g['today_end_time']}'
                  : 'Today: N/A';
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: ListTile(
                  leading: const Icon(Icons.security_rounded),
                  title: Text(fullName.isEmpty ? 'Unnamed Guard' : fullName,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('Position: $pos\nID: $guardDisplayId\n$shift'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SecurityGuardOverviewScreen(guardData: g),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}













