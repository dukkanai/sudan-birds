import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const domains = [
    'root',
    'file',
    'database',
    'sharedpref',
    'external',
    'device_root',
    'device_file',
    'device_database',
    'device_sharedpref',
  ];

  test(
    'Android disables backup and binds rules for both Android generations',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android:allowBackup="false"'));
      expect(
        manifest,
        contains('android:fullBackupContent="@xml/backup_rules"'),
      );
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
    },
  );

  test('legacy backup excludes every app-data domain', () {
    final rules = File(
      'android/app/src/main/res/xml/backup_rules.xml',
    ).readAsStringSync();
    expect(rules, contains('<full-backup-content>'));
    for (final domain in domains) {
      expect(rules, contains('<exclude domain="$domain" path="." />'));
    }
    expect(rules, isNot(contains('<include')));
  });

  test('cloud backup and device transfer independently exclude app data', () {
    final rules = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    expect(rules, contains('<data-extraction-rules>'));
    for (final channel in ['cloud-backup', 'device-transfer']) {
      final section = RegExp(
        '<$channel>(.*?)</$channel>',
        dotAll: true,
      ).firstMatch(rules)?.group(1);
      expect(section, isNotNull, reason: channel);
      for (final domain in domains) {
        expect(
          section,
          contains('<exclude domain="$domain" path="." />'),
          reason: '$channel: $domain',
        );
      }
    }
    expect(rules, isNot(contains('<include')));
  });

  test('iOS photo consent describes listings only', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('اختر صور الطيور لإرفاقها بإعلانك بعد موافقتك.'));
    expect(plist, isNot(contains('أو منشورك')));
  });

  test('native iOS metadata declares the existing Arabic-only UI', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(
      plist,
      contains(
        '<key>CFBundleLocalizations</key>\n\t<array><string>ar</string></array>',
      ),
    );
    expect(
      plist,
      contains(
        '<key>CFBundleDisplayName</key>\n\t<string>طيور السودان</string>',
      ),
    );
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('developmentRegion = ar;'));
    final regions = RegExp(r'knownRegions = \((.*?)\);', dotAll: true)
        .firstMatch(project)!
        .group(1)!
        .split(',')
        .map((region) => region.trim())
        .where((region) => region.isNotEmpty)
        .toList();
    expect(regions, ['ar', 'Base']);
  });
}
