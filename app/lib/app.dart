import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'domain.dart';

class BirdsApp extends StatelessWidget {
  const BirdsApp({
    super.key,
    required this.repository,
    this.startupFailure,
    this.errorSignal,
  });
  final BirdsRepository repository;
  final String? startupFailure;
  final ValueListenable<String?>? errorSignal;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'طيور السودان',
    builder: (context, child) => errorSignal == null
        ? child!
        : ValueListenableBuilder<String?>(
            valueListenable: errorSignal!,
            builder: (context, message, _) => Column(
              children: [
                if (message != null)
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          message,
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    ),
                  ),
                Expanded(child: child!),
              ],
            ),
          ),
    debugShowCheckedModeBanner: false,
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xff215b42),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 18),
        bodyLarge: TextStyle(fontSize: 20),
      ),
    ),
    home: HomePage(repository: repository, startupFailure: startupFailure),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repository, this.startupFailure});
  final BirdsRepository repository;
  final String? startupFailure;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;
  int generation = 0;
  bool loading = true;
  bool loadingMore = false, hasMore = false;
  StreamSubscription<void>? authSubscription;
  String? error;
  List<FeedEntry> entries = [];
  final search = TextEditingController();
  final location = TextEditingController();
  String category = '';
  FeedKind get kind => FeedKind.values[index];
  @override
  void initState() {
    super.initState();
    authSubscription = widget.repository.authChanges.listen((_) {
      if (mounted) refresh();
    });
    refresh();
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    search.dispose();
    location.dispose();
    super.dispose();
  }

  Future<void> refresh({bool more = false}) async {
    if (more && (loadingMore || entries.isEmpty)) return;
    final before = more ? entries.last : null;
    final request = ++generation;
    setState(() {
      loading = !more;
      loadingMore = more;
      error = null;
    });
    final result = await widget.repository.feed(
      kind,
      FeedFilter(
        search: search.text.trim(),
        location: location.text.trim(),
        category: category,
        before: before,
      ),
    );
    if (!mounted || request != generation) return;
    setState(() {
      loading = false;
      loadingMore = false;
      error = result.failure?.message;
      hasMore = (result.value?.length ?? 0) == 20;
      entries = more ? [...entries, ...?result.value] : result.value ?? [];
    });
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> account() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'الحساب',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                if (widget.repository.isPreview)
                  const Text(
                    'معاينة محلية فقط. لا توجد جلسة أو بيانات محفوظة على خادم.',
                  ),
                if (!widget.repository.signedIn) ...[
                  const Text(
                    'التصفح متاح للجميع. النشر والرد والإبلاغ يتطلب تسجيل الدخول.',
                  ),
                  for (final provider in ['google', 'apple'])
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: OutlinedButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          final result = await widget.repository.signIn(
                            provider,
                          );
                          message(
                            result.failure?.message ??
                                'أكمل تسجيل الدخول في المتصفح، ثم ارجع للتطبيق.',
                          );
                        },
                        child: Text(
                          provider == 'google'
                              ? 'الدخول باستخدام Google'
                              : 'الدخول باستخدام Apple',
                        ),
                      ),
                    ),
                ] else
                  FilledButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      final result = await widget.repository.signOut();
                      if (mounted) setState(() {});
                      message(result.failure?.message ?? 'تم تسجيل الخروج');
                    },
                    child: const Text('تسجيل الخروج'),
                  ),
                if (widget.repository.signedIn)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(this.context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              BlockedUsersPage(repository: widget.repository),
                        ),
                      );
                    },
                    child: const Text('الحسابات المحظورة وإلغاء الحظر'),
                  ),
                const SizedBox(height: 16),
                const Text(
                  'نسخة تأسيسية غير جاهزة للنشر العام. إعداد حذف الحساب وسياسة الخصوصية ووسائل التواصل قيد الإكمال.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> publish() async {
    if (!widget.repository.signedIn) {
      await account();
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            PublicationPage(repository: widget.repository, kind: kind),
      ),
    );
    if (saved == true && mounted) await refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('طيور السودان'),
      actions: [
        IconButton(
          onPressed: account,
          icon: const Icon(Icons.account_circle_outlined),
          tooltip: 'الحساب والإعدادات',
        ),
      ],
    ),
    body: Column(
      children: [
        if (widget.repository.isPreview || widget.startupFailure != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.all(12),
            child: Text(
              widget.startupFailure ??
                  'معاينة محلية • غير متصل بالخادم • لا بيانات تجريبية وهمية',
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: search,
                textInputAction: TextInputAction.search,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: 'البحث في العنوان والوصف',
                  prefixIcon: Icon(Icons.search),
                  counterText: '',
                ),
                onSubmitted: (_) => refresh(),
              ),
              const SizedBox(height: 8),
              if (kind != FeedKind.education)
                TextField(
                  controller: location,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'تصفية حسب الولاية',
                    counterText: '',
                  ),
                  onSubmitted: (_) => refresh(),
                ),
              if (kind == FeedKind.education)
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'نوع المحتوى'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('الكل')),
                    DropdownMenuItem(
                      value: 'information',
                      child: Text('معلومة للمربي'),
                    ),
                    DropdownMenuItem(
                      value: 'consultation',
                      child: Text('استشارة'),
                    ),
                  ],
                  onChanged: (value) {
                    category = value ?? '';
                    refresh();
                  },
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: refresh,
                  icon: const Icon(Icons.filter_alt_outlined),
                  label: const Text('تطبيق البحث والفلاتر'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'جارٍ تحميل المحتوى',
                  ),
                )
              : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(error!),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: refresh,
                          child: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ),
                  ),
                )
              : entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.repository.isPreview
                          ? 'لا يوجد محتوى في المعاينة المحلية. اربط خدمة Supabase لعرض المحتوى الحقيقي.'
                          : 'لا توجد نتائج. جرّب تغيير البحث أو الفلاتر.',
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    itemCount: entries.length + 1,
                    itemBuilder: (context, i) {
                      if (i == entries.length) {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: hasMore
                              ? TextButton(
                                  onPressed: loadingMore
                                      ? null
                                      : () => refresh(more: true),
                                  child: Text(
                                    loadingMore
                                        ? 'جارٍ التحميل…'
                                        : 'تحميل المزيد',
                                  ),
                                )
                              : const Text('وصلت إلى نهاية النتائج.'),
                        );
                      }
                      final item = entries[i];
                      return Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          title: Text(item.title),
                          subtitle: Text(
                            '${item.kind == FeedKind.education ? '${item.author} • ${item.category == 'consultation' ? 'استشارة' : 'معلومة للمربي'} • ${arabicDate(item.createdAt)}\n${item.replyCount} ردود\n' : ''}${item.body}\n${item.location}${item.price == null ? '' : '\n${item.kind == FeedKind.request ? 'الميزانية' : 'السعر'}: ${item.price} ${item.currency}${item.kind == FeedKind.offer ? (item.priceUnit == 'group' ? ' للمجموعة' : ' للطائر') : ''}'}\n${item.status}',
                          ),
                          isThreeLine: true,
                          onTap: () async {
                            await Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => DetailPage(
                                  repository: widget.repository,
                                  entry: item,
                                ),
                              ),
                            );
                            if (mounted) await refresh();
                          },
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: publish,
      icon: const Icon(Icons.add),
      label: Text(
        kind == FeedKind.education
            ? 'إضافة منشور'
            : kind == FeedKind.offer
            ? 'إضافة عرض'
            : 'إضافة طلب',
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) {
        setState(() {
          index = value;
          category = '';
          search.clear();
          location.clear();
        });
        refresh();
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.search), label: 'طلبات'),
        NavigationDestination(icon: Icon(Icons.storefront), label: 'معروضات'),
        NavigationDestination(
          icon: Icon(Icons.menu_book),
          label: 'محتوى تعليمي',
        ),
      ],
    ),
  );
}

