import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;
// Removed google fonts; use bundled assets
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:thesis_web/utils/download_saver.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const PdfPageFormat _longBondPageFormat = PdfPageFormat(
  8.5 * PdfPageFormat.inch,
  13 * PdfPageFormat.inch,
);

class CheckpointListReportScreen extends StatefulWidget {
  const CheckpointListReportScreen({super.key});

  @override
  State<CheckpointListReportScreen> createState() => _CheckpointListReportScreenState();
}

class _CheckpointListReportScreenState extends State<CheckpointListReportScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _checkpoints = [];
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
      final snap = await _firestore.collection('Checkpoints').get();
      final rows = snap.docs.map((d) {
        final data = d.data();
        return {
          'id': d.id,
          'name': data['name'] as String? ?? d.id,
          'location': data['location'] as String? ?? '-',
        };
      }).toList();
      rows.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      setState(() {
        _checkpoints = rows;
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

  List<Map<String, dynamic>> get _filtered {
    final q = _search.toLowerCase().trim();
    if (q.isEmpty) return _checkpoints;
    return _checkpoints.where((c) {
      final name = (c['name'] as String).toLowerCase();
      final id = (c['id'] as String).toLowerCase();
      return name.contains(q) || id.contains(q);
    }).toList();
  }

  Future<void> _print() async {
    final rows = _filtered;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No checkpoints to print')),
      );
      return;
    }
    final bytes = await _buildPdf(rows);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => bytes,
      name: 'Checkpoint_List_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf',
    );
  }

  Future<Uint8List> _buildPdf(List<Map<String, dynamic>> rows) async {
    pw.Font? base;
    pw.Font? bold;
    try {
      final boldData = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
      bold = pw.Font.ttf(boldData);
      // Regular is optional; if missing, use bold as base too
      try {
        final baseData = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
        base = pw.Font.ttf(baseData);
      } catch (_) {
        base = bold;
      }
    } catch (e) {
      // If even bold cannot be loaded, rethrow to surface the configuration issue
      rethrow;
    }

    final doc = pw.Document(theme: pw.ThemeData.withFont(base: base, bold: bold));
    doc.addPage(
      pw.MultiPage(
        pageFormat: _longBondPageFormat,
        margin: const pw.EdgeInsets.only(left: 40, right: 40, top: 80, bottom: 80),
        build: (context) => [
          pw.Center(
            child: pw.Text(
              'Checkpoint List',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text('Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
          pw.SizedBox(height: 16),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.8),
            columnWidths: {
              0: const pw.FixedColumnWidth(40),
              1: const pw.FlexColumnWidth(2),
              2: const pw.FlexColumnWidth(3),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _cell('No.', bold: true),
                  _cell('Name', bold: true),
                  _cell('Location', bold: true),
                ],
              ),
              ...List.generate(rows.length, (i) {
                final r = rows[i];
                return pw.TableRow(
                  children: [
                    _cell('${i + 1}')
                    , _cell(r['name'] as String)
                    , _cell(r['location'] as String)
                  ],
                );
              }),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Text('Total Checkpoints: ${rows.length}', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
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
      ),
    );
    return doc.save();
  }

  Future<void> _exportCsv() async {
    final rows = _filtered;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No checkpoints to export')),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('No.,Name,Location,ID');
    for (int i = 0; i < rows.length; i++) {
      final r = rows[i];
      String esc(String v) => '"${v.replaceAll('"', '""')}"';
      buffer.writeln([
        '${i + 1}',
        esc((r['name'] as String? ?? '')),
        esc((r['location'] as String? ?? '')),
        esc((r['id'] as String? ?? '')),
      ].join(','));
    }

    final bytes = Uint8List.fromList(buffer.toString().codeUnits);
    final fileName = 'Checkpoint_List_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';

    if (kIsWeb) {
      await saveBytesAsDownload(fileName, bytes, mimeType: 'text/csv');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV downloaded')));
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path)], text: 'Checkpoint list report');
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
                        labelText: 'Search by name or ID',
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
        title: const Text('Report: Checkpoint List'),
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
    final rows = _filtered;
    if (rows.isEmpty) {
      return const Center(child: Text('No checkpoints found'));
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
                      'NAME',
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
                      'LOCATION',
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
                  final checkpoint = entry.value;
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
                            checkpoint['name'] as String,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(checkpoint['location'] as String),
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


