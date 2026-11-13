import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'domain.dart';
import 'account_session.dart';
import 'password_sign_in.dart';
import 'screens.dart';
import 'moderation_screens.dart';
export 'screens.dart' show PublicationPage, DetailPage;

class BirdsApp extends StatelessWidget {
  const BirdsApp({
    super.key,
    required this.repository,
    this.startupFailure,
    this.startupNotice,
    this.errorSignal,
  });
  final BirdsRepository repository;
  final String? startupFailure;
  final Future<String?>? startupNotice;
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
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * .3,
                      ),
                      child: SingleChildScrollView(
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                message,
                                style: const TextStyle(fontSize: 18),
                              ),
                            ),
                          ),
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
    home: HomePage(
      repository: repository,
      startupFailure: startupFailure,
      startupNotice: startupNotice,
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repository,
    this.startupFailure,
    this.startupNotice,
  });
  final BirdsRepository repository;
  final String? startupFailure;
  final Future<String?>? startupNotice;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;
  int generation = 0;
  bool loading = true;
  bool accountOpen = false, authBusy = false, publicationOpen = false;
  bool loadingMore = false, hasMore = false;
  StreamSubscription<void>? authSubscription;
  String? error, moreError;
  FeedEntry? cursor;
  String? entriesUserId;
  bool entriesSignedIn = false;
  FeedFilter appliedFilter = const FeedFilter();
  List<FeedEntry> entries = [];
  final search = TextEditingController();
  final location = TextEditingController();
  FeedFilter filters = const FeedFilter();
  FeedKind get kind => FeedKind.values[index];
  @override
  void initState() {
    super.initState();
    authSubscription = widget.repository.authChanges.listen(
      (_) {
        if (mounted) refresh();
      },
      onError: (Object _, StackTrace _) {
        if (mounted) invalidateFeed();
      },
    );
    refresh();
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    search.dispose();
    location.dispose();
    super.dispose();
  }

  void invalidateFeed() {
    // A failed session observation invalidates both visible data and requests
    // already in flight. A late success must not erase this failure.
    setState(() {
      generation++;
      loading = false;
      loadingMore = false;
      hasMore = false;
      entries = [];
      cursor = null;
      entriesUserId = null;
      entriesSignedIn = false;
      moreError = null;
      error = 'تعذر التحقق من جلسة الحساب. أُخفي المحتوى؛ أعد المحاولة.';
    });
  }

  Future<void> refresh({bool more = false}) async {
    if (!mounted) return;
    if (more && (loading || loadingMore || !hasMore || cursor == null)) return;
    final before = more ? cursor : null;
    final request = ++generation;
    final requestUserId = widget.repository.currentUserId;
    final requestSignedIn = widget.repository.signedIn;
    if (!more) {
      appliedFilter = filters.withCursor(null, query: search.text.trim());
    }
    setState(() {
      loading = !more;
      loadingMore = more;
      error = null;
      moreError = null;
    });
    final result = await guardResult(
      () => widget.repository.feed(kind, appliedFilter.withCursor(before)),
    );
    if (!mounted || request != generation) return;
    if (requestUserId != widget.repository.currentUserId ||
        requestSignedIn != widget.repository.signedIn) {
      invalidateFeed();
      return;
    }
    setState(() {
      loading = false;
      loadingMore = false;
      if (!result.isSuccess) {
        if (more) {
          moreError = result.failure!.message;
        } else {
          error = result.failure!.message;
          entries = [];
          cursor = null;
          hasMore = false;
        }
        return;
      }
      entriesUserId = requestUserId;
      entriesSignedIn = requestSignedIn;
      final page = result.value ?? [];
      final seen = more ? entries.map((item) => item.id).toSet() : <String>{};
      final additions = page.where((item) => seen.add(item.id)).toList();
      entries = more ? [...entries, ...additions] : additions;
      cursor = page.isEmpty ? before : page.last;
      hasMore = page.length == 20 && (!more || cursor?.id != before?.id);
    });
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> account() async {
    if (!mounted || accountOpen || authBusy) return;
    accountOpen = true;
    final originalUser = widget.repository.currentUserId;
    final originalSignedIn = widget.repository.signedIn;
    bool invalidated = false;
    bool sameAccount() =>
        !invalidated &&
        mounted &&
        widget.repository.currentUserId == originalUser &&
        widget.repository.signedIn == originalSignedIn;
    BuildContext? sheetContext;
    void closeSheet() {
      final sheet = sheetContext;
      if (sheet != null &&
          sheet.mounted &&
          ModalRoute.of(sheet)?.isCurrent == true) {
        Navigator.of(sheet).pop();
      }
    }

    final sessionChanges = widget.repository.authChanges.listen(
      (_) {
        if (!sameAccount()) {
          invalidated = true;
          closeSheet();
        }
      },
      onError: (Object _, StackTrace _) {
        invalidated = true;
        closeSheet();
      },
    );
    final opened = await protect(
      () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => StreamBuilder<void>(
          stream: widget.repository.authChanges,
          builder: (context, snapshot) {
            sheetContext = context;
            if (!sameAccount() || snapshot.hasError) {
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'تغيرت جلسة الحساب. أغلق هذه القائمة وافتحها مجدداً.',
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('إغلاق'),
                      ),
                    ],
                  ),
                ),
              );
            }
            return SafeArea(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'الحساب',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (widget.repository.isPreview)
                        const Text(
                          'معاينة محلية فقط. لا توجد جلسة أو بيانات محفوظة على خادم.',
                        ),
                      if (!widget.repository.signedIn &&
                          !widget.repository.sessionCleanupRequired) ...[
                        const Text(
                          'التصفح متاح للجميع. النشر والإبلاغ يتطلب تسجيل الدخول.',
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: OutlinedButton(
                            onPressed: () async {
                              if (authBusy ||
                                  !sameAccount() ||
                                  !context.mounted ||
                                  ModalRoute.of(context)?.isCurrent != true) {
                                return;
                              }
                              authBusy = true;
                              final opened = await protect(() {
                                Navigator.pop(context);
                                return Navigator.of(this.context).push<bool>(
                                  MaterialPageRoute(
                                    builder: (_) => PasswordSignInPage(
                                      repository: widget.repository,
                                    ),
                                  ),
                                );
                              }, timeout: null);
                              authBusy = false;
                              if (mounted) setState(() {});
                              if (opened.failure != null) {
                                message(opened.failure!.message);
                              }
                            },
                            child: const Text('الدخول بالبريد وكلمة المرور'),
                          ),
                        ),
                      ] else
                        FilledButton(
                          onPressed: () async {
                            if (authBusy || !sameAccount()) return;
                            authBusy = true;
                            final result = await guardResult(() {
                              Navigator.pop(context);
                              return widget.repository.signOut();
                            });
                            authBusy = false;
                            if (mounted) setState(() {});
                            message(
                              result.failure?.message ?? 'تم تسجيل الخروج',
                            );
                          },
                          child: Text(
                            widget.repository.sessionCleanupRequired
                                ? 'إعادة مسح الجلسة المحلية'
                                : 'تسجيل الخروج',
                          ),
                        ),
                      if (widget.repository.signedIn)
                        TextButton(
                          onPressed: () {
                            if (!sameAccount()) return;
                            Navigator.pop(context);
                            Navigator.of(this.context).push<void>(
                              accountPageRoute(
                                repository: widget.repository,
                                builder: (_) => BlockedUsersPage(
                                  repository: widget.repository,
                                ),
                              ),
                            );
                          },
                          child: const Text('الحسابات المحظورة وإلغاء الحظر'),
                        ),
                      if (widget.repository.signedIn)
                        FilledButton(
                          onPressed: () {
                            if (!sameAccount()) return;
                            Navigator.pop(context);
                            Navigator.of(this.context).push<void>(
                              accountPageRoute(
                                repository: widget.repository,
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
            );
          },
        ),
      ),
      timeout: null,
    );
    accountOpen = false;
    if (mounted) setState(() {});
    final cleanup = await protect(sessionChanges.cancel, timeout: null);
    final failure = opened.failure ?? cleanup.failure;
    if (failure != null) message(failure.message);
  }

  Future<void> publish() async {
    if (!mounted || publicationOpen) return;
    if (!widget.repository.signedIn) {
      await account();
      return;
    }
    publicationOpen = true;
    final authorId = widget.repository.currentUserId;
    final opened = await protect(
      () => Navigator.of(context).push<FeedEntry>(
        accountPageRoute(
          repository: widget.repository,
          builder: (_) =>
              PublicationPage(repository: widget.repository, kind: kind),
        ),
      ),
      timeout: null,
    );
    publicationOpen = false;
    if (!opened.isSuccess) {
      message(opened.failure!.message);
      return;
    }
    final saved = opened.value;
    if (saved != null &&
        mounted &&
        widget.repository.signedIn &&
        widget.repository.currentUserId == authorId) {
      await refresh();
      if (!mounted ||
          !widget.repository.signedIn ||
          widget.repository.currentUserId != authorId) {
        return;
      }
      await Navigator.of(context).push<void>(
        accountPageRoute(
          repository: widget.repository,
          builder: (_) =>
              DetailPage(repository: widget.repository, entry: saved),
        ),
      );
      if (mounted) await refresh();
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
                if (widget.startupNotice != null)
                  FutureBuilder<String?>(
                    future: widget.startupNotice,
                    builder: (context, snapshot) =>
                        snapshot.data == null && !snapshot.hasError
                        ? const SizedBox.shrink()
                        : Semantics(
                            liveRegion: true,
                            child: Container(
                              width: double.infinity,
                              color: Theme.of(
                                context,
                              ).colorScheme.tertiaryContainer,
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                snapshot.hasError
                                    ? 'تعذر التحقق من استعادة اختيار الصور. لم تُرفق صورة تلقائياً؛ اخترها مجدداً من الإعلان المطلوب.'
                                    : snapshot.data!,
                              ),
                            ),
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
                                accountPageRoute(
                                  repository: widget.repository,
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
                    Semantics(liveRegion: true, child: Text(error!)),
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
                      child: Column(
                        children: [
                          if (moreError != null)
                            Semantics(
                              liveRegion: true,
                              child: Text(moreError!),
                            ),
                          if (hasMore)
                            TextButton(
                              onPressed: loadingMore
                                  ? null
                                  : () => refresh(more: true),
                              child: Text(
                                loadingMore
                                    ? 'جارٍ التحميل…'
                                    : moreError != null
                                    ? 'إعادة تحميل المزيد'
                                    : 'تحميل المزيد',
                              ),
                            )
                          else
                            const Text('وصلت إلى نهاية النتائج.'),
                        ],
                      ),
                    );
                  }
                  final item = entries[i];
                  final itemGeneration = generation;
                  final itemUserId = entriesUserId;
                  final itemSignedIn = entriesSignedIn;
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      title: Text(item.title),
                      subtitle: Text(
                        '${item.body}\n${item.location}${item.price == null ? '' : '\n${item.kind == FeedKind.request ? 'الميزانية' : 'السعر'}: ${item.price} ${item.currency}${item.kind == FeedKind.offer ? (item.priceUnit == 'group' ? ' للمجموعة' : ' للطائر') : ''}'}\n${item.status}',
                      ),
                      onTap: () async {
                        if (loading ||
                            generation != itemGeneration ||
                            widget.repository.currentUserId != itemUserId ||
                            widget.repository.signedIn != itemSignedIn) {
                          return;
                        }
                        await Navigator.of(context).push<void>(
                          accountPageRoute(
                            repository: widget.repository,
                            isAllowed: () =>
                                mounted && generation == itemGeneration,
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

class _BlockedUsersPageState extends State<BlockedUsersPage>
    with AccountBoundState<BlockedUsersPage> {
  @override
  BirdsRepository get accountRepository => widget.repository;
  @override
  void clearAccountData() {
    users = [];
  }

  List<String> users = [];
  bool loading = true, changing = false;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (!isAccountCurrent) return;
    final request = ++generation;
    setState(() => loading = true);
    final result = await guardResult(() => widget.repository.blockedUsers());
    if (mounted && isAccountCurrent && request == generation) {
      setState(() {
        loading = false;
        error = result.failure?.message;
        users = result.value ?? [];
      });
    }
  }

  @override
  Widget build(BuildContext context) => protectAccount(
    Scaffold(
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
                  Semantics(liveRegion: true, child: Text(error!)),
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
                            onPressed: changing
                                ? null
                                : () async {
                                    if (!isAccountCurrent || changing) return;
                                    setState(() {
                                      changing = true;
                                      loading = true;
                                    });
                                    final result = await guardResult(
                                      () => widget.repository.block(id, false),
                                    );
                                    if (!mounted || !isAccountCurrent) return;
                                    setState(() => changing = false);
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
    ),
  );
}
