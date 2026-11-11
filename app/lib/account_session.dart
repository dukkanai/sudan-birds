import 'dart:async';
import 'package:flutter/material.dart';
import 'domain.dart';

/// Consent, drafts and private data belong to the account that opened a route.
/// A changed or unverifiable session permanently invalidates that route; opening
/// it again starts a new scope. Token refresh for the same account is allowed.
mixin AccountBoundState<T extends StatefulWidget> on State<T> {
  BirdsRepository get accountRepository;
  late final String? _initialUser;
  late final bool _initialSignedIn;
  bool _invalidated = false;
  StreamSubscription<void>? _accountSubscription;

  bool get isAccountCurrent =>
      mounted &&
      !_invalidated &&
      accountRepository.signedIn == _initialSignedIn &&
      accountRepository.currentUserId == _initialUser;

  @override
  void initState() {
    super.initState();
    _initialUser = accountRepository.currentUserId;
    _initialSignedIn = accountRepository.signedIn;
    _accountSubscription = accountRepository.authChanges.listen((_) {
      if (!isAccountCurrent) _invalidate();
    }, onError: (Object _, StackTrace _) => _invalidate());
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    setState(() {
      _invalidated = true;
      clearAccountData();
    });
  }

  void clearAccountData() {}

  Widget protectAccount(Widget child) => isAccountCurrent
      ? child
      : Scaffold(
          appBar: AppBar(title: const Text('تغيرت جلسة الحساب')),
          body: const SingleChildScrollView(
            padding: EdgeInsets.all(20),
            child: Text(
              'انتهت جلسة الحساب أو تغيرت، أو تعذر التحقق منها. أُخفيت بيانات هذه الشاشة وأُوقفت إجراءاتها. ارجع وافتحها مجدداً بالحساب المطلوب.',
            ),
          ),
        );

  Widget protectAccountDialog(Widget child) => StreamBuilder<void>(
    stream: accountRepository.authChanges,
    builder: (context, snapshot) =>
        mounted && isAccountCurrent && !snapshot.hasError
        ? child
        : AlertDialog(
            title: const Text('تغيرت جلسة الحساب'),
            content: const Text(
              'أُلغي هذا التأكيد. افتح الإجراء مجدداً بالحساب المطلوب.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إغلاق'),
              ),
            ],
          ),
  );

  @override
  void dispose() {
    _accountSubscription?.cancel();
    super.dispose();
  }
}

/// MaterialPageRoute builds lazily. Keep the navigation-time identity instead
/// of letting an old snapshot initialize a new screen under a different user.
MaterialPageRoute<T> accountPageRoute<T>({
  required BirdsRepository repository,
  required WidgetBuilder builder,
  bool Function()? isAllowed,
}) {
  final user = repository.currentUserId;
  final signedIn = repository.signedIn;
  return MaterialPageRoute<T>(
    builder: (context) =>
        repository.currentUserId == user &&
            repository.signedIn == signedIn &&
            (isAllowed?.call() ?? true)
        ? builder(context)
        : Scaffold(
            appBar: AppBar(title: const Text('تغيرت جلسة الحساب')),
            body: const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'أُوقف فتح البيانات من جلسة سابقة. ارجع وافتحها مجدداً بالحساب المطلوب.',
              ),
            ),
          ),
  );
}
