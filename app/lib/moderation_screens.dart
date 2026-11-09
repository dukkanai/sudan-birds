import 'package:flutter/material.dart';
import 'domain.dart';
import 'media_screens.dart';

String reportKindLabel(ReportKind kind) => switch (kind) {
  ReportKind.listing => 'إعلان',
  ReportKind.account => 'حساب',
};
String reportStateLabel(String state) => switch (state) {
  'open' => 'جديد',
  'reviewing' => 'قيد المراجعة',
  'resolved' => 'تمت المعالجة',
  'dismissed' => 'مرفوض',
  _ => state,
};

class ReportPage extends StatefulWidget {
  const ReportPage({
    super.key,
    required this.repository,
    required this.kind,
    required this.targetId,
  });
  final BirdsRepository repository;
  final ReportKind kind;
  final String targetId;
  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  final reason = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> send() async {
    if (busy) return;
    if (!widget.repository.signedIn) {
      setState(() => error = 'سجّل الدخول وأكمل الملف الشخصي أولاً.');
      return;
    }
    if (reason.text.trim().length < 5) {
      setState(() => error = 'اكتب سبباً واضحاً من خمسة أحرف على الأقل.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.repository.reportTarget(
      widget.kind,
      widget.targetId,
      reason.text,
    );
    if (!mounted) return;
    if (result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أُرسل البلاغ إلى المراجعة.')),
      );
      Navigator.pop(context);
    } else {
      setState(() {
        busy = false;
        error = result.failure!.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('إبلاغ عن ${reportKindLabel(widget.kind)}')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'اشرح المشكلة دون إضافة أرقام اتصال أو معلومات خاصة غير لازمة. يطّلع على البلاغ المشرفون المخوّلون ولا يُعرض لصاحب المحتوى.',
        ),
        if (!widget.repository.signedIn)
          const Text('تسجيل الدخول مطلوب لإرسال البلاغ.'),
        TextField(
          controller: reason,
          maxLength: 2000,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'سبب الإبلاغ'),
        ),
        if (error != null) Semantics(liveRegion: true, child: Text(error!)),
        FilledButton(
          onPressed: busy ? null : send,
          child: Text(busy ? 'جارٍ إرسال البلاغ…' : 'إرسال البلاغ'),
        ),
      ],
    ),
  );
}

class ModeratorAccessTile extends StatefulWidget {
  const ModeratorAccessTile({super.key, required this.repository});
  final BirdsRepository repository;
  @override
  State<ModeratorAccessTile> createState() => _ModeratorAccessTileState();
}

class _ModeratorAccessTileState extends State<ModeratorAccessTile> {
  bool loading = true, allowed = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final result = await widget.repository.isModerator();
    if (mounted) {
      setState(() {
        loading = false;
        allowed = result.value == true;
        error = result.failure?.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const SizedBox.shrink();
    if (error != null) {
      return TextButton(
        onPressed: load,
        child: const Text('إعادة التحقق من صلاحية الإشراف'),
      );
    }
    if (!allowed) return const SizedBox.shrink();
    return OutlinedButton.icon(
      onPressed: () => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ModerationQueuePage(repository: widget.repository),
        ),
      ),
      icon: const Icon(Icons.shield_outlined),
      label: const Text('مراجعة البلاغات (للمشرفين)'),
    );
  }
}

class ModerationQueuePage extends StatefulWidget {
  const ModerationQueuePage({super.key, required this.repository});
  final BirdsRepository repository;
  @override
  State<ModerationQueuePage> createState() => _ModerationQueuePageState();
}

class _ModerationQueuePageState extends State<ModerationQueuePage> {
  final List<ModerationReport> reports = [];
  String state = 'open';
  bool loading = true, more = false;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool next = false}) async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    final result = await widget.repository.moderationReports(
      state,
      before: next && reports.isNotEmpty ? reports.last : null,
    );
    if (!mounted || generation != request) return;
    setState(() {
      loading = false;
      error = result.failure?.message;
      if (result.isSuccess) {
        if (!next) reports.clear();
        reports.addAll(result.value!);
        more = result.value!.length == 20;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('مراجعة البلاغات')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'الصلاحية تُراجع من الخادم. لا تظهر هنا وسائل التواصل الخاصة. كل إجراء إشراف يُسجل مع سببه.',
        ),
        DropdownButtonFormField<String>(
          isExpanded: true,
          itemHeight: null,
          initialValue: state,
          decoration: const InputDecoration(labelText: 'حالة البلاغات'),
          items: [
            for (final s in ['open', 'reviewing', 'resolved', 'dismissed'])
              DropdownMenuItem(value: s, child: Text(reportStateLabel(s))),
          ],
          onChanged: loading
              ? null
              : (v) {
                  state = v!;
                  load();
                },
        ),
        if (loading)
          const LinearProgressIndicator(semanticsLabel: 'تحميل البلاغات'),
        if (error != null) ...[
          Semantics(liveRegion: true, child: Text(error!)),
          TextButton(
            onPressed: () => load(),
            child: const Text('إعادة تحميل البلاغات'),
          ),
        ],
        if (!loading && error == null && reports.isEmpty)
          const Text('لا توجد بلاغات بهذه الحالة.'),
        for (final report in reports)
          Card(
            child: ListTile(
              title: Text(
                '${reportKindLabel(report.kind)} • ${reportStateLabel(report.state)}',
              ),
              subtitle: Text(
                '${report.reason}\n${arabicDate(report.createdAt)}',
              ),
              onTap: () async {
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ReviewReportPage(
                      repository: widget.repository,
                      report: report,
                    ),
                  ),
                );
                if (mounted) await load();
              },
            ),
          ),
        if (more)
          TextButton(
            onPressed: loading ? null : () => load(next: true),
            child: const Text('تحميل بلاغات إضافية'),
          ),
      ],
    ),
  );
}

