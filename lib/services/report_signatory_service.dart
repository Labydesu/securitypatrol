import 'package:cloud_firestore/cloud_firestore.dart';

class ReportSignatory {
  final String preparedByName;
  final String preparedByTitle;
  final String since;

  const ReportSignatory({
    required this.preparedByName,
    required this.preparedByTitle,
    required this.since,
  });

  static const ReportSignatory defaults = ReportSignatory(
    preparedByName: 'PRINCE JUN N. DAMASCO',
    preparedByTitle: 'Head, Security Services',
    since: '2014',
  );

  factory ReportSignatory.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return defaults;
    }
    final name = (data['preparedByName'] as String?)?.trim();
    final title = (data['preparedByTitle'] as String?)?.trim();
    final since = (data['since'] as String?)?.trim();
    return ReportSignatory(
      preparedByName: (name == null || name.isEmpty) ? defaults.preparedByName : name,
      preparedByTitle: (title == null || title.isEmpty) ? defaults.preparedByTitle : title,
      since: (since == null || since.isEmpty) ? defaults.since : since,
    );
  }

  Map<String, dynamic> toMap() => {
        'preparedByName': preparedByName,
        'preparedByTitle': preparedByTitle,
        'since': since,
      };
}

class ReportSignatoryEntry {
  final String id;
  final ReportSignatory signatory;
  final DateTime? createdAt;

  const ReportSignatoryEntry({
    required this.id,
    required this.signatory,
    required this.createdAt,
  });

  factory ReportSignatoryEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    DateTime? created;
    final ts = data['createdAt'];
    if (ts is Timestamp) {
      created = ts.toDate();
    }
    return ReportSignatoryEntry(
      id: doc.id,
      signatory: ReportSignatory.fromMap(data),
      createdAt: created,
    );
  }
}

class ReportSignatoryService {
  ReportSignatoryService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'ReportSignatories';
  static const String _documentId = 'default';
  static const String _entriesCollection = 'ReportSignatoryEntries';

  static Future<ReportSignatory> fetch() async {
    final doc = await _firestore.collection(_collection).doc(_documentId).get();
    return ReportSignatory.fromMap(doc.data());
  }

  static Future<void> save(ReportSignatory signatory) async {
    await _firestore.collection(_collection).doc(_documentId).set({
      ...signatory.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> addEntry(ReportSignatory signatory) async {
    await _firestore.collection(_entriesCollection).add({
      ...signatory.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    await save(signatory);
  }

  static Future<void> setCurrentFromEntry(String entryId) async {
    final doc = await _firestore.collection(_entriesCollection).doc(entryId).get();
    if (!doc.exists) return;
    final entry = ReportSignatoryEntry.fromDoc(doc);
    await save(entry.signatory);
  }

  static Future<void> deleteEntry(String entryId) async {
    await _firestore.collection(_entriesCollection).doc(entryId).delete();
  }

  static Stream<List<ReportSignatoryEntry>> entriesStream() {
    return _firestore
        .collection(_entriesCollection)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(ReportSignatoryEntry.fromDoc).toList());
  }
}

