import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'search and keyset filters coexist with deterministic ordering',
    () async {
      Uri? sent;
      final client = SupabaseClient(
        'https://example.test',
        'public-test-key',
        httpClient: MockClient((request) async {
          sent = request.url;
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      final cursor = FeedEntry(
        id: '00000000-0000-0000-0000-000000000001',
        title: 'test',
        body: '',
        kind: FeedKind.offer,
        createdAt: DateTime.utc(2026, 11, 8),
      );
      final result = await repo.feed(
        FeedKind.offer,
        FeedFilter(search: 'عصفور",status.eq.closed', before: cursor),
      );
      expect(result.isSuccess, isTrue);
      expect(sent!.queryParametersAll['or'], hasLength(2));
      expect(sent!.queryParameters['order'], 'created_at.desc.nullslast,id.desc.nullslast');
      expect(sent!.queryParameters['limit'], '20');
      expect(sent!.queryParameters['status'], 'eq.active');
      expect(
        sent!.queryParametersAll['or']!.last,
        contains('id.lt.${cursor.id}'),
      );
      await client.dispose();
    },
  );
  test('network errors are recoverable without raw error disclosure', () async {
    final client = SupabaseClient(
      'https://example.test',
      'public-test-key',
      httpClient: MockClient((_) async => throw Exception('private-token')),
    );
    final result = await SupabaseBirdsRepository(
      client,
      authRedirect: '',
    ).feed(FeedKind.education, const FeedFilter());
    expect(result.isSuccess, isFalse);
    expect(result.failure!.message, isNot(contains('private-token')));
    await client.dispose();
  });
}
