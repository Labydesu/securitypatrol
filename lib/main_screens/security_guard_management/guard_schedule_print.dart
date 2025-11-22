import 'package:flutter/material.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:async/async.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:thesis_web/utils/download_saver.dart';
import 'dart:typed_data';

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

  // Font and asset data for PDF generation
  pw.Font? _robotoRegular;
  pw.Font? _robotoBold;
  pw.Font? _robotoItalic;
  pw.MemoryImage? _headerImage;
  pw.MemoryImage? _footerImage;

  @override
  void initState() {
    super.initState();
    _fetchGuards();
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    try {
      // Load Roboto fonts for PDF generation
      _robotoRegular = await PdfGoogleFonts.robotoRegular();
      _robotoBold = await PdfGoogleFonts.robotoBold();
      _robotoItalic = await PdfGoogleFonts.robotoItalic();

      try {
        final headerBytes = await rootBundle.load('assets/images/SecurityHeader.png');
        _headerImage = pw.MemoryImage(headerBytes.buffer.asUint8List());
      } catch (e) {
        print('Error loading header image: $e');
      }

      try {
        final footerBytes = await rootBundle.load('assets/images/SecurityFooter.png');
        _footerImage = pw.MemoryImage(footerBytes.buffer.asUint8List());
      } catch (e) {
        print('Error loading footer image: $e');
      }
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

  Future<void> _exportCsv() async {
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
          const SnackBar(content: Text('No schedule data to export for the selected period')),
        );
        return;
      }

      final buffer = StringBuffer();
      buffer.writeln('Date,Start Time,End Time,Status');
      for (final schedule in scheduleData) {
        final statusText = schedule['type'] == 'EndedSchedules' ? 'ENDED' : 'ACTIVE';
        String esc(String v) => '"${v.replaceAll('"', '""')}"';
        buffer.writeln([
          esc(schedule['date'] as String? ?? ''),
          esc(schedule['start_time'] as String? ?? ''),
          esc(schedule['end_time'] as String? ?? ''),
          esc(statusText),
        ].join(','));
      }

      final bytes = Uint8List.fromList(buffer.toString().codeUnits);
      final fileName = 'Guard_Schedule_${_selectedGuardName?.replaceAll(' ', '_')}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';

      if (kIsWeb) {
        await saveBytesAsDownload(fileName, bytes, mimeType: 'text/csv');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV downloaded')));
        }
      } else {
        // For non-web platforms, you might want to add file saving logic here
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('CSV export is only available on web')),
          );
        }
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating CSV: $e')),
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


  Future<void> _generateAndPrintPDF(List<Map<String, dynamic>> scheduleData) async {
    try {
      final pdf = pw.Document();

      // 1. Font and Theme Definition
      final font = await rootBundle.load("assets/fonts/Roboto-Regular.ttf");
      final boldFont = await rootBundle.load("assets/fonts/Roboto-Bold.ttf");
      final theme = pw.ThemeData.withFont(base: pw.Font.ttf(font), bold: pw.Font.ttf(boldFont));

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

      // 2. Image Loading
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

      // 3. Custom Page Format: 8.5 x 13 inches (Long Bond)
      const double longBondWidth = 8.5 * PdfPageFormat.inch;
      const double longBondHeight = 13.0 * PdfPageFormat.inch;
      final pageFormat = PdfPageFormat(longBondWidth, longBondHeight);

      pdf.addPage(
        pw.MultiPage(
          theme: theme,
          pageFormat: pageFormat,
          margin: const pw.EdgeInsets.only(left: 30, right: 30, top: 20, bottom: 10),

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
                  'SECURITY GUARD SCHEDULE REPORT',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18),
                ),
              ),
              pw.SizedBox(height: 10), // Small space after the title before the main content begins
            ],
          ),

          // 5. 🚨 FOOTER CALLBACK: Conditional content
          footer: (context) {
            // Conditional Signature Block
            final signatureBlock = (context.pageNumber == context.pagesCount)
                ? pw.Padding(
              padding: const pw.EdgeInsets.only(top: 8, bottom: 12),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Column(
                    children: [
                      pw.Text('Prepared by:', style: const pw.TextStyle(fontSize: 11)),
                      pw.SizedBox(height: 16),
                      pw.Text(
                        'PRINCE JUN N. DAMASCO',
                        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
                      ),
                      pw.Text('Head, Security Services', style: const pw.TextStyle(fontSize: 11)),
                    ],
                  ),
                ],
              ),
            )
                : pw.SizedBox(height: 10); // Placeholder space on other pages

            // Fixed Footer Image
            final imageWidget = (footerImg != null)
                ? pw.Center(
              child: pw.Image(
                footerImg,
                fit: pw.BoxFit.fitWidth,
                height: 60,
              ),
            )
                : pw.SizedBox.shrink();

            // Combine the conditional signature block and the fixed image
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              mainAxisAlignment: pw.MainAxisAlignment.end, // Ensure content sits at the bottom edge
              children: [
                signatureBlock,
                imageWidget,
              ],
            );
          },

          // 6. Build Content (Unique Info Block, Detailed Table, and Summary)
          build: (pw.Context context) {
            // --- Data preparation for the simple table layout ---
            final List<List<String>> tableData = sortedScheduleData.map((schedule) {
              final statusText = schedule['type'] == 'EndedSchedules' ? 'ENDED' : 'ACTIVE';
              return [
                schedule['date'] as String,
                schedule['start_time'] as String,
                schedule['end_time'] as String,
                statusText,
              ];
            }).toList();
            // ---------------------------------------------------

            return [
              // UNIQUE INFO BLOCK: Now only appears on the first page
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Security Guard: ${_selectedGuardName ?? 'Unknown'}'),
                  pw.Text('Period: $periodString'),
                  pw.Text('Schedule Type: $_scheduleType'),
                  pw.Text('Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}'),
                  pw.SizedBox(height: 20), // Gap before the main table
                ],
              ),

              // Table Header Title
              pw.Text(
                'SCHEDULE DETAILS',
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.blue800,
                ),
              ),
              pw.SizedBox(height: 12),

              // Table with the required columns (simple design)
              pw.TableHelper.fromTextArray(
                border: pw.TableBorder.all(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.black),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
                cellHeight: 30,
                cellAlignments: {
                  0: pw.Alignment.center, // DATE
                  1: pw.Alignment.center, // START TIME
                  2: pw.Alignment.center, // END TIME
                  3: pw.Alignment.center, // STATUS
                },
                columnWidths: {
                  0: const pw.FlexColumnWidth(2),
                  1: const pw.FlexColumnWidth(2),
                  2: const pw.FlexColumnWidth(2),
                  3: const pw.FlexColumnWidth(1.5),
                },
                headers: ['DATE', 'START TIME', 'END TIME', 'STATUS'],
                data: tableData,
              ),

              pw.SizedBox(height: 24),

              // Summary Section (Total Shifts) - Simple text
              pw.Text(
                'Total Shifts: ${sortedScheduleData.length}',
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ];
          },
        ),
      );

      // Print the PDF
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: 'Checkpoint_Summary_${_selectedGuardName?.replaceAll(' ', '_')}_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.pdf',
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
                             color: Colors.orange,
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
                           icon: const Icon(Icons.table_chart),
                           label: const Text('CSV Report'),
                           onPressed: _exportCsv,
                           style: ElevatedButton.styleFrom(
                               backgroundColor: Colors.orange,
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
