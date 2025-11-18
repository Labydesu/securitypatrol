import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class GuardStatusService {
  GuardStatusService._();

  static Future<void> updateStatusesNow() async {
    final firestore = FirebaseFirestore.instance;
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final currentMinutes = now.hour * 60 + now.minute;

    // Fetch all security guards (Accounts.role == Security)
    final guardsSnap = await firestore
        .collection('Accounts')
        .where('role', isEqualTo: 'Security')
        .get();

    if (guardsSnap.docs.isEmpty) return;

    // Fetch today's schedules
    final schedulesSnap = await firestore
        .collection('Schedules')
        .where('date', isEqualTo: todayStr)
        .get();

    final Map<String, List<Map<String, String>>> schedulesByGuardId = {};
    for (final d in schedulesSnap.docs) {
      final data = d.data();
      final guardId = (data['guard_id'] as String?)?.trim();
      final start = data['start_time'] as String?;
      final end = data['end_time'] as String?;
      if (guardId == null || guardId.isEmpty || start == null || end == null) continue;
      (schedulesByGuardId[guardId] ??= []).add({'start_time': start, 'end_time': end});
    }

    final batch = firestore.batch();
    for (final g in guardsSnap.docs) {
      final accountRef = g.reference;
      final data = g.data();
      final guardUserFacingId = (data['guard_id'] as String?)?.trim();
      String newStatus = 'Off Duty';
      if (guardUserFacingId != null && guardUserFacingId.isNotEmpty) {
        final guardSchedules = schedulesByGuardId[guardUserFacingId];
        if (guardSchedules != null && guardSchedules.isNotEmpty) {
          for (final sched in guardSchedules) {
            try {
              final s = sched['start_time']!;
              final e = sched['end_time']!;
              final partsS = s.split(':').map(int.parse).toList();
              final partsE = e.split(':').map(int.parse).toList();
              if (partsS.length != 2 || partsE.length != 2) continue;
              final startMinutes = partsS[0] * 60 + partsS[1];
              final endMinutes = partsE[0] * 60 + partsE[1];
              final overnight = endMinutes <= startMinutes;
              final withinSameDay = !overnight && currentMinutes >= startMinutes && currentMinutes < endMinutes;
              final withinOvernight = overnight && (currentMinutes >= startMinutes || currentMinutes < endMinutes);
              if (withinSameDay || withinOvernight) {
                newStatus = 'On Duty';
                break;
              }
            } catch (_) {}
          }
        }
      }
      batch.update(accountRef, {'status': newStatus});
    }

    await batch.commit();
  }
}


