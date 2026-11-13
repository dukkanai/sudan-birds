import 'package:flutter/material.dart';

/// A failed prerequisite must not turn into an editable blank form.
class LoadFailurePanel extends StatelessWidget {
  const LoadFailurePanel({
    super.key,
    required this.message,
    required this.onRetry,
  });
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Semantics(liveRegion: true, child: Text(message)),
      TextButton(onPressed: onRetry, child: const Text('إعادة المحاولة')),
    ],
  );
}
