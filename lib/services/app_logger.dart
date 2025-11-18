import 'package:cloud_firestore/cloud_firestore.dart';

class AppLogger {
  AppLogger._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static Future<void> log({
    required String type,
    required String message,
    String? userId,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      await _firestore.collection('TransactionLogs').add({
        'type': type,
        'message': message,
        'userId': userId,
        'metadata': metadata ?? {},
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Swallow logging errors to avoid breaking UX
    }
  }
}
















