import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:thesis_web/main_screens/profile/profile_admin.dart';
import 'package:thesis_web/main_screens/scheduling/assign_schedule.dart';
import 'package:thesis_web/main_screens/scheduling/weekly_schedule_screen.dart';
import 'package:thesis_web/main_screens/scheduling/monthly_schedule_screen.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_list.dart';
import 'package:thesis_web/main_screens/security_guard_management/security_guard_schedules_list.dart';
import 'package:thesis_web/main_screens/security_guard_management/add_security_guard.dart';
import 'package:thesis_web/main_screens/reports/guard_list_report.dart';
import 'package:thesis_web/main_screens/reports/checkpoint_list_report.dart';
import 'package:thesis_web/main_screens/reports/schedule_checkpoint_summary_report.dart';
import 'package:thesis_web/main_screens/security_guard_management/guard_schedule_print.dart';
import 'package:thesis_web/main_screens/mapping/mapping_management.dart';
import 'package:thesis_web/main_screens/checkpoint_management/checkpoint_list.dart';
import 'package:thesis_web/main_screens/logs/transaction_logs.dart';
import 'package:thesis_web/main_screens/settings/manage_users.dart';
import 'package:thesis_web/main_screens/settings/restore_and_backup.dart';
import 'package:thesis_web/main_screens/dashboard/dashboard_screen.dart';

Widget _navSubItem(BuildContext context, String title, Widget Function() screenBuilder, {IconData? icon, required bool closeDrawer}) {
  final colorScheme = Theme.of(context).colorScheme;
  return ListTile(
    leading: icon != null ? Icon(icon, size: 20, color: colorScheme.onSurfaceVariant) : const SizedBox(width: 24),
    title: Text(title, style: TextStyle(fontSize: 14.5, color: colorScheme.onSurface)),
    contentPadding: const EdgeInsets.only(left: 40.0, right: 16.0),
    dense: true,
    onTap: () {
      if (closeDrawer) Navigator.pop(context);
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => screenBuilder()));
    },
  );
}

Widget appNavList(BuildContext context, {required bool closeDrawer}) {
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
                child: const Icon(Icons.security, size: 30, color: Colors.white),
              ),
              const SizedBox(height: 12),
              const Text('Security Dashboard', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              Text('Tour Patrol System', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
            ],
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.home_outlined),
        title: const Text('Home'),
        onTap: () {
          if (closeDrawer) Navigator.pop(context);
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const DashboardScreen()));
        },
      ),
      ListTile(
        leading: const Icon(Icons.person_outline),
        title: const Text('Profile'),
        onTap: () {
          if (closeDrawer) Navigator.pop(context);
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const ProfileAdminScreen()));
        },
      ),
      ExpansionTile(
        leading: const Icon(Icons.schedule_outlined),
        title: const Text('Schedule Management'),
        children: [
          _navSubItem(context, 'Daily Schedule', () => const AssignScheduleScreen(), icon: Icons.calendar_today, closeDrawer: closeDrawer),
          _navSubItem(context, 'Weekly Schedule', () => const WeeklyScheduleScreen(), icon: Icons.calendar_view_week, closeDrawer: closeDrawer),
          _navSubItem(context, 'Monthly Schedule', () => const MonthlyScheduleScreen(), icon: Icons.calendar_month, closeDrawer: closeDrawer),
        ],
      ),
      ExpansionTile(
        leading: const Icon(Icons.group_outlined),
        title: const Text('Security Guard Management'),
        children: [
          _navSubItem(context, 'Security Guard List', () => SecurityGuardListScreen(), closeDrawer: closeDrawer),
          _navSubItem(context, 'Security Guard Schedules List', () => const SecurityGuardSchedulesListScreen(), closeDrawer: closeDrawer),
          _navSubItem(context, 'Add Security Guard', () => const AddSecurityGuardScreen(), closeDrawer: closeDrawer),
        ],
      ),
      ExpansionTile(
        leading: const Icon(Icons.list_alt_outlined),
        title: const Text('Report Management'),
        children: [
          _navSubItem(context, 'Print Security Guard List', () => const GuardListReportScreen(), icon: Icons.people_outline, closeDrawer: closeDrawer),
          _navSubItem(context, 'Print Checkpoint List', () => const CheckpointListReportScreen(), icon: Icons.location_on_outlined, closeDrawer: closeDrawer),
          _navSubItem(context, 'Print Security Guard Schedules', () => const GuardSchedulePrintScreen(), icon: Icons.schedule_outlined, closeDrawer: closeDrawer),
          _navSubItem(context, 'Print Report Schedule Checkpoint Summary', () => const ScheduleCheckpointSummaryReportScreen(), icon: Icons.summarize_outlined, closeDrawer: closeDrawer),
        ],
      ),
      ExpansionTile(
        leading: const Icon(Icons.map_outlined),
        title: const Text('Mapping Management'),
        children: [
          _navSubItem(context, 'Open Map', () => const MappingManagementScreen(), closeDrawer: closeDrawer),
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
          _navSubItem(context, 'Manage Users', () => const ManageUsersPage(), icon: Icons.manage_accounts_outlined, closeDrawer: closeDrawer),
          _navSubItem(context, 'Backup and Restore', () => const BackupRestorePage(), icon: Icons.backup_outlined, closeDrawer: closeDrawer),
          _navSubItem(context, 'Transaction Logs', () => const TransactionLogsPage(), icon: Icons.list_alt_outlined, closeDrawer: closeDrawer),
        ],
      ),
      const Divider(),
      ListTile(
        leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
        title: Text('Logout', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        onTap: () async {
          await FirebaseAuth.instance.signOut();
          if (closeDrawer) Navigator.pop(context);
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




