import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/screens.dart';
import 'package:sudan_birds/media_screens.dart';

class AccountRepository extends PreviewRepository {
  int savedProfiles = 0, deletionCalls = 0;
  ContactData? savedContact;
  @override
  bool get signedIn => true;
  @override
  Future<Result<bool>> saveProfile(String name, bool accepted) async {
    if (name.length < 2 || !accepted) {
      return const Result.failure(AppFailure('الإقرار مطلوب'));
    }
    savedProfiles++;
    return const Result.success(true);
  }

  @override
  Future<Result<bool>> saveContact(ContactData contact) async {
    savedContact = contact;
    return const Result.success(true);
  }

  @override
  Future<Result<DeletionStatus>> deleteOwnAccount() async {
    deletionCalls++;
    return const Result.success(DeletionStatus(false, retryAfter: 30));
  }
}

void main() {
  testWidgets(
    'profile onboarding works without publishing and requires acknowledgement',
    (tester) async {
      final repo = AccountRepository();
      await tester.pumpWidget(MaterialApp(home: ProfilePage(repository: repo)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'اسم العرض العام'),
        'مربي الطيور',
      );
      await tester.ensureVisible(find.text('حفظ الملف والإقرار'));
      await tester.tap(find.text('حفظ الملف والإقرار'));
      await tester.pumpAndSettle();
      expect(repo.savedProfiles, 0);
      await tester.ensureVisible(find.byType(CheckboxListTile).first);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.ensureVisible(find.text('حفظ الملف والإقرار'));
      await tester.tap(find.text('حفظ الملف والإقرار'));
      await tester.pumpAndSettle();
      expect(repo.savedProfiles, 1);
      expect(repo.savedContact, isNull);
    },
  );
  testWidgets(
    'deletion needs typed and dialog confirmation and pending is honest',
    (tester) async {
      final repo = AccountRepository();
      await tester.pumpWidget(
        MaterialApp(home: DeleteAccountPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('طلب حذف حسابي نهائياً'));
      await tester.tap(find.text('طلب حذف حسابي نهائياً'));
      await tester.pumpAndSettle();
      expect(repo.deletionCalls, 0);
      await tester.enterText(find.byType(TextField), 'حذف حسابي');
      await tester.ensureVisible(find.text('طلب حذف حسابي نهائياً'));
      await tester.tap(find.text('طلب حذف حسابي نهائياً'));
      await tester.pumpAndSettle();
      expect(repo.deletionCalls, 0);
      await tester.tap(find.text('أؤكد الحذف النهائي'));
      await tester.pumpAndSettle();
      expect(repo.deletionCalls, 1);
      expect(
        find.textContaining('ولم يُحذف الحساب بالكامل بعد'),
        findsOneWidget,
      );
      expect(find.text('أكد الخادم حذف الحساب.'), findsNothing);
    },
  );
  test(
    'changing filters discards the cursor and preserves scoped price currency',
    () {
      final filter = FeedFilter(
        currency: 'SDG',
        minPrice: 100,
        birdId: 1,
        before: FeedEntry(
          id: 'id',
          title: '',
          body: '',
          kind: FeedKind.offer,
          createdAt: DateTime.utc(2026),
        ),
      );
      final reset = filter.withCursor(null, query: 'عصفور');
      expect(reset.before, isNull);
      expect(reset.currency, 'SDG');
      expect(reset.minPrice, 100);
      expect(reset.birdId, 1);
    },
  );
}
