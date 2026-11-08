import 'package:flutter/material.dart';
import 'domain.dart';
import 'media_screens.dart';
import 'moderation_screens.dart';
import 'repository.dart' show statusLabel;

const draftRules =
    'هذه قواعد نسخة تجريبية وليست الشروط القانونية النهائية. ألتزم بمحتوى قانوني يحترم الخصوصية والرفق بالحيوان، ولا أنشر معلومات مضللة أو بيانات اتصال خاصة في المحتوى العام.';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.repository});
  final BirdsRepository repository;
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final name = TextEditingController(), contactValue = TextEditingController();
  bool accepted = false,
      consent = false,
      loading = true,
      busy = false,
      deletionPending = false;
  String contactKind = 'phone';
  String? error, notice;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    contactValue.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final deletion = await widget.repository.deletionStatus();
    if (!mounted) return;
    if (!deletion.isSuccess || deletion.value != null) {
      setState(() {
        loading = false;
        deletionPending = true;
        error = deletion.failure?.message;
      });
      return;
    }
    final p = await widget.repository.profile();
    final c = await widget.repository.contact();
    if (!mounted) return;
    setState(() {
      loading = false;
      deletionPending = false;
      error = p.failure?.message ?? c.failure?.message;
      name.text = p.value?.name ?? '';
      accepted = p.value?.accepted ?? false;
      contactValue.text = c.value?.value ?? '';
      consent = c.value?.consent ?? false;
      contactKind = c.value?.kind ?? 'phone';
    });
  }

  Future<void> save({bool contact = false}) async {
    if (busy || deletionPending) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    final result = contact
        ? await widget.repository.saveContact(
            ContactData(contactKind, contactValue.text, consent),
          )
        : await widget.repository.saveProfile(name.text, accepted);
    if (mounted) {
      setState(() {
        busy = false;
        error = result.failure?.message;
        notice = result.isSuccess
            ? (contact
                  ? 'تم حفظ تفضيل مشاركة التواصل.'
                  : 'تم حفظ الملف الشخصي. يمكنك النشر والرد والإبلاغ.')
            : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الملف الشخصي والخصوصية')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : deletionPending
        ? ListView(
            padding: const EdgeInsets.all(20),
            children: [
              DeletionStatusPanel(repository: widget.repository),
              const Text(
                'لا تُنشئ ملفاً جديداً أثناء حذف الحساب. إذا تعذر التحقق من حالة الحذف، أعد المحاولة أولاً.',
              ),
              if (error != null) Text(error!),
              TextButton(
                onPressed: load,
                child: const Text('إعادة التحقق من حالة الحساب'),
              ),
            ],
          )
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const DraftLegalLinks(),
              DeletionStatusPanel(repository: widget.repository),
              const Text(
                'اسم العرض ظاهر للجميع؛ لا تضع رقم هاتفك أو بريدك فيه.',
              ),
              TextField(
                controller: name,
                enabled: !busy,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'اسم العرض العام'),
              ),
              CheckboxListTile(
                value: accepted,
                onChanged: busy ? null : (v) => setState(() => accepted = v!),
                title: const Text(draftRules),
              ),
              FilledButton(
                onPressed: busy ? null : () => save(),
                child: const Text('حفظ الملف والإقرار'),
              ),
              const Divider(height: 32),
              const Text(
                'وسيلة التواصل الخاصة',
                style: TextStyle(fontSize: 24),
              ),
              const Text(
                'احفظ الملف أولاً. لن تُدرج وسيلة التواصل في المنشورات أو الملف العام. إذا وافقت أدناه، يستطيع مستخدم مسجل طلبها عبر إعلان نشط لك. يمكن إيقاف المشاركة لاحقاً، لكن لا يمكن سحب ما سبق أن رآه الآخرون.',
              ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                itemHeight: null,
                initialValue: contactKind,
                decoration: const InputDecoration(labelText: 'نوع التواصل'),
                items: const [
                  DropdownMenuItem(value: 'phone', child: Text('هاتف')),
                  DropdownMenuItem(value: 'whatsapp', child: Text('واتساب')),
                  DropdownMenuItem(
                    value: 'email',
                    child: Text('بريد إلكتروني'),
                  ),
                ],
                onChanged: busy ? null : (v) => contactKind = v!,
              ),
              TextField(
                controller: contactValue,
                enabled: !busy,
                maxLength: 160,
                decoration: const InputDecoration(
                  labelText: 'رقم التواصل أو البريد الخاص',
                ),
              ),
              CheckboxListTile(
                value: consent,
                onChanged: busy ? null : (v) => setState(() => consent = v!),
                title: const Text(
                  'أوافق صراحة على كشف وسيلة التواصل هذه للمستخدمين المسجلين الذين يطلبون التواصل عبر إعلاناتي النشطة.',
                ),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => save(contact: true),
                child: const Text('حفظ تفضيل مشاركة التواصل'),
              ),
              if (error != null) ...[
                Semantics(liveRegion: true, child: Text(error!)),
                TextButton(onPressed: load, child: const Text('إعادة التحميل')),
              ],
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              DeleteAccountPage(repository: widget.repository),
                        ),
                      ),
                child: const Text('حذف الحساب نهائياً'),
              ),
              if (notice != null)
                Semantics(liveRegion: true, child: Text(notice!)),
            ],
          ),
  );
}

