import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'domain.dart';

/// Android can kill the activity while the system picker is open. A recovered
/// file has no trustworthy account/listing association after process restart.
/// Consume the plugin's recovery record, but never read, attach or upload it.
Future<String?> discardInterruptedImageSelection({ImagePicker? picker}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  final result = await protect(
    () => (picker ?? ImagePicker()).retrieveLostData(),
    timeout: const Duration(seconds: 5),
  );
  if (!result.isSuccess) {
    return 'تعذر التحقق من اختيار صورة سابق. لم تُرفق أي صورة تلقائياً. افتح الإعلان المطلوب واختر الصورة مجدداً.';
  }
  if (result.value!.isEmpty) return null;
  return 'انقطع اختيار صورة سابق عند توقف التطبيق. لم تُرفق أو تُرفع الصورة المستعادة. افتح الإعلان المطلوب واختر الصورة مجدداً.';
}
