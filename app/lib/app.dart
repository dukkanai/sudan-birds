import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'domain.dart';
import 'screens.dart';
import 'moderation_screens.dart';
export 'screens.dart' show PublicationPage, DetailPage;

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
  FeedFilter filters = const FeedFilter();
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
      filters.withCursor(before, query: search.text.trim()),
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
                if (widget.repository.signedIn)
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(this.context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              ProfilePage(repository: widget.repository),
                        ),
                      );
                    },
                    child: const Text('الملف الشخصي وإعدادات التواصل'),
                  ),
                if (widget.repository.signedIn) ...[
                  DeletionStatusPanel(repository: widget.repository),
                  ModeratorAccessTile(repository: widget.repository),
                ],
                const DraftLegalLinks(),
                const SizedBox(height: 16),
                const Text(
                  'نسخة تأسيسية غير جاهزة للنشر العام. سياسة الخصوصية القانونية واختبارات التشغيل الفعلي قيد الإكمال.',
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
    final saved = await Navigator.of(context).push<FeedEntry>(
      MaterialPageRoute(
        builder: (_) =>
            PublicationPage(repository: widget.repository, kind: kind),
      ),
    );
    if (saved != null && mounted) {
      await refresh();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              DetailPage(repository: widget.repository, entry: saved),
        ),
      );
    }
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
    body: RefreshIndicator(
      onRefresh: refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                if (widget.repository.isPreview ||
                    widget.startupFailure != null)
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
                      OutlinedButton.icon(
                        onPressed: () async {
                          final selected = await Navigator.of(context)
                              .push<FeedFilter>(
                                MaterialPageRoute(
                                  builder: (_) => FilterPage(
                                    repository: widget.repository,
                                    kind: kind,
                                    initial: filters,
                                  ),
                                ),
                              );
                          if (selected != null && mounted) {
                            filters = selected;
                            await refresh();
                          }
                        },
                        icon: const Icon(Icons.tune),
                        label: const Text('نوع الطيور والموقع وبقية الفلاتر'),
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
              ],
            ),
          ),
          if (loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'جارٍ تحميل المحتوى',
                ),
              ),
            )
          else if (error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
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
          else if (entries.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    widget.repository.isPreview
                        ? 'لا يوجد محتوى في المعاينة المحلية. اربط خدمة Supabase لعرض المحتوى الحقيقي.'
                        : 'لا توجد نتائج. جرّب تغيير البحث أو الفلاتر.',
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.builder(
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
                                loadingMore ? 'جارٍ التحميل…' : 'تحميل المزيد',
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
                        '${item.body}\n${item.location}${item.price == null ? '' : '\n${item.kind == FeedKind.request ? 'الميزانية' : 'السعر'}: ${item.price} ${item.currency}${item.kind == FeedKind.offer ? (item.priceUnit == 'group' ? ' للمجموعة' : ' للطائر') : ''}'}\n${item.status}',
                      ),
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
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: publish,
      icon: const Icon(Icons.add),
      label: Text(kind == FeedKind.offer ? 'إضافة عرض' : 'إضافة طلب'),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) {
        setState(() {
          index = value;
          filters = const FeedFilter();
          search.clear();
          location.clear();
        });
        refresh();
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.search), label: 'طلبات'),
        NavigationDestination(icon: Icon(Icons.storefront), label: 'معروضات'),
      ],
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