class FilterPage extends StatefulWidget {
  const FilterPage({
    super.key,
    required this.repository,
    required this.kind,
    required this.initial,
  });
  final BirdsRepository repository;
  final FeedKind kind;
  final FeedFilter initial;
  @override
  State<FilterPage> createState() => _FilterPageState();
}

class _FilterPageState extends State<FilterPage> {
  Taxonomy data = const Taxonomy();
  bool loading = true;
  String? error;
  late int? bird = widget.initial.birdId,
      location = widget.initial.locationId,
      topic = widget.initial.topicId;
  late String status = widget.initial.status,
      currency = widget.initial.currency,
      category = widget.initial.category,
      ageUnit = widget.initial.ageUnit;
  late DateTime? since = widget.initial.since, until = widget.initial.until;
  late final min = TextEditingController(
        text: widget.initial.minPrice?.toString() ?? '',
      ),
      max = TextEditingController(
        text: widget.initial.maxPrice?.toString() ?? '',
      );
  late final minAge = TextEditingController(
        text: widget.initial.minAge?.toString() ?? '',
      ),
      maxAge = TextEditingController(
        text: widget.initial.maxAge?.toString() ?? '',
      );
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    min.dispose();
    max.dispose();
    minAge.dispose();
    maxAge.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final result = await widget.repository.taxonomy();
    if (mounted) {
      setState(() {
        loading = false;
        data = result.value ?? const Taxonomy();
        error = result.failure?.message;
      });
    }
  }

  Widget options(
    String label,
    int? value,
    List<NamedOption> choices,
    void Function(int?) change,
  ) => DropdownButtonFormField<int>(
    itemHeight: null,
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      const DropdownMenuItem<int>(value: null, child: Text('الكل')),
      for (final option in choices)
        DropdownMenuItem(value: option.id, child: Text(option.name)),
    ],
    onChanged: change,
  );
  Future<void> date(bool start) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: (start ? since : until) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (selected != null && mounted) {
      setState(() {
        if (start) {
          since = selected;
        } else {
          until = selected.add(const Duration(days: 1));
        }
      });
    }
  }

  void apply() {
    final low = parseAmount(min.text), high = parseAmount(max.text);
    String? issue =
        validateAmount(min.text, required: false) ??
        validateAmount(max.text, required: false);
    if ((low != null || high != null) && currency.isEmpty) {
      issue = 'اختر العملة عند تحديد نطاق السعر.';
    }
    if (low != null && high != null && low > high) {
      issue = 'السعر الأدنى يجب ألا يتجاوز الأعلى.';
    }
    if (since != null && until != null && !since!.isBefore(until!)) {
      issue = 'تاريخ البداية يجب ألا يتجاوز النهاية.';
    }
    final loAge = int.tryParse(normalizeDigits(minAge.text)),
        hiAge = int.tryParse(normalizeDigits(maxAge.text));
    if ((minAge.text.isNotEmpty && (loAge == null || loAge < 0)) ||
        (maxAge.text.isNotEmpty && (hiAge == null || hiAge < 0)) ||
        (loAge != null && hiAge != null && loAge > hiAge)) {
      issue = 'أدخل نطاق عمر صحيحاً وغير سالب.';
    }
    if (issue != null) {
      setState(() => error = issue);
      return;
    }
    Navigator.pop(
      context,
      FeedFilter(
        search: widget.initial.search,
        birdId: bird,
        locationId: location,
        topicId: topic,
        status: status,
        category: category,
        currency: currency,
        minPrice: low,
        maxPrice: high,
        since: since,
        until: until,
        minAge: loAge,
        maxAge: hiAge,
        ageUnit: ageUnit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('تصفية النتائج')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              options('نوع الطيور', bird, data.birds, (v) => bird = v),
              if (widget.kind == FeedKind.education) ...[
                options('الموضوع', topic, data.topics, (v) => topic = v),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  itemHeight: null,
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
                  onChanged: (v) => category = v!,
                ),
              ] else ...[
                options(
                  'الولاية والمدينة',
                  location,
                  data.locations
                      .map((p) => NamedOption(p.id, p.label))
                      .toList(),
                  (v) => location = v,
                ),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  itemHeight: null,
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'حالة الإعلان'),
                  items: [
                    for (final s in [
                      'active',
                      if (widget.kind == FeedKind.offer) 'reserved',
                      'fulfilled',
                      'closed',
                      'expired',
                    ])
                      DropdownMenuItem(
                        value: s,
                        child: Text(statusLabel(s, widget.kind)),
                      ),
                  ],
                  onChanged: (v) => status = v!,
                ),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  itemHeight: null,
                  initialValue: currency,
                  decoration: const InputDecoration(
                    labelText: 'عملة السعر أو الميزانية',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('كل العملات'),
                    ),
                    for (final c in ['SDG', 'USD', 'SAR'])
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => currency = v!,
                ),
                TextField(
                  controller: min,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'الحد الأدنى للسعر أو الميزانية',
                  ),
                ),
                TextField(
                  controller: max,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'الحد الأعلى للسعر أو الميزانية',
                  ),
                ),
                if (widget.kind == FeedKind.offer) ...[
                  TextField(
                    controller: minAge,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'العمر الأدنى',
                    ),
                  ),
                  TextField(
                    controller: maxAge,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'العمر الأعلى',
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    itemHeight: null,
                    initialValue: ageUnit,
                    decoration: const InputDecoration(labelText: 'وحدة العمر'),
                    items: const [
                      DropdownMenuItem(value: 'day', child: Text('أيام')),
                      DropdownMenuItem(value: 'month', child: Text('أشهر')),
                      DropdownMenuItem(value: 'year', child: Text('سنوات')),
                    ],
                    onChanged: (v) => ageUnit = v!,
                  ),
                ],
              ],
              TextButton(
                onPressed: () => date(true),
                child: Text(
                  since == null ? 'من تاريخ' : 'من ${arabicDate(since!)}',
                ),
              ),
              TextButton(
                onPressed: () => date(false),
                child: Text(
                  until == null
                      ? 'إلى تاريخ (شامل)'
                      : 'إلى ${arabicDate(until!.subtract(const Duration(days: 1)))}',
                ),
              ),
              if (error != null) Text(error!),
              FilledButton(
                onPressed: apply,
                child: const Text('تطبيق الفلاتر'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, const FeedFilter()),
                child: const Text('مسح الفلاتر'),
              ),
              if (data.birds.isEmpty || data.locations.isEmpty)
                const Text(
                  'القوائم المرجعية فارغة أو لم تُضبط بعد. لن تُضاف خيارات وهمية.',
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
    this.existing,
  });
  final BirdsRepository repository;
  final FeedKind kind;
  final FeedEntry? existing;
  @override
  State<PublicationPage> createState() => _PublicationPageState();
}