class ReviewReportPage extends StatefulWidget {
  const ReviewReportPage({
    super.key,
    required this.repository,
    required this.report,
  });
  final BirdsRepository repository;
  final ModerationReport report;
  @override
  State<ReviewReportPage> createState() => _ReviewReportPageState();
}

class _ReviewReportPageState extends State<ReviewReportPage> {
  final reason = TextEditingController();
  ModerationTarget? target;
  bool loading = true, busy = false, confirming = false;
  String? error, notice;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final result = await widget.repository.moderationTarget(widget.report);
    if (mounted) {
      setState(() {
        loading = false;
        target = result.value;
        error = result.failure?.message;
      });
    }
  }

  Future<void> act({bool? hidden, String? state}) async {
    if (busy || confirming) return;
    if (reason.text.trim().length < 5) {
      setState(() => error = 'اكتب سبب الإجراء في خمسة أحرف على الأقل.');
      return;
    }
    final action = hidden != null
        ? (hidden ? 'إخفاء المحتوى' : 'إعادة إظهار المحتوى')
        : 'تغيير حالة البلاغ إلى ${reportStateLabel(state!)}';
    setState(() => confirming = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: Text(action),
        content: Text('سيُسجل هذا الإجراء وسببه: ${reason.text.trim()}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('تأكيد الإجراء'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => confirming = false);
    if (confirmed != true) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    final result = hidden != null
        ? await widget.repository.moderate(widget.report, hidden, reason.text)
        : await widget.repository.resolveReport(
            widget.report.id,
            state!,
            reason.text,
          );
    if (!mounted) return;
    setState(() {
      busy = false;
      error = result.failure?.message;
      if (result.isSuccess) notice = 'أكد الخادم تنفيذ الإجراء وتسجيله.';
    });
    if (result.isSuccess && hidden != null) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('مراجعة بلاغ')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('سبب البلاغ: ${widget.report.reason}'),
        if (loading)
          const LinearProgressIndicator()
        else if (target == null && error == null)
          const Text(
            'الهدف لم يعد موجوداً أو غير متاح للمراجعة. لا نعرض محتوى محذوفاً تخمينياً.',
          )
        else if (target != null) ...[
          Text(target!.title, style: const TextStyle(fontSize: 22)),
          SelectableText(target!.body),
          Text(target!.hidden ? 'المحتوى مخفي' : 'المحتوى ظاهر'),
        ],
        TextField(
          controller: reason,
          maxLength: 2000,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'سبب إجراء الإشراف'),
        ),
        if (target != null && widget.report.kind != ReportKind.account)
          OutlinedButton(
            onPressed: busy || confirming
                ? null
                : () => act(hidden: !target!.hidden),
            child: Text(
              target!.hidden ? 'إعادة إظهار المحتوى' : 'إخفاء المحتوى',
            ),
          ),
        if (widget.report.kind == ReportKind.account)
          const Text(
            'لا تمنح هذه الشاشة صلاحية تعليق الحسابات أو تغيير أدوارها. يمكن مراجعة البلاغ وتوثيق نتيجته.',
          ),
        for (final s in ['reviewing', 'resolved', 'dismissed'])
          TextButton(
            onPressed: busy || confirming ? null : () => act(state: s),
            child: Text('تعيين الحالة: ${reportStateLabel(s)}'),
          ),
        if (error != null) ...[
          Semantics(liveRegion: true, child: Text(error!)),
          TextButton(
            onPressed: busy || confirming ? null : load,
            child: const Text('إعادة تحميل الهدف'),
          ),
        ],
        if (notice != null) Semantics(liveRegion: true, child: Text(notice!)),
      ],
    ),
  );
}

class DeletionStatusPanel extends StatefulWidget {
  const DeletionStatusPanel({super.key, required this.repository});
  final BirdsRepository repository;
  @override
  State<DeletionStatusPanel> createState() => _DeletionStatusPanelState();
}

