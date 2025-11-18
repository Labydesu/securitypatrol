import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import '../models/checkpoint_model.dart';
import 'package:thesis_web/main_screens/login/login_screen.dart';

class MappingManagementScreen extends StatefulWidget {
  final bool selectMode;

  const MappingManagementScreen({
    super.key,
    this.selectMode = false,
  });

  @override
  State<MappingManagementScreen> createState() => _MappingManagementScreenState();
}

class _MappingManagementScreenState extends State<MappingManagementScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoading = true;
  List<CheckpointModel> _checkpoints = [];
  LatLng? _selectedLatLng;
  bool _isSelecting = false;
  // Controller kept for future interactions; suppress unused warning by referencing in build
  // Note: store controller for completeness
  GoogleMapController? _mapController;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _checkpointSub;
  // Small custom circle icons to ensure color reflects status across platforms
  BitmapDescriptor? _iconScanned;
  BitmapDescriptor? _iconNotScanned;

  @override
  void initState() {
    super.initState();
    _initializeScreen();
  }

  Future<void> _initializeScreen() async {
    await _prepareMarkerIcons(size: 38);
    _listenToCheckpointStream();
  }

  void _listenToCheckpointStream() {
    _checkpointSub?.cancel();
    _checkpointSub = _firestore.collection('Checkpoints').snapshots().listen((snapshot) {
      if (!mounted) return;
      setState(() {
        _checkpoints = snapshot.docs.map((doc) => CheckpointModel.fromFirestore(doc)).toList();
        _isLoading = false;
      });
    }, onError: (e) {
      debugPrint('Error loading checkpoints: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _checkpoints = [];
        });
      }
    });
  }

  Future<void> _prepareMarkerIcons({int size = 38}) async {
    try {
      final scanned = await _createMarkerBitmap(color: Colors.green.shade700, size: size);
      final notScanned = await _createMarkerBitmap(color: Colors.red.shade700, size: size);
      if (!mounted) return;
      setState(() {
        _iconScanned = scanned;
        _iconNotScanned = notScanned;
      });
    } catch (_) {}
  }

  Future<BitmapDescriptor> _createMarkerBitmap({required Color color, int size = 38}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final double radius = size / 2.0;

    // Outer white border
    final borderPaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(radius, radius), radius, borderPaint);

    // Inner colored circle
    final fillPaint = Paint()..color = color;
    canvas.drawCircle(Offset(radius, radius), radius - 3, fillPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size, size);
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
  }

  @override
  void dispose() {
    _checkpointSub?.cancel();
    super.dispose();
  }

  void _onMapTap(LatLng latLng) {
    if (!widget.selectMode) return;
    setState(() {
      _selectedLatLng = latLng;
      _isSelecting = true;
    });
  }

  void _confirmSelection() {
    if (_selectedLatLng != null) {
      Navigator.pop(context, {
        'mapX': null,
        'mapY': null,
        'latitude': _selectedLatLng!.latitude,
        'longitude': _selectedLatLng!.longitude,
      });
    }
  }

  void _cancelSelection() {
    setState(() {
      _selectedLatLng = null;
      _isSelecting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.selectMode ? 'Select Map Location' : 'DMMMSU NLUC Map'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        actions: widget.selectMode
            ? [
                if (_isSelecting) ...[
                  TextButton(
                    onPressed: _cancelSelection,
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: colorScheme.onPrimary),
                    ),
                  ),
                  TextButton(
                    onPressed: _confirmSelection,
                    child: Text(
                      'Confirm',
                      style: TextStyle(color: colorScheme.onPrimary),
                    ),
                  ),
                ],
              ]
            : [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context) => const LoginScreen()),
                      );
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.onPrimary,
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    child: const Text('Login'),
                  ),
                ),
              ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _initialCameraTarget(),
                      zoom: 16,
                    ),
                    markers: _buildMarkers(),
                    onTap: _onMapTap,
                    onMapCreated: (controller) {
                      _mapController = controller;
                      // no-op usage to satisfy analyzer
                      // ignore: unnecessary_statements
                      _mapController?.hashCode;
                    },
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: true,
                  ),
                ),

                // Bottom Panel
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.selectMode) ...[
                        Text(
                          'Selection Mode',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _selectedLatLng != null
                              ? 'Selected: ${_selectedLatLng!.latitude.toStringAsFixed(6)}, ${_selectedLatLng!.longitude.toStringAsFixed(6)}'
                              : 'Tap on the map to select a location',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _cancelSelection,
                                child: const Text('Cancel'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _selectedLatLng != null
                                    ? _confirmSelection
                                    : null,
                                child: const Text('Confirm Selection'),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        Text(
                          'Checkpoint Summary',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSummaryCard(
                                'Total Checkpoints',
                                _checkpoints.length.toString(),
                                Icons.location_on,
                                colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildSummaryCard(
                                'With GPS Location',
                                _checkpoints.where((cp) => cp.latitude != null && cp.longitude != null).length.toString(),
                                Icons.map,
                                Colors.blue,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildSummaryCard(
                                'Scanned Today',
                                _checkpoints.where((cp) => cp.status == CheckpointScanStatus.scanned).length.toString(),
                                Icons.check_circle,
                                Colors.green,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSummaryCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: color.withOpacity(0.8),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
  LatLng _initialCameraTarget() {
    final withGps = _checkpoints.where((c) => c.latitude != null && c.longitude != null).toList();
    if (withGps.isNotEmpty) {
      return LatLng(withGps.first.latitude!, withGps.first.longitude!);
    }
    return const LatLng(0.0, 0.0);
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};
    for (final cp in _checkpoints) {
      if (cp.latitude != null && cp.longitude != null) {
        final BitmapDescriptor icon;
        if (_iconScanned != null && _iconNotScanned != null) {
          icon = cp.status == CheckpointScanStatus.scanned ? _iconScanned! : _iconNotScanned!;
        } else {
          final hue = cp.status == CheckpointScanStatus.scanned ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed;
          icon = BitmapDescriptor.defaultMarkerWithHue(hue);
        }
        markers.add(
          Marker(
            markerId: MarkerId(cp.id),
            position: LatLng(cp.latitude!, cp.longitude!),
            infoWindow: InfoWindow(
              title: cp.name,
              snippet: checkpointScanStatusToString(cp.status),
            ),
            icon: icon,
          ),
        );
      }
    }
    if (_isSelecting && _selectedLatLng != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('selection'),
          position: _selectedLatLng!,
          infoWindow: const InfoWindow(title: 'Selected Location'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        ),
      );
    }
    return markers;
  }
}
