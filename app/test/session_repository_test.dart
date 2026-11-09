import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/repository.dart';

const a = '00000000-0000-4000-8000-000000000001';
const b = '00000000-0000-4000-8000-000000000002';
Map<String, dynamic> session(String id) {
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final token =
      '${base64Url.encode(utf8.encode('{"alg":"HS256"}'))}.${base64Url.encode(utf8.encode(jsonEncode({'sub': id, 'exp': exp})))}.fixture';
  return {
    'access_token': token,
    'refresh_token': 'synthetic-refresh-$id',
    'expires_in': 3600,
    'expires_at': exp,
    'token_type': 'bearer',
    'user': {
      'id': id,
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}

http.Response response(http.Request r, Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
  request: r,
);
Future<SupabaseClient> clientFor(
  Future<http.Response> Function(http.Request) handler,
) async {
  final client = SupabaseClient(
    'https://example.test',
    'public-test-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(handler),
  );
  await client.auth.recoverSession(jsonEncode(session(a)));
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final contact in [false, true]) {
    test(
      '${contact ? 'contact' : 'profile'} write aborts if identity changes during existence read',
      () async {
        final started = Completer<void>();
        final read = Completer<http.Response>();
        http.Request? readRequest;
        var writes = 0;
        final client = await clientFor((r) async {
          if (r.method != 'GET') {
            writes++;
            return response(r, {});
          }
          readRequest = r;
          started.complete();
          return read.future;
        });
        final repo = SupabaseBirdsRepository(client, authRedirect: '');
        final operation = contact
            ? repo.saveContact(const ContactData('phone', 'private-A', true))
            : repo.saveProfile('اسم الحساب أ', true);
        await started.future;
        await client.auth.recoverSession(jsonEncode(session(b)));
        read.complete(response(readRequest!, []));
        final result = await operation;
        expect(result.isSuccess, false);
        expect(result.failure!.message, contains('تغيرت جلسة الحساب'));
        expect(writes, 0);
        expect(
          readRequest!.url.queryParameters[contact ? 'owner_id' : 'id'],
          'eq.$a',
        );
        await client.dispose();
      },
    );
  }

  test(
    'account-delete keeps initiating Authorization through SDK encoding and never logs out B',
    () async {
      http.Request? sent;
      String? principalAtSend;
      late SupabaseClient client;
      client = await clientFor((r) async {
        sent = r;
        principalAtSend = client.auth.currentUser?.id;
        return response(r, {'status': 'completed'});
      });
      final tokenA = client.auth.currentSession!.accessToken;
      final operation = SupabaseBirdsRepository(
        client,
        authRedirect: '',
      ).deleteOwnAccount();
      // recoverSession changes the in-memory account synchronously before the SDK
      // completes JSON encoding and asks AuthHttpClient for its current token.
      await client.auth.recoverSession(jsonEncode(session(b)));
      final result = await operation;
      expect(principalAtSend, b);
      expect(sent!.headers['Authorization'], 'Bearer $tokenA');
      expect(result.value!.completed, true);
      expect(client.auth.currentUser!.id, b);
      await client.dispose();
    },
  );

  test(
    'listing insert remains authorized as A when SDK sees a newer B session',
    () async {
      http.Request? sent;
      String? principalAtSend;
      late SupabaseClient client;
      client = await clientFor((r) async {
        sent = r;
        principalAtSend = client.auth.currentUser?.id;
        return response(r, {
          'id': 'listing',
          'owner_id': a,
          'title': 'عنوان',
          'description': 'وصف',
          'created_at': '2026-01-01T00:00:00Z',
        });
      });
      final tokenA = client.auth.currentSession!.accessToken;
      final operation = SupabaseBirdsRepository(client, authRedirect: '')
          .savePublication(
            const Publication(
              kind: FeedKind.request,
              title: 'عنوان',
              body: 'وصف',
              birdId: 1,
              locationId: 1,
            ),
          );
      await client.auth.recoverSession(jsonEncode(session(b)));
      final result = await operation;
      expect(principalAtSend, b);
      expect(sent!.headers['Authorization'], 'Bearer $tokenA');
      expect(result.isSuccess, true);
      expect(result.value!.ownerId, a);
      await client.dispose();
    },
  );

  test(
    'role check cannot authorize a moderation write from a newer actor',
    () async {
      final started = Completer<void>();
      final role = Completer<http.Response>();
      http.Request? roleRequest;
      var writes = 0;
      final client = await clientFor((r) async {
        if (r.url.path.endsWith('moderator_roles')) {
          roleRequest = r;
          started.complete();
          return role.future;
        }
        writes++;
        return response(r, {});
      });
      final operation = SupabaseBirdsRepository(
        client,
        authRedirect: '',
      ).resolveReport('report', 'resolved', 'سبب واضح');
      await started.future;
      await client.auth.recoverSession(jsonEncode(session(b)));
      role.complete(
        response(roleRequest!, [
          {'role': 'moderator'},
        ]),
      );
      expect((await operation).isSuccess, false);
      expect(writes, 0);
      await client.dispose();
    },
  );

  test(
    'real repository marks lost listing response uncertain without repeating POST',
    () async {
      var accepted = 0;
      final client = await clientFor((r) async {
        accepted++;
        throw TimeoutException('synthetic response lost after commit');
      });
      final result = await SupabaseBirdsRepository(client, authRedirect: '')
          .savePublication(
            const Publication(
              kind: FeedKind.request,
              title: 'عنوان',
              body: 'وصف',
              birdId: 1,
              locationId: 1,
            ),
          );
      expect(result.isSuccess, false);
      expect(result.failure!.outcomeUnknown, true);
      expect(accepted, 1);
      expect(result.failure!.message, isNot(contains('synthetic')));
      await client.dispose();
    },
  );

  test(
    'mutation timeout does not pretend to cancel the original operation',
    () async {
      final pending = Completer<bool>();
      final result = await protect(
        () => pending.future,
        timeout: const Duration(milliseconds: 1),
        mutation: true,
      );
      expect(result.failure!.outcomeUnknown, true);
      expect(pending.isCompleted, false);
      pending.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(result.isSuccess, false);
    },
  );
  test(
    'unsafe successful reserve contract remains an uncertain committed reservation',
    () async {
      var reservations = 0;
      final client = await clientFor((r) async {
        reservations++;
        return response(r, {
          'put_url': 'https://test.r2.cloudflarestorage.com/key',
          'intent_id': 'intent',
          'expires_in': 60,
          'required_headers': {'Content-Type': 'image/jpeg'},
        });
      });
      final result = await SupabaseBirdsRepository(client, authRedirect: '')
          .reserveImage(
            FeedEntry(
              id: 'listing',
              title: 'عنوان',
              body: 'وصف',
              ownerId: a,
              kind: FeedKind.request,
              createdAt: DateTime.utc(2026),
            ),
            12,
          );
      expect(result.failure!.outcomeUnknown, true);
      expect(reservations, 1);
      await client.dispose();
    },
  );
}
