import 'dart:async';

class AppFailure {
  const AppFailure(this.message);
  final String message;
}

class Result<T> {
  const Result.success(this.value) : failure = null;
  const Result.failure(this.failure) : value = null;
  final T? value;
  final AppFailure? failure;
  bool get isSuccess => failure == null;
}

Future<Result<T>> protect<T>(Future<T> Function() action) async {
  try {
    return Result.success(await action().timeout(const Duration(seconds: 20)));
  } on TimeoutException {
    return const Result.failure(
      AppFailure(
        'انتهت مهلة الاتصال. قد تكون العملية وصلت للخادم؛ تحقق من المحتوى قبل إعادة الإرسال.',
      ),
    );
  } on AppFailure catch (failure) {
    return Result.failure(failure);
  } catch (_) {
    // Never expose raw exceptions: SDK errors may contain credentials or PII.
    return const Result.failure(
      AppFailure(
        'تعذر إتمام العملية. تحقق من الاتصال والصلاحيات ثم حاول مجدداً.',
      ),
    );
  }
}

enum FeedKind { request, offer, education }

extension FeedKindLabel on FeedKind {
  String get label => switch (this) {
    FeedKind.request => 'طلبات',
    FeedKind.offer => 'معروضات',
    FeedKind.education => 'محتوى تعليمي',
  };
}

class FeedEntry {
  const FeedEntry({
    required this.id,
    required this.title,
    required this.body,
    required this.kind,
    required this.createdAt,
    this.price,
    this.currency,
    this.location = '',
    this.category = '',
    this.status = '',
    this.author = '',
    this.priceUnit = 'bird',
    this.ownerId = '',
    this.statusCode = 'active',
    this.replyCount = 0,
  });
  final String id,
      title,
      body,
      location,
      category,
      status,
      author,
      priceUnit,
      ownerId,
      statusCode;
  final int replyCount;
  final FeedKind kind;
  final DateTime createdAt;
  final num? price;
  final String? currency;
}

class FeedFilter {
  const FeedFilter({
    this.search = '',
    this.location = '',
    this.category = '',
    this.before,
  });
  final FeedEntry? before;
  final String search, location, category;
}

String normalizeDigits(String value) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  for (var i = 0; i < 10; i++) {
    value = value.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
  }
  return value.replaceAll('٫', '.').trim();
}

num? parseAmount(String value) => num.tryParse(normalizeDigits(value));
String? validateAmount(String? value, {required bool required}) {
  if ((value ?? '').trim().isEmpty) {
    return required ? 'أدخل سعراً رقمياً' : null;
  }
  final parsed = parseAmount(value!);
  if (parsed == null ||
      !parsed.isFinite ||
      parsed < 0 ||
      parsed >= 1000000000000) {
    return 'أدخل مبلغاً غير سالب وأقل من تريليون';
  }
  return null;
}

String? requiredText(String? text) =>
    (text ?? '').trim().isEmpty ? 'هذا الحقل مطلوب' : null;

class Publication {
  const Publication({
    required this.kind,
    required this.title,
    required this.body,
    required this.birdType,
    required this.state,
    required this.city,
    required this.quantity,
    required this.category,
    this.amount,
    this.currency = 'SDG',
    this.age,
    this.ageUnit = 'months',
    this.priceUnit = 'each',
    this.negotiable = false,
    this.displayName = '',
  });
  final FeedKind kind;
  final String title,
      body,
      birdType,
      state,
      city,
      category,
      currency,
      ageUnit,
      priceUnit,
      displayName;
  final int quantity;
  final num? amount;
  final int? age;
  final bool negotiable;
}

abstract interface class BirdsRepository {
  bool get isPreview;
  bool get signedIn;
  Stream<void> get authChanges;
  String? get currentUserId;
  Future<Result<bool>> updateEntry(
    FeedEntry entry,
    String title,
    String body,
    String status,
  );
  Future<Result<List<String>>> blockedUsers();
  Future<Result<bool>> block(String userId, bool blocked);
  Future<Result<List<FeedEntry>>> feed(FeedKind kind, FeedFilter filter);
  Future<Result<bool>> signIn(String provider);
  Future<Result<bool>> signOut();
  Future<Result<bool>> publish(Publication publication);
  Future<Result<List<String>>> replies(String postId);
  Future<Result<bool>> reply(String postId, String body);
  Future<Result<bool>> report(FeedEntry entry, String reason);
}

class PreviewRepository implements BirdsRepository {
  @override
  String? get currentUserId => null;
  @override
  Future<Result<bool>> updateEntry(
    FeedEntry entry,
    String title,
    String body,
    String status,
  ) async => _unavailable;
  @override
  Future<Result<List<String>>> blockedUsers() async => const Result.success([]);
  @override
  Future<Result<bool>> block(String userId, bool blocked) async => _unavailable;
  @override
  Stream<void> get authChanges => const Stream<void>.empty();
  @override
  bool get isPreview => true;
  @override
  bool get signedIn => false;
  @override
  Future<Result<List<FeedEntry>>> feed(
    FeedKind kind,
    FeedFilter filter,
  ) async => const Result.success([]);
  @override
  Future<Result<bool>> signIn(String provider) async => _unavailable;
  @override
  Future<Result<bool>> signOut() async => _unavailable;
  @override
  Future<Result<bool>> publish(Publication publication) async => _unavailable;
  @override
  Future<Result<List<String>>> replies(String postId) async =>
      const Result.success([]);
  @override
  Future<Result<bool>> reply(String postId, String body) async => _unavailable;
  @override
  Future<Result<bool>> report(FeedEntry entry, String reason) async =>
      _unavailable;
  static const _unavailable = Result<bool>.failure(
    AppFailure(
      'هذه معاينة محلية. يلزم إعداد Supabase لتسجيل الدخول وحفظ البيانات.',
    ),
  );
}

String arabicDate(DateTime date) {
  var value = date.toLocal().toIso8601String().split('T').first;
  for (var i = 0; i < 10; i++) {
    value = value.replaceAll('$i', '٠١٢٣٤٥٦٧٨٩'[i]);
  }
  return value;
}

/// Escapes SQL LIKE literals first, then PostgREST quoted-string syntax.
/// Star is rejected because PostgREST aliases it to a LIKE wildcard.
String quotedSearchPattern(String input) {
  if (input.contains('*')) {
    throw const AppFailure('اكتب كلمات البحث دون علامة النجمة.');
  }
  final slash = String.fromCharCode(92);
  final like = input
      .replaceAll(slash, '$slash$slash')
      .replaceAll('%', '$slash%')
      .replaceAll('_', '${slash}_');
  final quoted = like
      .replaceAll(slash, '$slash$slash')
      .replaceAll('"', '$slash"');
  return '"%$quoted%"';
}
