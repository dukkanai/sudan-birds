import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/repository.dart';

const userId = '00000000-0000-4000-8000-000000000001';
Future<SupabaseClient> authenticated(
  http.Response Function(http.Request) handler,
) async {
  final token =
      '${base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'))}.${base64Url.encode(utf8.encode(jsonEncode({'sub': userId, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})))}.test';
  final client = SupabaseClient(
    'https://example.test',
    'public-test-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      if (request.url.path.contains('/auth/v1/token')) {
        return http.Response(
          jsonEncode({
            'access_token': token,
            'refresh_token': 'test-refresh',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': userId,
              'aud': 'authenticated',
              'email': 'test@example.test',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      return handler(request);
    }),
  );
  await client.auth.signInWithPassword(
    email: 'test@example.test',
    password: 'test-only',
  );
  return client;
}

http.Response jsonResponse(http.Request r, Object body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
      request: r,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'advanced filters remain scoped and do not compare mixed currencies',
    () async {
      Uri? uri;
      final client = SupabaseClient(
        'https://example.test',
        'public-test-key',
        httpClient: MockClient((r) async {
          uri = r.url;
          return jsonResponse(r, []);
        }),
      );
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      final rejected = await repo.feed(
        FeedKind.offer,
        const FeedFilter(minPrice: 10),
      );
      expect(rejected.isSuccess, false);
      expect(uri, isNull);
      final result = await repo.feed(
        FeedKind.offer,
        FeedFilter(
          birdId: 2,
          locationId: 3,
          currency: 'SDG',
          minPrice: 10,
          maxPrice: 50,
          since: DateTime.utc(2026),
          status: 'reserved',
        ),
      );
      expect(result.isSuccess, true);
      expect(uri!.queryParameters['currency'], 'eq.SDG');
      expect(uri!.queryParametersAll['price'], ['gte.10', 'lte.50']);
      expect(uri!.queryParameters['bird_type_id'], 'eq.2');
      expect(uri!.queryParameters['location_id'], 'eq.3');
      await client.dispose();
    },
  );
  test(
    'contact reveal requires confirmation and deletion sends no target user',
    () async {
      final requests = <http.Request>[];
      final client = await authenticated((r) {
        requests.add(r);
        return jsonResponse(r, {
          'status': 'pending',
          'retry_after_seconds': 45,
        }, 202);
      });
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      expect((await repo.revealContact('listing', false)).isSuccess, false);
      expect(requests, isEmpty);
      final result = await repo.deleteOwnAccount();
      expect(result.value!.completed, false);
      expect(result.value!.retryAfter, 45);
      expect(jsonDecode(requests.single.body), {
        'confirmation': 'DELETE_MY_ACCOUNT',
      });
      await client.dispose();
    },
  );
  test('media completion does not succeed without verified response', () async {
    final client = await authenticated(
      (r) => jsonResponse(r, {'status': 'pending', 'media_id': 'test-id'}),
    );
    final repo = SupabaseBirdsRepository(client, authRedirect: '');
    final intent = UploadIntent(
      id: 'test-id',
      url: 'https://test.r2.cloudflarestorage.com/key',
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      headers: const {},
    );
    expect((await repo.completeImage(intent, 'عصفور')).isSuccess, false);
    await client.dispose();
  });
  test('private image URLs reject redirects to untrusted hosts', () {
    expect(
      () => requirePrivateImageUrl('http://test.r2.cloudflarestorage.com/x'),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => requirePrivateImageUrl('https://evil.test/x'),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => requirePrivateImageUrl(
        'https://user:secret@test.r2.cloudflarestorage.com/x',
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => requirePrivateImageUrl('https://test.r2.cloudflarestorage.com/x'),
      returnsNormally,
    );
  });
  test(
    'reports use listing/account target columns without private data',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final client = await authenticated((r) {
        bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return jsonResponse(r, {}, 201);
      });
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      expect(
        (await repo.reportTarget(
          ReportKind.listing,
          'listing-id',
          'سبب واضح',
        )).isSuccess,
        true,
      );
      expect(
        (await repo.reportTarget(
          ReportKind.account,
          userId,
          'سبب واضح',
        )).isSuccess,
        true,
      );
      expect(bodies, [
        {'listing_id': 'listing-id', 'reason': 'سبب واضح'},
        {'account_id': userId, 'reason': 'سبب واضح'},
      ]);
      await client.dispose();
    },
  );
  test(
    'moderator queue requires a role returned by the protected table',
    () async {
      final paths = <String>[];
      final client = await authenticated((r) {
        paths.add(r.url.path);
        return jsonResponse(r, []);
      });
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      expect((await repo.moderationReports('open')).isSuccess, false);
      expect(paths, ['/rest/v1/moderator_roles']);
      await client.dispose();
    },
  );
  test('moderation queue selects only listing and account targets', () async {
    Uri? query;
    final client = await authenticated((r) {
      if (r.url.path.endsWith('moderator_roles')) {
        return jsonResponse(r, [
          {'role': 'moderator'},
        ]);
      }
      query = r.url;
      return jsonResponse(r, [
        {
          'id': 'report',
          'listing_id': 'listing',
          'account_id': null,
          'reason': 'سبب واضح',
          'state': 'open',
          'created_at': '2026-01-01T00:00:00Z',
        },
      ]);
    });
    final result = await SupabaseBirdsRepository(
      client,
      authRedirect: '',
    ).moderationReports('open');
    expect(result.isSuccess, isTrue);
    expect(result.value!.single.kind, ReportKind.listing);
    expect(
      query!.queryParameters['select'],
      'id,listing_id,account_id,reason,state,created_at',
    );
    await client.dispose();
  });
  test(
    'deleted moderation targets and pending deletion are decoded honestly',
    () async {
      final client = await authenticated((r) {
        if (r.url.path.endsWith('moderator_roles')) {
          return jsonResponse(r, [
            {'role': 'moderator'},
          ]);
        }
        if (r.url.path.endsWith('own_deletion_status')) {
          return jsonResponse(r, [
            {
              'state': 'pending',
              'retry_after_seconds': 47,
              'requires_operator': true,
            },
          ]);
        }
        return jsonResponse(r, [
          {'missing': true, 'target_kind': 'listing', 'target_id': 'deleted'},
        ]);
      });
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      final report = ModerationReport(
        id: 'report',
        reason: 'reason',
        state: 'open',
        createdAt: DateTime.utc(2026),
        kind: ReportKind.listing,
        targetId: 'deleted',
      );
      final target = await repo.moderationTarget(report);
      expect(target.isSuccess, true);
      expect(target.value, isNull);
      expect((await repo.deletionStatus()).value!.completed, false);
      expect((await repo.deletionStatus()).value!.retryAfter, 47);
      expect((await repo.deletionStatus()).value!.requiresOperator, true);
      await client.dispose();
    },
  );
  test('guest photos use public RLS-checked media-read endpoint', () async {
    http.Request? request;
    final client = SupabaseClient(
      'https://example.test',
      'public-test-key',
      httpClient: MockClient((r) async {
        request = r;
        return jsonResponse(r, {
          'url': 'https://test.r2.cloudflarestorage.com/verified',
        });
      }),
    );
    final result = await SupabaseBirdsRepository(
      client,
      authRedirect: '',
    ).imageUrl('media-id');
    expect(result.isSuccess, true);
    expect(request!.url.path, '/functions/v1/media-read');
    expect(jsonDecode(request!.body), {'media_id': 'media-id'});
    await client.dispose();
  });
  test(
    'upload contract rejects missing or changed create-only precondition',
    () {
      final correct = {
        'Content-Type': 'image/jpeg',
        'Content-Length': '12',
        'If-None-Match': '*',
      };
      expect(() => validateUploadHeaders(correct, 12), returnsNormally);
      expect(
        () => validateUploadHeaders({
          'Content-Type': 'image/jpeg',
          'Content-Length': '12',
        }, 12),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => validateUploadHeaders({...correct, 'If-None-Match': 'other'}, 12),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => validateUploadHeaders(correct, 13),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test(
    'unsupported auth provider is rejected without launching or network',
    () async {
      var requests = 0;
      final client = SupabaseClient(
        'https://example.test',
        'public-test-key',
        httpClient: MockClient((r) async {
          requests++;
          return jsonResponse(r, {});
        }),
      );
      final result = await SupabaseBirdsRepository(
        client,
        authRedirect: 'dev.sudanbirds.staging://auth/callback',
      ).signIn('unsupported');
      expect(result.isSuccess, false);
      expect(result.failure!.message, contains('غير مدعوم'));
      expect(requests, 0);
      await client.dispose();
    },
  );
}
