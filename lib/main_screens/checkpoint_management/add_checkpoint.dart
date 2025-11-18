import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' as pdf_core;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:screenshot/screenshot.dart';
import 'package:thesis_web/main_screens/models/checkpoint_model.dart';
import 'package:thesis_web/main_screens/mapping/mapping_management.dart';
import 'package:thesis_web/widgets/app_nav.dart';


const pdf_core.PdfPageFormat _longBondPageFormat = pdf_core.PdfPageFormat(
  8.5 * pdf_core.PdfPageFormat.inch,
  13 * pdf_core.PdfPageFormat.inch,
);

class AddCheckpointScreen extends StatefulWidget {
  final CheckpointModel? checkpointToEdit;

  const AddCheckpointScreen({super.key, this.checkpointToEdit});

  @override
  State<AddCheckpointScreen> createState() => _AddCheckpointScreenState();
}

class _AddCheckpointScreenState extends State<AddCheckpointScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  String? _qrDataString;
  bool _isSaving = false;
  bool _isEditMode = false;
  String _originalCheckpointIdForQr = '';
  double? _mapX; // legacy normalized 0..1 (kept for backward compatibility)
  double? _mapY;
  double? _latitude;
  double? _longitude;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ScreenshotController _screenshotController = ScreenshotController();

  @override
  void initState() {
    super.initState();
    if (widget.checkpointToEdit != null) {
      _isEditMode = true;
      final cp = widget.checkpointToEdit!;
      _nameController.text = cp.name;
      _idController.text = cp.id;
      _originalCheckpointIdForQr = cp.id;
      _locationController.text = cp.location;
      _notesController.text = cp.notes ?? '';
      _qrDataString = cp.qrData;
      _mapX = cp.mapX;
      _mapY = cp.mapY;
      _latitude = cp.latitude;
      _longitude = cp.longitude;
    }
    // If creating new, suggest next checkpoint ID like CP00X
    if (!_isEditMode) {
      _suggestAndPrefillNextCheckpointId();
    }
  }

  void _generateQrDataForScreen(String checkpointId) {
    if (checkpointId.isEmpty) {
      setState(() {
        _qrDataString = null;
      });
      return;
    }
    final Map<String, dynamic> qrPayload = {
      'checkpoint_id': checkpointId,
      'name': _nameController.text.trim(),
      'location': _locationController.text.trim(),
    };
    setState(() {
      _qrDataString = jsonEncode(qrPayload);
    });
  }

  Future<void> _triggerQrGenerationAndDisplay() async {
    if (!_formKey.currentState!.validate()) {
      _showFeedbackSnackbar('Please correct the errors in the form.', isError: true);
      return;
    }
    String idForQr = _isEditMode ? _originalCheckpointIdForQr : _idController.text.trim();
    if (idForQr.isEmpty) {
      _showFeedbackSnackbar('Checkpoint ID is required to generate QR data.', isError: true, isWarning: true);
      return;
    }
    _generateQrDataForScreen(idForQr);
    if (_qrDataString == null && mounted) {
      _showFeedbackSnackbar('Could not generate QR data. Check fields.', isError: true);
    } else if (mounted) {
      _showFeedbackSnackbar('QR Code generated/refreshed successfully.', isError: false);
    }
  }

  Future<bool> _isCheckpointIdUnique(String id) async {
    if (_isEditMode && id == widget.checkpointToEdit!.id) {
      return true;
    }
    final querySnapshot = await _firestore.collection('Checkpoints').doc(id).get();
    return !querySnapshot.exists;
  }

  Future<void> _saveOrUpdateCheckpointData() async {
    if (!_formKey.currentState!.validate()) {
      _showFeedbackSnackbar('Please fill all required fields correctly.', isError: true);
      return;
    }

    if (_qrDataString == null) {
      _generateQrDataForScreen(_isEditMode ? _originalCheckpointIdForQr : _idController.text.trim());
      if (_qrDataString == null) {
        _showFeedbackSnackbar('Please generate or ensure QR Code data is present before saving.', isError: true, isWarning: true);
        return;
      }
    }

    // Must have GPS coordinates selected now
    if (_latitude == null || _longitude == null) {
      _showFeedbackSnackbar('Please select a GPS location on the map before saving.', isError: true, isWarning: true);
      return;
    }

    setState(() { _isSaving = true; });

    final String name = _nameController.text.trim();
    final String currentId = _idController.text.trim();
    final String documentId = _isEditMode ? widget.checkpointToEdit!.id : currentId;

    if (!_isEditMode) {
      final bool isUnique = await _isCheckpointIdUnique(documentId);
      if (!isUnique) {
        if (mounted) {
          _showFeedbackSnackbar('Error: Checkpoint ID "$documentId" already exists.', isError: true);
          setState(() { _isSaving = false; });
        }
        return;
      }
    }

    Map<String, dynamic> checkpointFirestoreData;

    if (_isEditMode) {
      final updatedCheckpoint = widget.checkpointToEdit!.copyWith(
        name: name,
        location: _locationController.text.trim(),
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
        qrData: _qrDataString,
        lastAdminUpdate: Timestamp.now(),
        mapX: _mapX,
        mapY: _mapY,
        latitude: _latitude,
        longitude: _longitude,
      );
      checkpointFirestoreData = updatedCheckpoint.toFirestore();
    } else {
      final newCheckpoint = CheckpointModel(
        id: documentId,
        name: name,
        location: _locationController.text.trim(),
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
        qrData: _qrDataString!,
        createdAt: Timestamp.now(),
        lastAdminUpdate: Timestamp.now(),
        status: CheckpointScanStatus.notScanned,
        lastScannedAt: null,
        mapX: _mapX,
        mapY: _mapY,
        latitude: _latitude,
        longitude: _longitude,
      );
      checkpointFirestoreData = newCheckpoint.toFirestore();
    }


    try {
      final checkpointRef = _firestore.collection('Checkpoints').doc(documentId);
      if (_isEditMode) {
        await checkpointRef.update(checkpointFirestoreData);
      } else {
        await checkpointRef.set(checkpointFirestoreData);
        _originalCheckpointIdForQr = documentId;
      }
      if (mounted) {
        _showFeedbackSnackbar(
          'Checkpoint "$name" ${_isEditMode ? "updated" : "created"} successfully!',
          isError: false,
        );
        if (Navigator.canPop(context)) {
          Navigator.of(context).pop(true); // Pop with a result to indicate success
        }
      }
    } catch (e) {
      if (mounted) {
        _showFeedbackSnackbar('Error saving checkpoint: ${e.toString()}', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() { _isSaving = false; });
      }
    }
  }

  Future<void> _suggestAndPrefillNextCheckpointId() async {
    try {
      final String nextId = await _generateNextCheckpointId();
      if (mounted && _idController.text.trim().isEmpty) {
        setState(() {
          _idController.text = nextId;
        });
      }
    } catch (_) {
      // Silent fail on suggestion; user can still type manually
    }
  }

  Future<String> _generateNextCheckpointId() async {
    // Fetch existing checkpoint document IDs and compute next CP number
    final snap = await _firestore.collection('Checkpoints').get();
    int maxNum = 0;
    int padLen = 3; // default CP001
    final regex = RegExp(r'^CP(\d+)\$');
    for (final d in snap.docs) {
      final id = d.id.trim();
      final m = regex.firstMatch(id);
      if (m != null) {
        final numStr = m.group(1)!;
        final n = int.tryParse(numStr) ?? 0;
        if (n > maxNum) {
          maxNum = n;
          padLen = numStr.length; // keep current padding width
        }
      }
    }
    int candidate = maxNum + 1;
    String makeId(int n) => 'CP' + n.toString().padLeft(padLen, '0');

    String next = makeId(candidate);
    // Ensure uniqueness in case of concurrent creation
    while (!(await _isCheckpointIdUnique(next))) {
      candidate++;
      next = makeId(candidate);
    }
    return next;
  }


  Future<void> _printQrCode() async {
    if (_qrDataString == null) {
      _showFeedbackSnackbar('Generate a QR code first to print.', isError: true, isWarning: true);
      return;
    }
    try {
      final Uint8List? imageBytes = await _screenshotController.capture();
      if (imageBytes == null) {
        _showFeedbackSnackbar('Could not capture QR code for printing.', isError: true);
        return;
      }
      final pdf = pw.Document();
      final image = pw.MemoryImage(imageBytes);
      final checkpointName = _nameController.text.trim();
      final checkpointId = _isEditMode ? _originalCheckpointIdForQr : _idController.text.trim();

      pdf.addPage(pw.Page(
          pageFormat: _longBondPageFormat,
          build: (pw.Context context) {
            return pw.Center(
                child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Text(checkpointName, style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 8),
                      pw.Text("ID: $checkpointId", style: const pw.TextStyle(fontSize: 16)),
                      pw.SizedBox(height: 20),
                      pw.Container(width: 250, height: 250, child: pw.Image(image)),
                    ]));
          }));
      await Printing.layoutPdf(
        onLayout: (pdf_core.PdfPageFormat format) async => pdf.save(),
        name: 'Checkpoint_QR_${checkpointName.replaceAll(RegExp(r'[^\w\s]+'), '_')}.pdf',
      );
    } catch (e) {
      _showFeedbackSnackbar('Error printing QR code: ${e.toString()}', isError: true);
    }
  }

  void _showFeedbackSnackbar(String message, {required bool isError, bool isWarning = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : (isWarning ? Colors.orangeAccent : Colors.green),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _locationController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool isRequired = true,
    String? hintText,
    bool readOnly = false,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        maxLines: maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText ?? 'Enter $label',
          prefixIcon: Icon(icon),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          fillColor: readOnly ? Colors.grey[200] : null,
          filled: readOnly,
          floatingLabelBehavior: FloatingLabelBehavior.auto,
        ),
        validator: validator ?? (value) {
          if (isRequired && (value == null || value.trim().isEmpty)) {
            return '$label is required.';
          }
          return null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final double buttonWidth = MediaQuery.of(context).size.width * 0.6;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? 'Edit Checkpoint Details' : 'Create New Checkpoint'),
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: Drawer(child: appNavList(context, closeDrawer: true)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTextField(
                controller: _idController,
                label: 'Checkpoint ID',
                icon: Icons.vpn_key_outlined,
                hintText: 'e.g., CP001, MainGateNorth',
                readOnly: _isEditMode,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return 'Checkpoint ID is required.';
                  if (value.length < 3) return 'ID must be at least 3 characters long.';
                  if (RegExp(r'\s').hasMatch(value)) return 'ID cannot contain spaces.';
                  return null;
                },
              ),
              if (!_isEditMode)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _suggestAndPrefillNextCheckpointId,
                    icon: const Icon(Icons.autorenew),
                    label: const Text('Suggest next ID'),
                  ),
                ),
              _buildTextField(
                controller: _nameController,
                label: 'Checkpoint Name',
                icon: Icons.label_important_outline,
              ),
              _buildTextField(
                controller: _locationController,
                label: 'Location Description',
                icon: Icons.location_on_outlined,
                maxLines: 2,
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _latitude != null && _longitude != null
                          ? 'GPS: ${_latitude!.toStringAsFixed(6)}, ${_longitude!.toStringAsFixed(6)}'
                          : 'GPS: not selected',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Pick on Map'),
                    onPressed: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const MappingManagementScreen(selectMode: true),
                        ),
                      );
                      if (result is Map && mounted) {
                        setState(() {
                          _mapX = (result['mapX'] as num?)?.toDouble();
                          _mapY = (result['mapY'] as num?)?.toDouble();
                          _latitude = (result['latitude'] as num?)?.toDouble();
                          _longitude = (result['longitude'] as num?)?.toDouble();
                        });
                      }
                    },
                  ),
                ],
              ),
              _buildTextField(
                controller: _notesController,
                label: 'Notes (Optional)',
                icon: Icons.notes_outlined,
                isRequired: false,
                maxLines: 3,
              ),
              const SizedBox(height: 25),
              Center(
                child: SizedBox(
                  width: buttonWidth,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code_scanner_outlined),
                    label: Text(_qrDataString == null ? 'Generate QR Code' : 'Refresh QR Code'),
                    onPressed: _triggerQrGenerationAndDisplay,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colorScheme.secondary,
                      side: BorderSide(color: colorScheme.secondary),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 15),
              if (_isSaving)
                const Center(child: CircularProgressIndicator())
              else
                Center(
                  child: SizedBox(
                    width: buttonWidth,
                    child: ElevatedButton.icon(
                      icon: Icon(_isEditMode ? Icons.save_alt_outlined : Icons.add_circle_outline),
                      label: Text(_isEditMode ? 'Update Details' : 'Create Checkpoint'),
                      onPressed: _saveOrUpdateCheckpointData,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isEditMode ? Colors.orange.shade700 : colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 25),
              if (_qrDataString != null) ...[
                Center(
                  child: Text(
                    'Checkpoint QR Code',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Screenshot(
                    controller: _screenshotController,
                    child: Container(
                      padding: const EdgeInsets.all(10.0),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: Colors.grey.shade300, width: 1.5),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withOpacity(0.3),
                            spreadRadius: 2,
                            blurRadius: 5,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: QrImageView(
                        data: _qrDataString!,
                        version: QrVersions.auto,
                        size: 230,
                        gapless: false,
                        backgroundColor: Colors.white,
                        errorStateBuilder: (cxt, err) {
                          return Container(
                            width: 230,
                            height: 230,
                            alignment: Alignment.center,
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.error_outline, color: Colors.red, size: 40),
                                SizedBox(height: 8),
                                Text('Error generating QR.', textAlign: TextAlign.center, style: TextStyle(color: Colors.red)),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    "Scan for essential checkpoint details.",
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: Colors.grey.shade700),
                  ),
                ),
                const SizedBox(height: 15),
                Center(
                  child: SizedBox(
                    width: buttonWidth,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print QR with Details'),
                      onPressed: _printQrCode,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.tertiaryContainer,
                        foregroundColor: colorScheme.onTertiaryContainer,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

}