class _DeletionStatusPanelState extends State<DeletionStatusPanel> {
  DeletionStatus? status;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final result = await widget.repository.deletionStatus();
    if (mounted) {
      setState(() {
        status = result.value;
        error = result.failure?.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return TextButton(
        onPressed: load,
        child: const Text('تعذر التحقق من حالة حذف الحساب؛ إعادة المحاولة'),
      );
    }
    if (status == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              status!.completed
                  ? 'أكد الخادم اكتمال حذف الحساب.'
                  : status!.requiresOperator
                  ? 'حذف الحساب يحتاج إلى تدخل مسؤول الخدمة لمعالجة إعداد أو عائق أمني. لم يكتمل الحذف؛ تواصل مع مسؤول نسخة التجربة قبل إعادة المحاولة. لا توجد إعادة محاولات تلقائية.'
                  : 'حذف الحساب قيد التنفيذ. قد تتوقف الكتابة لحماية بياناتك، وقد تنتظر العملية انتهاء روابط الرفع قبل إزالة الصور والحساب. لم نؤكد اكتمال الحذف بعد.',
            ),
            if (!status!.completed)
              TextButton(
                onPressed: () async {
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          DeleteAccountPage(repository: widget.repository),
                    ),
                  );
                  if (mounted) await load();
                },
                child: const Text('متابعة طلب حذف الحساب'),
              ),
            TextButton(onPressed: load, child: const Text('تحديث حالة الحذف')),
          ],
        ),
      ),
    );
  }
}

class DraftLegalLinks extends StatelessWidget {
  const DraftLegalLinks({super.key});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => const DraftLegalPage(privacy: false),
          ),
        ),
        child: const Text('مسودة شروط الاستخدام • غير نهائية'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => const DraftLegalPage(privacy: true),
          ),
        ),
        child: const Text('مسودة سياسة الخصوصية • غير نهائية'),
      ),
    ],
  );
}

class DraftLegalPage extends StatelessWidget {
  const DraftLegalPage({super.key, required this.privacy});
  final bool privacy;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(privacy ? 'مسودة سياسة الخصوصية' : 'مسودة شروط الاستخدام'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'مسودة للاختبار فقط • غير نهائية وغير معتمدة للنشر العام',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
        ),
        const SizedBox(height: 16),
        Text(
          privacy
              ? 'تستخدم النسخة Supabase لتسجيل الدخول والبيانات، وCloudflare R2 للصور. اسم العرض والمحتوى الذي تنشره يظهران للمستخدمين وفق صلاحيات الخدمة. وسيلة التواصل منفصلة عن الملف العام ولا تُكشف إلا بموافقتك ولمستخدم يطلبها عبر إعلان مؤهل.\n\nتعالج الصور محلياً ثم يعيد الخادم التحقق منها، وتُزال البيانات الوصفية قبل اعتمادها. البلاغات وقرارات الإشراف متاحة للمخوّلين فقط. يمكن طلب حذف الحساب من الإعدادات، وقد يبقى الطلب معلّقاً أثناء تسوية الصور وروابط الرفع.\n\nقد تبقى بعد حذف الحساب معرّفات وسجلات محدودة للإشراف وإثبات الحذف ومنع إعادة الرفع. لم تُعتمد مدد الاحتفاظ النهائية بهذه السجلات.\n\nهوية الجهة المسؤولة، عنوان الدعم، الأساس القانوني، مدد الاحتفاظ والنسخ الاحتياطية، نقل البيانات، وحقوق المستخدم القانونية لم تُعتمد بعد. يجب استكمالها ومراجعتها قبل جمع بيانات إنتاجية أو النشر العام. هذه المسودة لا تَعِد بحذف نسخ احتياطية أو نسخ احتفظ بها الآخرون فوراً.'
              : 'النسخة مخصصة للاختبار وليست جاهزة للتعاملات العامة. التطبيق مجاني للمستخدم ولا ينفذ دفعاً أو توصيلاً أو ضماناً للبيع. الإعلانات مسؤولية ناشريها، ويجب أن تكون قانونية وصحيحة وتحترم الخصوصية والرفق بالحيوان.\n\nلا تنشر معلومات شخصية لغيرك أو بيانات اتصال في النص العام. لا تنشر احتيالاً أو إساءة أو بيعاً محظوراً.\n\nيمكن الإبلاغ عن الإعلانات والحسابات، ويمكن للمشرف المخوّل إخفاء المحتوى وتوثيق سبب الإجراء. آلية الاعتراض، الجهة المسؤولة، حدود المسؤولية، القانون المختص، ومدد الاحتفاظ تحتاج مراجعة قانونية قبل اعتماد الشروط النهائية. إقرار قواعد الاختبار ليس قبولاً لشروط إنتاجية لم تصدر بعد.',
        ),
      ],
    ),
  );
}
