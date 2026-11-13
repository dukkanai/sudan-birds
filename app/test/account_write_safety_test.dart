import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/repository.dart';
import 'extended_repository_test.dart' show authenticated, jsonResponse, userId;

// The SDK owns a real JSON isolate. Create/dispose it outside the widget fake
// clock while exercising operation deadlines with deterministic clock advances.
Future<SupabaseClient> widgetAuthenticated(
  WidgetTester tester,
  FutureOr<http.Response> Function(http.Request) handler,
) async => (await tester.runAsync(() => authenticated(handler)))!;

Future<Result<bool>> save(
  SupabaseBirdsRepository repo,
  bool contact,
  String value,
) => contact
    ? repo.saveContact(ContactData('phone', value, true))
    : repo.saveProfile(value, true);

final report = ModerationReport(
  id: 'report',
  reason: 'سبب واضح',
  state: 'open',
  createdAt: DateTime.utc(2026),
  kind: ReportKind.listing,
  targetId: 'target',
);

Future<Result<bool>> moderate(SupabaseBirdsRepository repo, bool resolve) =>
    resolve
    ? repo.resolveReport('report', 'resolved', 'سبب إجراء واضح')
    : repo.moderate(report, true, 'سبب إجراء واضح');

void main() {
  for (final contact in [false, true]) {
    final label = contact ? 'contact' : 'profile';
    final idKey = contact ? 'owner_id' : 'id';
    final valueKey = contact ? 'contact_value' : 'display_name';
    testWidgets('$label late read A cannot overwrite successful B', (
      tester,
    ) async {
      final delayed = Completer<http.Response>();
      http.Request? firstRead;
      final writes = <http.Request>[];
      final client = await widgetAuthenticated(tester, (r) {
        if (r.method == 'GET' && firstRead == null) {
          firstRead = r;
          return delayed.future;
        }
        if (r.method == 'GET') {
          return jsonResponse(r, [
            {idKey: userId},
          ]);
        }
        writes.add(r);
        return jsonResponse(r, [
          {idKey: userId},
        ]);
      });
      addTearDown(() => tester.runAsync(client.dispose));
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      final a = save(repo, contact, 'older-value');
      await tester.pump();
      expect(firstRead, isNotNull);
      await tester.pump(const Duration(seconds: 21));
      final aResult = await a;
      expect(aResult.isSuccess, false);
      expect(aResult.failure!.outcomeUnknown, false);
      expect(writes, isEmpty);
      expect((await save(repo, contact, 'newer-value')).isSuccess, true);
      delayed.complete(
        jsonResponse(firstRead!, [
          {idKey: userId},
        ]),
      );
      await tester.pump();
      expect(writes, hasLength(1));
      expect(jsonDecode(writes.single.body)[valueKey], 'newer-value');
    });

    testWidgets(
      '$label sent A remains quarantined after timeout and late success',
      (tester) async {
        final delayed = Completer<http.Response>();
        final writes = <http.Request>[];
        var reads = 0;
        final client = await widgetAuthenticated(tester, (r) {
          if (r.method == 'GET') {
            reads++;
            return jsonResponse(r, [
              {idKey: userId},
            ]);
          }
          writes.add(r);
          return delayed.future;
        });
        addTearDown(() => tester.runAsync(client.dispose));
        final repo = SupabaseBirdsRepository(client, authRedirect: '');
        final a = save(repo, contact, 'older-value');
        await tester.pump();
        expect(writes, hasLength(1));
        await tester.pump(const Duration(seconds: 21));
        final result = await a;
        expect(result.isSuccess, false);
        expect(result.failure!.outcomeUnknown, true);
        expect((await save(repo, contact, 'newer-value')).isSuccess, false);
        delayed.complete(
          jsonResponse(writes.single, [
            {idKey: userId},
          ]),
        );
        await tester.pump();
        // A late transport response is not proof that the caller observed success.
        expect((await save(repo, contact, 'third-value')).isSuccess, false);
        expect(reads, 1);
        expect(writes, hasLength(1));
        expect(result.isSuccess, false);
      },
    );

    testWidgets('$label concurrent duplicate cannot release active fence', (
      tester,
    ) async {
      final delayed = Completer<http.Response>();
      final writes = <http.Request>[];
      final client = await widgetAuthenticated(tester, (r) {
        if (r.method == 'GET') {
          return jsonResponse(r, [
            {idKey: userId},
          ]);
        }
        writes.add(r);
        return writes.length == 1
            ? delayed.future
            : jsonResponse(r, [
                {idKey: userId},
              ]);
      });
      addTearDown(() => tester.runAsync(client.dispose));
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      final a = save(repo, contact, 'first-value');
      await tester.pump();
      expect((await save(repo, contact, 'second-value')).isSuccess, false);
      expect((await save(repo, contact, 'third-value')).isSuccess, false);
      expect(writes, hasLength(1));
      delayed.complete(
        jsonResponse(writes.single, [
          {idKey: userId},
        ]),
      );
      await tester.pump();
      expect((await a).isSuccess, true);
      expect((await save(repo, contact, 'fourth-value')).isSuccess, true);
      expect(writes, hasLength(2));
    });

    for (final insert in [false, true]) {
      for (final wrongOwner in [false, true]) {
        test(
          '$label ${insert ? 'insert' : 'update'} rejects ${wrongOwner ? 'wrong owner' : 'zero rows'} and blocks retry',
          () async {
            final writes = <http.Request>[];
            final client = await authenticated((r) {
              if (r.method == 'GET') {
                return jsonResponse(
                  r,
                  insert
                      ? []
                      : [
                          {idKey: userId},
                        ],
                );
              }
              writes.add(r);
              return jsonResponse(
                r,
                wrongOwner
                    ? [
                        {idKey: 'other-account'},
                      ]
                    : [],
              );
            });
            addTearDown(client.dispose);
            final repo = SupabaseBirdsRepository(client, authRedirect: '');
            final result = await save(repo, contact, 'valid-value');
            expect(result.isSuccess, false);
            expect(result.failure!.outcomeUnknown, true);
            expect(
              (await save(repo, contact, 'another-value')).isSuccess,
              false,
            );
            expect(writes, hasLength(1));
            expect(writes.single.method, insert ? 'POST' : 'PATCH');
            expect(writes.single.url.queryParameters['select'], idKey);
            expect(
              writes.single.headers['prefer'],
              contains('return=representation'),
            );
          },
        );
      }
    }

    test('$label validation sends nothing and permits valid retry', () async {
      final requests = <http.Request>[];
      final client = await authenticated((r) {
        requests.add(r);
        return jsonResponse(r, [
          {idKey: userId},
        ]);
      });
      addTearDown(client.dispose);
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      final invalid = await save(repo, contact, 'x');
      expect(invalid.isSuccess, false);
      expect(invalid.failure!.outcomeUnknown, false);
      expect(requests, isEmpty);
      expect((await save(repo, contact, 'valid-value')).isSuccess, true);
      expect(requests, hasLength(2));
    });
  }

  for (final resolve in [false, true]) {
    final label = resolve ? 'resolveReport' : 'moderate';
    testWidgets('$label late role check cannot dispatch expired action', (
      tester,
    ) async {
      final delayed = Completer<http.Response>();
      http.Request? firstRole;
      final writes = <http.Request>[];
      final client = await widgetAuthenticated(tester, (r) {
        if (r.method == 'GET') {
          if (firstRole == null) {
            firstRole = r;
            return delayed.future;
          }
          return jsonResponse(r, [
            {'role': 'moderator'},
          ]);
        }
        writes.add(r);
        return jsonResponse(r, null);
      });
      addTearDown(() => tester.runAsync(client.dispose));
      final repo = SupabaseBirdsRepository(client, authRedirect: '');
      final a = moderate(repo, resolve);
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      expect((await a).failure!.outcomeUnknown, false);
      expect((await moderate(repo, resolve)).isSuccess, true);
      delayed.complete(
        jsonResponse(firstRole!, [
          {'role': 'moderator'},
        ]),
      );
      await tester.pump();
      expect(writes, hasLength(1));
    });

    testWidgets(
      '$label sent RPC timeout remains unknown and blocks duplicates',
      (tester) async {
        final delayed = Completer<http.Response>();
        final writes = <http.Request>[];
        final client = await widgetAuthenticated(tester, (r) {
          if (r.method == 'GET') {
            return jsonResponse(r, [
              {'role': 'moderator'},
            ]);
          }
          writes.add(r);
          return delayed.future;
        });
        addTearDown(() => tester.runAsync(client.dispose));
        final repo = SupabaseBirdsRepository(client, authRedirect: '');
        final a = moderate(repo, resolve);
        await tester.pump();
        await tester.pump(const Duration(seconds: 21));
        expect((await a).failure!.outcomeUnknown, true);
        expect((await moderate(repo, resolve)).isSuccess, false);
        delayed.complete(jsonResponse(writes.single, null));
        await tester.pump();
        expect((await moderate(repo, resolve)).isSuccess, false);
        expect(writes, hasLength(1));
        expect(
          writes.single.url.path,
          endsWith(resolve ? '/resolve_report' : '/moderate_content'),
        );
      },
    );
  }

  test('both report entry points share bounds and trim valid reason', () async {
    final writes = <http.Request>[];
    final client = await authenticated((r) {
      writes.add(r);
      return jsonResponse(r, {});
    });
    addTearDown(client.dispose);
    final repo = SupabaseBirdsRepository(client, authRedirect: '');
    final listing = FeedEntry(
      id: 'listing',
      title: 'عنوان',
      body: 'وصف',
      kind: FeedKind.offer,
      createdAt: DateTime.utc(2026),
    );
    for (final invalid in ['    ', '1234', 'x' * 2001]) {
      expect((await repo.report(listing, invalid)).isSuccess, false);
      expect(
        (await repo.reportTarget(
          ReportKind.listing,
          listing.id,
          invalid,
        )).isSuccess,
        false,
      );
    }
    expect(writes, isEmpty);
    expect((await repo.report(listing, '  valid reason  ')).isSuccess, true);
    expect(
      (await repo.reportTarget(
        ReportKind.listing,
        listing.id,
        '  valid reason  ',
      )).isSuccess,
      true,
    );
    expect(writes, hasLength(2));
    expect(jsonDecode(writes[0].body), {
      'listing_id': 'listing',
      'reason': 'valid reason',
    });
    expect(writes[0].body, writes[1].body);
    expect(
      writes.every(
        (r) => r.headers['authorization']?.startsWith('Bearer ') == true,
      ),
      true,
    );
  });
}
