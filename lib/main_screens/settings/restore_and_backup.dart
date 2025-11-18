import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:thesis_web/utils/download_saver.dart';
import 'package:thesis_web/services/app_logger.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'dart:typed_data';

class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  String? statusMessage;
  bool _isLoading = false;
  bool _isSuccess = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      // Request storage permission for Android
      final status = await Permission.storage.request();
      if (status != PermissionStatus.granted) {
        print('Storage permission denied');
      }
    }
  }

  Future<void> _createBackup() async {
    setState(() {
      _isLoading = true;
      statusMessage = 'Creating backup...';
      _isSuccess = false;
    });

    try {
      // Step 1: Collect backup data
      setState(() {
        statusMessage = 'Collecting data from Firestore...';
      });
      final backupData = await _collectBackupData();
      
      // Step 2: Convert to JSON
      setState(() {
        statusMessage = 'Converting data to JSON format...';
      });
      final jsonData = jsonEncode(backupData);
      
      // Step 3: Save or share backup depending on platform
      setState(() {
        statusMessage = 'Saving backup file...';
      });

      final dateStr = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final backupFileName = 'security_backup_$dateStr.json';

      if (kIsWeb) {
        // On web, trigger a browser download directly to avoid permission prompts.
        final bytes = Uint8List.fromList(utf8.encode(jsonData));
        await saveBytesAsDownload(backupFileName, bytes, mimeType: 'application/json');
        setState(() {
          statusMessage = 'Backup downloaded as $backupFileName';
          _isSuccess = true;
          _isLoading = false;
        });

        // Log backup creation
        await AppLogger.log(
          type: 'Backup',
          message: 'Backup created (web download)',
          metadata: {
            'fileName': backupFileName,
            'byteLength': bytes.length,
          },
        );
      } else {
        final directory = await getApplicationDocumentsDirectory();
        final backupFile = File('${directory.path}/$backupFileName');

        // Write backup file
        await backupFile.writeAsString(jsonData);

        // Verify file was created
        if (!await backupFile.exists()) {
          throw Exception('Backup file was not created successfully');
        }

        final fileSize = await backupFile.length();

        setState(() {
          statusMessage = 'Backup created successfully!\nFile: $backupFileName\nSize: ${(fileSize / 1024).toStringAsFixed(1)} KB';
          _isSuccess = true;
          _isLoading = false;
        });

        // Log backup creation
        await AppLogger.log(
          type: 'Backup',
          message: 'Backup created',
          metadata: {
            'filePath': backupFile.path,
            'fileName': backupFileName,
            'fileSizeBytes': fileSize,
          },
        );

        // Show success dialog with file path
        _showSuccessDialog(backupFile.path, fileSize);
      }
      
    } catch (e) {
      print('Backup error details: $e');
      setState(() {
        statusMessage = 'Error creating backup: ${e.toString()}';
        _isSuccess = false;
        _isLoading = false;
      });
    }
  }

  Future<Map<String, dynamic>> _collectBackupData() async {
    final firestore = FirebaseFirestore.instance;
    final backupData = <String, dynamic>{
      'metadata': {
        'createdAt': DateTime.now().toIso8601String(),
        'version': '2.1',
        'collections': <String>[],
        'totalDocuments': 0,
        'systemInfo': {
          'appName': 'Security Tour Patrol',
          'backupType': 'Full System Backup',
          'includesSchedules': true,
          'includesNotifications': true,
          'includesSOSAlerts': true,
          'includesAdminNotifications': true,
          'includesEmergencyAlerts': true,
          'features': [
            'Real-time SOS alerts',
            'Admin notification system',
            'Schedule management (upcoming and ended)',
            'Checkpoint tracking',
            'Guard status management',
            'Transaction logging',
            'Daily patrol summaries'
          ],
        },
      },
      'data': <String, dynamic>{},
    };

    try {
      // Define the collections we want to backup
      final collectionsToBackup = [
        'Accounts',
        'Schedules', 
        'Checkpoints',
        'TransactionLogs',
        'DailyPatrolSummaries',
        'Notifications',
        'WeeklySchedules',
        'MonthlySchedules',
        'EndedSchedules',
        'AdminNotifications', // Updated from 'SOS' to 'AdminNotifications'
        'EmergencyAlerts', // Keep for backward compatibility
        'SOS' // Keep for backward compatibility
      ];
      
      int totalDocuments = 0;
      
      for (final collectionName in collectionsToBackup) {
        try {
          print('Backing up collection: $collectionName');
          
          // Get all documents in collection
          final querySnapshot = await firestore.collection(collectionName).get();
          final documents = <Map<String, dynamic>>[];
          
          for (final doc in querySnapshot.docs) {
            try {
              final docData = doc.data();
              // Convert Firestore data types to JSON-serializable types
              final convertedData = _convertFirestoreData(docData);
              documents.add({
                'id': doc.id,
                'data': convertedData,
              });
              totalDocuments++;
            } catch (e) {
              print('Warning: Could not process document ${doc.id} in collection $collectionName: $e');
              // Continue with other documents
            }
          }
          
          backupData['metadata']['collections'].add(collectionName);
          backupData['data'][collectionName] = documents;
          
          // Add collection-specific metadata
          if (!backupData['metadata'].containsKey('collectionDetails')) {
            backupData['metadata']['collectionDetails'] = <String, dynamic>{};
          }
          backupData['metadata']['collectionDetails'][collectionName] = {
            'documentCount': documents.length,
            'backedUpAt': DateTime.now().toIso8601String(),
          };
          
          print('Successfully backed up ${documents.length} documents from $collectionName');
          
        } catch (e) {
          // If a collection doesn't exist or can't be accessed, log it but continue
          print('Warning: Could not access collection $collectionName: $e');
          backupData['data'][collectionName] = [];
          backupData['metadata']['collections'].add('$collectionName (failed)');
          
          // Add error details to metadata
          if (!backupData['metadata'].containsKey('errors')) {
            backupData['metadata']['errors'] = <String, dynamic>{};
          }
          backupData['metadata']['errors'][collectionName] = {
            'error': e.toString(),
            'timestamp': DateTime.now().toIso8601String(),
          };
        }
      }
      
      backupData['metadata']['totalDocuments'] = totalDocuments;
      print('Backup completed. Total documents: $totalDocuments');
      
    } catch (e) {
      print('Error in _collectBackupData: $e');
      throw Exception('Failed to collect backup data: $e');
    }

    return backupData;
  }

  /// Converts Firestore data types to JSON-serializable types
  Map<String, dynamic> _convertFirestoreData(Map<String, dynamic> data) {
    final converted = <String, dynamic>{};
    
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      
      try {
        if (value == null) {
          converted[key] = null;
        } else if (value is Timestamp) {
          // Convert Timestamp to ISO string
          converted[key] = value.toDate().toIso8601String();
        } else if (value is GeoPoint) {
          // Convert GeoPoint to lat/lng map
          converted[key] = {
            'latitude': value.latitude,
            'longitude': value.longitude,
          };
        } else if (value is DocumentReference) {
          // Convert DocumentReference to path string
          converted[key] = value.path;
        } else if (value is FieldValue) {
          // Handle FieldValue by converting to a placeholder
          converted[key] = '__FIELD_VALUE_PLACEHOLDER__';
        } else if (value is List) {
          // Recursively convert list items
          converted[key] = value.map((item) {
            if (item is Map<String, dynamic>) {
              return _convertFirestoreData(item);
            } else if (item is Timestamp) {
              return item.toDate().toIso8601String();
            } else if (item is GeoPoint) {
              return {
                'latitude': item.latitude,
                'longitude': item.longitude,
              };
            } else if (item is DocumentReference) {
              return item.path;
            } else if (item is FieldValue) {
              return '__FIELD_VALUE_PLACEHOLDER__';
            }
            return item;
          }).toList();
        } else if (value is Map<String, dynamic>) {
          // Recursively convert nested maps
          converted[key] = _convertFirestoreData(value);
        } else if (value is num || value is String || value is bool) {
          // Keep primitive types as-is
          converted[key] = value;
        } else {
          // Handle unknown types by converting to string
          print('Warning: Unknown data type for key $key: ${value.runtimeType}');
          converted[key] = value.toString();
        }
      } catch (e) {
        print('Error converting field $key: $e');
        // Skip problematic fields
        converted[key] = 'ERROR_CONVERTING_FIELD';
      }
    }
    
    return converted;
  }

  /// Converts JSON data back to Firestore-compatible types
  Map<String, dynamic> _convertJsonToFirestoreData(Map<String, dynamic> data) {
    final converted = <String, dynamic>{};
    
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      
      if (value == null) {
        converted[key] = null;
      } else if (value is String) {
        // Check if it's a timestamp field or ISO date string
        if (_isTimestampField(key) || _isIsoDateString(value)) {
        try {
          final dateTime = DateTime.parse(value);
          converted[key] = Timestamp.fromDate(dateTime);
        } catch (e) {
          // If parsing fails, keep as string
            converted[key] = value;
          }
        } else if (value == '__FIELD_VALUE_PLACEHOLDER__') {
          // Handle FieldValue placeholders by using serverTimestamp
          converted[key] = FieldValue.serverTimestamp();
        } else {
          converted[key] = value;
        }
             } else if (value is Map<String, dynamic> && value.containsKey('latitude') && value.containsKey('longitude')) {
         // Convert lat/lng map back to GeoPoint
         try {
           final lat = (value['latitude'] as num).toDouble();
           final lng = (value['longitude'] as num).toDouble();
           converted[key] = GeoPoint(lat, lng);
         } catch (e) {
           // If conversion fails, keep as map
           converted[key] = value;
         }
      } else if (value is List) {
        // Recursively convert list items
        converted[key] = value.map((item) {
          if (item is Map<String, dynamic>) {
            return _convertJsonToFirestoreData(item);
          } else if (item is String && item == '__FIELD_VALUE_PLACEHOLDER__') {
            return FieldValue.serverTimestamp();
          }
          return item;
        }).toList();
      } else if (value is Map<String, dynamic>) {
        // Recursively convert nested maps
        converted[key] = _convertJsonToFirestoreData(value);
      } else {
        // Keep primitive types as-is
        converted[key] = value;
      }
    }
    
    return converted;
  }

  /// Check if a field name indicates it should be a timestamp
  bool _isTimestampField(String fieldName) {
    final timestampFields = [
      'created_at', 'createdAt', 'timestamp', 'time', 'date',
      'readAt', 'ended_at', 'updated_at', 'updatedAt'
    ];
    return timestampFields.contains(fieldName.toLowerCase());
  }

  /// Check if a string looks like an ISO date string
  bool _isIsoDateString(String value) {
    try {
      DateTime.parse(value);
      return value.contains('T') && value.contains('Z');
    } catch (e) {
      return false;
    }
  }

  Future<void> _restoreBackup() async {
    try {
      // Pick backup file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() {
          statusMessage = 'No file selected';
          _isSuccess = false;
        });
        return;
      }

      setState(() {
        _isLoading = true;
        statusMessage = 'Reading backup file...';
        _isSuccess = false;
      });

      // Read and parse backup file (web uses bytes; non-web reads from path)
      String jsonString;
      if (kIsWeb) {
        final picked = result.files.first;
        final bytes = picked.bytes;
        if (bytes == null) {
          throw Exception('Unable to read file bytes in web context');
        }
        jsonString = utf8.decode(bytes);
      } else {
        final path = result.files.first.path;
        if (path == null) {
          throw Exception('File path is null');
        }
        final file = File(path);
        if (!await file.exists()) {
          throw Exception('Selected file does not exist');
        }
        jsonString = await file.readAsString();
      }
      final backupData = jsonDecode(jsonString) as Map<String, dynamic>;

      setState(() {
        statusMessage = 'Validating backup data...';
      });

      // Validate backup structure
      if (!_validateBackupData(backupData)) {
        throw Exception('Invalid backup file format');
      }

      setState(() {
        statusMessage = 'Restoring data...';
      });

      // Show confirmation dialog
      final shouldProceed = await _showRestoreConfirmationDialog(backupData);
      if (!shouldProceed) {
        setState(() {
          _isLoading = false;
          statusMessage = 'Restore cancelled';
        });
        return;
      }

      // Perform restore
      await _performRestore(backupData);

      // Log restore action
      await AppLogger.log(
        type: 'Restore',
        message: 'Backup restored',
        metadata: backupData['metadata'] as Map<String, dynamic>? ?? {'info': 'no metadata'},
      );

      setState(() {
        statusMessage = 'Backup restored successfully!';
        _isSuccess = true;
        _isLoading = false;
      });

    } catch (e) {
      setState(() {
        statusMessage = 'Error restoring backup: $e';
        _isSuccess = false;
        _isLoading = false;
      });
    }
  }

  bool _validateBackupData(Map<String, dynamic> backupData) {
    // Basic structure validation
    if (!backupData.containsKey('metadata') ||
        !backupData.containsKey('data') ||
        backupData['metadata'] is! Map<String, dynamic> ||
        backupData['data'] is! Map<String, dynamic>) {
      return false;
    }
    
    final metadata = backupData['metadata'] as Map<String, dynamic>;
    final data = backupData['data'] as Map<String, dynamic>;
    
    // Check for required metadata fields
    if (!metadata.containsKey('version') || 
        !metadata.containsKey('createdAt') ||
        !metadata.containsKey('collections')) {
      return false;
    }
    
    // Check if collections in metadata match data keys
    final collections = metadata['collections'] as List<dynamic>;
    for (final collection in collections) {
      if (collection is String && !collection.contains('(failed)')) {
        if (!data.containsKey(collection)) {
          print('Warning: Collection $collection in metadata but not in data');
        }
      }
    }
    
    return true;
  }

  Future<bool> _showRestoreConfirmationDialog(Map<String, dynamic> backupData) async {
    final metadata = backupData['metadata'] as Map<String, dynamic>;
    final collections = metadata['collections'] as List<dynamic>;
    final createdAt = metadata['createdAt'] as String?;
    final version = metadata['version'] as String? ?? '1.0';
    final systemInfo = metadata['systemInfo'] as Map<String, dynamic>?;
    final collectionDetails = metadata['collectionDetails'] as Map<String, dynamic>?;
    
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Restore'),
        content: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              Text('Backup Information:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
              Text('Created: ${createdAt ?? 'Unknown date'}'),
              Text('Version: $version'),
              if (systemInfo != null) ...[
                Text('App: ${systemInfo['appName'] ?? 'Unknown'}'),
                Text('Type: ${systemInfo['backupType'] ?? 'Unknown'}'),
                if (systemInfo['features'] != null) ...[
                  const SizedBox(height: 8),
                  Text('Features included:', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ...(systemInfo['features'] as List<dynamic>).map((feature) => 
                    Text('• $feature', style: const TextStyle(fontSize: 12))
                  ).toList(),
                ],
              ],
              const SizedBox(height: 12),
              Text('Collections to restore: ${collections.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
              if (collectionDetails != null) ...[
            const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: collectionDetails.entries.map((entry) {
                      final details = entry.value as Map<String, dynamic>;
                      return Text('• ${entry.key}: ${details['documentCount']} documents');
                    }).toList(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
            const Text('⚠️ WARNING: This will overwrite existing data!', 
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            const Text('Are you sure you want to proceed?'),
          ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Restore', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ) ?? false;
  }

  Future<void> _performRestore(Map<String, dynamic> backupData) async {
    final firestore = FirebaseFirestore.instance;
    final data = backupData['data'] as Map<String, dynamic>;
    
    int totalDocuments = 0;
    int processedCollections = 0;
    final totalCollections = data.length;
    
    for (final entry in data.entries) {
      final collectionName = entry.key;
      final documents = entry.value as List<dynamic>;
      
      setState(() {
        statusMessage = 'Restoring collection: $collectionName (${processedCollections + 1}/$totalCollections)';
      });
      
      // Use batch writes for better performance (Firestore batch limit is 500)
      const batchSize = 500;
      for (int i = 0; i < documents.length; i += batchSize) {
        final batch = firestore.batch();
        final batchEnd = (i + batchSize < documents.length) ? i + batchSize : documents.length;
        
        for (int j = i; j < batchEnd; j++) {
          final doc = documents[j] as Map<String, dynamic>;
          final docId = doc['id'] as String;
          final docContent = doc['data'] as Map<String, dynamic>;
          
          final docRef = firestore.collection(collectionName).doc(docId);
          // Convert JSON data back to Firestore-compatible types
          final convertedContent = _convertJsonToFirestoreData(docContent);
          batch.set(docRef, convertedContent, SetOptions(merge: true));
          totalDocuments++;
        }
        
        await batch.commit();
        
        // Update progress
        setState(() {
          statusMessage = 'Restoring collection: $collectionName (${processedCollections + 1}/$totalCollections) - ${totalDocuments} documents processed';
        });
      }
      
      processedCollections++;
    }
    
    setState(() {
      statusMessage = 'Restored $totalDocuments documents from $totalCollections collections successfully!';
    });
  }

  void _showSuccessDialog(String filePath, int fileSize) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backup Created Successfully'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your backup has been created and saved to:'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                filePath,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            Text('File size: ${(fileSize / 1024).toStringAsFixed(1)} KB'),
            const SizedBox(height: 8),
            const Text('You can copy this file to a safe location for storage.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.of(context).pop();
              await _shareBackupFile(filePath);
            },
            icon: const Icon(Icons.share),
            label: const Text('Share'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareBackupFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await Share.shareXFiles(
          [XFile(filePath)],
          text: 'Security System Backup File',
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup file not found')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sharing file: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nav = appNavList(context, closeDrawer: true);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text('Backup and Restore'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
      ),
      drawer: Drawer(child: nav),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.backup_rounded,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'System Backup & Restore',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create backups of your data or restore from previous backups',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 30),
                  ElevatedButton.icon(
                    icon: _isLoading ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ) : const Icon(Icons.backup),
                    label: Text(_isLoading ? 'Creating...' : 'Create Backup'),
                    onPressed: _isLoading ? null : _createBackup,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      minimumSize: const Size(200, 50),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    icon: _isLoading ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ) : const Icon(Icons.restore),
                    label: Text(_isLoading ? 'Restoring...' : 'Restore from File'),
                    onPressed: _isLoading ? null : _restoreBackup,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      minimumSize: const Size(200, 50),
                    ),
                  ),
                  if (statusMessage != null) ...[
                    const SizedBox(height: 30),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _isSuccess ? Colors.green.shade50 : Colors.red.shade50,
                        border: Border.all(
                          color: _isSuccess ? Colors.green.shade200 : Colors.red.shade200,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          if (_isLoading) ...[
                            const SizedBox(height: 8),
                            const LinearProgressIndicator(),
                            const SizedBox(height: 8),
                          ],
                          Text(
                            statusMessage!,
                            style: TextStyle(
                              color: _isSuccess ? Colors.green.shade700 : Colors.red.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  ]
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
