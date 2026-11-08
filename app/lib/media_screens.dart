import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'domain.dart';
import 'image_sanitizer.dart';
import 'media_policy.dart';

class MediaPanel extends StatefulWidget {
  const MediaPanel({super.key, required this.repository, required this.entry});
  final BirdsRepository repository;
  final FeedEntry entry;
  @override
  State<MediaPanel> createState() => _MediaPanelState();
}

class _MediaPanelState extends State<MediaPanel> {
  List<MediaAsset> images = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final result = await widget.repository.media(widget.entry);
    if (mounted) {
      setState(() {
        loading = false;
        images = result.value ?? [];
        error = result.failure?.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (loading) const LinearProgressIndicator(semanticsLabel: 'تحميل الصور'),
      for (final asset in images)
        PrivateImage(
          key: ValueKey(asset.id),
          repository: widget.repository,
          asset: asset,
        ),
      if (error != null) ...[
        Text(error!),
        TextButton(onPressed: load, child: const Text('إعادة تحميل الصور')),
      ],
      if (widget.repository.signedIn &&
          widget.entry.ownerId == widget.repository.currentUserId)
        OutlinedButton.icon(
          onPressed: () async {
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => UploadImagePage(
                  repository: widget.repository,
                  entry: widget.entry,
                ),
              ),
            );
            if (mounted) await load();
          },
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('إرفاق صور ووصف بديل (حتى ٣)'),
        ),
    ],
  );
}

class PrivateImage extends StatefulWidget {
  const PrivateImage({
    super.key,
    required this.repository,
    required this.asset,
  });
  final BirdsRepository repository;
  final MediaAsset asset;
  @override
  State<PrivateImage> createState() => _PrivateImageState();
}

class _PrivateImageState extends State<PrivateImage> {
  String? url, error;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    final result = await widget.repository.imageUrl(widget.asset.id);
    if (mounted) {
      setState(() {
        loading = false;
        url = result.value;
        error = result.failure?.message;
      });
    }
  }

  Widget retry() => Column(
    children: [
      Text(error ?? 'تعذر عرض الصورة أو انتهت صلاحية رابطها.'),
      TextButton(onPressed: load, child: const Text('تجديد رابط الصورة')),
    ],
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      children: [
        if (loading)
          const LinearProgressIndicator(semanticsLabel: 'تحميل الصورة')
        else if (url != null)
          Image.network(
            url!,
            semanticLabel: widget.asset.altText.isEmpty
                ? 'صورة مرفقة'
                : widget.asset.altText,
            fit: BoxFit.contain,
            height: 260,
            errorBuilder: (_, _, _) => retry(),
          )
        else
          retry(),
        if (widget.asset.altText.isNotEmpty) Text(widget.asset.altText),
      ],
    ),
  );
}

class UploadImagePage extends StatefulWidget {
  const UploadImagePage({
    super.key,
    required this.repository,
    required this.entry,
  });
  final BirdsRepository repository;
  final FeedEntry entry;
  @override
  State<UploadImagePage> createState() => _UploadImagePageState();
}

class _UploadImagePageState extends State<UploadImagePage> {
  final alt = TextEditingController();
  Uint8List? bytes;
  UploadIntent? intent;
  bool busy = false, attempted = false, uploaded = false;
  int? existingCount;
  String? error, notice;
  @override
  void initState() {
    super.initState();
    loadCount();
  }

  @override
  void dispose() {
    alt.dispose();
    super.dispose();
  }

  Future<void> loadCount() async {
    final result = await widget.repository.media(widget.entry);
    if (mounted) {
      setState(() {
        existingCount = result.value?.length;
        error = result.failure?.message;
      });
    }
  }

