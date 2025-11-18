import 'package:cloud_firestore/cloud_firestore.dart';

enum CheckpointScanStatus {
  notScanned,
  scanned,
}

String checkpointScanStatusToString(CheckpointScanStatus status) {
  switch (status) {
    case CheckpointScanStatus.scanned:
      return 'Scanned';
    case CheckpointScanStatus.notScanned:
      return 'Not Yet Scanned';
  }
}

CheckpointScanStatus checkpointScanStatusFromString(String? statusString) {
  if (statusString == null || statusString.isEmpty) {
    return CheckpointScanStatus.notScanned;
  }
  
  // Handle different possible status values
  final normalizedStatus = statusString.toLowerCase().trim();
  if (normalizedStatus == 'scanned' || 
      normalizedStatus == 'completed' || 
      normalizedStatus == 'done' ||
      normalizedStatus == 'visited') {
    return CheckpointScanStatus.scanned;
  }
  
  return CheckpointScanStatus.notScanned;
}

class CheckpointModel {
  final String id;
  final String name;
  final String location;
  final String? notes;
  final String? remarks;
  final String qrData;
  final Timestamp createdAt;
  Timestamp? lastAdminUpdate;
  Timestamp? lastScannedAt;
  CheckpointScanStatus status;
  // Who scanned last
  final String? lastScannedById;
  final String? lastScannedByName;
  // Normalized map coordinates [0..1] relative to map image width/height
  final double? mapX;
  final double? mapY;
  // Geographic coordinates for Google Maps
  final double? latitude;
  final double? longitude;

  CheckpointModel({
    required this.id,
    required this.name,
    required this.location,
    this.notes,
    this.remarks,
    required this.qrData,
    required this.createdAt,
    this.lastAdminUpdate,
    this.lastScannedAt,
    this.status = CheckpointScanStatus.notScanned,
    this.mapX,
    this.mapY,
    this.latitude,
    this.longitude,
    this.lastScannedById,
    this.lastScannedByName,
  });

