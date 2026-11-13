import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'domain.dart';
import 'account_session.dart';
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
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant MediaPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id ||
        oldWidget.repository != widget.repository) {
      images = [];
      load();
    }
  }

  Future<void> load() async {
    if (!mounted) return;
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    final result = await guardResult(
      () => widget.repository.media(widget.entry),
    );
    if (mounted && request == generation) {
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
        Semantics(liveRegion: true, child: Text(error!)),
        TextButton(onPressed: load, child: const Text('إعادة تحميل الصور')),
      ],
      if (widget.repository.signedIn &&
          widget.entry.ownerId == widget.repository.currentUserId)
        OutlinedButton.icon(
          onPressed: () async {
            await Navigator.of(context).push<void>(
              accountPageRoute(
                repository: widget.repository,
                isAllowed: () =>
                    mounted &&
                    widget.entry.ownerId == widget.repository.currentUserId,
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
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant PrivateImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.repository != widget.repository) {
      load();
    }
  }

  Future<void> load() async {
    if (!mounted) return;
    final request = ++generation;
    final previousUrl = url;
    setState(() {
      loading = true;
      error = null;
      url = null;
    });
    if (previousUrl != null) {
      // Evict a failed cached download before retrying the same signed URL.
      final evicted = await protect(
        () => NetworkImage(previousUrl).evict(),
        timeout: null,
      );
      if (!mounted || request != generation) return;
      if (!evicted.isSuccess) {
        setState(() {
          loading = false;
          error = evicted.failure!.message;
        });
        return;
      }
    }
    if (!mounted || request != generation) return;
    final result = await guardResult(
      () => widget.repository.imageUrl(widget.asset.id),
    );
    if (mounted && request == generation) {
      setState(() {
        loading = false;
        url = result.value;
        error = result.failure?.message;
      });
    }
  }

  Widget retry() => Column(
    children: [
      Semantics(
        liveRegion: true,
        child: Text(error ?? 'تعذر عرض الصورة أو انتهت صلاحية رابطها.'),
      ),
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
    this.picker,
  });
  final BirdsRepository repository;
  final FeedEntry entry;
  final ImagePicker? picker;
  @override
  State<UploadImagePage> createState() => _UploadImagePageState();
}

class _UploadImagePageState extends State<UploadImagePage>
    with AccountBoundState<UploadImagePage> {
  @override
  BirdsRepository get accountRepository => widget.repository;
  @override
  void clearAccountData() {
    bytes = null;
    intent = null;
    alt.clear();
  }

  final alt = TextEditingController();
  Uint8List? bytes;
  UploadIntent? intent;
  bool busy = false, attempted = false, uploaded = false, counting = false;
  int? existingCount;
  bool uncertainReservation = false;
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
    if (!isAccountCurrent) return;
    if (counting) return;
    setState(() => counting = true);
    final result = await guardResult(
      () => widget.repository.media(widget.entry),
    );
    if (mounted && isAccountCurrent) {
      setState(() {
        counting = false;
        existingCount = result.value?.length;
        error = result.failure?.message;
      });
    }
  }

  Future<void> choose() async {
    if (!isAccountCurrent) return;
    if (busy ||
        counting ||
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
      final file = await (widget.picker ?? ImagePicker()).pickImage(
        source: ImageSource.gallery,
        maxWidth: MediaPolicy.maxDimension.toDouble(),
        maxHeight: MediaPolicy.maxDimension.toDouble(),
        imageQuality: 90,
        requestFullMetadata: false,
      );
      // The picker can return after the route or its account has gone away.
      // Do not read or decode that file under a stale consent/screen scope.
      if (file == null || !isAccountCurrent) return null;
      final length = await file.length();
      if (!isAccountCurrent) return null;
      if (length > 10485760) {
        throw const AppFailure('اختر صورة أصغر من ١٠ ميغابايت.');
      }
      final source = await file.readAsBytes();
      if (!isAccountCurrent) return null;
      return compute(sanitizeJpeg, source);
    }, timeout: null);
    if (mounted && isAccountCurrent) {
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
    if (!isAccountCurrent) return;
    if (busy || counting || uncertainReservation || bytes == null) return;
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
      final reserved = await guardMutation(
        () => widget.repository.reserveImage(widget.entry, bytes!.length),
      );
      if (!mounted || !isAccountCurrent) return;
      if (!reserved.isSuccess) {
        setState(() {
          busy = false;
          error = reserved.failure!.message;
          uncertainReservation = reserved.failure!.outcomeUnknown;
        });
        return;
      }
      intent = reserved.value;
    }
    if (!verifyOnly && !uploaded) {
      attempted = true;
      final put = await guardResult(
        () => widget.repository.putImage(intent!, bytes!),
      );
      if (!mounted || !isAccountCurrent) return;
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
    final completed = await guardResult(
      () => widget.repository.completeImage(intent!, alt.text),
    );
    if (!mounted || !isAccountCurrent) return;
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
  Widget build(BuildContext context) => protectAccount(
    PopScope(
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
                      counting ||
                      existingCount == null ||
                      existingCount! >= MediaPolicy.maxImages
                  ? null
                  : choose,
              child: const Text('اختيار صورة من المعرض'),
            ),
            if (bytes != null) ...[
              FilledButton(
                onPressed: busy || counting || uncertainReservation
                    ? null
                    : () => upload(),
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
                  onPressed: busy || counting
                      ? null
                      : () => upload(verifyOnly: true),
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
            if (uncertainReservation)
              const Text(
                'قد يكون حجز الرفع أُنشئ دون وصول نتيجته. لا نكرر الحجز هنا؛ انتظر انتهاءه قبل بدء رفع جديد.',
              ),
            if (error != null) Semantics(liveRegion: true, child: Text(error!)),
            if (notice != null)
              Semantics(liveRegion: true, child: Text(notice!)),
            TextButton(
              onPressed: busy || counting ? null : loadCount,
              child: const Text('تحديث حالة الصور'),
            ),
          ],
        ),
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

class _DeleteAccountPageState extends State<DeleteAccountPage>
    with AccountBoundState<DeleteAccountPage> {
  @override
  BirdsRepository get accountRepository => widget.repository;
  @override
  void clearAccountData() {
    confirmation.clear();
    notice = null;
  }

  final confirmation = TextEditingController();
  bool busy = false,
      confirming = false,
      requiresOperator = false,
      deletionCompleted = false;
  String? error, notice;
  DateTime? retryAt;
  @override
  void dispose() {
    confirmation.dispose();
    super.dispose();
  }

  Future<void> remove() async {
    if (!isAccountCurrent) return;
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
      builder: (c) => protectAccountDialog(
        AlertDialog(
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
      ),
    );
    if (!mounted || !isAccountCurrent) return;
    setState(() => confirming = false);
    if (consent != true) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    final result = await guardResult(
      () => widget.repository.deleteOwnAccount(),
    );
    if (!mounted) return;
    if (result.value?.completed == true &&
        (widget.repository.currentUserId == null || isAccountCurrent)) {
      setState(() {
        deletionCompleted = true;
        busy = false;
        notice = result.value!.sessionCleanupRequired
            ? 'أكد الخادم حذف الحساب، لكن تعذر إنهاء الجلسة المحلية. سجّل الخروج من زر الحساب.'
            : 'أكد الخادم حذف الحساب.';
      });
      return;
    }
    if (!isAccountCurrent) return;
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
  Widget build(BuildContext context) => deletionCompleted
      ? Scaffold(
          appBar: AppBar(title: const Text('حذف الحساب')),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(notice ?? 'أكد الخادم حذف الحساب.'),
          ),
        )
      : protectAccount(
          PopScope(
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
                    decoration: const InputDecoration(
                      labelText: 'اكتب: حذف حسابي',
                    ),
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
                  if (error != null)
                    Semantics(liveRegion: true, child: Text(error!)),
                  if (notice != null)
                    Semantics(liveRegion: true, child: Text(notice!)),
                ],
              ),
            ),
          ),
        );
}