  Future<void> choose() async {
    if (busy ||
        existingCount == null ||
        existingCount! >= MediaPolicy.maxImages) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    final result = await protect(() async {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: MediaPolicy.maxDimension.toDouble(),
        maxHeight: MediaPolicy.maxDimension.toDouble(),
        imageQuality: 90,
        requestFullMetadata: false,
      );
      if (file == null) return null;
      if (await file.length() > 10485760) {
        throw const AppFailure('اختر صورة أصغر من ١٠ ميغابايت.');
      }
      return compute(sanitizeJpeg, await file.readAsBytes());
    }, timeout: null);
    if (mounted) {
      setState(() {
        busy = false;
        error = result.failure?.message;
        if (result.value != null) {
          bytes = result.value;
          intent = null;
          attempted = false;
          uploaded = false;
        }
      });
    }
  }

  Future<void> upload({bool verifyOnly = false}) async {
    if (busy || bytes == null) return;
    if (alt.text.trim().isEmpty || alt.text.length > 500) {
      setState(() => error = 'اكتب وصفاً بديلاً للصورة من حرف إلى ٥٠٠ حرف.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    if (intent == null) {
      final reserved = await widget.repository.reserveImage(
        widget.entry,
        bytes!.length,
      );
      if (!mounted) return;
      if (!reserved.isSuccess) {
        setState(() {
          busy = false;
          error = reserved.failure!.message;
        });
        return;
      }
      intent = reserved.value;
    }
    if (!verifyOnly && !uploaded) {
      attempted = true;
      final put = await widget.repository.putImage(intent!, bytes!);
      if (!mounted) return;
      if (!put.isSuccess) {
        setState(() {
          busy = false;
          error =
              '${put.failure!.message} يمكنك التحقق من الرفع السابق قبل إعادة الإرسال.';
        });
        return;
      }
      uploaded = true;
    }
    final completed = await widget.repository.completeImage(intent!, alt.text);
    if (!mounted) return;
    if (completed.isSuccess) {
      setState(() {
        busy = false;
        bytes = null;
        intent = null;
        attempted = false;
        uploaded = false;
        notice = 'تحقق الخادم من الصورة وأرفقها بالمحتوى.';
        alt.clear();
      });
      await loadCount();
    } else {
      setState(() {
        busy = false;
        error = completed.failure!.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('إرفاق صورة')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'JPEG وPNG من المعرض فقط. نعالج الصورة محلياً ونحذف البيانات الوصفية ثم نرفع JPEG جديداً. الحد ٣ صور للمحتوى، و٢ ميغابايت و٦٤٠×٦٤٠ بكسل للصورة. لا تُنشر قبل تحقق الخادم.',
          ),
          if (existingCount != null)
            Text('الصور المتحققة: $existingCount من ٣'),
          if (bytes != null)
            Image.memory(
              bytes!,
              height: 220,
              semanticLabel: 'معاينة الصورة المختارة قبل الرفع',
            ),
          TextField(
            controller: alt,
            enabled: !busy,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'وصف بديل للصورة لقارئ الشاشة',
            ),
          ),
          OutlinedButton(
            onPressed:
                busy ||
                    existingCount == null ||
                    existingCount! >= MediaPolicy.maxImages
                ? null
                : choose,
            child: const Text('اختيار صورة من المعرض'),
          ),
          if (bytes != null) ...[
            FilledButton(
              onPressed: busy ? null : () => upload(),
              child: Text(
                busy
                    ? 'جارٍ المعالجة…'
                    : uploaded
                    ? 'إعادة التحقق والإرفاق'
                    : 'رفع الصورة والتحقق منها',
              ),
            ),
            if (attempted)
              TextButton(
                onPressed: busy ? null : () => upload(verifyOnly: true),
                child: const Text('التحقق من الرفع السابق دون إعادته'),
              ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      bytes = null;
                      intent = null;
                      attempted = false;
                      uploaded = false;
                      notice =
                          'أُلغي الاختيار. أي حجز غير مكتمل ينتهي على الخادم تلقائياً؛ لا نؤكد نشر صورة.';
                    }),
              child: const Text('إلغاء اختيار الصورة'),
            ),
          ],
          if (busy) const Text('انتظر انتهاء العملية قبل مغادرة الشاشة.'),
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
          if (notice != null) Semantics(liveRegion: true, child: Text(notice!)),
          TextButton(
            onPressed: busy ? null : loadCount,
            child: const Text('تحديث حالة الصور'),
          ),
        ],
      ),
    ),
  );
}

class DeleteAccountPage extends StatefulWidget {
  const DeleteAccountPage({super.key, required this.repository});
  final BirdsRepository repository;
  @override
  State<DeleteAccountPage> createState() => _DeleteAccountPageState();
}

