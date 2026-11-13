import 'dart:typed_data';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'domain.dart';
import 'auth_config.dart';
import 'media_policy.dart';
import 'secure_auth_storage.dart';
import 'mobile_oauth.dart';

class SupabaseBirdsRepository implements BirdsRepository {
  SupabaseBirdsRepository(
    this.client, {
    required this.authRedirect,
    this.authStorage,
    this.oauth,
    this.oauthEnabled = false,
  });
  final SupabaseClient client;
  final String authRedirect;
  final SecureAuthStorage? authStorage;
  final MobileOAuthCoordinator? oauth;
  final bool oauthEnabled;

  // A timed-out Future does not cancel its HTTP request. Keep ownership of an
  // affected resource until the outcome is classified; quarantine sent writes
  // whose result is unknown, even if their response later arrives. Navigation
  // or another caller of this repository must not reopen the write window.
  final Map<String, Object> _accountWrites = {};

  Future<Result<bool>> _accountWrite(
    String resource,
    Future<bool> Function(_AccountSession session, void Function() beforeSend)
    action,
  ) async {
    String? key;
    final owner = Object();
    var owns = false, expired = false, sent = false;
    final result = await protectMutation(() async {
      final session = _accountSession();
      key = '${session.userId}:$resource';
      if (_accountWrites.containsKey(key)) {
        throw const AppFailure(
          'هناك كتابة سابقة لم تتأكد نتيجتها. أُوقف إرسال طلب جديد لحماية البيانات.',
          outcomeUnknown: true,
        );
      }
      _accountWrites[key!] = owner;
      owns = true;
      return action(session, () {
        if (expired) {
          throw const AppFailure('انتهت المهلة قبل إرسال التعديل.');
        }
        requireSameAccount(session.userId);
        sent = true;
      });
    });
    expired = true;
    if (owns && identical(_accountWrites[key], owner)) {
      if (result.failure?.outcomeUnknown != true || !sent) {
        _accountWrites.remove(key);
      }
      if (result.failure?.outcomeUnknown == true && !sent) {
        return const Result.failure(
          AppFailure('تعذر إكمال التحقق قبل الحفظ. لم يُرسل تعديل جديد.'),
        );
      }
    }
    return result;
  }

  void _requireStorage() {
    authStorage?.requireAvailable();
    if (authStorage?.acceptsSessions == false &&
        client.auth.currentSession != null) {
      throw const SecureStorageFailure();
    }
  }

  Future<Map<String, dynamic>> _edge(
    String name,
    Map<String, dynamic> body, {
    _AccountSession? account,
    bool mutation = false,
  }) async {
    _requireStorage();
    final token =
        account?.authorization ??
        (client.auth.currentSession == null
            ? null
            : 'Bearer ${client.auth.currentSession!.accessToken}');
    try {
      final response = await client.functions.invoke(
        name,
        body: body,
        headers: token == null ? null : {'Authorization': token},
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw AppFailure(
          'استجابة الخدمة غير مكتملة. لم نؤكد نجاح العملية.',
          outcomeUnknown: mutation,
        );
      }
      if (response.status >= 400 || data['error'] != null) {
        final failure = edgeFailure(response.status, data['error']);
        throw AppFailure(
          failure.message,
          outcomeUnknown: mutation && response.status >= 500,
        );
      }
      return data;
    } on FunctionException catch (e) {
      final details = e.details;
      final failure = edgeFailure(
        e.status,
        details is Map ? details['error'] : null,
      );
      throw AppFailure(
        failure.message,
        outcomeUnknown: mutation && e.status >= 500,
      );
    }
  }

  @override
  Future<Result<bool>> reportTarget(
    ReportKind kind,
    String targetId,
    String reason,
  ) => protectMutation(() async {
    final session = _accountSession();
    if (reason.trim().length < 5 || reason.length > 2000) {
      throw const AppFailure('اكتب سبباً واضحاً من ٥ إلى ٢٠٠٠ حرف.');
    }
    await client
        .from('reports')
        .setHeader('Authorization', session.authorization)
        .insert({'${kind.name}_id': targetId, 'reason': reason.trim()});
    return true;
  });
  Future<bool> _verifiedModerator([_AccountSession? initial]) async {
    final session = initial ?? _accountSession();
    final row = await client
        .from('moderator_roles')
        .setHeader('Authorization', session.authorization)
        .select('role')
        .eq('user_id', session.userId)
        .maybeSingle();
    requireSameAccount(session.userId);
    return row != null &&
        (row['role'] == 'moderator' || row['role'] == 'admin');
  }

