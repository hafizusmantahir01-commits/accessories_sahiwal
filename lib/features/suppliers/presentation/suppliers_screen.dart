import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/validators.dart';
import '../../../core/widgets/common.dart';
import '../data/suppliers_repository.dart';

class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  bool _showInactive = false;

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(suppliersProvider(_showInactive));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Suppliers'),
        actions: [
          IconButton(
            tooltip: _showInactive ? 'Hide inactive' : 'Show inactive',
            icon: Icon(_showInactive ? Icons.visibility : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _showInactive = !_showInactive),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSupplierEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add supplier'),
      ),
      body: AsyncView<List<Supplier>>(
        value: suppliers,
        onRetry: () => ref.invalidate(suppliersProvider),
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.local_shipping_outlined,
                title: 'No suppliers yet',
                message: 'Add the suppliers you buy stock from.',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final s = list[i];
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(s.name.characters.first.toUpperCase())),
                      title: Text(s.name),
                      subtitle: Text([if (s.phone.isNotEmpty) s.phone, if (s.address.isNotEmpty) s.address].join(' · ')),
                      trailing: s.isActive ? const Icon(Icons.edit_outlined) : const StatusChip('Inactive', color: Colors.grey),
                      onTap: () => showSupplierEditor(context, ref, existing: s),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// Create/edit dialog. Returns the saved supplier (used by the purchase editor too).
Future<Supplier?> showSupplierEditor(BuildContext context, WidgetRef ref, {Supplier? existing}) {
  return showDialog<Supplier>(context: context, builder: (_) => _SupplierDialog(existing: existing));
}

class _SupplierDialog extends ConsumerStatefulWidget {
  const _SupplierDialog({this.existing});
  final Supplier? existing;

  @override
  ConsumerState<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends ConsumerState<_SupplierDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _address = TextEditingController(text: widget.existing?.address ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late bool _active = widget.existing?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final s = await ref.read(suppliersRepositoryProvider).save(
            id: widget.existing?.id,
            name: _name.text,
            phone: _phone.text,
            address: _address.text,
            notes: _notes.text,
            isActive: _active,
          );
      ref.invalidate(suppliersProvider);
      if (mounted) Navigator.pop(context, s);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New supplier' : 'Edit supplier'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Supplier name *'),
                  validator: (v) => Validators.required(v, 'Name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone (optional)'),
                ),
                const SizedBox(height: 12),
                TextFormField(controller: _address, decoration: const InputDecoration(labelText: 'Address (optional)')),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes (optional)'),
                ),
                if (widget.existing != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: _active,
                    onChanged: (v) => setState(() => _active = v),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
