import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/common.dart';
import '../data/private_area_controller.dart';

class PrivateSecurityScreen extends ConsumerStatefulWidget {
  const PrivateSecurityScreen({super.key});

  @override
  ConsumerState<PrivateSecurityScreen> createState() => _PrivateSecurityScreenState();
}

class _PrivateSecurityScreenState extends ConsumerState<PrivateSecurityScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    try {
      await ref.read(privateAreaProvider.notifier).setSecret(current: _current.text, next: _next.text);
      if (!mounted) return;
      context.showSuccess('Private password changed. Unlock again with the new password.');
      context.go('/private/unlock');
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Private password')),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 520,
          child: SectionCard(
            title: 'Change private password',
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _current,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Current private password'),
                    validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _next,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'New private password'),
                    validator: (v) => (v == null || v.length < 8) ? 'Use at least 8 characters' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Confirm new private password'),
                    validator: (v) => v != _next.text ? 'Passwords do not match' : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Changing it locks the private area on every device.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  BusyButton(label: 'Change password', onPressed: _save),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