class _DeleteAccountPageState extends State<DeleteAccountPage> {
  final confirmation = TextEditingController();
  bool busy = false, confirming = false, requiresOperator = false;
  String? error, notice;
  DateTime? retryAt;
  @override
  void dispose() {
    confirmation.dispose();
    super.dispose();
  }

  Future<void> remove() async {
    if (busy || confirming) return;
    if (confirmation.text.trim() != 'حذف حسابي') {
      setState(() => error = 'اكتب «حذف حسابي» لتأكيد الطلب.');
      return;
    }
    if (retryAt != null && DateTime.now().isBefore(retryAt!)) {
      setState(() => error = 'لم تنتهِ مهلة الانتظار. حاول لاحقاً.');
      return;
    }
    setState(() => confirming = true);
    final consent = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: const Text('حذف الحساب نهائياً؟'),
        content: const Text(
          'سيُحذف حسابك وملفك وبيانات التواصل ومحتواك وصورك المرتبطة. هذه عملية نهائية لا يمكن التراجع عنها. قد تبقى معرّفات وسجلات أمنية محدودة لإثبات الحذف ومنع تكرار الرفع، ومدد الاحتفاظ النهائية لم تُعتمد بعد. لا تحذف ما قد يكون الآخرون نسخوه سابقاً. هل تريد المتابعة؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('أؤكد الحذف النهائي'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => confirming = false);
    if (consent != true) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    final result = await widget.repository.deleteOwnAccount();
    if (!mounted) return;
    setState(() {
      busy = false;
      error = result.failure?.message;
      if (result.value != null) {
        if (result.value!.completed) {
          notice = 'أكد الخادم حذف الحساب.';
        } else {
          retryAt = DateTime.now().add(
            Duration(seconds: result.value!.retryAfter),
          );
          requiresOperator = result.value!.requiresOperator;
          notice = requiresOperator
              ? 'طلب الحذف يحتاج إلى تدخل مسؤول الخدمة لمعالجة إعداد أو عائق أمني. لم يكتمل الحذف؛ راجع مسؤول نسخة التجربة قبل إعادة المحاولة. لن نكرر الطلب تلقائياً.'
              : 'طلب الحذف قيد التنفيذ، ولم يُحذف الحساب بالكامل بعد. انتظر ${result.value!.retryAfter} ثانية ثم تحقق مجدداً؛ قد تستغرق تسوية روابط الرفع عدة دقائق.';
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('حذف الحساب')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'يلزم تسجيل دخول جديد خلال آخر عشر دقائق. إذا طلب الخادم إعادة التحقق، سجّل الخروج ثم ادخل مجدداً، وبعدها عد لهذه الشاشة. لن نرسل طلب حذف بلا تأكيدك.',
          ),
          const Text(
            'الحذف النهائي يشمل حساب الدخول والملف والتواصل والمحتوى والصور المرتبطة. قد يبقى الطلب معلّقاً حتى انتهاء روابط رفع قصيرة الأجل. قد تبقى معرّفات وسجلات أمنية محدودة لإثبات الحذف ومنع إعادة الرفع، ولا يعني حذف الحساب محو كل سجل أمني. مدد الاحتفاظ النهائية لم تُعتمد بعد. هذه الواجهة لا تمثل موافقة على سياسة قانونية نهائية.',
          ),
          TextField(
            controller: confirmation,
            enabled: !busy,
            decoration: const InputDecoration(labelText: 'اكتب: حذف حسابي'),
          ),
          FilledButton(
            onPressed: busy || confirming || !widget.repository.signedIn
                ? null
                : remove,
            child: Text(
              busy
                  ? 'جارٍ طلب الحذف…'
                  : requiresOperator
                  ? 'إعادة المحاولة بعد معالجة مسؤول الخدمة'
                  : retryAt != null
                  ? 'التحقق وإكمال طلب الحذف'
                  : 'طلب حذف حسابي نهائياً',
            ),
          ),
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
          if (notice != null) Semantics(liveRegion: true, child: Text(notice!)),
        ],
      ),
    ),
  );
}