class PublicationPage extends StatefulWidget {
  const PublicationPage({
    super.key,
    required this.repository,
    required this.kind,
  });
  final BirdsRepository repository;
  final FeedKind kind;
  @override
  State<PublicationPage> createState() => _PublicationPageState();
}

class _PublicationPageState extends State<PublicationPage> {
  final form = GlobalKey<FormState>();
  final fields = {
    for (final key in [
      'displayName',
      'title',
      'body',
      'bird',
      'state',
      'city',
      'quantity',
      'amount',
      'age',
    ])
      key: TextEditingController(),
  };
  bool busy = false, accepted = false, negotiable = false;
  String category = 'information',
      currency = 'SDG',
      unit = 'each',
      ageUnit = 'months';
  String? error;
  bool get educational => widget.kind == FeedKind.education;
  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget input(
    String key,
    String label, {
    bool required = true,
    bool number = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: fields[key],
      maxLines: lines,
      maxLength: key == 'body'
          ? 5000
          : key == 'displayName'
          ? 80
          : 120,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      validator: key == 'amount'
          ? (value) =>
                validateAmount(value, required: widget.kind == FeedKind.offer)
          : number
          ? (value) {
              if (!required && (value ?? '').isEmpty) return null;
              final n = int.tryParse(normalizeDigits(value ?? ''));
              return n == null || n < 1 || n > 100000
                  ? 'أدخل عدداً صحيحاً من ١ إلى ١٠٠٠٠٠'
                  : null;
            }
          : key == 'title' || key == 'displayName'
          ? (value) => (value ?? '').trim().length < (key == 'title' ? 3 : 2)
                ? 'أدخل نصاً أطول'
                : null
          : required
          ? requiredText
          : null,
    ),
  );
  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    if (!accepted) {
      setState(() => error = 'وافق على قواعد المحتوى قبل النشر.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.repository.publish(
      Publication(
        displayName: fields['displayName']!.text.trim(),
        kind: widget.kind,
        title: fields['title']!.text.trim(),
        body: fields['body']!.text.trim(),
        birdType: fields['bird']!.text.trim(),
        state: fields['state']!.text.trim(),
        city: fields['city']!.text.trim(),
        quantity: int.tryParse(normalizeDigits(fields['quantity']!.text)) ?? 1,
        category: category,
        amount: parseAmount(fields['amount']!.text),
        currency: currency,
        age: int.tryParse(normalizeDigits(fields['age']!.text)),
        ageUnit: ageUnit,
        priceUnit: unit,
        negotiable: negotiable,
      ),
    );
    if (!mounted) return;
    if (result.isSuccess) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        busy = false;
        error = result.failure!.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('إضافة • ${widget.kind.label}')),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          input('displayName', 'اسم العرض العام (لإنشاء الملف الشخصي)'),
          input('title', 'العنوان'),
          input(
            'body',
            educational ? 'نص المنشور' : 'المواصفات والوصف',
            lines: 4,
          ),
          input('bird', 'نوع الطيور', required: !educational),
          if (educational)
            DropdownButtonFormField<String>(
              initialValue: category,
              decoration: const InputDecoration(labelText: 'نوع المنشور'),
              items: const [
                DropdownMenuItem(
                  value: 'information',
                  child: Text('معلومة للمربي'),
                ),
                DropdownMenuItem(value: 'consultation', child: Text('استشارة')),
              ],
              onChanged: (value) => category = value!,
            ),
          if (!educational) ...[
            input('state', 'الولاية'),
            input('city', 'المدينة'),
            input('quantity', 'عدد الطيور', number: true),
            input(
              'amount',
              widget.kind == FeedKind.offer
                  ? 'السعر الرقمي (مطلوب)'
                  : 'الميزانية (اختيارية)',
              number: true,
              required: widget.kind == FeedKind.offer,
            ),
            DropdownButtonFormField<String>(
              initialValue: currency,
              decoration: const InputDecoration(labelText: 'العملة'),
              items: [
                for (final c in ['SDG', 'USD', 'SAR'])
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (value) => currency = value!,
            ),
            if (widget.kind == FeedKind.offer) ...[
              const SizedBox(height: 16),
              input('age', 'عمر الطيور', number: true),
              DropdownButtonFormField<String>(
                initialValue: ageUnit,
                decoration: const InputDecoration(labelText: 'وحدة العمر'),
                items: const [
                  DropdownMenuItem(value: 'days', child: Text('أيام')),
                  DropdownMenuItem(value: 'months', child: Text('أشهر')),
                  DropdownMenuItem(value: 'years', child: Text('سنوات')),
                ],
                onChanged: (value) => ageUnit = value!,
              ),
              DropdownButtonFormField<String>(
                initialValue: unit,
                decoration: const InputDecoration(labelText: 'السعر مقابل'),
                items: const [
                  DropdownMenuItem(value: 'each', child: Text('الطائر الواحد')),
                  DropdownMenuItem(value: 'group', child: Text('المجموعة')),
                ],
                onChanged: (value) => unit = value!,
              ),
              CheckboxListTile(
                value: negotiable,
                onChanged: (value) => setState(() => negotiable = value!),
                title: const Text('السعر قابل للتفاوض'),
              ),
            ],
          ],
          const SizedBox(height: 16),
          const Text(
            'رفع الصور ووسيلة التواصل غير متاحين بعد في هذه النسخة. لا تضع بيانات اتصال خاصة في النص العام.',
          ),
          CheckboxListTile(
            value: accepted,
            onChanged: (value) => setState(() => accepted = value!),
            title: const Text(
              'ألتزم بمحتوى قانوني يحترم الخصوصية والرفق بالحيوان، ولا أنشر معلومات مضللة. هذه قواعد تجريبية وليست الشروط القانونية النهائية.',
            ),
          ),
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? 'جارٍ الحفظ…' : 'نشر'),
          ),
        ],
      ),
    ),
  );
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.repository, required this.entry});
  final BirdsRepository repository;
  final FeedEntry entry;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  final body = TextEditingController();
  List<String> replies = [];
  String? error;
  bool busy = false, loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    body.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (widget.entry.kind != FeedKind.education) {
      setState(() => loading = false);
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    final result = await widget.repository.replies(widget.entry.id);
    if (mounted) {
      setState(() {
        loading = false;
        replies = result.value ?? [];
        error = result.failure?.message;
      });
    }
  }

  Future<void> act({required bool report}) async {
    if (busy) return;
    if (!widget.repository.signedIn) {
      setState(() => error = 'سجّل الدخول من زر الحساب أولاً.');
      return;
    }
    final text = body.text.trim();
    if (text.length < (report ? 5 : 1)) {
      setState(
        () => error = report
            ? 'اكتب سبب الإبلاغ في خمسة أحرف على الأقل.'
            : 'اكتب الرد أولاً.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final result = report
        ? await widget.repository.report(widget.entry, text)
        : await widget.repository.reply(widget.entry.id, text);
    if (!mounted) return;
    setState(() {
      busy = false;
      error = result.failure?.message;
    });
    if (result.isSuccess) {
      body.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(report ? 'تم إرسال البلاغ للمراجعة' : 'تم نشر الرد'),
        ),
      );
      if (!report) await load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.entry.title)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (widget.repository.signedIn &&
            widget.entry.ownerId == widget.repository.currentUserId)
          OutlinedButton.icon(
            onPressed: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => EditEntryPage(
                    repository: widget.repository,
                    entry: widget.entry,
                  ),
                ),
              );
              if (saved == true && context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.edit_outlined),
            label: const Text('تعديل المحتوى أو إغلاق الإعلان'),
          ),
        if (widget.entry.ownerId.isNotEmpty &&
            widget.entry.ownerId != widget.repository.currentUserId)
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () async {
                    if (!widget.repository.signedIn) {
                      setState(() => error = 'سجّل الدخول من زر الحساب أولاً.');
                      return;
                    }
                    setState(() => busy = true);
                    final result = await widget.repository.block(
                      widget.entry.ownerId,
                      true,
                    );
                    if (!context.mounted) return;
                    if (result.isSuccess) {
                      Navigator.pop(context);
                    } else {
                      setState(() {
                        busy = false;
                        error = result.failure!.message;
                      });
                    }
                  },
            icon: const Icon(Icons.block),
            label: const Text('حظر صاحب المحتوى'),
          ),
        SelectableText(widget.entry.body),
        const SizedBox(height: 16),
        Text(widget.entry.location),
        if (widget.entry.price != null)
          Text(
            '${widget.entry.price} ${widget.entry.currency}${widget.entry.kind == FeedKind.offer ? (widget.entry.priceUnit == 'group' ? ' للمجموعة' : ' للطائر') : ' ميزانية'}',
          ),
        if (widget.entry.kind == FeedKind.education) ...[
          const Text('الردود', style: TextStyle(fontSize: 24)),
          if (loading)
            const LinearProgressIndicator(semanticsLabel: 'تحميل الردود'),
          for (final reply in replies)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(reply),
              ),
            ),
          if (!loading && replies.isEmpty) const Text('لا توجد ردود حتى الآن.'),
        ],
        TextField(
          controller: body,
          maxLines: 3,
          maxLength: 1000,
          decoration: const InputDecoration(
            labelText: 'نص الرد أو سبب الإبلاغ',
          ),
        ),
        if (error != null) ...[
          Semantics(liveRegion: true, child: Text(error!)),
          TextButton(onPressed: load, child: const Text('إعادة تحميل الردود')),
        ],
        if (widget.entry.kind == FeedKind.education)
          FilledButton(
            onPressed: busy ? null : () => act(report: false),
            child: const Text('إرسال الرد'),
          ),
        OutlinedButton.icon(
          onPressed: busy ? null : () => act(report: true),
          icon: const Icon(Icons.flag_outlined),
          label: const Text('إبلاغ عن المحتوى'),
        ),
      ],
    ),
  );
}

