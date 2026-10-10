import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/widgets/common.dart';
import '../../auth/data/auth_repository.dart';
import '../data/private_area_controller.dart';

/// Second step for the owner's "locked folder". The app never stores the
/// private password; the server verifies it and unlocks THIS session only.
class PrivateUnlockScreen extends ConsumerStatefulWidget {
  const PrivateUnlockScreen({super.key, this.from});
  final String? from;

  @override
  ConsumerState<PrivateUnlockScreen> createState() => _PrivateUnlockScreenState();
}

class _PrivateUnlockScreenState extends ConsumerState<PrivateUnlockScreen> {
  final _form = GlobalKey<FormState>();
  final _secret = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await ref.read(privateAreaProvider.notifier).refresh();
    } catch (e) {
      _error = AppException.from(e).message;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (ref.read(privateAreaProvider).unlocked) _continue();
  }

  @override
  void dispose() {
    _secret.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _continue() {
    final target = widget.from;
    context.go(target != null && target.startsWith('/') && !target.startsWith('/private/unlock') ? target : '/private');
  }

  Future<void> _submit({required bool creating}) async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final controller = ref.read(privateAreaProvider.notifier);
    try {
      if (creating) await controller.setSecret(next: _secret.text);
      final ok = await controller.unlock(_secret.text);
      if (!mounted) return;
      if (ok) {
        _secret.clear();
        _continue();
      } else {
        setState(() => _error = 'Incorrect password.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = AppException.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(privateAreaProvider);
    final partner = ref.watch(profileOrNullProvider)?.isFullPartner ?? false;
    final creating = !partner && state.checked && !state.hasSecret;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Owner Private Area')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: PageBody(
                maxWidth: 440,
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      Icon(Icons.lock_person_outlined, size: 56, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      Text(
                        creating
                            ? 'Create your private password'
                            : (partner ? 'Enter your login password' : 'Enter private password'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        creating
                            ? 'This second password protects purchases, costs, profit and user management. '
                                'Use a different password from your login.'
                            : 'Stock, purchases, costs and profit are hidden until you unlock. '
                                'It locks again after 10 minutes of inactivity, when the app is closed, and on sign-out.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _secret,
                        obscureText: true,
                        autofocus: true,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: creating
                              ? 'New private password'
                              : (partner ? 'Your login password' : 'Private password'),
                          prefixIcon: const Icon(Icons.key_outlined),
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Required';
                          if (creating && v.length < 8) return 'Use at least 8 characters';
                          return null;
                        },
                        onFieldSubmitted: creating ? null : (_) => _submit(creating: false),
                      ),
                      if (creating) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _confirm,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'Confirm private password'),
                          validator: (v) => v != _secret.text ? 'Passwords do not match' : null,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : () => _submit(creating: creating),
                          icon: _busy
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.lock_open),
                          label: Text(creating ? 'Save and unlock' : 'Unlock'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (!partner) Text(
                        'Forgot it? See "Reset private password" in the owner guide — it requires access to '
                        'the Supabase dashboard and revokes all existing unlocks.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
