import 'dart:collection';

/// Closed labels only: never add identifiers, routes, exception types or text.
enum FailureBoundary {
  operation,
  mutation,
  uiGuard,
  uiMutationGuard,
  startup,
  flutter,
  platform,
  zone,
  secureStorage,
  oauthLinks,
  oauthCallback,
  oauthCleanup,
}

enum FailureCode { timeout, rejected, unexpected, storageUnavailable }

class LocalFailureEvent {
  const LocalFailureEvent._(
    this.boundary,
    this.code,
    this.occurredAt,
    this.outcomeUnknown,
  );

  final FailureBoundary boundary;
  final FailureCode code;
  final DateTime occurredAt;
  final bool outcomeUnknown;
}

/// A bounded, process-local debugging aid, not persistent crash reporting.
/// The API deliberately cannot accept an exception, stack trace or free text.
class LocalDiagnostics {
  LocalDiagnostics({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const capacity = 100;
  final DateTime Function() _clock;
  final Queue<LocalFailureEvent> _events = Queue<LocalFailureEvent>();

  List<LocalFailureEvent> get snapshot => List.unmodifiable(_events);

  void record(
    FailureBoundary boundary,
    FailureCode code, {
    bool outcomeUnknown = false,
  }) {
    try {
      final event = LocalFailureEvent._(
        boundary,
        code,
        _clock().toUtc(),
        outcomeUnknown,
      );
      if (_events.length == capacity) _events.removeFirst();
      _events.addLast(event);
    } catch (_) {
      // Best effort only. Diagnostics must never replace the original failure
      // or prevent the caller's user-visible warning/recovery path.
    }
  }

  void reset() => _events.clear();
}

final localDiagnostics = LocalDiagnostics();
