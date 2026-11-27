/// Ayarlar › Güvenlik › Kullanıcılar & Yetkiler (spec §23.3, task A3/A4).
///
/// Runs only on the Windows POS, which is the authority for local accounts.
/// Every change goes through [LocalAuth] (validated, audited); no password,
/// PIN or token is ever shown again after it is entered.
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'brand.dart';
import 'local_accounts.dart';
import 'permission_catalogue.g.dart';
import 'pos_logic.dart';

const _sectionNames = {
  'menu': 'Menü', 'sync': 'Bulut & Senkronizasyon', 'backup': 'Yedekleme',
  'permissions': 'Yetkiler', 'tables': 'Masalar', 'orders': 'Siparişler',
  'pickup': 'Gel-Al', 'payments': 'Ödemeler', 'receipts': 'Fişler',
  'online': 'Online siparişler', 'shifts': 'Vardiyalar', 'payroll': 'Bordro',
  'dashboard': 'Genel bakış', 'sales': 'Satışlar', 'finance': 'Finans',
  'reports': 'Raporlar', 'staff': 'Personel', 'accounts': 'Cari hesaplar',
  'integrations': 'Entegrasyonlar', 'reviews': 'Yorumlar', 'audit': 'Denetim',
  'users': 'Kullanıcılar',
};

class AccountsPanel extends StatefulWidget {
  const AccountsPanel({super.key, required this.auth, required this.employees});
  final LocalAuth auth;
  final List<Json> employees;
  @override
  State<AccountsPanel> createState() => _AccountsPanelState();
}

