import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/auth_config.dart';
import 'package:sudan_birds/domain.dart';

void main() {
  test('only exact staging configuration is accepted', () {
    expect(() => validateAuthRedirect(stagingAuthRedirect), returnsNormally);
    for (final value in [
      '',
      'https://example.com/auth/callback',
      '$stagingAuthRedirect?code=x',
      'dev.sudanbirds.staging://other/callback',
    ]) {
      expect(() => validateAuthRedirect(value), throwsA(isA<AppFailure>()));
    }
  });
  test(
    'callback predicate admits PKCE staging route and rejects unrelated tokens',
    () {
      expect(
        isStagingAuthCallback(Uri.parse('$stagingAuthRedirect?code=one-time')),
        true,
      );
      expect(
        isStagingAuthCallback(
          Uri.parse('$stagingAuthRedirect?error=access_denied'),
        ),
        true,
      );
      for (final value in [
        'https://example.test?code=x',
        'dev.sudanbirds.staging://auth/other?code=x',
        '$stagingAuthRedirect#access_token=x',
        '$stagingAuthRedirect?access_token=x',
        '$stagingAuthRedirect?code=a&code=b',
        '$stagingAuthRedirect?code=a&error=bad',
        'dev.sudanbirds.staging://user@auth/callback?code=x',
        'dev.sudanbirds.staging://auth:42/callback?code=x',
      ]) {
        expect(isStagingAuthCallback(Uri.parse(value)), false, reason: value);
      }
    },
  );
  test('native manifests declare staging route and Flutter uses explicit PKCE', () {
    final android = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final ios = File('ios/Runner/Info.plist').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    expect(
      android,
      contains(
        'android:scheme="dev.sudanbirds.staging" android:host="auth" android:path="/callback"',
      ),
    );
    expect(
      ios,
      contains(
        '<key>CFBundleURLSchemes</key><array><string>dev.sudanbirds.staging</string></array>',
      ),
    );
    expect(main, contains('authFlowType: AuthFlowType.pkce'));
    expect(main, contains('detectSessionInUri: false'));
  });
}
