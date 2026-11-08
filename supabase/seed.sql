-- LOCAL DEVELOPMENT REFERENCE DATA ONLY.
-- Reviewed production reference data must be provisioned separately; this is not
-- a production migration or a complete geography/taxonomy of Sudan.
-- No accounts, contacts, listings, posts, replies or reports are created.
insert into public.bird_types(name_ar) values
 ('حمام'),
 ('دجاج'),
 ('بط'),
 ('إوز'),
 ('ديك رومي'),
 ('سمان'),
 ('كناري'),
 ('بادجي'),
 ('كوكتيل')
on conflict (name_ar) do nothing;

insert into public.topics(name_ar) values
 ('التغذية'),
 ('الرعاية اليومية'),
 ('التكاثر والتفريخ'),
 ('المسكن والنظافة'),
 ('صحة الطيور'),
 ('إرشادات للمبتدئين')
on conflict (name_ar) do nothing;

insert into public.locations(state_ar,city_ar) values
 ('الخرطوم','الخرطوم'),
 ('الخرطوم','أم درمان'),
 ('الخرطوم','بحري'),
 ('كسلا','كسلا'),
 ('البحر الأحمر','بورتسودان')
on conflict (state_ar,city_ar) do nothing;
