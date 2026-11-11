import 'package:flutter_test/flutter_test.dart';

// Only labels declared here can reach failure messages. Neither platform
// exceptions nor arbitrary TestFailure objects are trusted diagnostics.
const _checkLabels = <String>{
  'Exact test-key cleanup and restore block',
  'Explicit disposable native test opt-in required',
  'Android or iOS required',
  'Adapter disposal',
  'Empty',
  'Fresh credential adapter readback',
  'Separate namespace remains empty',
  'Deletion',
  'Never-written scope denies restore',
  'Fresh fence adapter readback',
  'Malformed write rejected',
  'Malformed write cannot enable restore',
  'Blocked startup',
  'No restored session',
  'Stale key removed',
  'Flow verifier readback',
  'Session adapter write/read',
  'Fresh owner restores allowed synthetic value',
  'Orphan cleared',
  'Logout persisted restore block',
  'Fixture exists before blocked startup',
  'Restore denied',
  'Cleared',
  'Cleanup succeeded',
};

const _groupLabels = <String>{
  'Initial cleanup',
  'Credential operations and namespace isolation',
  'Native fence read/write and malformed request rejection',
  'Missing fence clears stale synthetic values',
  'Session/PKCE adapters, fresh instances and logout fence',
};

class _SafeStorageFailure extends TestFailure {
  _SafeStorageFailure(String label) : super('$label failed');
}

void checkNativeStorage(bool condition, String label) {
  if (!_checkLabels.contains(label)) {
    throw _SafeStorageFailure('Unknown storage check');
  }
  if (!condition) throw _SafeStorageFailure(label);
}

Future<void> guardNativeStorage(
  String label,
  Future<void> Function() action,
) async {
  if (!_groupLabels.contains(label)) {
    throw _SafeStorageFailure('Unknown storage group');
  }
  try {
    await action();
  } on _SafeStorageFailure {
    // This private type can only contain an allowlisted label.
    rethrow;
  } catch (_) {
    // Do not stringify the exception, its cause, or its stack.
    fail('$label failed (details suppressed)');
  }
}