  factory CheckpointModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) {
      throw StateError('Missing data for Checkpoint ID: ${doc.id}');
    }
    
    final statusString = data['status'] as String?;
    final parsedStatus = checkpointScanStatusFromString(statusString);
    
    // Debug logging to help identify status issues
    if (statusString != null && statusString.isNotEmpty) {
      print("Checkpoint ${doc.id} (${data['name']}): status='$statusString' -> parsed as ${parsedStatus == CheckpointScanStatus.scanned ? 'scanned' : 'notScanned'}");
    }
    
    double? parseLatitude(dynamic value) {
      try {
        if (value == null) return null;
        if (value is num) return value.toDouble();
        if (value is GeoPoint) return value.latitude.toDouble();
        if (value is String) return double.tryParse(value);
      } catch (_) {}
      return null;
    }

    double? parseLongitude(dynamic value) {
      try {
        if (value == null) return null;
        if (value is num) return value.toDouble();
        if (value is GeoPoint) return value.longitude.toDouble();
        if (value is String) return double.tryParse(value);
      } catch (_) {}
      return null;
    }

    Timestamp? parseTimestamp(dynamic value) {
      try {
        if (value == null) return null;
        if (value is Timestamp) return value;
        if (value is DateTime) return Timestamp.fromDate(value);
        if (value is int) {
          // Heuristic: treat as millisecondsSinceEpoch if large
          final millis = value;
          return Timestamp.fromMillisecondsSinceEpoch(millis);
        }
        if (value is String) {
          final dt = DateTime.tryParse(value);
          if (dt != null) return Timestamp.fromDate(dt);
        }
      } catch (_) {}
      return null;
    }

    String? parseString(dynamic value) {
      try {
        if (value == null) return null;
        if (value is String) return value;
        return value.toString();
      } catch (_) {}
      return null;
    }

    String? mapString(Map<String, dynamic>? m, List<String> keys) {
      if (m == null) return null;
      for (final k in keys) {
        final v = m[k];
        if (v is String && v.trim().isNotEmpty) return v;
      }
      return null;
    }

    dynamic latitudeSource =
        data['latitude'] ??
        data['lat'] ??
        data['Latitude'] ??
        data['Lat'];
    dynamic longitudeSource =
        data['longitude'] ??
        data['lon'] ??
        data['lng'] ??
        data['Longitude'] ??
        data['Long'] ??
        data['Lng'];
    final dynamic geoPointLike =
        data['geoPoint'] ??
        data['geo_point'] ??
        data['geo'] ??
        data['coordinates'] ??
        data['locationGeo'] ??
        data['position'];
    if (latitudeSource == null && geoPointLike != null) {
      latitudeSource = geoPointLike;
    }
    if (longitudeSource == null && geoPointLike != null) {
      longitudeSource = geoPointLike;
    }

    final dynamic lastScannedByRaw = data['lastScannedBy'];
    Map<String, dynamic>? lastScannedByMap;
    if (lastScannedByRaw is Map) {
      lastScannedByMap = Map<String, dynamic>.from(lastScannedByRaw);
    }

    return CheckpointModel(
      id: doc.id,
      name: data['name'] ?? 'Unknown Name',
      location: data['location'] ?? 'Unknown Location',
      notes: data['notes'] as String?,
      remarks: data['remarks'] as String?,
      qrData: data['qrData'] ?? '',
      createdAt: parseTimestamp(data['createdAt']) ?? Timestamp.now(),
      lastAdminUpdate: parseTimestamp(data['lastAdminUpdate']),
      lastScannedAt: parseTimestamp(data['lastScannedAt']),
      status: parsedStatus,
      mapX: (data['mapX'] as num?)?.toDouble(),
      mapY: (data['mapY'] as num?)?.toDouble(),
      latitude: parseLatitude(latitudeSource),
      longitude: parseLongitude(longitudeSource),
      lastScannedById: parseString(
        data['lastScannedById'] ??
        (lastScannedByMap != null ? (lastScannedByMap['uid'] ?? lastScannedByMap['id']) : null) ??
        data['scannedById'] ?? data['scannedBy']
      ),
      lastScannedByName: parseString(
        data['lastScannedByName'] ??
        data['scannedByName'] ??
        data['scannerName'] ??
        mapString(lastScannedByMap, ['name', 'displayName', 'fullName', 'email'])
      ),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'location': location,
      'notes': notes,
      'remarks': remarks,
      'qrData': qrData,
      'createdAt': createdAt,
      'lastAdminUpdate': lastAdminUpdate,
      'lastScannedAt': lastScannedAt,
      'status': checkpointScanStatusToString(status),
      'lastScannedById': lastScannedById,
      'lastScannedByName': lastScannedByName,
      'mapX': mapX,
      'mapY': mapY,
      'latitude': latitude,
      'longitude': longitude,
    };
  }

  CheckpointModel copyWith({
    String? id,
    String? name,
    String? location,
    String? notes,
    String? remarks,
    String? qrData,
    Timestamp? createdAt,
    Timestamp? lastAdminUpdate,
    Timestamp? lastScannedAt,
    CheckpointScanStatus? status,
    double? mapX,
    double? mapY,
    double? latitude,
    double? longitude,
    String? lastScannedById,
    String? lastScannedByName,
  }) {
    return CheckpointModel(
      id: id ?? this.id,
      name: name ?? this.name,
      location: location ?? this.location,
      notes: notes ?? this.notes,
      remarks: remarks ?? this.remarks,
      qrData: qrData ?? this.qrData,
      createdAt: createdAt ?? this.createdAt,
      lastAdminUpdate: lastAdminUpdate ?? this.lastAdminUpdate,
      lastScannedAt: lastScannedAt ?? this.lastScannedAt,
      status: status ?? this.status,
      mapX: mapX ?? this.mapX,
      mapY: mapY ?? this.mapY,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      lastScannedById: lastScannedById ?? this.lastScannedById,
      lastScannedByName: lastScannedByName ?? this.lastScannedByName,
    );
  }
}
