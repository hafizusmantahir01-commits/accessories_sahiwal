import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/utils/validators.dart';
import '../../../core/widgets/brand_logo.dart';
import '../../../core/widgets/common.dart';
import '../data/settings_repository.dart';

/// Owner-only branding and receipt details. Contact details stay blank
/// until the owner supplies them — nothing is invented.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _logoText = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _footer = TextEditingController();
  final _lowStock = TextEditingController();
  bool _initialised = false;
  bool _dirty = false;
  bool _uploading = false;

  @override
  void dispose() {
    for (final c in [_name, _logoText, _address, _phone, _footer, _lowStock]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(BusinessSettings s) {
    if (_initialised) return;
    _initialised = true;
    _name.text = s.businessName;
    _logoText.text = s.logoText;
    _address.text = s.address;
    _phone.text = s.phone;
    _footer.text = s.receiptFooter;
    _lowStock.text = '${s.lowStockDefault}';
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    try {
      await ref.read(settingsRepositoryProvider).update(
            businessName: _name.text,
            logoText: _logoText.text,
            address: _address.text,
            phone: _phone.text,
            receiptFooter: _footer.text,
            lowStockDefault: int.parse(_lowStock.text.trim()),
          );
      ref.invalidate(businessSettingsProvider);
      if (!mounted) return;
      setState(() => _dirty = false);
      context.showSuccess('Settings saved.');
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  Future<void> _uploadLogo() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 90);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      await ref.read(settingsRepositoryProvider).uploadLogo(await file.readAsBytes());
      ref.invalidate(businessSettingsProvider);
      if (mounted) context.showSuccess('Logo updated everywhere.');
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _removeLogo() async {
    try {
      await ref.read(settingsRepositoryProvider).removeLogo();
      ref.invalidate(businessSettingsProvider);
      if (mounted) context.showSuccess('Using the monogram logo.');
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(businessSettingsProvider);
    return UnsavedChangesGuard(
      isDirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: AsyncView<BusinessSettings>(
          value: settings,
          onRetry: () => ref.invalidate(businessSettingsProvider),
          data: (s) {
            _fill(s);
            return Form(
              key: _form,
              onChanged: () {
                if (!_dirty) setState(() => _dirty = true);
              },
              child: ListView(
                children: [
                  PageBody(
                    maxWidth: 720,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SectionCard(
                          title: 'Branding',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const BrandLogo(size: 64),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        OutlinedButton.icon(
                                          onPressed: _uploading ? null : _uploadLogo,
                                          icon: const Icon(Icons.upload),
                                          label: Text(s.logoPath == null ? 'Upload final logo' : 'Replace logo'),
                                        ),
                                        if (s.logoPath != null)
                                          TextButton(onPressed: _removeLogo, child: const Text('Use monogram')),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _name,
                                decoration: const InputDecoration(labelText: 'Business name'),
                                validator: (v) => Validators.required(v, 'Business name'),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _logoText,
                                maxLength: 4,
                                textCapitalization: TextCapitalization.characters,
                                decoration: const InputDecoration(labelText: 'Monogram letters', helperText: 'Shown when no logo image is set'),
                                validator: (v) => Validators.required(v, 'Monogram'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          title: 'Receipt details',
                          child: Column(
                            children: [
                              TextFormField(controller: _address, maxLines: 2, decoration: const InputDecoration(labelText: 'Address')),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _phone,
                                keyboardType: TextInputType.phone,
                                decoration: const InputDecoration(labelText: 'Phone'),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _footer,
                                maxLines: 2,
                                decoration: const InputDecoration(labelText: 'Receipt footer', hintText: 'e.g. Thank you for shopping'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          title: 'Stock alerts',
                          child: TextFormField(
                            controller: _lowStock,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            decoration: const InputDecoration(labelText: 'Default low-stock level for new products'),
                            validator: (v) => Validators.quantity(v, allowZero: true),
                          ),
                        ),
                        const SizedBox(height: 16),
                        BusyButton(label: 'Save settings', icon: Icons.save_outlined, onPressed: _save, expand: true),
                        const SizedBox(height: 16),
                        ListTile(
                          leading: const Icon(Icons.group_outlined),
                          title: const Text('Users & permissions'),
                          subtitle: const Text('In the Owner Private Area'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.go('/private/users'),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
