import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AddEditGuardScreen extends StatefulWidget {
  final String? guardDocumentId;
  final Map<String, dynamic>? initialData;

  const AddEditGuardScreen({
    super.key,
    this.guardDocumentId,
    this.initialData,
  });

  bool get isEditing => guardDocumentId != null;

  @override
  State<AddEditGuardScreen> createState() => _AddEditGuardScreenState();
}

class _AddEditGuardScreenState extends State<AddEditGuardScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _guardIdController;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.initialData?['first_name'] as String? ?? '');
    _lastNameController = TextEditingController(text: widget.initialData?['last_name'] as String? ?? '');
    _guardIdController = TextEditingController(text: widget.initialData?['guard_id'] as String? ?? '');
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _guardIdController.dispose();
    super.dispose();
  }

  Future<void> _saveGuard() async {
    final guardIdPattern = RegExp(r'^[A-Z]{2}\d{3}$');
    if (_guardIdController.text.isNotEmpty && !guardIdPattern.hasMatch(_guardIdController.text.trim())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Guard ID must be in the format XX000 (e.g., SG001).')),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final guardData = {
      'first_name': _firstNameController.text.trim(),
      'last_name': _lastNameController.text.trim(),
      'guard_id': _guardIdController.text.trim(),
      'role': 'Security',
    };

    try {
      if (widget.isEditing) {
        await FirebaseFirestore.instance
            .collection('Accounts')
            .doc(widget.guardDocumentId!)
            .update(guardData);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Guard details updated successfully!')),
          );
        }
      } else {
        final existingGuard = await FirebaseFirestore.instance
            .collection('Accounts')
            .where('guard_id', isEqualTo: _guardIdController.text.trim())
            .limit(1)
            .get();

        if (existingGuard.docs.isNotEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: Guard ID "${_guardIdController.text.trim()}" already exists.')),
            );
          }
          setState(() => _isLoading = false);
          return;
        }

        await FirebaseFirestore.instance.collection('Accounts').add({
          ...guardData,
          'status': 'Off Duty',
          'createdAt': FieldValue.serverTimestamp(),
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Guard added successfully!')),
          );
        }
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving guard: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  InputDecoration _buildInputDecoration(String label, {IconData? prefixIcon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: prefixIcon != null ? Icon(prefixIcon, color: Theme.of(context).colorScheme.primary) : null,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.outline.withOpacity(0.5)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2.0),
      ),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
      contentPadding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 12.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isWideScreen = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit Guard Details' : 'Add New Guard'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        elevation: 2.0,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWideScreen ? 600 : double.infinity),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(isWideScreen ? 32.0 : 20.0),
            child: Card(
              elevation: isWideScreen ? 4.0 : 2.0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        widget.isEditing ? 'Update Guard Information' : 'Enter Guard Details',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _firstNameController,
                        decoration: _buildInputDecoration('First Name', prefixIcon: Icons.person_outline),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a first name';
                          }
                          return null;
                        },
                        textCapitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _lastNameController,
                        decoration: _buildInputDecoration('Last Name', prefixIcon: Icons.person_outline),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a last name';
                          }
                          return null;
                        },
                        textCapitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _guardIdController,
                        decoration: _buildInputDecoration(
                            'Guard ID (e.g., SG001)',
                            prefixIcon: Icons.badge_outlined
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a guard ID';
                          }
                          final pattern = RegExp(r'^[A-Z]{2}\d{3}$');
                          if (!pattern.hasMatch(value.trim())) {
                            return 'Format must be XX000 (e.g., SG001)';
                          }
                          return null;
                        },
                        textCapitalization: TextCapitalization.characters,
                      ),
                      const SizedBox(height: 32),
                      if (_isLoading)
                        const Center(child: Padding(
                          padding: EdgeInsets.all(16.0),
                          child: CircularProgressIndicator(),
                        ))
                      else
                        ElevatedButton.icon(
                          icon: Icon(widget.isEditing ? Icons.save_as_outlined : Icons.add_circle_outline),
                          onPressed: _saveGuard,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            foregroundColor: Theme.of(context).colorScheme.onPrimary,
                            textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8.0),
                            ),
                            elevation: 2.0,
                          ),
                          label: Text(widget.isEditing ? 'Save Changes' : 'Add Guard'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