class EditEntryPage extends StatefulWidget {
  const EditEntryPage({
    super.key,
    required this.repository,
    required this.entry,
  });
  final BirdsRepository repository;
  final FeedEntry entry;
  @override
  State<EditEntryPage> createState() => _EditEntryPageState();
}

class _EditEntryPageState extends State<EditEntryPage> {
  final form = GlobalKey<FormState>();
  late final TextEditingController title = TextEditingController(
    text: widget.entry.title,
  );
  late final TextEditingController body = TextEditingController(
    text: widget.entry.body,
  );
  late String status = widget.entry.statusCode;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate() || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.repository.updateEntry(
      widget.entry,
      title.text.trim(),
      body.text.trim(),
      status,
    );
    if (!mounted) return;
    if (result.isSuccess) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        busy = false;
        error = result.failure!.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('تعديل المحتوى')),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextFormField(
            controller: title,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'العنوان'),
            validator: (value) => (value ?? '').trim().length < 3
                ? 'العنوان ثلاثة أحرف على الأقل'
                : null,
          ),
          TextFormField(
            controller: body,
            maxLength: 5000,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'النص والوصف'),
            validator: requiredText,
          ),
          if (widget.entry.kind != FeedKind.education)
            DropdownButtonFormField<String>(
              initialValue: status,
              decoration: const InputDecoration(labelText: 'حالة الإعلان'),
              items: [
                DropdownMenuItem(
                  value: 'active',
                  child: Text(
                    widget.entry.kind == FeedKind.offer ? 'متاح' : 'مفتوح',
                  ),
                ),
                if (widget.entry.kind == FeedKind.offer)
                  const DropdownMenuItem(
                    value: 'reserved',
                    child: Text('محجوز'),
                  ),
                DropdownMenuItem(
                  value: 'fulfilled',
                  child: Text(
                    widget.entry.kind == FeedKind.offer
                        ? 'تم البيع'
                        : 'تم العثور على المطلوب',
                  ),
                ),
                const DropdownMenuItem(value: 'closed', child: Text('مغلق')),
                const DropdownMenuItem(value: 'expired', child: Text('منتهي')),
              ],
              onChanged: (value) => status = value!,
            ),
          const Text(
            'هذه الشاشة تعدّل العنوان والوصف والحالة فقط. بقية بيانات الإعلان لم تُتح للتعديل بعد.',
          ),
          if (error != null) Text(error!),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? 'جارٍ الحفظ…' : 'حفظ التعديل'),
          ),
        ],
      ),
    ),
  );
}