class _AccountsPanelState extends State<AccountsPanel> {
  static const actor = 'windows';
  LocalAuth get auth => widget.auth;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      _toast(done);
    } on LocalAuthException catch (e) {
      _toast(e.message.isNotEmpty ? e.message : 'İşlem yapılamadı (${e.code}).');
    }
    if (mounted) setState(() {});
  }

  String _employeeName(Object? id) {
    for (final e in widget.employees) {
      if (e['id'] == id) return '${e['name']}';
    }
    return '';
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Onayla')),
          ],
        ),
      ) ??
      false;

  // ------------------------------------------------------------ dialogs
  Future<void> _userDialog({bool owner = false}) async {
    final name = TextEditingController(), pass = TextEditingController(), pass2 = TextEditingController();
    String role = owner ? 'Yönetici' : 'Personel';
    int? employee;
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
        title: Text(owner ? 'İşletme sahibi hesabı' : 'Kullanıcı ekle'),
        content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Kullanıcı adı')),
          TextField(controller: pass, obscureText: true,
              decoration: const InputDecoration(labelText: 'Şifre (en az 8 karakter)')),
          TextField(controller: pass2, obscureText: true,
              decoration: const InputDecoration(labelText: 'Şifre (tekrar)')),
          if (!owner) DropdownButtonFormField<String>(
            initialValue: role,
            decoration: const InputDecoration(labelText: 'Rol (varsayılan yetkiler)'),
            items: [for (final r in localAuthRoles) DropdownMenuItem(value: r, child: Text(r))],
            onChanged: (v) => set(() => role = v ?? role),
          ),
          DropdownButtonFormField<int?>(
            initialValue: employee,
            decoration: const InputDecoration(labelText: 'Bağlı çalışan (siparişlerde görünen ad)'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('Bağlı değil')),
              for (final e in widget.employees.where((e) => e['active'] != false))
                DropdownMenuItem<int?>(value: e['id'] as int?, child: Text('${e['name']}')),
            ],
            onChanged: (v) => set(() => employee = v),
          ),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: const TextStyle(color: Colors.red))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () {
            if (pass.text != pass2.text) return set(() => error = 'Şifreler aynı değil.');
            Navigator.pop(c, true);
          }, child: const Text('Oluştur')),
        ],
      )),
    );
    if (ok != true) return;
    await _run(() => auth.createUser(username: name.text, password: pass.text, role: role,
        employeeId: employee, isOwner: owner, actor: actor), 'Hesap oluşturuldu.');
  }

  Future<void> _passwordDialog(Json user) async {
    final pass = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text('${user['username']} · şifre sıfırla'),
      content: TextField(controller: pass, obscureText: true,
          decoration: const InputDecoration(labelText: 'Yeni şifre (en az 8 karakter)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Kaydet')),
      ],
    ));
    if (ok != true) return;
    await _run(() async {
      await auth.resetPassword(user['userId'] as String, pass.text, actor: actor);
      auth.revokeSessions(user['userId'] as String, actor: actor);
    }, 'Şifre değişti; açık oturumlar kapatıldı.');
  }

  Future<void> _grantsDialog(Json user) async {
    final userId = user['userId'] as String;
    final grants = (user['grants'] as List).cast<String>().toSet();
    final bySection = <String, List<String>>{};
    for (final e in permissionCatalogue.entries) {
      if (e.value.sensitivity == 'ownerOnly') continue;
      (bySection[e.value.section] ??= []).add(e.key);
    }
    await showDialog<void>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
      title: Text('${user['username']} · yetkiler'),
      content: SizedBox(width: 520, height: 520, child: ListView(children: [
        const Text('Yalnızca sahibe ait işlemler (geri yükleme, bulut kurulumu, yetki yönetimi) burada verilemez. '
            'Bulut & Senkronizasyon ve Yedekleme yalnızca Windows POS’ta çalışır.',
            style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
        for (final s in bySection.entries) ...[
          Padding(padding: const EdgeInsets.only(top: 12, bottom: 2),
              child: Text(_sectionNames[s.key] ?? s.key,
                  style: const TextStyle(fontWeight: FontWeight.w800, color: NohutBrand.green))),
          for (final op in s.value)
            CheckboxListTile(
              dense: true,
              value: grants.contains(op),
              title: Text(op),
              subtitle: Text([
                if (permissionCatalogue[op]!.sensitivity == 'elevated') 'hassas',
                permissionCatalogue[op]!.clients.join(' · '),
              ].join(' · ')),
              onChanged: (v) {
                try {
                  auth.setGrant(userId, op, v == true, actor: actor);
                  set(() => v == true ? grants.add(op) : grants.remove(op));
                } on LocalAuthException catch (e) {
                  _toast(e.message.isNotEmpty ? e.message : e.code);
                }
              },
            ),
        ],
      ])),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Kapat'))],
    )));
    if (mounted) setState(() {});
  }

  Future<void> _mfaDialog(Json owner) async {
    final userId = owner['userId'] as String;
    final secret = auth.beginTotp(userId);
    final uri = 'otpauth://totp/Nohut%20POS:${Uri.encodeComponent('${owner['username']}')}'
        '?secret=$secret&issuer=Nohut%20POS&digits=6&period=30';
    final code = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Sahip için iki adımlı doğrulama'),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Google Authenticator, Microsoft Authenticator veya benzeri bir uygulamayla kodu okutun, '
            'sonra uygulamadaki 6 haneli kodu girin.'),
        const SizedBox(height: 10),
        SizedBox(width: 200, height: 200, child: QrImageView(data: uri, backgroundColor: Colors.white)),
        SelectableText(secret, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        TextField(controller: code, keyboardType: TextInputType.number, maxLength: 6,
            decoration: const InputDecoration(labelText: 'Doğrulama kodu')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Etkinleştir')),
      ],
    ));
    if (ok != true) return;
    await _run(() async => auth.confirmTotp(userId, code.text.trim()), 'İki adımlı doğrulama açıldı.');
  }

  Future<void> _userAction(Json user, String action) async {
    final id = user['userId'] as String;
    switch (action) {
      case 'grants':
        return _grantsDialog(user);
      case 'password':
        return _passwordDialog(user);
      case 'pin':
        return _run(() async => auth.resetPin(id, actor: actor), 'PIN sıfırlandı; sonraki kilitte şifre istenir.');
      case 'sessions':
        return _run(() async => auth.revokeSessions(id, actor: actor), 'Tüm oturumlar kapatıldı.');
      case 'devices':
        if (!await _confirm('Cihazları kaldır', '${user['username']} için tüm güvenilen cihazlar ve oturumlar kaldırılsın mı? '
            'Bu cihazlarda tekrar giriş yapılamaz; yeni bir cihazdan giriş gerekir.')) return;
        return _run(() async => auth.revokeSessions(id, devicesToo: true, actor: actor), 'Cihazlar kaldırıldı.');
      case 'mfa':
        return _mfaDialog(user);
      case 'toggle':
        final active = user['active'] == true;
        if (active && !await _confirm('Hesabı devre dışı bırak', '${user['username']} artık giriş yapamaz. Geçmiş kayıtları korunur.')) return;
        return _run(() async {
          auth.setActive(id, !active, actor: actor);
          if (active) auth.revokeSessions(id, actor: actor);
        }, active ? 'Hesap devre dışı.' : 'Hesap etkin.');
      default:
        if (action.startsWith('role:')) {
          return _run(() async => auth.setRole(id, action.substring(5), actor: actor), 'Rol güncellendi.');
        }
    }
  }

  // ------------------------------------------------------------ build
  Widget _card(String title, String subtitle, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13),
          side: const BorderSide(color: Color(0xffDCE8DE))),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(color: NohutBrand.green, fontSize: 15, fontWeight: FontWeight.w800)),
          Text(subtitle, style: const TextStyle(color: NohutBrand.muted, fontSize: 12)),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final users = auth.users();
    final owner = users.where((u) => u['isOwner'] == true).firstOrNull;
    if (owner == null) {
      return _card('Kullanıcılar & Yetkiler',
          'Bireysel girişleri başlatmak için önce işletme sahibi hesabını oluşturun. '
          'Personel paneli bu ayar açılana kadar bugünkü gibi çalışmaya devam eder.', [
        Align(alignment: Alignment.centerLeft, child: FilledButton.icon(
          key: const ValueKey('create-owner'),
          onPressed: () => _userDialog(owner: true),
          icon: const Icon(Icons.person_add_alt_1_outlined),
          label: const Text('İşletme sahibi hesabı oluştur'),
        )),
      ]);
    }
    final idle = auth.idleLock.inMinutes;
    final devices = auth.devices();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _card('Giriş kuralları', 'Personel ve Yönetici tarayıcı uygulamaları için.', [
        SwitchListTile(
          key: const ValueKey('lan-login-required'),
          contentPadding: EdgeInsets.zero,
          value: auth.lanLoginRequired,
          title: const Text('Bireysel giriş zorunlu'),
          subtitle: const Text('Açıkken telefonlar ad seçerek değil, kendi kullanıcı adı ve şifresiyle girer. '
              'Önce çalışanlar için hesap oluşturun.'),
          onChanged: (v) async {
            if (v && users.length < 2 &&
                !await _confirm('Yalnızca sahip hesabı var', 'Henüz çalışan hesabı yok. Açarsanız telefonlarda yalnızca sahip giriş yapabilir. Devam edilsin mi?')) {
              return;
            }
            auth.setSetting('lan_login_required', v ? '1' : '0', actor: actor);
            setState(() {});
          },
        ),
        Row(children: [
          const Expanded(child: Text('İşlem yapılmazsa kilitle')),
          DropdownButton<int>(
            value: const [5, 10, 15, 30, 60].contains(idle) ? idle : 30,
            items: [for (final m in const [5, 10, 15, 30, 60])
              DropdownMenuItem(value: m, child: Text('$m dakika'))],
            onChanged: (m) {
              if (m == null) return;
              auth.setSetting('idle_lock_minutes', '$m', actor: actor);
              auth.loadSettings();
              setState(() {});
            },
          ),
        ]),
      ]),
      _card('Kullanıcılar', 'Her kişi kendi hesabıyla girer; yetkiler kişiye göre ayarlanır.', [
        for (final u in users)
          ListTile(
            key: ValueKey('user-${u['username']}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(u['isOwner'] == true ? Icons.verified_user_outlined : Icons.person_outline,
                color: u['active'] == true ? NohutBrand.green : NohutBrand.muted),
            title: Text('${u['username']}${u['active'] == true ? '' : ' (devre dışı)'}'),
            subtitle: Text([
              u['isOwner'] == true ? 'İşletme sahibi' : '${u['role']}',
              if (_employeeName(u['employeeId']).isNotEmpty) _employeeName(u['employeeId']),
              '${u['devices']} cihaz',
              if (u['isOwner'] == true) u['mfa'] == true ? 'iki adımlı doğrulama açık' : 'iki adımlı doğrulama kapalı',
            ].join(' · ')),
            trailing: PopupMenuButton<String>(
              tooltip: 'İşlemler',
              onSelected: (a) => _userAction(u, a),
              itemBuilder: (c) => [
                if (u['isOwner'] != true) ...[
                  const PopupMenuItem(value: 'grants', child: Text('Yetkileri düzenle')),
                  for (final r in localAuthRoles)
                    if (r != u['role']) PopupMenuItem(value: 'role:$r', child: Text('Rol: $r')),
                ],
                const PopupMenuItem(value: 'password', child: Text('Şifre sıfırla')),
                const PopupMenuItem(value: 'pin', child: Text('PIN sıfırla')),
                const PopupMenuItem(value: 'sessions', child: Text('Oturumları kapat')),
                const PopupMenuItem(value: 'devices', child: Text('Cihazları kaldır')),
                if (u['isOwner'] == true && u['mfa'] != true)
                  const PopupMenuItem(value: 'mfa', child: Text('İki adımlı doğrulamayı kur')),
                if (u['isOwner'] != true)
                  PopupMenuItem(value: 'toggle',
                      child: Text(u['active'] == true ? 'Devre dışı bırak' : 'Etkinleştir')),
              ],
            ),
          ),
        Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
          key: const ValueKey('add-user'),
          onPressed: _userDialog,
          icon: const Icon(Icons.person_add_alt_outlined),
          label: const Text('Kullanıcı ekle'),
        )),
      ]),
      _card('Güvenilen cihazlar', 'Bir telefon kaybolursa buradan kaldırın; oturumu hemen kapanır.', [
        if (devices.isEmpty) const Text('Henüz giriş yapılmış cihaz yok.'),
        for (final d in devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.smartphone_outlined),
            title: Text('${d['username']} · ${(d['label'] as String?)?.isNotEmpty == true ? d['label'] : d['client']}'),
            subtitle: Text(d['revoked'] == true ? 'Kaldırıldı'
                : 'Son görülme: ${d['lastSeenAt'] ?? '-'}${d['hasPin'] == true ? ' · PIN var' : ''}'),
            trailing: d['revoked'] == true ? null : TextButton(
              onPressed: () => _run(() async => auth.revokeDevice(d['deviceId'] as String, actor: actor),
                  'Cihaz kaldırıldı.'),
              child: const Text('Kaldır'),
            ),
          ),
      ]),
      _card('Son güvenlik olayları', 'Girişler, yetki değişiklikleri ve kaldırılan cihazlar.', [
        for (final a in auth.audit(limit: 15))
          Text('${a['at']}  ${a['action']}', style: const TextStyle(fontSize: 12)),
      ]),
    ]);
  }
}
