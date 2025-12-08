import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:thesis_web/services/report_signatory_service.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class ReportSignatorySettingsScreen extends StatefulWidget {
  const ReportSignatorySettingsScreen({super.key});

  @override
  State<ReportSignatorySettingsScreen> createState() => _ReportSignatorySettingsScreenState();
}

class _ReportSignatorySettingsScreenState extends State<ReportSignatorySettingsScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _sinceController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;
  ReportSignatory? _currentSignatory;
  String? _entryProcessingId;
  bool _isDeletingEntry = false;

  @override
  void initState() {
    super.initState();
    _loadSignatory();
  }

  Future<void> _loadSignatory() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final signatory = await ReportSignatoryService.fetch();
      if (!mounted) return;
      _currentSignatory = signatory;
      _nameController.text = signatory.preparedByName;
      _titleController.text = signatory.preparedByTitle;
      _sinceController.text = signatory.since;
    } catch (e) {
      if (mounted) {
        _error = 'Failed to load signatory info: $e';
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final title = _titleController.text.trim();
    final since = _sinceController.text.trim();
    if (name.isEmpty || title.isEmpty || since.isEmpty) {
      _showSnack('Name, title, and since year are required.', isError: true);
      return;
    }

    if (since.length < 4 || int.tryParse(since) == null) {
      _showSnack('Please enter a valid start year (e.g., 2014).', isError: true);
      return;
    }

    setState(() {
      _isSaving = true;
    });

    final signatory = ReportSignatory(preparedByName: name, preparedByTitle: title, since: since);

    try {
      await ReportSignatoryService.addEntry(signatory);
      await _loadSignatory();
      if (mounted) {
        _showSnack('Signatory saved and set as current.');
      }
    } on FirebaseException catch (e) {
      if (mounted) _showSnack('Firestore error: ${e.message}', isError: true);
    } catch (e) {
      if (mounted) _showSnack('Unexpected error: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _applyEntry(ReportSignatoryEntry entry) async {
    if (_isSaving || _entryProcessingId != null) return;
    setState(() {
      _entryProcessingId = entry.id;
      _isDeletingEntry = false;
    });
    try {
      await ReportSignatoryService.setCurrentFromEntry(entry.id);
      _nameController.text = entry.signatory.preparedByName;
      _titleController.text = entry.signatory.preparedByTitle;
      _sinceController.text = entry.signatory.since;
      await _loadSignatory();
      if (mounted) _showSnack('Signatory updated.');
    } catch (e) {
      if (mounted) _showSnack('Failed to set signatory: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _entryProcessingId = null;
        });
      }
    }
  }

  Future<void> _deleteEntry(ReportSignatoryEntry entry) async {
    if (_isSaving || _entryProcessingId != null || _isCurrent(entry)) {
      _showSnack('Cannot delete the active signatory.', isError: true);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Signatory'),
        content: Text('Remove "${entry.signatory.preparedByName}" from saved signatories?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _entryProcessingId = entry.id;
      _isDeletingEntry = true;
    });
    try {
      await ReportSignatoryService.deleteEntry(entry.id);
      _showSnack('Signatory deleted.');
    } catch (e) {
      _showSnack('Failed to delete signatory: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _entryProcessingId = null;
          _isDeletingEntry = false;
        });
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _titleController.dispose();
    _sinceController.dispose();
    super.dispose();
  }

  bool _isCurrent(ReportSignatoryEntry entry) {
    if (_currentSignatory == null) return false;
    return entry.signatory.preparedByName == _currentSignatory!.preparedByName &&
        entry.signatory.preparedByTitle == _currentSignatory!.preparedByTitle;
  }

  @override
  Widget build(BuildContext context) {
    final nav = appNavList(context, closeDrawer: true);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text('Report Signatory Settings'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      drawer: Drawer(child: nav),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Prepared by (Name)',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Prepared by (Title)',
                      prefixIcon: Icon(Icons.work_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _sinceController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Since (Year started)',
                      helperText: 'Example: 2014',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save_outlined),
                      label: const Text('Save Signatory'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Expanded(child: _buildEntriesSection()),
                ],
              ),
      ),
    );
  }

  Widget _buildEntriesSection() {
    return StreamBuilder<List<ReportSignatoryEntry>>(
      stream: ReportSignatoryService.entriesStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = List<ReportSignatoryEntry>.from(snapshot.data ?? []);
        entries.sort((a, b) {
          final aIsCurrent = _isCurrent(a);
          final bIsCurrent = _isCurrent(b);
          if (aIsCurrent && !bIsCurrent) return -1;
          if (!aIsCurrent && bIsCurrent) return 1;
          final aDate = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bDate = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bDate.compareTo(aDate);
        });
        if (entries.isEmpty) {
          return Center(
            child: Text(
              'No saved signatories yet.',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          );
        }
        return Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final isCurrent = _isCurrent(entry);
              final sinceValue = entry.signatory.since.isNotEmpty ? entry.signatory.since : 'Unknown';
              return ListTile(
                title: Text(entry.signatory.preparedByName, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${entry.signatory.preparedByTitle}\nSince: $sinceValue'),
                isThreeLine: true,
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 160),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton(
                        onPressed: (isCurrent || _entryProcessingId != null)
                            ? null
                            : () => _applyEntry(entry),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isCurrent ? Colors.grey.shade300 : Theme.of(context).colorScheme.primary,
                          foregroundColor: isCurrent ? Colors.grey.shade700 : Colors.white,
                        ),
                        child: _entryProcessingId == entry.id && !_isDeletingEntry
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(isCurrent ? 'Current' : 'Set signatory'),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Delete signatory',
                        onPressed: (_entryProcessingId != null) ? null : () => _deleteEntry(entry),
                        icon: _entryProcessingId == entry.id && _isDeletingEntry
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

