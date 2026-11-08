import 'dart:async';
import 'dart:typed_data';

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

Future<Result<T>> protect<T>(
  Future<T> Function() action, {
  Duration? timeout = const Duration(seconds: 20),
}) async {
  try {
    final pending = action();
    return Result.success(
      await (timeout == null ? pending : pending.timeout(timeout)),
    );
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
    this.birdId,
    this.locationId,
    this.topicId,
    this.quantity = 1,
    this.age,
    this.ageUnit = 'month',
    this.negotiable = false,
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
  final int replyCount, quantity;
  final int? birdId, locationId, topicId, age;
  final String ageUnit;
  final bool negotiable;
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
    this.birdId,
    this.locationId,
    this.topicId,
    this.status = 'active',
    this.currency = '',
    this.minPrice,
    this.maxPrice,
    this.since,
    this.until,
    this.minAge,
    this.maxAge,
    this.ageUnit = 'month',
  });
  final FeedEntry? before;
  final int? birdId, locationId, topicId, minAge, maxAge;
  final String status, currency, ageUnit;
  final num? minPrice, maxPrice;
  final DateTime? since, until;
  FeedFilter withCursor(FeedEntry? cursor, {String? query}) => FeedFilter(
    search: query ?? search,
    location: location,
    category: category,
    before: cursor,
    birdId: birdId,
    locationId: locationId,
    topicId: topicId,
    status: status,
    currency: currency,
    minPrice: minPrice,
    maxPrice: maxPrice,
    since: since,
    until: until,
    minAge: minAge,
    maxAge: maxAge,
    ageUnit: ageUnit,
  );
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
    this.birdType = '',
    this.state = '',
    this.city = '',
    this.quantity = 1,
    this.category = 'information',
    this.amount,
    this.currency = 'SDG',
    this.age,
    this.ageUnit = 'months',
    this.priceUnit = 'each',
    this.negotiable = false,
    this.displayName = '',
    this.birdId,
    this.locationId,
    this.topicId,
    this.status = 'active',
  });
  final FeedKind kind;
  final int? birdId, locationId, topicId;
  final String status;
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
  Future<Result<bool>> reportTarget(
    ReportKind kind,
    String targetId,
    String reason,
  );
  Future<Result<bool>> isModerator();
  Future<Result<List<ModerationReport>>> moderationReports(
    String state, {
    ModerationReport? before,
  });
  Future<Result<ModerationTarget?>> moderationTarget(ModerationReport report);
  Future<Result<bool>> moderate(
    ModerationReport report,
    bool hidden,
    String reason,
  );
  Future<Result<bool>> resolveReport(
    String reportId,
    String state,
    String reason,
  );
  Future<Result<DeletionStatus?>> deletionStatus();
  Future<Result<List<MediaAsset>>> media(FeedEntry entry);
  Future<Result<UploadIntent>> reserveImage(FeedEntry entry, int bytes);
  Future<Result<bool>> putImage(UploadIntent intent, Uint8List bytes);
  Future<Result<MediaAsset>> completeImage(UploadIntent intent, String altText);
  Future<Result<String>> imageUrl(String mediaId);
  Future<Result<DeletionStatus>> deleteOwnAccount();
  Future<Result<Taxonomy>> taxonomy();
  Future<Result<ProfileData?>> profile();
  Future<Result<bool>> saveProfile(String name, bool accepted);
  Future<Result<ContactData?>> contact();
  Future<Result<bool>> saveContact(ContactData contact);
  Future<Result<ContactData?>> revealContact(String listingId, bool confirmed);
  Future<Result<FeedEntry>> savePublication(
    Publication publication, {
    FeedEntry? existing,
  });
  Future<Result<List<ReplyEntry>>> replyPage(
    String postId, {
    ReplyEntry? after,
  });
  Future<Result<bool>> sendReply(
    String postId,
    String body, {
    String? parentId,
  });
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
  Future<Result<bool>> reportTarget(
    ReportKind kind,
    String targetId,
    String reason,
  ) async => _unavailable;
  @override
  Future<Result<bool>> isModerator() async => const Result.success(false);
  @override
  Future<Result<List<ModerationReport>>> moderationReports(
    String state, {
    ModerationReport? before,
  }) async => Result.failure(_unavailable.failure!);
  @override
  Future<Result<ModerationTarget?>> moderationTarget(
    ModerationReport report,
  ) async => Result.failure(_unavailable.failure!);
  @override
  Future<Result<bool>> moderate(
    ModerationReport report,
    bool hidden,
    String reason,
  ) async => _unavailable;
  @override
  Future<Result<bool>> resolveReport(
    String reportId,
    String state,
    String reason,
  ) async => _unavailable;
  @override
  Future<Result<DeletionStatus?>> deletionStatus() async =>
      const Result.success(null);

  @override
  Future<Result<List<MediaAsset>>> media(FeedEntry entry) async =>
      const Result.success([]);
  @override
  Future<Result<UploadIntent>> reserveImage(FeedEntry entry, int bytes) async =>
      Result.failure(_unavailable.failure!);
  @override
  Future<Result<bool>> putImage(UploadIntent intent, Uint8List bytes) async =>
      _unavailable;
  @override
  Future<Result<MediaAsset>> completeImage(
    UploadIntent intent,
    String altText,
  ) async => Result.failure(_unavailable.failure!);
  @override
  Future<Result<String>> imageUrl(String mediaId) async =>
      Result.failure(_unavailable.failure!);
  @override
  Future<Result<DeletionStatus>> deleteOwnAccount() async =>
      Result.failure(_unavailable.failure!);

  @override
  Future<Result<Taxonomy>> taxonomy() async => const Result.success(Taxonomy());
  @override
  Future<Result<ProfileData?>> profile() async => const Result.success(null);
  @override
  Future<Result<bool>> saveProfile(String name, bool accepted) async =>
      _unavailable;
  @override
  Future<Result<ContactData?>> contact() async => const Result.success(null);
  @override
  Future<Result<bool>> saveContact(ContactData contact) async => _unavailable;
  @override
  Future<Result<ContactData?>> revealContact(
    String listingId,
    bool confirmed,
  ) async => Result.failure(_unavailable.failure!);
  @override
  Future<Result<FeedEntry>> savePublication(
    Publication publication, {
    FeedEntry? existing,
  }) async => Result.failure(_unavailable.failure!);
  @override
  Future<Result<List<ReplyEntry>>> replyPage(
    String postId, {
    ReplyEntry? after,
  }) async => const Result.success([]);
  @override
  Future<Result<bool>> sendReply(
    String postId,
    String body, {
    String? parentId,
  }) async => _unavailable;

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

