# Vitreus على Arch Linux بنواة Zen

صورة Live ‏x86_64 تفتح جلسة Hyprland وواجهة Vitreus المبنية على Pleamar. مصدر الواجهة هو الإصدار المثبّت [`12bf45c` من Vitreus](https://github.com/natepayn3/Vitreus/tree/12bf45c64534d262f89c785c77b25349df45bd9c). الثيم الافتراضي Glass يستمد ألوانه من الخلفية. أُزيل UwU من مجموعة الثيمات.

## تنزيل الصورة أو تحديث نسخة قديمة

نزّل أداة التحديث مرة واحدة من آخر إصدار منشور. تحتاج Python 3.8 أو أحدث. التحميل من الريبو العام متاح من غير حساب GitHub.

```bash
curl -fL -o iso_delta.py https://github.com/9a6r/vitreus-arch-zen/releases/latest/download/iso_delta.py
```

أول تنزيل يحتاج الصورة كاملة.

```bash
python3 iso_delta.py fetch --repo 9a6r/vitreus-arch-zen --output vitreus.iso
```

بعد صدور نسخة أحدث، استخدم ملف الـ ISO القديم كمصدر للأجزاء الموجودة عندك. اترك مساحة كافية لحفظ الصورة الجديدة.

```bash
python3 iso_delta.py fetch --repo 9a6r/vitreus-arch-zen --seed vitreus.iso --output vitreus-new.iso
```

الأداة تقارن محتوى الإصدارين، وتنزّل الأجزاء الناقصة، وتتحقق من بصمة SHA-256 للصورة النهائية. حجم التنزيل يعتمد على التغييرات الفعلية. تحديث النواة أو عدد كبير من حزم Arch قد يغيّر أجزاء كبيرة من الصورة. لتحديث فلاشة الإقلاع، اكتب عليها ملف الـ ISO الجديد بعد اكتمال التحقق.

## تجربة سطح المكتب

جلسة الـ Live تدخل تلقائيًا باسم `vitreus`. كلمة سر الحساب لفتح القفل هي `vitreus`. تقدر تستخدم الاختصارات الأصلية الآتية.

| الاختصار | الوظيفة |
|---|---|
| Super + Space | البحث وتشغيل التطبيقات |
| Super + Shift + Space | الإعدادات والثيمات |
| Super + B | اختيار الخلفية |
| Super + C | لوحة التحكم |
| Super + D | Desk |
| Super + L | قفل الشاشة |

الصور وعروض الحركة الأصلية متاحة في [README الخاص بـ Vitreus](https://github.com/natepayn3/Vitreus/blob/12bf45c64534d262f89c785c77b25349df45bd9c/README.md).

## تعديل المشروع وإصدار ISO جديد

نزّل ملفات المشروع للتعديل.

```bash
git clone https://github.com/9a6r/vitreus-arch-zen.git
cd vitreus-arch-zen
```

ملفات Vitreus موجودة في `desktop/vitreus/`. ملفات جلسة الـ Live موجودة في `desktop/session/`، وحزم سطح المكتب في `packages/desktop.list`. لقطة حزم Arch مثبّتة في `packages/arch-snapshot` حتى تقدر تعيد البناء بنفس إصدارات الحزم بعد تعديل الخلفية أو ملفات الجلسة. الخلفية الابتدائية هي صورة `assets/greeter.jpeg` اللي وزّعها Vitreus. بعض الخلفيات المفتوحة في عروض الريدمي كانت على جهاز المصمّم.

بعد رفع تعديلاتك، اختار **Actions → Build Vitreus ISO → Run workflow** لتجربة البناء. لإصدار نسخة للتحميل والتحديث التفاضلي، اعمل وادفع tag جديد من الكوميت المطلوب. المثال التالي يستخدم رقم إصدار توضيحي.

```bash
git tag v1.1.0
git push origin v1.1.0
```

الـ workflow يبني ISO ويفحص ملفات الإقلاع، ثم يشغّله في QEMU ويتحقق من نواة Zen وظهور واجهة Vitreus واستجابتها لاختصار لوحة التحكم. نتائج التجربة ولقطات الشاشة تبقى ضمن مرفقات الـ run. بعد نجاح الاختبارات، تظهر صورة الإصدار وفهرس التحديث في [Releases](https://github.com/9a6r/vitreus-arch-zen/releases).

لخيارات التحديث، بما فيها استبدال الصورة القديمة بنفس الاسم بعد التحقق، راجع [دليل التحديث](docs/release-update.md).
