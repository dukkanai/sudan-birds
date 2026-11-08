import 'domain.dart';

/// Development identity only. Production requires approved store identities and
/// domain-linked redirects, with its own reviewed native configuration.
const stagingAuthRedirect = 'dev.sudanbirds.staging://auth/callback';

void validateAuthRedirect(String redirect) {
  if (redirect != stagingAuthRedirect) {
    throw const AppFailure(
      'تسجيل الدخول متاح فقط عبر رابط عودة التجربة المعتمد. تحقق من إعداد AUTH_REDIRECT_URL.',
    );
  }
}

bool isStagingAuthCallback(Uri uri) {
  if (uri.scheme != 'dev.sudanbirds.staging' ||
      uri.host != 'auth' ||
      uri.path != '/callback' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.queryParameters.containsKey('access_token')) {
    return false;
  }
  final codes = uri.queryParametersAll['code'];
  final errors = uri.queryParametersAll['error'];
  if (codes != null && errors != null) return false;
  return (codes?.length == 1 && codes!.single.isNotEmpty) ||
      (errors?.length == 1 && errors!.single.isNotEmpty);
}
