import 'dart:async';
import 'package:flutter/material.dart';
import 'domain.dart';

/// Staging account login only. No signup, provider launch or password persistence.
class PasswordSignInPage extends StatefulWidget {
  const PasswordSignInPage({super.key, required this.repository});
  final BirdsRepository repository;

  @override
  State<PasswordSignInPage> createState() => _PasswordSignInPageState();
}

class _PasswordSignInPageState extends State<PasswordSignInPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool pending = false, canceling = false;
  int generation = 0;
  String? error;

  Future<void> submit() async {
    if (pending || canceling) return;
    final address = email.text.trim();
    final secret = password.text;
    if (address.isEmpty ||
        !address.contains('@') ||
        address.length > 254 ||
        secret.isEmpty ||
        secret.length > 4096) {
      password.clear();
      setState(
        () => error = 'أدخل البريد الإلكتروني وكلمة المرور لحساب التجربة.',
      );
      return;
    }
    final attempt = ++generation;
    setState(() {
      pending = true;
      error = null;
    });
    // Remove the editable copy before awaiting the Auth operation. No password
    // is kept in widget state, restored routes, analytics or persistent storage.
    password.clear();
    FocusScope.of(context).unfocus();
    final result = await guardResult(
      () => widget.repository.signInWithPassword(address, secret),
    );
    if (!mounted || attempt != generation) return;
    setState(() => pending = false);
    if (result.isSuccess && result.value == true) {
      Navigator.of(context).pop(true);
    } else {
      setState(
        () => error =
            result.failure?.message ?? 'لم يكتمل تسجيل الدخول. أعد المحاولة.',
      );
    }
  }

  Future<void> cancel() async {
    if (canceling) return;
    ++generation; // Ignore any old completion before the cancellation await.
    password.clear();
    if (!pending) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => canceling = true);
    final result = await guardResult(widget.repository.cancelSignIn);
    if (!mounted) return;
    final canceled = result.isSuccess && result.value == true;
    setState(() {
      pending = !canceled;
      canceling = false;
    });
    if (canceled) {
      Navigator.of(context).pop(false);
    } else {
      setState(
        () => error =
            result.failure?.message ?? 'تعذر تأكيد إلغاء الدخول. أعد المحاولة.',
      );
    }
  }

  @override
  void dispose() {
    ++generation;
    if (pending && !canceling) {
      // Also fences an externally removed route. guardResult contains exceptions;
      // the coordinator performs synchronous invalidation before its first await.
      unawaited(guardResult(widget.repository.cancelSignIn));
    }
    password.clear();
    password.dispose();
    email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !pending && !canceling,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(cancel());
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('دخول حساب التجربة')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'استخدم بريد وكلمة مرور حساب التجربة الموجود. لا يمكن إنشاء حساب من هذه النسخة.',
              ),
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('trial-email'),
                controller: email,
                enabled: !pending && !canceling,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                textDirection: TextDirection.ltr,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('trial-password'),
                controller: password,
                enabled: !pending && !canceling,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(submit()),
                decoration: const InputDecoration(labelText: 'كلمة المرور'),
              ),
              const SizedBox(height: 20),
              if (error != null)
                Semantics(liveRegion: true, child: Text(error!)),
              if (pending)
                Semantics(
                  liveRegion: true,
                  child: const Text('جارٍ التحقق من بيانات الدخول…'),
                ),
              FilledButton(
                onPressed: pending || canceling ? null : submit,
                child: const Text('تسجيل الدخول'),
              ),
              TextButton(
                onPressed: canceling ? null : cancel,
                child: Text(canceling ? 'جارٍ إلغاء الدخول…' : 'إلغاء'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