class BlockedUsersPage extends StatefulWidget {
  const BlockedUsersPage({super.key, required this.repository});
  final BirdsRepository repository;
  @override
  State<BlockedUsersPage> createState() => _BlockedUsersPageState();
}

class _BlockedUsersPageState extends State<BlockedUsersPage> {
  List<String> users = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final result = await widget.repository.blockedUsers();
    if (mounted) {
      setState(() {
        loading = false;
        error = result.failure?.message;
        users = result.value ?? [];
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الحسابات المحظورة')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'لا تكشف الخدمة ملفات الحسابات المحظورة. يُعرض معرّف الحساب بدلاً من الاسم.',
              ),
              if (error != null) ...[
                Text(error!),
                TextButton(
                  onPressed: load,
                  child: const Text('إعادة المحاولة'),
                ),
              ],
              if (users.isEmpty && error == null)
                const Text('لا توجد حسابات محظورة.'),
              for (final id in users)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Text(id),
                        TextButton(
                          onPressed: () async {
                            setState(() => loading = true);
                            final result = await widget.repository.block(
                              id,
                              false,
                            );
                            if (!mounted) return;
                            if (result.isSuccess) {
                              await load();
                            } else {
                              setState(() {
                                loading = false;
                                error = result.failure!.message;
                              });
                            }
                          },
                          child: const Text('إلغاء الحظر'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}
