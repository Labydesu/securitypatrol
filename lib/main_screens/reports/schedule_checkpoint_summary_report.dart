import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:thesis_web/utils/download_saver.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const PdfPageFormat _longBondPageFormat = PdfPageFormat(
  8.5 * PdfPageFormat.inch,
  13 * PdfPageFormat.inch,
);

class ScheduleCheckpointSummaryReportScreen extends StatefulWidget {
  const ScheduleCheckpointSummaryReportScreen({super.key});

  @override
  State<ScheduleCheckpointSummaryReportScreen> createState() => _ScheduleCheckpointSummaryReportScreenState();
}

class _ScheduleCheckpointSummaryReportScreenState extends State<ScheduleCheckpointSummaryReportScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _selectedGuardId;
  String? _selectedGuardName;

  String _periodType = 'Monthly';
  DateTime _anchorDate = DateTime.now();
  String _scheduleType = 'All Schedules';

  List<Map<String, String>> _guards = const [];

  @override
  void initState() {
    super.initState();
    _fetchGuards();
  }

  Future<void> _fetchGuards() async {
    try {
      final guards = await _loadGuards();
      setState(() {
        _guards = guards;
        if (_guards.isNotEmpty && _selectedGuardId == null) {
          _selectedGuardId = _guards.first['id'];
          _selectedGuardName = _guards.first['name'];
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading guards: $e')));
      }
    }
  }

  Future<List<Map<String, String>>> _loadGuards() async {
    final guardsQuery = await _firestore
        .collection('Accounts')
        .where('role', isEqualTo: 'Security')
        .get();

    final guards = guardsQuery.docs.map((doc) {
      final data = doc.data();
      final guardId = (data['guard_id'] as String?) ?? doc.id;
      final firstName = data['first_name'] as String? ?? '';
      final lastName = data['last_name'] as String? ?? '';
      final name = ('$firstName $lastName').trim().isEmpty
          ? (data['name'] as String?) ?? 'Unnamed Guard'
          : ('$firstName $lastName').trim();
      return {
        'id': guardId,
        'name': name,
      };
    }).toList();

    guards.sort((a, b) => a['name']!.compareTo(b['name']!));
    return guards;
  }

  Stream<List<Map<String, dynamic>>> _scheduleStream() {
    if (_selectedGuardId == null) {
      return const Stream<List<Map<String, dynamic>>>.empty();
    }

    late final DateTime start;
    late final DateTime end;

    if (_periodType == 'Monthly') {
      start = DateTime(_anchorDate.year, _anchorDate.month, 1);
      end = DateTime(_anchorDate.year, _anchorDate.month + 1, 0);
    } else {
      final weekday = _anchorDate.weekday;
      start = _anchorDate.subtract(Duration(days: weekday - 1));
      end = start.add(const Duration(days: 6));
    }

    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);

    if (_scheduleType == 'All Schedules') {
      return _getCombinedSchedulesStream(startStr, endStr);
    } else {
      String collectionName = _scheduleType == 'Ended Schedules' ? 'EndedSchedules' : 'Schedules';
      return _firestore
          .collection(collectionName)
          .where('guard_id', isEqualTo: _selectedGuardId)
          .snapshots()
          .asyncMap((snap) async {
        final list = await _processScheduleDocuments(snap.docs, startStr, endStr);
        list.sort((a, b) {
          final dc = (a['date'] as String).compareTo(b['date'] as String);
          if (dc != 0) return dc;
          return (a['start_time'] as String).compareTo(b['start_time'] as String);
        });
        return list;
      });
    }
  }

  Stream<List<Map<String, dynamic>>> _getCombinedSchedulesStream(String startStr, String endStr) {
    final endedStream = _firestore
        .collection('EndedSchedules')
        .where('guard_id', isEqualTo: _selectedGuardId)
        .snapshots();

    final upcomingStream = _firestore
        .collection('Schedules')
        .where('guard_id', isEqualTo: _selectedGuardId)
        .snapshots();

    return endedStream.asyncMap((endedSnap) async {
      final upcomingSnap = await upcomingStream.first;
      final endedSchedules = await _processScheduleDocuments(endedSnap.docs, startStr, endStr);
      final upcomingSchedules = await _processScheduleDocuments(upcomingSnap.docs, startStr, endStr);

      final allSchedules = [...endedSchedules, ...upcomingSchedules];
      allSchedules.sort((a, b) {
        final dateCompare = (a['date'] as String).compareTo(b['date'] as String);
        if (dateCompare != 0) return dateCompare;
        return (a['start_time'] as String).compareTo(b['start_time'] as String);
      });
      return allSchedules;
    });
  }


  void _changeMonth(int delta) {
    setState(() {
      _anchorDate = DateTime(_anchorDate.year, _anchorDate.month + delta, 1);
    });
  }

  void _changeWeek(int delta) {
    setState(() {
      _anchorDate = _anchorDate.add(Duration(days: 7 * delta));
    });
  }

  Future<void> _printSchedule() async {
    if (_selectedGuardId == null || _selectedGuardName == null) return;

    try {
      final scheduleData = await _getScheduleDataForPrint();
      if (!mounted) return;

      if (scheduleData.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No schedule data to print')));
        return;
      }
      final reportText = _generateTextReport(scheduleData);
      _showReportDialog(reportText);

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error generating report: $e')));
      }
    }
  }

  Future<List<Map<String, dynamic>>> _getScheduleDataForPrint() async {
    if (_selectedGuardId == null) return [];

    late final DateTime start;
    late final DateTime end;

    if (_periodType == 'Monthly') {
      start = DateTime(_anchorDate.year, _anchorDate.month, 1);
      end = DateTime(_anchorDate.year, _anchorDate.month + 1, 0);
    } else {
      final weekday = _anchorDate.weekday;
      start = _anchorDate.subtract(Duration(days: weekday - 1));
      end = start.add(const Duration(days: 6));
    }

    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);

    List<Map<String, dynamic>> allSchedules = [];

    if (_scheduleType == 'All Schedules' || _scheduleType == 'Ended Schedules') {
      final snap = await _firestore.collection('EndedSchedules').where('guard_id', isEqualTo: _selectedGuardId).get();
      allSchedules.addAll(await _processScheduleDocuments(snap.docs, startStr, endStr));
    }

    if (_scheduleType == 'All Schedules' || _scheduleType == 'Active Schedules') {
      final snap = await _firestore.collection('Schedules').where('guard_id', isEqualTo: _selectedGuardId).get();
      allSchedules.addAll(await _processScheduleDocuments(snap.docs, startStr, endStr));
    }

    allSchedules.sort((a, b) {
      final dateCompare = (a['date'] as String).compareTo(b['date'] as String);
      if (dateCompare != 0) return dateCompare;
      return (a['start_time'] as String).compareTo(b['start_time'] as String);
    });

    return allSchedules;
  }

  String _generateTextReport(List<Map<String, dynamic>> scheduleData) {
    final buffer = StringBuffer();
    buffer.writeln('SCHEDULE CHECKPOINT SUMMARY REPORT');
    buffer.writeln('=' * 45);
    buffer.writeln('Guard: ${_selectedGuardName ?? 'Unknown'}');
    buffer.writeln('Period: ${_periodType == 'Monthly' ? DateFormat('MMMM yyyy').format(_anchorDate) : 'Weekly'}');
    buffer.writeln('Schedule Type: $_scheduleType');
    buffer.writeln('Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buffer.writeln('');
    buffer.writeln('Date\t\tCheckpoints');
    buffer.writeln('-' * 50);

    for (final schedule in scheduleData) {
      final checkpoints = schedule['checkpoints'] as List<Map<String, dynamic>>? ?? [];
      final checkpointText = checkpoints.map((cp) => '${cp['id']} (${cp['status']})').join(', ');
      buffer.writeln('${schedule['date']}\t\t$checkpointText');
    }

    buffer.writeln('');
    buffer.writeln('Total Schedules: ${scheduleData.length}');
    return buffer.toString();
  }

  void _showReportDialog(String reportText) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Checkpoint Summary Report'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: Text(
              reportText,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _printPDF() async {
    if (_selectedGuardId == null || _selectedGuardName == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a guard first')));
      return;
    }

    try {
      final scheduleData = await _getScheduleDataForPrint();
      if (!mounted) return;

      if (scheduleData.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No schedule data to print')));
        return;
      }
      await _generateAndPrintPDF(scheduleData);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error generating PDF: $e')));
      }
    }
  }

  Future<void> _exportCsv() async {
    if (_selectedGuardId == null || _selectedGuardName == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a guard first')));
      return;
    }
    final data = await _getScheduleDataForPrint();
    if (data.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No schedule data to export')));
      }
      return;
    }
    final buffer = StringBuffer();
    buffer.writeln('Date,Start Time,End Time,Checkpoints');
    for (final schedule in data) {
      final checkpoints = (schedule['checkpoints'] as List<Map<String, dynamic>>? ?? [])
          .map((cp) {
            final rawStatus = (cp['status'] as String? ?? '').toLowerCase();
            final statusLabel = rawStatus == 'scanned' || rawStatus == 'inspected'
                ? 'Inspected'
                : 'Not Yet Inspected';
            final location = (cp['location'] as String? ?? cp['name'] as String? ?? cp['id'] as String? ?? 'Unknown');
            return '$location ($statusLabel)';
          })
          .join('; ');
      String esc(String v) => '"${v.replaceAll('"', '""')}"';
      buffer.writeln([
        esc(schedule['date'] as String? ?? ''),
        esc(schedule['start_time'] as String? ?? ''),
        esc(schedule['end_time'] as String? ?? ''),
        esc(checkpoints),
      ].join(','));
    }
    final bytes = Uint8List.fromList(buffer.toString().codeUnits);
    final fileName = 'Schedule_Checkpoint_Summary_${_selectedGuardName?.replaceAll(' ', '_')}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';
    if (kIsWeb) {
      await saveBytesAsDownload(fileName, bytes, mimeType: 'text/csv');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV downloaded')));
      }
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path)], text: 'Schedule checkpoint summary');
    }
  }

  Future<void> _generateAndPrintPDF(List<Map<String, dynamic>> scheduleData) async {
    try {
      final pdf = pw.Document();

      final font = await rootBundle.load("assets/fonts/Roboto-Regular.ttf");
      final boldFont = await rootBundle.load("assets/fonts/Roboto-Bold.ttf");
      final theme = pw.ThemeData.withFont(base: pw.Font.ttf(font), bold: pw.Font.ttf(boldFont));

      final sortedScheduleData = List<Map<String, dynamic>>.from(scheduleData);
      sortedScheduleData.sort((a, b) {
        final dateCompare = (a['date'] as String).compareTo(b['date'] as String);
        if (dateCompare != 0) return dateCompare;
        return (a['start_time'] as String).compareTo(b['start_time'] as String);
      });

      final String periodString;
      if (_periodType == 'Monthly') {
        periodString = DateFormat('MMMM yyyy').format(_anchorDate);
      } else {
        final startOfWeek = _anchorDate.subtract(Duration(days: _anchorDate.weekday - 1));
        final endOfWeek = startOfWeek.add(const Duration(days: 6));
        periodString = '${DateFormat('MMM d').format(startOfWeek)} - ${DateFormat('MMM d, yyyy').format(endOfWeek)}';
      }

      pw.MemoryImage? headerImage;
      pw.MemoryImage? footerImage;
      try {
        final headerBytes = await rootBundle.load('assets/images/SecurityHeader.png');
        headerImage = pw.MemoryImage(headerBytes.buffer.asUint8List());
      } catch (_) {}
      try {
        final footerBytes = await rootBundle.load('assets/images/SecurityFooter.png');
        footerImage = pw.MemoryImage(footerBytes.buffer.asUint8List());
      } catch (_) {}

      final headerImg = headerImage;
      final footerImg = footerImage;

      // Define the custom page size for Long Bond (8.5 x 13 inches)
      const double longBondWidth = 8.5 * PdfPageFormat.inch;
      const double longBondHeight = 13.0 * PdfPageFormat.inch;
      final pageFormat = PdfPageFormat(longBondWidth, longBondHeight);

      pdf.addPage(
        pw.MultiPage(
          theme: theme,
          pageFormat: pageFormat,
          // 🚨 CHANGE APPLIED HERE: Increased left margin to 50 to visually center the content on the printed page
          margin: const pw.EdgeInsets.only(left: 50, right: 40, top: 20, bottom: 0),

          // HEADER remains the same
          header: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (headerImg != null)
                pw.Center(
                  child: pw.Image(
                    headerImg,
                    fit: pw.BoxFit.fitWidth,
                    height: 90,
                  ),
                ),
              pw.SizedBox(height: 12),
              pw.Center(
                child: pw.Text(
                  'SCHEDULE CHECKPOINT SUMMARY REPORT',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18),
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Text('Security Guard: ${_selectedGuardName ?? 'Unknown'}'),
              pw.Text('Period: $periodString'),
              pw.Text('Schedule Type: $_scheduleType'),
              pw.Text('Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}'),
              pw.SizedBox(height: 20),
            ],
          ),

          // FOOTER remains the same
          footer: (context) {
            final isLastPage = context.pageNumber == context.pagesCount;

            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (isLastPage)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 8, bottom: 8),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      children: [
                        pw.Column(
                          children: [
                            pw.Text('Prepared by:', style: const pw.TextStyle(fontSize: 11)),
                            pw.SizedBox(height: 16),
                            pw.Text(
                              'PRINCE JUN N. DAMASCO',
                              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),),
                            pw.Text('Head, Security Services', style: const pw.TextStyle(fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
                  ),

                if (footerImg != null)
                  pw.Center(
                    child: pw.Image(
                      footerImg,
                      fit: pw.BoxFit.fitWidth,
                      height: 60,
                    ),
                  )
                else
                  pw.SizedBox.shrink(),
              ],
            );
          },

          // BUILD remains the same
          build: (pw.Context context) {
            return [
              pw.TableHelper.fromTextArray(
                border: pw.TableBorder.all(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
                cellHeight: 30,
                cellAlignments: {0: pw.Alignment.centerLeft, 1: pw.Alignment.topLeft},
                columnWidths: {0: const pw.FixedColumnWidth(100), 1: const pw.FlexColumnWidth()},
                headers: ['Date', 'Checkpoints'],
                data: sortedScheduleData.map((schedule) {
                  final checkpoints = schedule['checkpoints'] as List<Map<String, dynamic>>? ?? [];
                  final checkpointText = checkpoints.map((cp) {
                    final rawStatus = (cp['status'] as String? ?? '').toLowerCase();
                    final location = (cp['location'] as String? ?? cp['name'] as String? ?? cp['id'] as String? ?? 'Unknown');
                    final scannedAtIso = cp['scannedAt'] as String?;
                    DateTime? scannedAt;
                    if (scannedAtIso != null && scannedAtIso.isNotEmpty) {
                      scannedAt = DateTime.tryParse(scannedAtIso);
                    }
                    final timeLabel = (scannedAt != null)
                        ? ' at ${DateFormat('h:mm a').format(scannedAt)}'
                        : '';
                    final statusLabel = rawStatus == 'scanned'
                        ? 'Inspected$timeLabel'
                        : 'Not Yet Inspected';
                    return '$location ($statusLabel)';
                  }).join(',\n');
                  return [schedule['date'] as String, checkpointText];
                }).toList(),
              ),
              pw.SizedBox(height: 20),
              pw.Text('Total Schedules: ${sortedScheduleData.length}'),
            ];
          },
        ),
      );

      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: 'Checkpoint_Summary_${_selectedGuardName?.replaceAll(' ', '_')}_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.pdf',
      );

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error generating PDF: $e')));
      }
    }
  }

  Future<List<Map<String, dynamic>>> _processScheduleDocuments(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, String startStr, String endStr) async {
    final schedules = await Future.wait(docs.map((d) async {
      final data = d.data();
      final checkpoints = data['checkpoints'] as List<dynamic>? ?? [];
      final checkpointDetails = await _getCheckpointDetailsForSchedule(data, checkpoints);

      return {
        'date': data['date'] as String? ?? '',
        'start_time': data['start_time'] as String? ?? 'N/A',
        'end_time': data['end_time'] as String? ?? 'N/A',
        'checkpoints': checkpointDetails,
        'type': d.reference.parent.id,
      };
    }));

    return schedules.where((schedule) {
      final scheduleDate = schedule['date'] as String;
      return scheduleDate.isNotEmpty && scheduleDate.compareTo(startStr) >= 0 && scheduleDate.compareTo(endStr) <= 0;
    }).toList();
  }

  // MODIFIED: This method now correctly uses the document's ID.
  Future<List<Map<String, dynamic>>> _getCheckpointDetailsForSchedule(Map<String, dynamic> scheduleData, List<dynamic> checkpoints) async {
    final List<Map<String, dynamic>> checkpointDetails = [];

    for (final checkpointId in checkpoints) {
      try {
        final checkpointDoc = await _firestore.collection('Checkpoints').doc(checkpointId.toString()).get();

        final String name;
        final String location;
        final String docId;

        if (checkpointDoc.exists) {
          final checkpointData = checkpointDoc.data()!;
          name = checkpointData['name'] as String? ?? 'Unknown';
          location = checkpointData['location'] as String? ?? 'Unknown';
          docId = checkpointDoc.id; // Get the document ID here
        } else {
          name = 'Not Found';
          location = 'Not Found';
          docId = checkpointId.toString(); // Fallback to the original ID if doc not found
        }

        final scheduleDate = scheduleData['date'] as String;
        final guardId = scheduleData['guard_id'] as String?;

        // Determine scan status without requiring composite indexes.
        // Fetch scans for this checkpoint and filter by day (and guard if available) client-side.
        bool isScanned = false;
        DateTime? scannedAtTime;
        try {
          final scansSnap = await _firestore
              .collection('CheckpointScans')
              .where('checkpointId', isEqualTo: checkpointId.toString())
              .get();
          final day = DateTime.parse(scheduleDate);
          final startDay = DateTime(day.year, day.month, day.day);
          final endDay = startDay.add(const Duration(days: 1));
          for (final doc in scansSnap.docs) {
            final m = doc.data();
            DateTime? when;
            final sa = m['scannedAt'];
            final ts = m['timestamp'];
            final ca = m['createdAt'];
            if (sa is Timestamp) when = sa.toDate();
            when ??= (ts is Timestamp) ? ts.toDate() : null;
            when ??= (ca is Timestamp) ? ca.toDate() : null;
            if (when == null) continue;
            if (when.isAfter(startDay.subtract(const Duration(milliseconds: 1))) && when.isBefore(endDay)) {
              final scanGuard = (m['guardId'] ?? m['guard_id'] ?? m['securityGuardId'])?.toString();
              if (guardId == null || guardId.isEmpty || scanGuard == null || scanGuard.isEmpty || scanGuard == guardId) {
                isScanned = true;
                scannedAtTime = when;
                break;
              }
            }
          }
        } catch (_) {
          // Fallback: try TransactionLogs without range filters
          try {
            final tlogs = await _firestore
            .collection('TransactionLogs')
            .where('checkpointId', isEqualTo: checkpointId.toString())
            .get();
            final day = DateTime.parse(scheduleDate);
            final startDay = DateTime(day.year, day.month, day.day);
            final endDay = startDay.add(const Duration(days: 1));
            for (final doc in tlogs.docs) {
              final m = doc.data();
              DateTime? when;
              final ts = m['timestamp'];
              final ca = m['createdAt'];
              if (ts is Timestamp) when = ts.toDate();
              when ??= (ca is Timestamp) ? ca.toDate() : null;
              if (when == null) continue;
              if (when.isAfter(startDay.subtract(const Duration(milliseconds: 1))) && when.isBefore(endDay)) {
                final scanGuard = (m['guardId'] ?? m['guard_id'] ?? m['securityGuardId'])?.toString();
                if (guardId == null || guardId.isEmpty || scanGuard == null || scanGuard.isEmpty || scanGuard == guardId) {
                  isScanned = true;
                  scannedAtTime = when;
                  break;
                }
              }
            }
          } catch (_) {}
        }

        checkpointDetails.add({
          'name': name,
          'location': location,
          'status': isScanned ? 'Scanned' : 'Not Yet Scanned',
          'id': docId, // Use the captured document ID
          'scannedAt': scannedAtTime?.toIso8601String(),
        });
      } catch (e) {
        checkpointDetails.add({
          'name': 'Error',
          'location': 'Error',
          'status': 'Error',
          'id': checkpointId.toString(),
        });
      }
    }
    return checkpointDetails;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Print Report Schedule Checkpoint Summary'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      drawer: Drawer(child: appNavList(context, closeDrawer: true)),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.withOpacity(0.2),
                              spreadRadius: 1,
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      child: DropdownButtonFormField<String>(
                        value: _selectedGuardId,
                          decoration: const InputDecoration(
                            labelText: 'Select Guard',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        items: _guards.map((guard) {
                          return DropdownMenuItem(value: guard['id'], child: Text(guard['name']!));
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedGuardId = value;
                              _selectedGuardName = _guards.firstWhere((g) => g['id'] == value)['name'];
                            });
                          }
                        },
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.withOpacity(0.2),
                              spreadRadius: 1,
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      child: DropdownButtonFormField<String>(
                        value: _periodType,
                          decoration: const InputDecoration(
                            labelText: 'Period',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        items: const [
                          DropdownMenuItem(value: 'Monthly', child: Text('Monthly')),
                          DropdownMenuItem(value: 'Weekly', child: Text('Weekly')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _periodType = value);
                          }
                        },
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.withOpacity(0.2),
                              spreadRadius: 1,
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      child: DropdownButtonFormField<String>(
                        value: _scheduleType,
                          decoration: const InputDecoration(
                            labelText: 'Schedule Type',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        items: const [
                          DropdownMenuItem(value: 'All Schedules', child: Text('All Schedules')),
                          DropdownMenuItem(value: 'Active Schedules', child: Text('Active Schedules')),
                          DropdownMenuItem(value: 'Ended Schedules', child: Text('Ended Schedules')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _scheduleType = value);
                          }
                        },
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => _periodType == 'Monthly' ? _changeMonth(-1) : _changeWeek(-1),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Text(
                          _periodType == 'Monthly'
                              ? DateFormat('MMMM yyyy').format(_anchorDate)
                              : '${DateFormat('MMM d').format(_anchorDate.subtract(Duration(days: _anchorDate.weekday - 1)))} - ${DateFormat('MMM d, yyyy').format(_anchorDate.subtract(Duration(days: _anchorDate.weekday - 1)).add(const Duration(days: 6)))}',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          onPressed: () => _periodType == 'Monthly' ? _changeMonth(1) : _changeWeek(1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.blue,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.grey.withOpacity(0.2),
                                spreadRadius: 1,
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ElevatedButton.icon(
                          icon: const Icon(Icons.text_snippet),
                          label: const Text('Text'),
                          onPressed: _printSchedule,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                              elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.green,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.grey.withOpacity(0.2),
                                spreadRadius: 1,
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ElevatedButton.icon(
                          icon: const Icon(Icons.picture_as_pdf),
                          label: const Text('PDF'),
                          onPressed: _printPDF,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.teal,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.grey.withOpacity(0.2),
                                spreadRadius: 1,
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.table_view),
                            label: const Text('CSV'),
                            onPressed: _exportCsv,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                              elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _scheduleStream(),
              builder: (context, snapshot) {
                if (_selectedGuardId == null) {
                  return const Center(child: Text('Select a guard to view schedules'));
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                final data = snapshot.data ?? [];
                if (data.isEmpty) {
                  return const Center(child: Text('No schedules found for selected period.'));
                }
                return Container(
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.grey.withOpacity(0.1),
                        spreadRadius: 1,
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Fixed header
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.green.shade600,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            topRight: Radius.circular(12),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          child: Row(
                            children: const [
                              Expanded(
                                flex: 2,
                                child: Text(
                                  'DATE',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 3,
                                child: Text(
                                  'CHECKPOINTS',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Scrollable body
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: data.asMap().entries.map((entry) {
                              final index = entry.key;
                              final schedule = entry.value;
                              final isEven = index % 2 == 0;
                              
                              return Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                decoration: BoxDecoration(
                                  color: isEven ? Colors.white : Colors.grey.shade50,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        schedule['date'] as String,
                                        style: const TextStyle(fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 3,
                                      child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: (schedule['checkpoints'] as List<Map<String, dynamic>>? ?? [])
                                            .map((cp) {
                                          final rawStatus = (cp['status'] as String? ?? '').toLowerCase();
                                          final isInspected = rawStatus == 'scanned' || rawStatus == 'inspected';
                                          final label = isInspected ? 'Inspected' : 'Not Yet Inspected';
                                          final location = (cp['location'] as String? ?? cp['name'] as String? ?? cp['id'] as String? ?? 'Unknown');
                                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                                              color: isInspected ? Colors.green.shade100 : Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(
                                                color: isInspected ? Colors.green.shade300 : Colors.orange.shade300,
                                                width: 1,
                                              ),
                            ),
                            child: Text(
                                              '$location ($label)',
                              style: TextStyle(
                                                color: isInspected ? Colors.green.shade800 : Colors.orange.shade800,
                                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