  Future<void> _requireModerator(_AccountSession session) async {
    if (!await _verifiedModerator(session)) {
      throw const AppFailure('لا تتوفر صلاحية الإشراف لهذا الحساب.');
    }
    requireSameAccount(session.userId);
  }

  @override
  Future<Result<bool>> isModerator() => protect(_verifiedModerator);
  @override
  Future<Result<List<ModerationReport>>> moderationReports(
    String state, {
    ModerationReport? before,
  }) => protect(() async {
    final session = _accountSession();
    await _requireModerator(session);
    if (!['open', 'reviewing', 'resolved', 'dismissed'].contains(state)) {
      throw const AppFailure('حالة بلاغ غير مدعومة.');
    }
    var query = client
        .from('reports')
        .setHeader('Authorization', session.authorization)
        .select('id,listing_id,account_id,reason,state,created_at')
        .eq('state', state);
    if (before != null) {
      final stamp = before.createdAt.toUtc().toIso8601String();
      query = query.or(
        'created_at.lt.$stamp,and(created_at.eq.$stamp,id.lt.${before.id})',
      );
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(20);
    return rows.map((r) {
      final kind = ReportKind.values.firstWhere(
        (k) => r['${k.name}_id'] != null,
      );
      return ModerationReport(
        id: r['id'] as String,
        reason: r['reason'] as String,
        state: r['state'] as String,
        createdAt: DateTime.parse(r['created_at'] as String),
        kind: kind,
        targetId: r['${kind.name}_id'] as String,
      );
    }).toList();
  });
  @override
  Future<Result<ModerationTarget?>> moderationTarget(
    ModerationReport report,
  ) => protect(() async {
    final session = _accountSession();
    await _requireModerator(session);
    final rows =
        await client
                .rpc('moderator_report_target', params: {'p_report': report.id})
                .setHeader('Authorization', session.authorization)
            as List<dynamic>;
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    if (row['missing'] == true) return null;
    return ModerationTarget(
      id: report.targetId,
      kind: report.kind,
      title: row['title'] as String? ?? row['display_name'] as String? ?? '',
      body: row['body'] as String? ?? '',
      hidden: row['moderation_state'] == 'hidden',
    );
  });
  @override
  Future<Result<bool>> moderate(
    ModerationReport report,
    bool hidden,
    String reason,
  ) => _accountWrite('moderation:${report.targetId}', (
    session,
    beforeSend,
  ) async {
    final accountId = session.userId;
    await _requireModerator(session);
    requireSameAccount(accountId);
    if (report.kind == ReportKind.account || reason.trim().length < 5) {
      throw const AppFailure('هذا الإجراء يتطلب محتوى محدداً وسبباً واضحاً.');
    }
    beforeSend();
    await client
        .rpc(
          'moderate_content',
          params: {
            'p_kind': report.kind.name,
            'p_id': report.targetId,
            'p_hidden': hidden,
            'p_reason': reason.trim(),
          },
        )
        .setHeader('Authorization', session.authorization);
    return true;
  });
  @override
  Future<Result<bool>> resolveReport(
    String reportId,
    String state,
    String reason,
  ) => _accountWrite('report:$reportId', (session, beforeSend) async {
    final accountId = session.userId;
    await _requireModerator(session);
    requireSameAccount(accountId);
    if (!['reviewing', 'resolved', 'dismissed'].contains(state) ||
        reason.trim().length < 5) {
      throw const AppFailure('اختر حالة مراجعة واكتب سبباً واضحاً.');
    }
    beforeSend();
    await client
        .rpc(
          'resolve_report',
          params: {
            'p_report': reportId,
            'p_state': state,
            'p_reason': reason.trim(),
          },
        )
        .setHeader('Authorization', session.authorization);
    return true;
  });
  @override
  Future<Result<DeletionStatus?>> deletionStatus() => protect(() async {
    final session = _accountSession();
    final rows =
        await client
                .rpc('own_deletion_status')
                .setHeader('Authorization', session.authorization)
            as List<dynamic>;
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    return DeletionStatus(
      row['state'] == 'completed',
      retryAfter: (row['retry_after_seconds'] as num?)?.toInt() ?? 30,
      requiresOperator: row['requires_operator'] == true,
    );
  });
  @override
  Future<Result<List<MediaAsset>>> media(FeedEntry entry) => protect(() async {
    _requireStorage();
    final rows = await client
        .from('media')
        .select('id,alt_text')
        .eq('listing_id', entry.id)
        .order('verified_at')
        .limit(MediaPolicy.maxImages);
    return rows
        .map(
          (r) => MediaAsset(r['id'] as String, r['alt_text'] as String? ?? ''),
        )
        .toList();
  });
  @override
  Future<Result<UploadIntent>> reserveImage(FeedEntry entry, int bytes) =>
      protectMutation(() async {
        final session = _accountSession();
        if (entry.ownerId != currentUserId ||
            bytes < 1 ||
            bytes > MediaPolicy.maxBytes) {
          throw const AppFailure('الصورة غير صالحة أو لا تملك هذا المحتوى.');
        }
        final data = await _edge(
          'media',
          {
            'action': 'reserve',
            'listing_id': entry.id,
            'bytes': bytes,
            'mime': 'image/jpeg',
          },
          account: session,
          mutation: true,
        );
        try {
          final url = data['put_url'] as String;
          requirePrivateImageUrl(url);
          final headers = Map<String, String>.from(
            data['required_headers'] as Map,
          );
          validateUploadHeaders(headers, bytes);
          return UploadIntent(
            id: data['intent_id'] as String,
            url: url,
            expiresAt: DateTime.now().add(
              Duration(seconds: (data['expires_in'] as num).toInt()),
            ),
            headers: headers,
          );
        } on AppFailure catch (failure) {
          // Reservation may already exist even when its returned upload
          // contract is unsafe. Never silently enable another reservation.
          throw AppFailure(failure.message, outcomeUnknown: true);
        }
      });
  @override
  Future<Result<bool>> putImage(
    UploadIntent intent,
    Uint8List bytes,
  ) => protect(() async {
    requireAccount();
    requirePrivateImageUrl(intent.url);
    validateUploadHeaders(intent.headers, bytes.length);
    if (DateTime.now().isAfter(intent.expiresAt)) {
      throw const AppFailure(
        'انتهت مهلة رابط الرفع. أعد اختيار الصورة بعد انتهاء الحجز السابق.',
      );
    }
    final request = http.Request('PUT', Uri.parse(intent.url))
      ..followRedirects = false
      ..headers.addAll(intent.headers)
      ..bodyBytes = bytes;
    final uploadClient = http.Client();
    try {
      final status = await (() async {
        final response = await uploadClient.send(request);
        await response.stream.drain<void>();
        return response.statusCode;
      })().timeout(const Duration(seconds: 18));
      if (status == 412) {
        throw const AppFailure(
          'مفتاح الرفع موجود مسبقاً ولن نكتب فوقه. تحقّق من الرفع السابق؛ لصورة جديدة اختر حجزاً جديداً.',
        );
      }
      if (status < 200 || status >= 300) {
        throw const AppFailure(
          'تعذر رفع الصورة. قد يكون الرابط منتهياً؛ جرّب التحقق أو أعد اختيار الصورة لاحقاً.',
        );
      }
      return true;
    } finally {
      uploadClient.close();
    }
  });
  @override
  Future<Result<MediaAsset>> completeImage(
    UploadIntent intent,
    String altText,
  ) => protect(() async {
    final session = _accountSession();
    final data = await _edge('media', {
      'action': 'complete',
      'intent_id': intent.id,
      'alt_text': altText.trim(),
    }, account: session);
    if (data['status'] != 'verified' || data['media_id'] is! String) {
      throw const AppFailure(
        'لم يؤكد الخادم التحقق من الصورة؛ لا تُعد منشورة بعد.',
      );
    }
    return MediaAsset(data['media_id'] as String, altText.trim());
  });
  @override
  Future<Result<String>> imageUrl(String mediaId) => protect(() async {
    final data = await _edge('media-read', {'media_id': mediaId});
    final url = data['url'] as String;
    requirePrivateImageUrl(url);
    return url;
  });
  @override
  Future<Result<DeletionStatus>> deleteOwnAccount() => protect(() async {
    final session = _accountSession();
    final accountId = session.userId;
    final data = await _edge('account-delete', {
      'confirmation': 'DELETE_MY_ACCOUNT',
    }, account: session);
    if (data['status'] == 'completed') {
      var cleanupRequired = false;
      try {
        if (client.auth.currentUser?.id == accountId) {
          final result = await signOut();
          cleanupRequired = !result.isSuccess;
        }
      } catch (_) {
        cleanupRequired = true;
      }
      return DeletionStatus(true, sessionCleanupRequired: cleanupRequired);
    }
    if (data['status'] == 'pending') {
      return DeletionStatus(
        false,
        retryAfter: (data['retry_after_seconds'] as num?)?.toInt() ?? 30,
        requiresOperator: data['requires_operator'] == true,
      );
    }
    throw const AppFailure('حالة حذف الحساب غير مؤكدة. تحقق قبل إعادة الطلب.');
  });
  @override
  String? get currentUserId => signedIn ? client.auth.currentUser?.id : null;
  @override
  Future<Result<bool>> updateEntry(
    FeedEntry entry,
    String title,
    String body,
    String status,
  ) => protect(() async {
    final session = _accountSession();
    if (entry.ownerId != currentUserId) {
      throw const AppFailure('يمكن لصاحب المحتوى وحده تعديله.');
    }
    final rows = await client
        .from('listings')
        .setHeader('Authorization', session.authorization)
        .update({'title': title, 'description': body, 'status': status})
        .eq('id', entry.id)
        .eq('owner_id', session.userId)
        .select('id');
    if (rows.length != 1) {
      throw const AppFailure(
        'لم يُحفظ التعديل. تحقق من الصلاحية وحدّث المحتوى.',
      );
    }
    return true;
  });
  @override
  Future<Result<List<String>>> blockedUsers() => protect(() async {
    final session = _accountSession();
    final rows = await client
        .from('user_blocks')
        .setHeader('Authorization', session.authorization)
        .select('blocked_id')
        .eq('blocker_id', session.userId);
    return rows.map((r) => r['blocked_id'] as String).toList();
  });
  @override
  Future<Result<bool>> block(String userId, bool blocked) => protect(() async {
    final session = _accountSession();
    if (userId == currentUserId) throw const AppFailure('لا يمكنك حظر حسابك.');
    if (blocked) {
      await client
          .from('user_blocks')
          .setHeader('Authorization', session.authorization)
          .insert({'blocker_id': session.userId, 'blocked_id': userId});
    } else {
      final rows = await client
          .from('user_blocks')
          .setHeader('Authorization', session.authorization)
          .delete()
          .eq('blocker_id', session.userId)
          .eq('blocked_id', userId)
          .select('blocked_id');
      if (rows.length != 1) {
        throw const AppFailure('لم يُلغَ الحظر. حدّث القائمة وحاول مجدداً.');
      }
    }
    return true;
  });
  @override
  bool get isPreview => false;
  @override
  bool get signedIn =>
      authStorage?.failed != true &&
      authStorage?.acceptsSessions != false &&
      client.auth.currentUser != null;
  @override
  bool get sessionCleanupRequired =>
      authStorage?.failed == true ||
      (authStorage?.acceptsSessions == false &&
          client.auth.currentSession != null);
  @override
  Stream<void> get authChanges => Stream<void>.multi((events) {
    final auth = client.auth.onAuthStateChange.listen(
      (_) => events.add(null),
      onError: (Object _, StackTrace _) =>
          events.addError(const AppFailure('تعذر تحديث جلسة الحساب.')),
    );
    final storage = authStorage?.changes.listen((_) => events.add(null));
    events.onCancel = () async {
      await auth.cancel();
      await storage?.cancel();
    };
  }, isBroadcast: true);
  _AccountSession _accountSession() {
    requireAccount();
    final session = client.auth.currentSession;
    if (session == null || session.user.id != currentUserId) {
      throw const AppFailure('أعد تسجيل الدخول قبل تنفيذ الإجراء.');
    }
    return _AccountSession(session.user.id, 'Bearer ${session.accessToken}');
  }

  void requireSameAccount(String expected) {
    if (!signedIn || currentUserId != expected) {
      throw const AppFailure(
        'تغيرت جلسة الحساب. افتح الشاشة مجدداً قبل تنفيذ الإجراء.',
      );
    }
  }

  void requireAccount() {
    _requireStorage();
    if (!signedIn) throw const AppFailure('سجّل الدخول أولاً.');
  }

  @override
  Future<Result<List<FeedEntry>>> feed(
    FeedKind kind,
    FeedFilter filter,
  ) => protect(() async {
    _requireStorage();
    var query = client.from('listings').select('*,locations(state_ar,city_ar)');
    query = query.eq('kind', kind.name).eq('status', filter.status);
    if (filter.status == 'active' || filter.status == 'reserved') {
      query = query.gt('expires_at', DateTime.now().toUtc().toIso8601String());
    }
    if (filter.locationId != null) {
      query = query.eq('location_id', filter.locationId!);
    }
    if (filter.currency.isNotEmpty) {
      query = query.eq('currency', filter.currency);
    }
    if ((filter.minPrice != null || filter.maxPrice != null) &&
        filter.currency.isEmpty) {
      throw const AppFailure('اختر العملة عند تصفية السعر.');
    }
    if (filter.minPrice != null) query = query.gte('price', filter.minPrice!);
    if (filter.maxPrice != null) query = query.lte('price', filter.maxPrice!);
    if (filter.minAge != null || filter.maxAge != null) {
      query = query.eq('age_unit', filter.ageUnit);
    }
    if (filter.minAge != null) query = query.gte('age_value', filter.minAge!);
    if (filter.maxAge != null) query = query.lte('age_value', filter.maxAge!);
    if (filter.location.isNotEmpty) {
      final locations = await client
          .from('locations')
          .select('id')
          .eq('state_ar', filter.location);
      if (locations.isEmpty) return <FeedEntry>[];
      query = query.inFilter(
        'location_id',
        locations.map((r) => r['id']).toList(),
      );
    }
    if (filter.birdId != null) query = query.eq('bird_type_id', filter.birdId!);
    if (filter.since != null) {
      query = query.gte('created_at', filter.since!.toUtc().toIso8601String());
    }
    if (filter.until != null) {
      query = query.lt('created_at', filter.until!.toUtc().toIso8601String());
    }
    if (filter.search.isNotEmpty) {
      // Use a quoted PostgREST value; user input cannot inject filter operators.
      final pattern = quotedSearchPattern(filter.search);
      query = query.or('title.ilike.$pattern,description.ilike.$pattern');
    }
    final before = filter.before;
    if (before != null) {
      final time = before.createdAt.toUtc().toIso8601String();
      query = query.or(
        'created_at.lt.$time,and(created_at.eq.$time,id.lt.${before.id})',
      );
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(20);
    return rows.map((row) => decodeEntry(row, kind)).toList();
  });

  @override
  Future<Result<bool>> signIn(String provider) => protect(() async {
    authStorage?.requireAvailable();
    if (sessionCleanupRequired) throw const SecureStorageFailure();
    if (provider != 'google' && provider != 'apple') {
      throw const AppFailure('موفر تسجيل الدخول غير مدعوم.');
    }
    if (!oauthEnabled) {
      throw const AppFailure(
        'دخول Google وApple غير متاح في نسخة التجربة الحالية. استخدم البريد وكلمة المرور.',
      );
    }
    if (authRedirect.isEmpty) {
      throw const AppFailure('لم يُضبط رابط العودة الآمن لتسجيل الدخول بعد.');
    }
    validateAuthRedirect(authRedirect);
    if (authStorage != null && oauth == null) {
      throw const SecureStorageFailure();
    }
    if (oauth != null) {
      return oauth!.signIn(
        provider == 'apple' ? OAuthProvider.apple : OAuthProvider.google,
        authRedirect,
      );
    }
    final launched = await client.auth.signInWithOAuth(
      provider == 'apple' ? OAuthProvider.apple : OAuthProvider.google,
      redirectTo: authRedirect,
    );
    if (!launched) {
      throw const AppFailure('تعذر فتح صفحة تسجيل الدخول. حاول مجدداً.');
    }
    return true;
  });
  @override
  Future<Result<bool>> signInWithPassword(String email, String password) =>
      protect(() async {
        validateAuthRedirect(
          authRedirect,
        ); // This path is restricted to the staging identity.
        if (authStorage == null || oauth == null) {
          throw const SecureStorageFailure();
        }
        authStorage!.requireAvailable();
        if (sessionCleanupRequired) throw const SecureStorageFailure();
        return oauth!.signInWithPassword(email, password);
      }, timeout: null);

  @override
  Future<Result<bool>> cancelSignIn() => protect(() async {
    await oauth?.cancelSignIn();
    return true;
  }, timeout: null);

  @override
  Future<Result<bool>> signOut() => protect(() async {
    if (oauth != null) {
      await oauth!.signOut();
      return true;
    }
    await authStorage?.beginSignOut();
    var serviceFailed = false;
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      serviceFailed = true;
    }
    await authStorage?.clearAfterSignOut();
    if (serviceFailed) {
      throw const AppFailure(
        'مُسحت بيانات الدخول المحلية المتاحة، لكن تعذر تأكيد إنهاء الجلسة لدى الخدمة. لا نؤكد إبطال جلسة الخادم.',
      );
    }
    return true;
  });
  @override
  Future<Result<bool>> publish(Publication p) async {
    final result = await savePublication(p);
    return result.isSuccess
        ? const Result.success(true)
        : Result.failure(result.failure!);
  }

  @override
  Future<Result<bool>> report(FeedEntry entry, String reason) =>
      reportTarget(ReportKind.listing, entry.id, reason);
  @override
  Future<Result<Taxonomy>> taxonomy() => protect(() async {
    _requireStorage();
    final birds = await client.from('bird_types').select().order('name_ar');
    final locations = await client
        .from('locations')
        .select()
        .order('state_ar')
        .order('city_ar');
    return Taxonomy(
      birds: birds
          .map((r) => NamedOption(r['id'] as int, r['name_ar'] as String))
          .toList(),
      locations: locations
          .map(
            (r) => LocationOption(
              r['id'] as int,
              r['state_ar'] as String,
              r['city_ar'] as String,
            ),
          )
          .toList(),
    );
  });
  @override
  Future<Result<ProfileData?>> profile() => protect(() async {
    final session = _accountSession();
    final row = await client
        .from('profiles')
        .setHeader('Authorization', session.authorization)
        .select('display_name,accepted_terms_at')
        .eq('id', session.userId)
        .maybeSingle();
    return row == null
        ? null
        : ProfileData(
            row['display_name'] as String,
            row['accepted_terms_at'] != null,
          );
  });
  @override
  Future<Result<bool>> saveProfile(String name, bool accepted) =>
      _accountWrite('profile', (session, beforeSend) async {
        final accountId = session.userId;
        if (name.trim().length < 2 || name.trim().length > 80 || !accepted) {
          throw const AppFailure(
            'أدخل اسم عرض من حرفين إلى ٨٠ حرفاً وأقرّ بقواعد النسخة التجريبية.',
          );
        }
        final existing = await client
            .from('profiles')
            .setHeader('Authorization', session.authorization)
            .select('id')
            .eq('id', accountId)
            .maybeSingle();
        requireSameAccount(accountId);
        final values = {
          'display_name': name.trim(),
          'accepted_terms_at': DateTime.now().toUtc().toIso8601String(),
        };
        beforeSend();
        final List<Map<String, dynamic>> rows;
        if (existing == null) {
          rows = await client
              .from('profiles')
              .setHeader('Authorization', session.authorization)
              .insert({'id': accountId, ...values})
              .select('id');
        } else {
          rows = await client
              .from('profiles')
              .setHeader('Authorization', session.authorization)
              .update(values)
              .eq('id', accountId)
              .select('id');
        }
        if (rows.length != 1 || rows.single['id'] != accountId) {
          throw const AppFailure(
            'لم نؤكد حفظ الملف الشخصي. تحقق من الحالة قبل طلب جديد.',
            outcomeUnknown: true,
          );
        }
        return true;
      });
  @override
  Future<Result<ContactData?>> contact() => protect(() async {
    final session = _accountSession();
    final row = await client
        .from('profile_contacts')
        .setHeader('Authorization', session.authorization)
        .select('contact_kind,contact_value,reveal_consent')
        .eq('owner_id', session.userId)
        .maybeSingle();
    return row == null
        ? null
        : ContactData(
            row['contact_kind'] as String,
            row['contact_value'] as String,
            row['reveal_consent'] as bool,
          );
  });
  @override
  Future<Result<bool>> saveContact(ContactData contact) =>
      _accountWrite('contact', (session, beforeSend) async {
        final accountId = session.userId;
        if (contact.value.trim().length < 3 || contact.value.length > 160) {
          throw const AppFailure('أدخل وسيلة تواصل صحيحة من ٣ إلى ١٦٠ حرفاً.');
        }
        final old = await client
            .from('profile_contacts')
            .setHeader('Authorization', session.authorization)
            .select('owner_id')
            .eq('owner_id', accountId)
            .maybeSingle();
        requireSameAccount(accountId);
        final values = {
          'contact_kind': contact.kind,
          'contact_value': contact.value.trim(),
          'reveal_consent': contact.consent,
          'consent_at': contact.consent
              ? DateTime.now().toUtc().toIso8601String()
              : null,
        };
        beforeSend();
        final List<Map<String, dynamic>> rows;
        if (old == null) {
          rows = await client
              .from('profile_contacts')
              .setHeader('Authorization', session.authorization)
              .insert({'owner_id': accountId, ...values})
              .select('owner_id');
        } else {
          rows = await client
              .from('profile_contacts')
              .setHeader('Authorization', session.authorization)
              .update(values)
              .eq('owner_id', accountId)
              .select('owner_id');
        }
        if (rows.length != 1 || rows.single['owner_id'] != accountId) {
          throw const AppFailure(
            'لم نؤكد حفظ تفضيل التواصل. تحقق من الحالة قبل طلب جديد.',
            outcomeUnknown: true,
          );
        }
        return true;
      });
  @override
  Future<Result<ContactData?>> revealContact(
    String listingId,
    bool confirmed,
  ) => protect(() async {
    final session = _accountSession();
    if (!confirmed) throw const AppFailure('يلزم تأكيد طلب وسيلة التواصل.');
    final rows =
        await client
                .rpc(
                  'reveal_listing_contact',
                  params: {'p_listing': listingId, 'p_explicit_consent': true},
                )
                .setHeader('Authorization', session.authorization)
            as List<dynamic>;
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    return ContactData(
      row['contact_kind'] as String,
      row['contact_value'] as String,
      true,
    );
  });
  @override
  Future<Result<FeedEntry>> savePublication(
    Publication p, {
    FeedEntry? existing,
  }) => protectMutation(() async {
    final session = _accountSession();
    if (existing != null &&
        (existing.ownerId != currentUserId || existing.kind != p.kind)) {
      throw const AppFailure('لا يمكنك تعديل محتوى حساب آخر.');
    }
    if (p.title.trim().length < 3 ||
        p.title.length > 120 ||
        p.body.trim().isEmpty) {
      throw const AppFailure('العنوان والوصف مطلوبان.');
    }
    if (p.birdId == null || p.locationId == null || p.quantity < 1) {
      throw const AppFailure('اختر نوع الطيور والموقع والعدد.');
    }
    if (p.kind == FeedKind.offer &&
        (p.amount == null || p.amount! < 0 || !p.amount!.isFinite)) {
      throw const AppFailure('أدخل سعراً رقمياً صالحاً.');
    }
    final data = <String, dynamic>{
      'title': p.title.trim(),
      'description': p.body.trim(),
      'bird_type_id': p.birdId,
      'location_id': p.locationId,
      'quantity': p.quantity,
      'price': p.amount,
      'currency': p.currency,
      'price_unit': p.priceUnit == 'group' ? 'group' : 'bird',
      'negotiable': p.negotiable,
      'age_value': p.age,
      'age_unit': p.age == null ? null : p.ageUnit,
    };
    const table = 'listings';
    Map<String, dynamic> row;
    if (existing == null) {
      data['kind'] = p.kind.name;
      row = await client
          .from(table)
          .setHeader('Authorization', session.authorization)
          .insert(data)
          .select()
          .single();
    } else {
      data['status'] = p.status;
      final rows = await client
          .from(table)
          .setHeader('Authorization', session.authorization)
          .update(data)
          .eq('id', existing.id)
          .eq('owner_id', session.userId)
          .select();
      if (rows.length != 1) {
        throw const AppFailure(
          'لم يُحفظ التعديل. حدّث المحتوى وتحقق من الصلاحيات.',
        );
      }
      row = rows.single;
    }
    return decodeEntry(row, p.kind);
  });
}

FeedEntry decodeEntry(Map<String, dynamic> row, FeedKind kind) {
  final place = row['locations'] as Map<String, dynamic>?;
  final status = row['status'] as String? ?? 'active';
  return FeedEntry(
    id: row['id'] as String,
    ownerId: row['owner_id'] as String,
    title: row['title'] as String,
    body: row['description'] as String,
    kind: kind,
    createdAt: DateTime.parse(row['created_at'] as String),
    price: row['price'] as num?,
    currency: row['currency'] as String?,
    location: place == null ? '' : '${place['state_ar']}، ${place['city_ar']}',
    author:
        (row['profiles'] as Map<String, dynamic>?)?['display_name']
            as String? ??
        '',
    priceUnit: row['price_unit'] as String? ?? 'bird',
    statusCode: status,
    status: statusLabel(status, kind),
    birdId: row['bird_type_id'] as int?,
    locationId: row['location_id'] as int?,
    quantity: row['quantity'] as int? ?? 1,
    age: row['age_value'] as int?,
    ageUnit: row['age_unit'] as String? ?? 'month',
    negotiable: row['negotiable'] as bool? ?? false,
  );
}

String statusLabel(String status, FeedKind kind) => switch (status) {
  'active' => kind == FeedKind.request ? 'مفتوح' : 'متاح',
  'reserved' => 'محجوز',
  'fulfilled' =>
    kind == FeedKind.request ? 'تم العثور على المطلوب' : 'تم البيع',
  'closed' => 'مغلق',
  'expired' => 'منتهي',
  _ => status,
};

AppFailure edgeFailure(int status, Object? code) {
  if (code == 'recent_sign_in_required') {
    return const AppFailure(
      'يلزم تسجيل دخول جديد خلال آخر عشر دقائق. سجّل الخروج ثم ادخل مجدداً قبل طلب الحذف.',
    );
  }
  if (code == 'image_verifier_busy' || code == 'verification_busy') {
    return const AppFailure(
      'التحقق من الصور مشغول مؤقتاً. احتفظ بالمحاولة وأعد التحقق بعد قليل؛ لم نؤكد نشر الصورة.',
    );
  }
  if (status == 503) {
    return const AppFailure(
      'الخدمة غير متاحة مؤقتاً أو لم تُفعّل بعد. لم نؤكد اكتمال العملية.',
    );
  }
  if (status == 401) {
    return const AppFailure('انتهت جلسة الدخول. سجّل الدخول مجدداً.');
  }
  if (status == 429) {
    return const AppFailure(
      'وصلت إلى حد العمليات أو الصور. انتظر ثم حاول مجدداً.',
    );
  }
  if (code == 'invalid_image' || code == 'invalid_upload') {
    return const AppFailure(
      'رفض الخادم الصورة. استخدم JPEG صحيحاً بحد أقصى ٢ ميغابايت و٦٤٠×٦٤٠ بكسل.',
    );
  }
  return const AppFailure(
    'لم تكتمل العملية. تحقق من الاتصال والصلاحية ثم حاول مجدداً.',
  );
}

void requirePrivateImageUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      !uri.host.endsWith('.r2.cloudflarestorage.com')) {
    throw const AppFailure('رابط صورة غير موثوق؛ أوقفنا العملية.');
  }
}

void validateUploadHeaders(Map<String, String> headers, int bytes) {
  final normalized = {
    for (final e in headers.entries) e.key.toLowerCase(): e.value,
  };
  if (normalized.length != 3 ||
      normalized['content-type'] != 'image/jpeg' ||
      normalized['content-length'] != bytes.toString() ||
      normalized['if-none-match'] != '*') {
    throw const AppFailure(
      'عقد الرفع الآمن غير مكتمل. لن نرفع دون شرط منع الكتابة فوق الملفات.',
    );
  }
}

/// In-memory request scope. Never persist or log its authorization value.
class _AccountSession {
  const _AccountSession(this.userId, this.authorization);
  final String userId, authorization;
}
