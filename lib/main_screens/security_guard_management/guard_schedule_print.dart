import 'package:flutter/material.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:async/async.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

const PdfPageFormat _longBondPageFormat = PdfPageFormat(
  8.5 * PdfPageFormat.inch,
  13 * PdfPageFormat.inch,
);

class GuardSchedulePrintScreen extends StatefulWidget {
  const GuardSchedulePrintScreen({super.key});

  @override
  State<GuardSchedulePrintScreen> createState() => _GuardSchedulePrintScreenState();
}

class _GuardSchedulePrintScreenState extends State<GuardSchedulePrintScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _selectedGuardId;
  String? _selectedGuardName;
  String _periodType = 'Monthly';
  DateTime _anchorDate = DateTime.now();
  String _scheduleType = 'Ended';

  List<Map<String, String>> _guards = const [];
  bool _isLoadingGuards = false;
  String? _guardsError;

  // Font data for PDF generation
  pw.Font? _robotoRegular;
  pw.Font? _robotoBold;
  pw.Font? _robotoItalic;

  @override
  void initState() {
    super.initState();
    _fetchGuards();
    _loadFonts();
  }

  Future<void> _loadFonts() async {
    try {
      // Load Roboto fonts for PDF generation
      _robotoRegular = await PdfGoogleFonts.robotoRegular();
      _robotoBold = await PdfGoogleFonts.robotoBold();
      _robotoItalic = await PdfGoogleFonts.robotoItalic();
    } catch (e) {
      print('Error loading fonts: $e');
      // Fallback to default fonts if custom fonts fail to load
    }
  }

  Future<void> _fetchGuards() async {
    setState(() {
      _isLoadingGuards = true;
      _guardsError = null;
    });
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
      setState(() {
        _guardsError = e.toString();
      });
    } finally {
      setState(() {
        _isLoadingGuards = false;
      });
    }
  }

  Future<List<Map<String, String>>> _loadGuards() async {
    final snap = await _firestore
        .collection('Accounts')
        .where('role', isEqualTo: 'Security')
        .get();

    final guards = snap.docs.map((d) {
      final data = d.data();
      final guardId = (data['guard_id'] as String?) ?? d.id;
      final firstName = data['first_name'] as String? ?? '';
      final lastName = data['last_name'] as String? ?? '';
      final name = ('$firstName $lastName').trim().isEmpty
          ? (data['name'] as String?) ?? 'Unnamed Guard'
          : ('$firstName $lastName').trim();
      return {'id': guardId, 'name': name};
    }).toList();

    guards.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
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
      end = DateTime(_anchorDate.year, _anchorDate.month + 1, 0); // Correct way to get last day of month
    } else {
      final weekday = _anchorDate.weekday;
      // Adjust for weeks starting on Monday (weekday 1)
      start = _anchorDate.subtract(Duration(days: weekday - 1));
      end = start.add(const Duration(days: 6));
    }

    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);

    if (_scheduleType == 'Both') {
      return _getCombinedSchedulesStream(startStr, endStr);
    } else {
      String collectionName = _scheduleType == 'Ended' ? 'EndedSchedules' : 'Schedules';
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

  // FIXED: This entire method is now correct
  Stream<List<Map<String, dynamic>>> _getCombinedSchedulesStream(String startStr, String endStr) {
    final endedStream = _firestore
        .collection('EndedSchedules')
        .where('guard_id', isEqualTo: _selectedGuardId)
        .snapshots();

    final upcomingStream = _firestore
        .collection('Schedules')
        .where('guard_id', isEqualTo: _selectedGuardId)
        .snapshots();

    // Use the StreamZip class from the 'async' package
    return StreamZip([endedStream, upcomingStream]).asyncMap((snapshots) async {
      final endedSnap = snapshots[0];
      final upcomingSnap = snapshots[1];

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


  Future<List<Map<String, dynamic>>> _processScheduleDocuments(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, String startStr, String endStr) async {
    final schedules = docs.map((d) {
      final data = d.data();
      return {
        'date': data['date'] as String? ?? '',
        'start_time': data['start_time'] as String? ?? 'N/A',
        'end_time': data['end_time'] as String? ?? 'N/A',
        'type': d.reference.parent.id, // e.g., 'Schedules' or 'EndedSchedules'
      };
    }).toList();

    return schedules.where((schedule) {
      final scheduleDate = schedule['date'] as String;
      if (scheduleDate.isEmpty) return false;
      return scheduleDate.compareTo(startStr) >= 0 && scheduleDate.compareTo(endStr) <= 0;
    }).toList();
  }


  void _changeMonth(int delta) {
    setState(() {
      _anchorDate = DateTime(_anchorDate.year, _anchorDate.month + delta, _anchorDate.day);
    });
  }

  void _changeWeek(int delta) {
    setState(() {
      _anchorDate = _anchorDate.add(Duration(days: 7 * delta));
    });
  }

  Future<void> _printSchedule() async {
    if (!mounted) return;
    if (_selectedGuardId == null || _selectedGuardName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a guard first')),
      );
      return;
    }

    try {
      final scheduleData = await _getScheduleDataForPrint();

      if (scheduleData.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No schedule data to print for the selected period')),
        );
        return;
      }

      final reportText = _generateTextReport(scheduleData);
      if (mounted) {
        _showReportDialog(reportText);
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating report: $e')),
        );
      }
    }
  }

  Future<void> _printPDF() async {
    if (!mounted) return;
    if (_selectedGuardId == null || _selectedGuardName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a guard first')),
      );
      return;
    }

    try {
      final scheduleData = await _getScheduleDataForPrint();

      if (scheduleData.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No schedule data to print for the selected period')),
        );
        return;
      }

      if (mounted) {
        await _generateAndPrintPDF(scheduleData);
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating PDF: $e')),
        );
      }
    }
  }

  Future<List<Map<String, dynamic>>> _getScheduleDataForPrint() async {
    if (_selectedGuardId == null) return [];

    late final DateTime start;
    late final DateTime end;

    if (_periodType == 'Monthly') {
      start = DateTime(_anchorDate.year, _anchorDate.month, 1);
      end = DateTime(_anchorDate.year, _anchorDate.month + 1, 0); // Correct
    } else {
      final weekday = _anchorDate.weekday;
      start = _anchorDate.subtract(Duration(days: weekday - 1));
      end = start.add(const Duration(days: 6));
    }

    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);

    List<Map<String, dynamic>> allSchedules = [];

    if (_scheduleType == 'Both' || _scheduleType == 'Ended') {
      final snap = await _firestore
          .collection('EndedSchedules')
          .where('guard_id', isEqualTo: _selectedGuardId)
          .get();
      allSchedules.addAll(await _processScheduleDocuments(snap.docs, startStr, endStr));
    }
    if (_scheduleType == 'Both' || _scheduleType == 'Upcoming') {
      final snap = await _firestore
          .collection('Schedules')
          .where('guard_id', isEqualTo: _selectedGuardId)
          .get();
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
    final String periodString;

    if (_periodType == 'Monthly') {
      periodString = DateFormat('MMMM yyyy').format(_anchorDate);
    } else {
      final startOfWeek = _anchorDate.subtract(Duration(days: _anchorDate.weekday - 1));
      final endOfWeek = startOfWeek.add(const Duration(days: 6));
      periodString = '${DateFormat('MMM d').format(startOfWeek)} - ${DateFormat('MMM d, yyyy').format(endOfWeek)}';
    }

    buffer.writeln('SECURITY GUARD SCHEDULE REPORT');
    buffer.writeln('=' * 40);
    buffer.writeln('Guard: ${_selectedGuardName ?? 'Unknown'}');
    buffer.writeln('Period: $periodString');
    buffer.writeln('Schedule Type: $_scheduleType');
    buffer.writeln('Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buffer.writeln();

    buffer.writeln('Date\t\tStart\t\tEnd');
    buffer.writeln('-' * 40);

    if(scheduleData.isEmpty) {
      buffer.writeln('No schedules found for this period.');
    } else {
      for (final schedule in scheduleData) {
        buffer.writeln('${schedule['date']}\t${schedule['start_time']}\t${schedule['end_time']}');
      }
    }

    buffer.writeln();
    buffer.writeln('Total Shifts: ${scheduleData.length}');

    return buffer.toString();
  }

  void _showReportDialog(String reportText) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Schedule Report'),
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

  Future<void> _generateAndPrintPDF(List<Map<String, dynamic>> scheduleData) async {
    try {
      final pdf = pw.Document();
      
      // Sort the data before generating PDF
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

      pdf.addPage(
        pw.MultiPage(
          pageFormat: _longBondPageFormat,
          margin: const pw.EdgeInsets.only(left: 40, right: 40, top: 80, bottom: 80),
          build: (pw.Context context) {
            return [
              // Header Section
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(20),
                decoration: pw.BoxDecoration(
                  color: PdfColors.blue50,
                  border: pw.Border.all(color: PdfColors.blue200, width: 2),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(
              children: [
                    pw.Text(
                    'SECURITY GUARD SCHEDULE REPORT',
                      style: pw.TextStyle(
                        fontSize: 24,
                        fontWeight: pw.FontWeight.bold,
                        font: _robotoBold,
                        color: PdfColors.blue900,
                  ),
                      textAlign: pw.TextAlign.center,
                ),
                    pw.SizedBox(height: 16),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                            pw.Text(
                              'Guard: ${_selectedGuardName ?? 'Unknown'}',
                              style: pw.TextStyle(
                                fontSize: 14,
                                font: _robotoRegular,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                            pw.SizedBox(height: 4),
                            pw.Text(
                              'Period: $periodString',
                              style: pw.TextStyle(
                                fontSize: 12,
                                font: _robotoRegular,
                              ),
                            ),
                            pw.SizedBox(height: 4),
                            pw.Text(
                              'Schedule Type: $_scheduleType',
                              style: pw.TextStyle(
                                fontSize: 12,
                                font: _robotoRegular,
                              ),
                            ),
                          ],
                        ),
                        pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.end,
                          children: [
                            pw.Text(
                              'Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
                              style: pw.TextStyle(
                                fontSize: 10,
                                font: _robotoItalic,
                                color: PdfColors.grey600,
                              ),
                    ),
                  ],
                ),
                      ],
                    ),
                  ],
                ),
              ),
              
              pw.SizedBox(height: 24),
                
                // Schedule Table
              if (sortedScheduleData.isNotEmpty) ...[
                pw.Text(
                  'SCHEDULE DETAILS',
                  style: pw.TextStyle(
                    fontSize: 16,
                    font: _robotoBold,
                    color: PdfColors.blue800,
                  ),
                ),
                pw.SizedBox(height: 12),
                
                pw.Table(
                  border: pw.TableBorder.all(
                    color: PdfColors.blue200,
                    width: 1,
                  ),
                  columnWidths: {
                    0: const pw.FlexColumnWidth(2),
                    1: const pw.FlexColumnWidth(2),
                    2: const pw.FlexColumnWidth(2),
                    3: const pw.FlexColumnWidth(1.5),
                  },
                  children: [
                    // Header row
                    pw.TableRow(
                      decoration: pw.BoxDecoration(
                        color: PdfColors.blue100,
                        borderRadius: const pw.BorderRadius.only(
                          topLeft: pw.Radius.circular(4),
                          topRight: pw.Radius.circular(4),
                        ),
                      ),
                      children: [
                        pw.Container(
                          padding: const pw.EdgeInsets.all(12),
                          child: pw.Text(
                            'DATE',
                            style: pw.TextStyle(
                              fontSize: 12,
                              font: _robotoBold,
                              color: PdfColors.blue900,
                            ),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Container(
                          padding: const pw.EdgeInsets.all(12),
                          child: pw.Text(
                            'START TIME',
                            style: pw.TextStyle(
                              fontSize: 12,
                              font: _robotoBold,
                              color: PdfColors.blue900,
                            ),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Container(
                          padding: const pw.EdgeInsets.all(12),
                          child: pw.Text(
                            'END TIME',
                            style: pw.TextStyle(
                              fontSize: 12,
                              font: _robotoBold,
                              color: PdfColors.blue900,
                            ),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Container(
                          padding: const pw.EdgeInsets.all(12),
                          child: pw.Text(
                            'STATUS',
                            style: pw.TextStyle(
                              fontSize: 12,
                              font: _robotoBold,
                              color: PdfColors.blue900,
                            ),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    // Data rows
                    ...sortedScheduleData.asMap().entries.map((entry) {
                      final index = entry.key;
                      final schedule = entry.value;
                      final isEven = index % 2 == 0;
                      
                      return pw.TableRow(
                        decoration: pw.BoxDecoration(
                          color: isEven ? PdfColors.white : PdfColors.grey50,
                        ),
                      children: [
                          pw.Container(
                            padding: const pw.EdgeInsets.all(10),
                            child: pw.Text(
                              schedule['date'] as String,
                              style: pw.TextStyle(
                                fontSize: 11,
                                font: _robotoRegular,
                        ),
                              textAlign: pw.TextAlign.center,
                            ),
                        ),
                          pw.Container(
                            padding: const pw.EdgeInsets.all(10),
                          child: pw.Text(
                              schedule['start_time'] as String,
                              style: pw.TextStyle(
                                fontSize: 11,
                                font: _robotoRegular,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Container(
                            padding: const pw.EdgeInsets.all(10),
                            child: pw.Text(
                              schedule['end_time'] as String,
                              style: pw.TextStyle(
                                fontSize: 11,
                                font: _robotoRegular,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Container(
                            padding: const pw.EdgeInsets.all(10),
                            child: pw.Container(
                              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: pw.BoxDecoration(
                                color: schedule['type'] == 'EndedSchedules' 
                                    ? PdfColors.red100 
                                    : PdfColors.green100,
                                borderRadius: pw.BorderRadius.circular(12),
                                border: pw.Border.all(
                                  color: schedule['type'] == 'EndedSchedules' 
                                      ? PdfColors.red300 
                                      : PdfColors.green300,
                                  width: 1,
                                ),
                              ),
                              child: pw.Text(
                                schedule['type'] == 'EndedSchedules' ? 'ENDED' : 'ACTIVE',
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  font: _robotoBold,
                                  color: schedule['type'] == 'EndedSchedules' 
                                      ? PdfColors.red800 
                                      : PdfColors.green800,
                                ),
                                textAlign: pw.TextAlign.center,
                              ),
                          ),
                        ),
                      ],
                      );
                    }),
                  ],
                ),
                
                pw.SizedBox(height: 24),
              ] else ...[
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.all(40),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.grey100,
                    borderRadius: pw.BorderRadius.circular(8),
                    border: pw.Border.all(color: PdfColors.grey300),
                  ),
                  child: pw.Column(
                    children: [
                      pw.Icon(
                        pw.IconData(0xe0b7), // info icon
                        size: 48,
                        color: PdfColors.grey600,
                      ),
                      pw.SizedBox(height: 16),
                      pw.Text(
                        'No schedules found for the selected period',
                        style: pw.TextStyle(
                          fontSize: 16,
                          font: _robotoRegular,
                          color: PdfColors.grey700,
                        ),
                        textAlign: pw.TextAlign.center,
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 24),
              ],
              
              // Summary Section
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(16),
                decoration: pw.BoxDecoration(
                  color: PdfColors.blue50,
                  borderRadius: pw.BorderRadius.circular(8),
                  border: pw.Border.all(color: PdfColors.blue200),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                pw.Text(
                  'Total Shifts: ${sortedScheduleData.length}',
                      style: pw.TextStyle(
                        fontSize: 14,
                        font: _robotoBold,
                        color: PdfColors.blue900,
                      ),
                    ),
                    pw.Text(
                      'Report Generated: ${DateFormat('MMM dd, yyyy').format(DateTime.now())}',
                      style: pw.TextStyle(
                        fontSize: 10,
                        font: _robotoItalic,
                        color: PdfColors.blue700,
                      ),
                ),
              ],
                ),
              ),
            ];
          },
        ),
      );

      // Print the PDF
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: 'Security_Guard_Schedule_${_selectedGuardName?.replaceAll(' ', '_')}_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.pdf',
      );
      
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating PDF: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Security Guard Schedule Print'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      drawer: Drawer(child: appNavList(context, closeDrawer: true)),
      body: Column(
        children: [
          // ---- START OF UI CONTROLS ----
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Colors.white,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
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
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Select Guard',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        items: _guards.map((guard) {
                          return DropdownMenuItem(
                            value: guard['id'],
                            child: Text(guard['name']!),
                          );
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
                      flex: 1,
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
                          if (value != null) { // FIXED: Null check
                            setState(() {
                              _periodType = value;
                            });
                          }
                        },
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 1,
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
                          DropdownMenuItem(value: 'Ended', child: Text('Ended')),
                          DropdownMenuItem(value: 'Upcoming', child: Text('Upcoming')),
                          DropdownMenuItem(value: 'Both', child: Text('Both')),
                        ],
                        onChanged: (value) {
                          if (value != null) { // FIXED: Null check
                            setState(() {
                              _scheduleType = value;
                            });
                          }
                        },
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => _periodType == 'Monthly' ? _changeMonth(-1) : _changeWeek(-1),
                          icon: const Icon(Icons.chevron_left),
                          tooltip: 'Previous Period',
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
                          tooltip: 'Next Period',
                        ),
                      ],
                    ),
                     Row(
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
                           label: const Text('Text Report'),
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
                           label: const Text('PDF Report'),
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
                       ],
                     ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          // ---- END OF UI CONTROLS ----

          // ---- START OF DATA TABLE ----
          Expanded(
            child: _isLoadingGuards
                ? const Center(child: CircularProgressIndicator())
                : _guardsError != null
                ? Center(child: Text('Error loading guards: $_guardsError'))
                : StreamBuilder<List<Map<String, dynamic>>>(
              stream: _scheduleStream(),
              builder: (context, snapshot) {
                if (_selectedGuardId == null) {
                  return const Center(child: Text('Select a guard to view schedules.'));
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                final data = snapshot.data ?? [];
                if (data.isEmpty) {
                  return const Center(child: Text('No schedules found for the selected period.'));
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
                                flex: 2,
                                child: Text(
                                  'START TIME',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  'END TIME',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 1,
                                child: Center(
                                  child: Text(
                                    'STATUS',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
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
                                      flex: 2,
                                      child: Text(schedule['start_time'] as String),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(schedule['end_time'] as String),
                                    ),
                                    Expanded(
                                      flex: 1,
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: schedule['type'] == 'EndedSchedules'
                                  ? Colors.red.shade100
                                  : Colors.green.shade100,
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(
                                              color: schedule['type'] == 'EndedSchedules'
                                                  ? Colors.red.shade300
                                                  : Colors.green.shade300,
                                              width: 1,
                                            ),
                            ),
                            child: Text(
                                            schedule['type'] == 'EndedSchedules' ? 'ENDED' : 'ACTIVE',
                              style: TextStyle(
                                color: schedule['type'] == 'EndedSchedules'
                                    ? Colors.red.shade800
                                    : Colors.green.shade800,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
                              ),
                            ),
                          ),
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
          // ---- END OF DATA TABLE ----
        ],
      ),
    );
  }
}
