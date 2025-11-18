import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:thesis_web/utils/download_saver.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const PdfPageFormat _longBondPageFormat = PdfPageFormat(
  8.5 * PdfPageFormat.inch,
  13 * PdfPageFormat.inch,
);

class GuardListReportScreen extends StatefulWidget {
  const GuardListReportScreen({super.key});

  @override
  State<GuardListReportScreen> createState() => _GuardListReportScreenState();
}

class _GuardListReportScreenState extends State<GuardListReportScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _guards = [];
  String _search = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await _firestore
          .collection('Accounts')
          .where('role', isEqualTo: 'Security')
          .get();
      final rows = snap.docs.map((d) {
        final data = d.data();
        final first = data['first_name'] as String? ?? '';
        final last = data['last_name'] as String? ?? '';
        final name = ('$first $last').trim().isEmpty
            ? (data['name'] as String? ?? 'Unnamed Guard')
            : ('$first $last').trim();
        return {
          'id': d.id,
          'guard_id': data['guard_id'] as String? ?? d.id,
          'name': name,
          'position': (data['position'] as String?) ?? (data['job_title'] as String?) ?? '-',
          'email': data['email'] as String? ?? '-',
        };
      }).toList();
      rows.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      setState(() {
        _guards = rows;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredGuards {
    final q = _search.toLowerCase().trim();
    if (q.isEmpty) return _guards;
    return _guards.where((g) {
      final name = (g['name'] as String).toLowerCase();
      final gid = (g['guard_id'] as String).toLowerCase();
      return name.contains(q) || gid.contains(q);
    }).toList();
  }

  Future<void> _print() async {
    if (_guards.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No guards to print')),
      );
      return;
    }
    final pdfBytes = await _buildPdf(_filteredGuards);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdfBytes,
      name: 'Guard_List_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf',
    );
  }

  Future<Uint8List> _buildPdf(List<Map<String, dynamic>> rows) async {
    pw.Font? base;
    pw.Font? bold;
    // Load from assets; if Regular missing, use Bold for both
    final boldData = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
    bold = pw.Font.ttf(boldData);
    try {
      final baseData = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
      base = pw.Font.ttf(baseData);
    } catch (_) {
      base = bold;
    }

    final doc = pw.Document(theme: pw.ThemeData.withFont(base: base, bold: bold));
    doc.addPage(
      pw.Page(
        pageFormat: _longBondPageFormat,
        margin: const pw.EdgeInsets.only(left: 40, right: 40, top: 80, bottom: 80),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(
                child: pw.Text(
                  'Security Guards',
                  style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Text('Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 16),
              pw.Table(
                border: pw.TableBorder.all(),
                columnWidths: {
                  0: const pw.FixedColumnWidth(30),
                  1: const pw.FlexColumnWidth(1.6),
                  2: const pw.FlexColumnWidth(1.2),
                  3: const pw.FlexColumnWidth(1.2),
                  4: const pw.FlexColumnWidth(1.6),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                    children: [
                      _cell('No.', bold: true),
                      _cell('Guard Name', bold: true),
                      _cell('Guard ID', bold: true),
                      _cell('Position', bold: true),
                      _cell('Email', bold: true),
                    ],
                  ),
                  ...List.generate(rows.length, (i) {
                    final r = rows[i];
                    return pw.TableRow(
                      children: [
                        _cell('${i + 1}'),
                        _cell(r['name'] as String),
                        _cell(r['guard_id'] as String),
                        _cell(r['position'] as String),
                        _cell(r['email'] as String),
                      ],
                    );
                  }),
                ],
              ),
              pw.SizedBox(height: 12),
              pw.Text('Total Guards: ${rows.length}', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 40),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Align(
                    alignment: pw.Alignment.centerLeft,
                    child: pw.Text(
                      'Prepared by:',
                      style: const pw.TextStyle(fontSize: 11),
                    ),
                  ),
                  pw.SizedBox(height: 20),
                  pw.Align(
                    alignment: pw.Alignment.center,
                    child: pw.Column(
                      children: [
                        pw.Text(
                          'PRINCE JUN N. DAMASCO',
                          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'Head, Security Services',
                          style: const pw.TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
    return doc.save();
  }

  Future<void> _exportCsv() async {
    final rows = _filteredGuards;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No guards to export')),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('No.,Guard Name,Guard ID,Position,Email');
    for (int i = 0; i < rows.length; i++) {
      final r = rows[i];
      String esc(String v) => '"${v.replaceAll('"', '""')}"';
      buffer.writeln([
        '${i + 1}',
        esc((r['name'] as String? ?? '')),
        esc((r['guard_id'] as String? ?? '')),
        esc((r['position'] as String? ?? '')),
        esc((r['email'] as String? ?? '')),
      ].join(','));
    }

    final bytes = Uint8List.fromList(buffer.toString().codeUnits);
    final fileName = 'Guard_List_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';

    if (kIsWeb) {
      await saveBytesAsDownload(fileName, bytes, mimeType: 'text/csv');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV downloaded')));
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path)], text: 'Guard list report');
    }
  }

  pw.Widget _cell(String text, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(text, style: pw.TextStyle(fontSize: 11, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nav = appNavList(context, closeDrawer: true);
    final body = Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: 'Search by name or Guard ID',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
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
                  child: IconButton(
                    onPressed: _loading ? null : _fetch, 
                    icon: const Icon(Icons.refresh),
                  ),
                ),
                const SizedBox(width: 12),
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
                    onPressed: _loading ? null : _print, 
                    icon: const Icon(Icons.picture_as_pdf), 
                    label: const Text('Print / Export'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
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
                    onPressed: _loading ? null : _exportCsv,
                    icon: const Icon(Icons.table_view),
                    label: const Text('Export CSV'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_error != null
                      ? Center(child: Text('Error: $_error'))
                      : _buildTable()),
            ),
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
        title: const Text('Report: Security Guard List'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: _loading ? null : _print, icon: const Icon(Icons.print)),
        ],
      ),
      drawer: Drawer(child: nav),
      body: body,
    );
  }

  Widget _buildTable() {
    final rows = _filteredGuards;
    if (rows.isEmpty) {
      return const Center(child: Text('No guards found'));
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
                    flex: 1,
                    child: Text(
                      'No.',
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
                      'GUARD NAME',
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
                      'GUARD ID',
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
                      'POSITION',
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
                      'EMAIL',
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
                children: rows.asMap().entries.map((entry) {
                  final index = entry.key;
                  final guard = entry.value;
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
                          flex: 1,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            guard['name'] as String,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            guard['guard_id'] as String,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(guard['position'] as String),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(guard['email'] as String),
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
  }
}


