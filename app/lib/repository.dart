import 'package:supabase_flutter/supabase_flutter.dart';
import 'domain.dart';

class SupabaseBirdsRepository implements BirdsRepository {
  SupabaseBirdsRepository(this.client, {required this.authRedirect});
  final SupabaseClient client;
  final String authRedirect;
  @override
  String? get currentUserId => client.auth.currentUser?.id;
  @override
  Future<Result<bool>> updateEntry(
    FeedEntry entry,
    String title,
    String body,
    String status,
  ) => protect(() async {
    requireAccount();
    if (entry.ownerId != currentUserId) {
      throw const AppFailure('يمكن لصاحب المحتوى وحده تعديله.');
    }
    final educational = entry.kind == FeedKind.education;
    final rows = await client
        .from(educational ? 'posts' : 'listings')
        .update({
          'title': title,
          educational ? 'body' : 'description': body,
          if (!educational) 'status': status,
        })
        .eq('id', entry.id)
        .eq('owner_id', currentUserId!)
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
    requireAccount();
    final rows = await client
        .from('user_blocks')
        .select('blocked_id')
        .eq('blocker_id', currentUserId!);
    return rows.map((r) => r['blocked_id'] as String).toList();
  });
  @override
  Future<Result<bool>> block(String userId, bool blocked) => protect(() async {
    requireAccount();
    if (userId == currentUserId) throw const AppFailure('لا يمكنك حظر حسابك.');
    if (blocked) {
      await client.from('user_blocks').insert({
        'blocker_id': currentUserId!,
        'blocked_id': userId,
      });
    } else {
      final rows = await client
          .from('user_blocks')
          .delete()
          .eq('blocker_id', currentUserId!)
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
  bool get signedIn => client.auth.currentUser != null;
  @override
  Stream<void> get authChanges =>
      client.auth.onAuthStateChange.map<void>((_) {});
  void requireAccount() {
    if (!signedIn) throw const AppFailure('سجّل الدخول أولاً.');
  }

  @override
  Future<Result<List<FeedEntry>>> feed(
    FeedKind kind,
    FeedFilter filter,
  ) => protect(() async {
    final education = kind == FeedKind.education;
    var query = client
        .from(education ? 'posts' : 'listings')
        .select(
          education
              ? 'id,owner_id,title,body,kind,created_at,profiles(display_name),replies(count)'
              : 'id,owner_id,title,description,kind,created_at,price,currency,price_unit,status,locations(state_ar,city_ar)',
        );
    if (!education) {
      query = query
          .eq('kind', kind.name)
          .eq('status', 'active')
          .gt('expires_at', DateTime.now().toUtc().toIso8601String());
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
    } else if (filter.category.isNotEmpty) {
      query = query.eq(
        'kind',
        filter.category == 'information' ? 'education' : 'consultation',
      );
    }
    if (filter.search.isNotEmpty) {
      // Use a quoted PostgREST value; user input cannot inject filter operators.
      final pattern = quotedSearchPattern(filter.search);
      query = query.or(
        'title.ilike.$pattern,${education ? 'body' : 'description'}.ilike.$pattern',
      );
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
    return rows.map((row) {
      final place = row['locations'] as Map<String, dynamic>?;
      return FeedEntry(
        id: row['id'] as String,
        ownerId: row['owner_id'] as String,
        statusCode: row['status'] as String? ?? 'active',
        title: row['title'] as String,
        body: row[education ? 'body' : 'description'] as String,
        kind: kind,
        createdAt: DateTime.parse(row['created_at'] as String),
        price: row['price'] as num?,
        currency: row['currency'] as String?,
        location: place == null
            ? ''
            : '${place['state_ar']}، ${place['city_ar']}',
        category: row['kind'] as String,
        author:
            (row['profiles'] as Map<String, dynamic>?)?['display_name']
                as String? ??
            '',
        replyCount:
            ((row['replies'] as List<dynamic>?)?.firstOrNull
                    as Map<String, dynamic>?)?['count']
                as int? ??
            0,
        priceUnit: row['price_unit'] as String? ?? 'bird',
        status: education
            ? ''
            : kind == FeedKind.request
            ? 'مفتوح'
            : 'متاح',
      );
    }).toList();
  });
  @override
  Future<Result<bool>> signIn(String provider) => protect(() async {
    if (authRedirect.isEmpty) {
      throw const AppFailure('لم يُضبط رابط العودة الآمن لتسجيل الدخول بعد.');
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
  Future<Result<bool>> signOut() => protect(() async {
    await client.auth.signOut();
    return true;
  });
  @override
  Future<Result<bool>> publish(Publication p) => protect(() async {
    requireAccount();
    final uid = client.auth.currentUser!.id;
    final profile = await client
        .from('profiles')
        .select('id')
        .eq('id', uid)
        .maybeSingle();
    if (profile == null) {
      if (p.displayName.trim().length < 2) {
        throw const AppFailure('أدخل اسم عرض عاماً من حرفين على الأقل.');
      }
      await client.from('profiles').insert({
        'id': uid,
        'display_name': p.displayName.trim(),
        'accepted_terms_at': DateTime.now().toUtc().toIso8601String(),
      });
    } else {
      await client
          .from('profiles')
          .update({
            'accepted_terms_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', uid);
    }
    int? birdId;
    if (p.birdType.isNotEmpty) {
      final bird = await client
          .from('bird_types')
          .select('id')
          .eq('name_ar', p.birdType)
          .maybeSingle();
      if (bird == null) {
        throw const AppFailure(
          'نوع الطيور غير موجود في القائمة المعتمدة. يلزم إضافة النوع بواسطة إدارة الخدمة أولاً.',
        );
      }
      birdId = bird['id'] as int;
    }
    if (p.kind == FeedKind.education) {
      await client.from('posts').insert({
        'title': p.title,
        'body': p.body,
        'kind': p.category == 'information' ? 'education' : 'consultation',
        'bird_type_id': birdId,
      });
    } else {
      if (p.kind == FeedKind.offer && (p.amount == null || p.amount! < 0)) {
        throw const AppFailure('السعر الرقمي مطلوب للعروض.');
      }
      final place = await client
          .from('locations')
          .select('id')
          .eq('state_ar', p.state)
          .eq('city_ar', p.city)
          .maybeSingle();
      if (place == null) {
        throw const AppFailure(
          'الولاية والمدينة غير موجودتين في القائمة المعتمدة. يلزم ضبط المواقع بواسطة إدارة الخدمة أولاً.',
        );
      }
      await client.from('listings').insert({
        'kind': p.kind.name,
        'title': p.title,
        'description': p.body,
        'bird_type_id': birdId,
        'location_id': place['id'],
        'quantity': p.quantity,
        'price': p.amount,
        'currency': p.currency,
        'price_unit': p.priceUnit == 'group' ? 'group' : 'bird',
        'negotiable': p.negotiable,
        'age_value': p.age,
        'age_unit': p.age == null
            ? null
            : {'days': 'day', 'months': 'month', 'years': 'year'}[p.ageUnit],
      });
    }
    return true;
  });
  @override
  Future<Result<List<String>>> replies(String postId) => protect(() async {
    final rows = await client
        .from('replies')
        .select('body')
        .eq('post_id', postId)
        .order('created_at')
        .order('id')
        .limit(100);
    return rows.map((row) => row['body'] as String).toList();
  });
  @override
  Future<Result<bool>> reply(String postId, String body) => protect(() async {
    requireAccount();
    await client.from('replies').insert({'post_id': postId, 'body': body});
    return true;
  });
  @override
  Future<Result<bool>> report(FeedEntry entry, String reason) =>
      protect(() async {
        requireAccount();
        await client.from('reports').insert({
          entry.kind == FeedKind.education ? 'post_id' : 'listing_id': entry.id,
          'reason': reason,
        });
        return true;
      });
}
