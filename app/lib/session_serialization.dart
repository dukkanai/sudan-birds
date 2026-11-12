import 'dart:convert';

/// Retention hygiene only, not provider grant registration or revocation.
/// Supabase credentials remain necessary for session restore. Provider credentials
/// must never enter routine persistent sessions or the installed main session.
String sanitizedSessionJson(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> ||
        decoded['access_token'] is! String ||
        (decoded['access_token'] as String).isEmpty) {
      throw const FormatException();
    }
    decoded.remove('provider_token');
    decoded.remove('provider_refresh_token');
    return jsonEncode(decoded);
  } catch (_) {
    // Never attach the original input or decoder error (which can contain it).
    throw const FormatException('Invalid stored session');
  }
}