class _PublicationPageState extends State<PublicationPage> {
  final form = GlobalKey<FormState>();
  late final title = TextEditingController(text: widget.existing?.title ?? ''),
      body = TextEditingController(text: widget.existing?.body ?? ''),
      quantity = TextEditingController(
        text: widget.existing?.quantity.toString() ?? '1',
      ),
      amount = TextEditingController(
        text: widget.existing?.price?.toString() ?? '',
      ),
      age = TextEditingController(text: widget.existing?.age?.toString() ?? '');
  late int? bird = widget.existing?.birdId,
      place = widget.existing?.locationId,
      topic = widget.existing?.topicId;
  late String category = widget.existing?.category == 'consultation'
          ? 'consultation'
          : 'information',
      currency = widget.existing?.currency ?? 'SDG',
      ageUnit = widget.existing?.ageUnit ?? 'month',
      priceUnit = widget.existing?.priceUnit ?? 'bird',
      status = widget.existing?.statusCode ?? 'active';
  late bool negotiable = widget.existing?.negotiable ?? false;
  Taxonomy data = const Taxonomy();
  bool loading = true, ready = false, busy = false, deletionPending = false;
  String? error;
  bool get education => widget.kind == FeedKind.education;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [title, body, quantity, amount, age]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    final deletion = await widget.repository.deletionStatus();
    if (!mounted) return;
    if (!deletion.isSuccess || deletion.value != null) {
      setState(() {
        loading = false;
        ready = false;
        deletionPending = true;
        error =
            deletion.failure?.message ??
            'حذف الحساب قيد التنفيذ؛ لا تنشئ ملفاً جديداً ولا تنشر محتوى.';
      });
      return;
    }
    final result = await widget.repository.taxonomy();
    final profile = await widget.repository.profile();
    if (mounted) {
      setState(() {
        loading = false;
        data = result.value ?? const Taxonomy();
        deletionPending = false;
        ready = profile.value?.accepted == true;
        error = result.failure?.message ?? profile.failure?.message;
      });
    }
  }

  Widget select(
    String label,
    int? value,
    List<NamedOption> options,
    void Function(int?) change, {
    bool required = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<int>(
      itemHeight: null,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (!required)
          const DropdownMenuItem<int>(value: null, child: Text('غير محدد')),
        for (final option in options)
          DropdownMenuItem(value: option.id, child: Text(option.name)),
      ],
      validator: required ? (v) => v == null ? 'اختر من القائمة' : null : null,
      onChanged: busy ? null : change,
    ),
  );
  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    if (!ready) {
      setState(
        () =>
            error = 'أكمل الملف الشخصي والإقرار بقواعد النسخة التجريبية أولاً.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.repository.savePublication(
      Publication(
        kind: widget.kind,
        title: title.text,
        body: body.text,
        birdId: bird,
        locationId: place,
        topicId: topic,
        quantity: int.tryParse(normalizeDigits(quantity.text)) ?? 1,
        category: category,
        amount: parseAmount(amount.text),
        currency: currency,
        age: int.tryParse(normalizeDigits(age.text)),
        ageUnit: ageUnit,
        priceUnit: priceUnit,
        negotiable: negotiable,
        status: status,
      ),
      existing: widget.existing,
    );
    if (!mounted) return;
    if (result.isSuccess) {
      Navigator.pop(context, result.value);
    } else {
      setState(() {
        busy = false;
        error = result.failure!.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        '${widget.existing == null ? 'إضافة' : 'تعديل'} • ${widget.kind.label}',
      ),
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : Form(
            key: form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (deletionPending)
                  DeletionStatusPanel(repository: widget.repository),
                if (!ready && !deletionPending) ...[
                  const Text(
                    'أكمل ملفك الشخصي قبل النشر. لا يتطلب ذلك إنشاء إعلان.',
                  ),
                  FilledButton(
                    onPressed: () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              ProfilePage(repository: widget.repository),
                        ),
                      );
                      if (mounted) await load();
                    },
                    child: const Text('إكمال الملف الشخصي'),
                  ),
                ],
                TextFormField(
                  controller: title,
                  enabled: !busy,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'العنوان'),
                  validator: (v) => (v ?? '').trim().length < 3
                      ? 'العنوان ثلاثة أحرف على الأقل'
                      : null,
                ),
                TextFormField(
                  controller: body,
                  enabled: !busy,
                  maxLength: 5000,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'النص والمواصفات',
                  ),
                  validator: requiredText,
                ),
                select(
                  'نوع الطيور',
                  bird,
                  data.birds,
                  (v) => bird = v,
                  required: !education,
                ),
                if (education) ...[
                  select('الموضوع', topic, data.topics, (v) => topic = v),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    itemHeight: null,
                    initialValue: category,
                    decoration: const InputDecoration(labelText: 'نوع المنشور'),
                    items: const [
                      DropdownMenuItem(
                        value: 'information',
                        child: Text('معلومة للمربي'),
                      ),
                      DropdownMenuItem(
                        value: 'consultation',
                        child: Text('استشارة'),
                      ),
                    ],
                    onChanged: widget.existing != null || busy
                        ? null
                        : (v) => category = v!,
                  ),
                ] else ...[
                  select(
                    'الولاية والمدينة',
                    place,
                    data.locations
                        .map((p) => NamedOption(p.id, p.label))
                        .toList(),
                    (v) => place = v,
                    required: true,
                  ),
                  TextFormField(
                    controller: quantity,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'عدد الطيور'),
                    validator: (v) {
                      final n = int.tryParse(normalizeDigits(v ?? ''));
                      return n == null || n < 1 || n > 100000
                          ? 'أدخل عدداً من ١ إلى ١٠٠٠٠٠'
                          : null;
                    },
                  ),
                  TextFormField(
                    controller: amount,
                    enabled: !busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: widget.kind == FeedKind.offer
                          ? 'السعر الرقمي (مطلوب)'
                          : 'الميزانية (اختيارية)',
                    ),
                    validator: (v) => validateAmount(
                      v,
                      required: widget.kind == FeedKind.offer,
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    itemHeight: null,
                    initialValue: currency,
                    decoration: const InputDecoration(labelText: 'العملة'),
                    items: [
                      for (final c in ['SDG', 'USD', 'SAR'])
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: busy ? null : (v) => currency = v!,
                  ),
                  if (widget.kind == FeedKind.offer) ...[
                    TextFormField(
                      controller: age,
                      enabled: !busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'عمر الطيور',
                      ),
                      validator: (v) {
                        final n = int.tryParse(normalizeDigits(v ?? ''));
                        return n == null || n < 0 || n > 10000
                            ? 'أدخل عمراً من صفر إلى ١٠٠٠٠'
                            : null;
                      },
                    ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      itemHeight: null,
                      initialValue: ageUnit,
                      decoration: const InputDecoration(
                        labelText: 'وحدة العمر',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'day', child: Text('أيام')),
                        DropdownMenuItem(value: 'month', child: Text('أشهر')),
                        DropdownMenuItem(value: 'year', child: Text('سنوات')),
                      ],
                      onChanged: busy ? null : (v) => ageUnit = v!,
                    ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      itemHeight: null,
                      initialValue: priceUnit,
                      decoration: const InputDecoration(
                        labelText: 'السعر مقابل',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'bird',
                          child: Text('الطائر الواحد'),
                        ),
                        DropdownMenuItem(
                          value: 'group',
                          child: Text('المجموعة'),
                        ),
                      ],
                      onChanged: busy ? null : (v) => priceUnit = v!,
                    ),
                    CheckboxListTile(
                      value: negotiable,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => negotiable = v!),
                      title: const Text('السعر قابل للتفاوض'),
                    ),
                  ],
                  if (widget.existing != null)
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      itemHeight: null,
                      initialValue: status,
                      decoration: const InputDecoration(
                        labelText: 'حالة الإعلان',
                      ),
                      items: [
                        for (final s in [
                          'active',
                          if (widget.kind == FeedKind.offer) 'reserved',
                          'fulfilled',
                          'closed',
                          'expired',
                        ])
                          DropdownMenuItem(
                            value: s,
                            child: Text(statusLabel(s, widget.kind)),
                          ),
                      ],
                      onChanged: busy ? null : (v) => status = v!,
                    ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'لا تضع بيانات اتصال خاصة في النص العام. يمكن ضبط التواصل من الملف الشخصي. تُرفق الصور بعد حفظ المحتوى من صفحته.',
                ),
                if (error != null)
                  Semantics(liveRegion: true, child: Text(error!)),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: Text(
                    busy
                        ? 'جارٍ الحفظ…'
                        : widget.existing == null
                        ? 'نشر'
                        : 'حفظ التعديل',
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : load,
                  child: const Text('إعادة تحميل القوائم'),
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
  late FeedEntry entry = widget.entry;
  final text = TextEditingController();
  final List<ReplyEntry> replies = [];
  ReplyEntry? parent;
  bool busy = false, loading = true, more = false;
  String? error;
  ContactData? revealed;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> load({bool next = false}) async {
    if (entry.kind != FeedKind.education) {
      setState(() => loading = false);
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    final result = await widget.repository.replyPage(
      entry.id,
      after: next && replies.isNotEmpty ? replies.last : null,
    );
    if (mounted) {
      setState(() {
        loading = false;
        error = result.failure?.message;
        if (result.isSuccess) {
          if (!next) replies.clear();
          replies.addAll(result.value!);
          more = result.value!.length == 20;
        }
      });
    }
  }

  Future<void> send({required bool report}) async {
    if (busy) return;
    if (!widget.repository.signedIn) {
      setState(
        () => error = 'سجّل الدخول وأكمل ملفك الشخصي أولاً من زر الحساب.',
      );
      return;
    }
    if (text.text.trim().length < (report ? 5 : 1)) {
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
        ? await widget.repository.report(entry, text.text.trim())
        : await widget.repository.sendReply(
            entry.id,
            text.text.trim(),
            parentId: parent?.id,
          );
    if (!mounted) return;
    setState(() {
      busy = false;
      error = result.failure?.message;
    });
    if (result.isSuccess) {
      text.clear();
      parent = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(report ? 'تم إرسال البلاغ للمراجعة' : 'تم نشر الرد'),
        ),
      );
      if (!report) await load();
    }
  }

  Future<void> reveal() async {
    if (!widget.repository.signedIn) {
      setState(() => error = 'سجّل الدخول لطلب وسيلة التواصل.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: const Text('طلب وسيلة التواصل'),
        content: const Text(
          'هل تريد الاطلاع على وسيلة التواصل التي وافق صاحب الإعلان على مشاركتها؟ استخدمها لهذا الإعلان فقط ولا تنشرها.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('طلب التواصل'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    final result = await widget.repository.revealContact(entry.id, true);
    if (mounted) {
      setState(() {
        busy = false;
        revealed = result.value;
        error =
            result.failure?.message ??
            (result.value == null
                ? 'لم يوافق صاحب الإعلان على مشاركة وسيلة تواصل أو لم يعد الإعلان نشطاً.'
                : null);
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(entry.title)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('${entry.author} • ${arabicDate(entry.createdAt)}'),
        SelectableText(entry.body),
        MediaPanel(repository: widget.repository, entry: entry),
        if (entry.price != null)
          Text(
            '${entry.price} ${entry.currency}${entry.kind == FeedKind.offer ? (entry.priceUnit == 'group' ? ' للمجموعة' : ' للطائر') : ' ميزانية'}',
          ),
        Text('${entry.location} ${entry.status}'),
        if (widget.repository.signedIn &&
            entry.ownerId == widget.repository.currentUserId)
          OutlinedButton.icon(
            onPressed: () async {
              final changed = await Navigator.of(context).push<FeedEntry>(
                MaterialPageRoute(
                  builder: (_) => PublicationPage(
                    repository: widget.repository,
                    kind: entry.kind,
                    existing: entry,
                  ),
                ),
              );
              if (changed != null && mounted) setState(() => entry = changed);
            },
            icon: const Icon(Icons.edit_outlined),
            label: const Text('تعديل المحتوى أو إغلاق الإعلان'),
          ),
        if (entry.ownerId.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ReportPage(
                  repository: widget.repository,
                  kind: ReportKind.account,
                  targetId: entry.ownerId,
                ),
              ),
            ),
            icon: const Icon(Icons.report_outlined),
            label: const Text('إبلاغ عن الحساب'),
          ),
        if (entry.kind != FeedKind.education) ...[
          OutlinedButton(
            onPressed: busy ? null : reveal,
            child: const Text('طلب وسيلة التواصل'),
          ),
          if (revealed != null)
            SelectableText('${revealed!.kind}: ${revealed!.value}'),
        ],
        if (entry.ownerId.isNotEmpty &&
            entry.ownerId != widget.repository.currentUserId)
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () async {
                    if (!widget.repository.signedIn) {
                      setState(() => error = 'سجّل الدخول أولاً.');
                      return;
                    }
                    setState(() => busy = true);
                    final result = await widget.repository.block(
                      entry.ownerId,
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
        if (entry.kind == FeedKind.education) ...[
          const Text('الردود', style: TextStyle(fontSize: 24)),
          for (final reply in replies)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${reply.author} • ${arabicDate(reply.createdAt)}'),
                    if (reply.parentId != null) const Text('رد على رد سابق'),
                    Text(reply.body),
                    TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => ReportPage(
                            repository: widget.repository,
                            kind: ReportKind.reply,
                            targetId: reply.id,
                          ),
                        ),
                      ),
                      child: const Text('إبلاغ عن الرد'),
                    ),

                    TextButton(
                      onPressed: () => setState(() => parent = reply),
                      child: const Text('الرد على هذا الرد'),
                    ),
                  ],
                ),
              ),
            ),
          if (loading)
            const LinearProgressIndicator(semanticsLabel: 'تحميل الردود'),
          if (!loading && replies.isEmpty) const Text('لا توجد ردود حتى الآن.'),
          if (more)
            TextButton(
              onPressed: loading ? null : () => load(next: true),
              child: const Text('تحميل المزيد من الردود'),
            ),
          if (parent != null)
            ListTile(
              title: Text('الرد على ${parent!.author}'),
              subtitle: Text(
                parent!.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                onPressed: () => setState(() => parent = null),
                tooltip: 'إلغاء الرد على رد',
                icon: const Icon(Icons.close),
              ),
            ),
        ],
        TextField(
          controller: text,
          maxLines: 3,
          maxLength: 2000,
          decoration: const InputDecoration(
            labelText: 'نص الرد أو سبب الإبلاغ',
          ),
        ),
        if (error != null) ...[
          Semantics(liveRegion: true, child: Text(error!)),
          if (entry.kind == FeedKind.education)
            TextButton(
              onPressed: () => load(),
              child: const Text('إعادة تحميل الردود'),
            ),
        ],
        if (entry.kind == FeedKind.education)
          FilledButton(
            onPressed: busy ? null : () => send(report: false),
            child: const Text('إرسال الرد'),
          ),
        OutlinedButton.icon(
          onPressed: busy ? null : () => send(report: true),
          icon: const Icon(Icons.flag_outlined),
          label: const Text('إبلاغ عن المحتوى'),
        ),
      ],
    ),
  );
}