class NamedOption {
  const NamedOption(this.id, this.name);
  final int id;
  final String name;
}

class LocationOption {
  const LocationOption(this.id, this.state, this.city);
  final int id;
  final String state, city;
  String get label => '$state، $city';
}

class Taxonomy {
  const Taxonomy({
    this.birds = const [],
    this.topics = const [],
    this.locations = const [],
  });
  final List<NamedOption> birds, topics;
  final List<LocationOption> locations;
}

class ProfileData {
  const ProfileData(this.name, this.accepted);
  final String name;
  final bool accepted;
}

class ContactData {
  const ContactData(this.kind, this.value, this.consent);
  final String kind, value;
  final bool consent;
}

class ReplyEntry {
  const ReplyEntry({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.ownerId,
    this.author = '',
    this.parentId,
  });
  final String id, body, ownerId, author;
  final String? parentId;
  final DateTime createdAt;
}

class MediaAsset {
  const MediaAsset(this.id, this.altText);
  final String id, altText;
}

class UploadIntent {
  const UploadIntent({
    required this.id,
    required this.url,
    required this.expiresAt,
    required this.headers,
  });
  final String id, url;
  final DateTime expiresAt;
  final Map<String, String> headers;
}

class DeletionStatus {
  const DeletionStatus(
    this.completed, {
    this.retryAfter = 30,
    this.requiresOperator = false,
  });
  final bool completed, requiresOperator;
  final int retryAfter;
}

enum ReportKind { post, listing, reply, account }

class ModerationReport {
  const ModerationReport({
    required this.id,
    required this.reason,
    required this.state,
    required this.createdAt,
    required this.kind,
    required this.targetId,
  });
  final String id, reason, state, targetId;
  final ReportKind kind;
  final DateTime createdAt;
}

class ModerationTarget {
  const ModerationTarget({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.hidden,
  });
  final String id, title, body;
  final ReportKind kind;
  final bool hidden;
}
