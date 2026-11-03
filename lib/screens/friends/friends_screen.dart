import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../models/friends.dart';
import '../../services/backend.dart';
import '../../services/friends_service.dart';
import '../../services/push_service.dart';
import '../../widgets/common.dart';
import '../../widgets/friend_avatar.dart';
import '../../widgets/pickers.dart';

/// Mes amis : ajout par e-mail, demandes reçues, présence en direct et
/// petits messages d'encouragement.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _email = TextEditingController();
  Timer? _tick;
  bool _busy = false;

  FriendsService get _s => Backend.I.friends;

  @override
  void initState() {
    super.initState();
    // Rafraîchit « Vu il y a 3 min » et le passage hors ligne sans attendre
    // un événement du serveur.
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
    if (_s.status == FriendsStatus.connected) {
      unawaited(_s.refresh().catchError((Object _) {}));
      unawaited(Backend.I.chat.refreshBlocks().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _email.dispose();
    super.dispose();
  }

  Future<String?> _askPassword(String message) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmez votre mot de passe'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: AppText.body(size: 14)),
            const SizedBox(height: Gap.m),
            TextField(
              key: const Key('friends_password'),
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Mot de passe GymFlow',
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            key: const Key('friends_password_ok'),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    await runAction(context, action, success: success);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _enable() async {
    final pwd = await _askPassword(
      'Votre compte sera relié à un service en ligne (Supabase) pour retrouver '
      'vos amis d\'un téléphone à l\'autre. Utilisez votre mot de passe '
      'GymFlow : il doit rester le même des deux côtés.',
    );
    if (pwd == null || pwd.isEmpty) return;
    await _run(() => _s.enable(pwd), success: 'Fonction Amis activée.');
  }

  Future<void> _reconnect() async {
    final pwd = await _askPassword(
      'Pour vous reconnecter au service Amis, ressaisissez votre mot de passe.',
    );
    if (pwd == null || pwd.isEmpty) return;
    await _run(() => _s.reconnect(pwd), success: 'Connecté.');
  }

  Future<void> _disable() async {
    final ok = await confirm(
      context,
      title: 'Désactiver la fonction Amis ?',
      message:
          'Vos amis, demandes et messages seront effacés du service en ligne. '
          'Vous devrez tout recommencer si vous la réactivez.',
      confirmLabel: 'Désactiver',
      destructive: true,
    );
    if (!ok) return;
    await _run(_s.disable, success: 'Fonction Amis désactivée.');
  }

  Future<void> _send() async {
    final email = _email.text;
    setState(() => _busy = true);
    try {
      final result = await _s.sendRequest(email);
      _email.clear();
      if (mounted) {
        showSnack(context, switch (result) {
          SendResult.sent =>
            'Invitation envoyée. Elle apparaît dans '
                "« Invitations envoyées » jusqu'à la réponse.",
          SendResult.accepted => 'Vous êtes maintenant amis.',
          SendResult.alreadyFriends => 'Vous êtes déjà amis.',
          SendResult.alreadyPending => 'Invitation déjà en attente.',
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(title: const Text('Mes amis')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_s, b.auth, b.chat, b.push]),
        builder: (context, _) {
          final me = b.auth.currentUser;
          final status = _s.status;
          return RefreshIndicator(
            onRefresh: () async {
              if (status == FriendsStatus.connected) {
                try {
                  await _s.refresh();
                } catch (_) {}
              }
            },
            child: ListView(
              padding: pagePadding(context, maxWidth: 760),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (status == FriendsStatus.unavailable)
                  const GfCard(
                    child: InfoRow(
                      Icons.cloud_off_outlined,
                      'La fonction Amis n\'est pas disponible dans cette '
                      'version de l\'application.',
                    ),
                  )
                else if (me == null || !me.isMember)
                  const GfCard(
                    child: InfoRow(
                      Icons.info_outline,
                      'La fonction Amis est réservée aux abonnés.',
                    ),
                  )
                else if (!me.isAdult)
                  const GfCard(
                    child: InfoRow(
                      Icons.shield_outlined,
                      'La fonction Amis est indisponible pour les comptes de '
                      'mineurs.',
                    ),
                  )
                else if (status == FriendsStatus.off)
                  _intro()
                else ...[
                  if (status != FriendsStatus.connected) _notConnected(status),
                  if (status == FriendsStatus.connected) ..._connected(),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------- Fonction éteinte

  Widget _intro() {
    return GfCard(
      key: const Key('friends_intro'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Entraînez-vous avec vos amis', style: AppText.title(size: 18)),
          const SizedBox(height: Gap.s),
          Text(
            'Ajoutez des amis avec leur adresse e-mail, voyez en direct '
            's\'ils sont connectés et envoyez-leur un petit message '
            'd\'encouragement.',
            style: AppText.body(size: 14, color: AppColors.inkSoft),
          ),
          const SizedBox(height: Gap.s),
          const InfoRow(
            Icons.lock_outline,
            'Facultatif, désactivé par défaut. Vos amis voient seulement '
            'votre nom, votre photo et si vous êtes en ligne.',
          ),
          const InfoRow(
            Icons.cloud_outlined,
            'Un compte est créé sur un service en ligne (Supabase) avec votre '
            'e-mail et votre mot de passe. Désactiver la fonction efface vos '
            'données de ce service.',
          ),
          const SizedBox(height: Gap.m),
          ElevatedButton.icon(
            key: const Key('friends_enable'),
            onPressed: _busy ? null : _enable,
            icon: const Icon(Icons.people_outline),
            label: const Text('Activer la fonction Amis'),
          ),
        ],
      ),
    );
  }

  Widget _notConnected(FriendsStatus status) {
    return GfCard(
      key: const Key('friends_not_connected'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status == FriendsStatus.connecting) ...[
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: Gap.s),
                Text('Connexion au service Amis…', style: AppText.body()),
              ],
            ),
          ] else ...[
            Text(
              status == FriendsStatus.needsPassword
                  ? 'Reconnexion nécessaire'
                  : 'Service Amis injoignable',
              style: AppText.title(size: 17),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              _s.error != null
                  ? friendlyError(_s.error!)
                  : 'Ressaisissez votre mot de passe pour retrouver vos amis.',
              style: AppText.body(size: 14, color: AppColors.inkSoft),
            ),
            const SizedBox(height: Gap.m),
            ElevatedButton.icon(
              key: const Key('friends_reconnect'),
              onPressed: _busy ? null : _reconnect,
              icon: const Icon(Icons.login),
              label: const Text('Se reconnecter'),
            ),
          ],
          const SizedBox(height: Gap.s),
          TextButton(
            key: const Key('friends_disable'),
            onPressed: _busy ? null : _disable,
            child: const Text('Désactiver la fonction Amis'),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------- Connecté

  List<Widget> _connected() {
    final friends = _s.friends;
    final requests = _s.requests;
    final now = _s.serverNow();
    return [
      Text(
        _s.onlineCount == 0
            ? 'Personne en ligne pour le moment'
            : '${_s.onlineCount} ami(s) en ligne',
        style: AppText.label(),
      ),
      const SizedBox(height: Gap.s),
      GfCard(
        padding: const EdgeInsets.symmetric(horizontal: Gap.m),
        child: ListTile(
          key: const Key('open_chats'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.chat_bubble_outline, color: AppColors.navy),
          title: Text('Messages', style: AppText.subtitle(size: 15)),
          subtitle: const Text('Vos discussions avec vos amis'),
          trailing: Backend.I.chat.unreadTotal > 0
              ? Pill('${Backend.I.chat.unreadTotal}', color: AppColors.red)
              : const Icon(Icons.chevron_right),
          onTap: () => Navigator.pushNamed(context, Routes.chats),
        ),
      ),
      const SizedBox(height: Gap.s),
      GfCard(
        padding: const EdgeInsets.symmetric(horizontal: Gap.m),
        child: SwitchListTile(
          key: const Key('friends_invisible'),
          contentPadding: EdgeInsets.zero,
          value: _s.invisible,
          onChanged: _busy
              ? null
              : (v) => _run(
                  () => _s.setInvisible(v),
                  success: v
                      ? 'Vos amis vous voient hors ligne.'
                      : 'Vos amis voient quand vous êtes en ligne.',
                ),
          title: const Text('Apparaître hors ligne'),
          subtitle: const Text(
            'Vos amis ne voient ni « en ligne » ni « vu il y a ». Vous '
            'continuez de recevoir vos messages et de voir les leurs.',
          ),
        ),
      ),
      const SizedBox(height: Gap.s),
      GfCard(
        padding: const EdgeInsets.symmetric(horizontal: Gap.m),
        child: Column(
          children: [
            SwitchListTile(
              key: const Key('chat_hide_receipts'),
              contentPadding: EdgeInsets.zero,
              value: _s.settings.hideReadReceipts,
              onChanged: _busy
                  ? null
                  : (v) => _run(() => _s.setChatSettings(hideReadReceipts: v)),
              title: const Text('Masquer les « Vu »'),
              subtitle: const Text(
                'Vos amis ne voient pas quand vous avez lu leurs messages, et '
                'vous ne voyez plus les leurs.',
              ),
            ),
            SwitchListTile(
              key: const Key('chat_hide_typing'),
              contentPadding: EdgeInsets.zero,
              value: _s.settings.hideTyping,
              onChanged: _busy
                  ? null
                  : (v) => _run(() => _s.setChatSettings(hideTyping: v)),
              title: const Text('Masquer « en train d\'écrire »'),
              subtitle: const Text(
                'Même règle : si vous le masquez, vous ne le voyez plus non plus.',
              ),
            ),
            SwitchListTile(
              key: const Key('chat_push_preview'),
              contentPadding: EdgeInsets.zero,
              value: _s.settings.pushPreview,
              onChanged: _busy
                  ? null
                  : (v) => _run(() => _s.setChatSettings(pushPreview: v)),
              title: const Text('Afficher le texte des messages'),
              subtitle: const Text(
                'Dans les notifications, y compris sur l\'écran verrouillé. '
                'Désactivé : « X vous a écrit ».',
              ),
            ),
            ListTile(
              key: const Key('push_status'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.notifications_active_outlined,
                color: Backend.I.push.status == PushStatus.enabled
                    ? AppColors.success
                    : AppColors.inkSoft,
              ),
              title: const Text('Notifications application fermée'),
              subtitle: Text(_pushLabel(Backend.I.push.status)),
            ),
          ],
        ),
      ),
      const SectionHeader('Ajouter un ami'),
      GfCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('friend_email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Adresse e-mail de votre ami',
                prefixIcon: Icon(Icons.alternate_email),
              ),
              onSubmitted: (_) => _busy ? null : _send(),
            ),
            const SizedBox(height: Gap.s),
            Text(
              'Votre ami doit avoir activé la fonction Amis avec cette adresse.',
              style: AppText.label(size: 12),
            ),
            const SizedBox(height: Gap.s),
            ElevatedButton.icon(
              key: const Key('friend_send'),
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Envoyer la demande'),
            ),
          ],
        ),
      ),
      if (requests.isNotEmpty) ...[
        SectionHeader('Demandes reçues (${requests.length})'),
        GfCard(
          key: const Key('friend_requests'),
          child: Column(
            children: [
              for (final r in requests)
                ListTile(
                  key: Key('request_${r.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: FriendAvatar(name: r.fromName, url: r.avatarUrl),
                  title: Text(r.fromName, style: AppText.subtitle(size: 15)),
                  subtitle: const Text('veut vous ajouter en ami'),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        key: Key('accept_${r.id}'),
                        tooltip: 'Accepter',
                        color: AppColors.success,
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => _s.respond(r, true),
                                success:
                                    '${r.fromName} est maintenant votre ami.',
                              ),
                        icon: const Icon(Icons.check_circle_outline),
                      ),
                      IconButton(
                        key: Key('decline_${r.id}'),
                        tooltip: 'Refuser',
                        color: AppColors.red,
                        onPressed: _busy
                            ? null
                            : () => _run(() => _s.respond(r, false)),
                        icon: const Icon(Icons.cancel_outlined),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
      if (_s.sentRequests.isNotEmpty) ...[
        SectionHeader('Invitations envoyées (${_s.sentRequests.length})'),
        GfCard(
          key: const Key('sent_requests'),
          child: Column(
            children: [
              for (final r in _s.sentRequests)
                ListTile(
                  key: Key('sent_${r.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: FriendAvatar(name: r.toName, url: r.avatarUrl),
                  title: Text(r.toName, style: AppText.subtitle(size: 15)),
                  subtitle: const Text('En attente de réponse'),
                  trailing: TextButton(
                    key: Key('cancel_${r.id}'),
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => _s.cancelRequest(r),
                            success: 'Invitation annulée.',
                          ),
                    child: const Text('Annuler'),
                  ),
                ),
            ],
          ),
        ),
      ],
      if (Backend.I.chat.blocks.isNotEmpty) ...[
        SectionHeader('Personnes bloquées (${Backend.I.chat.blocks.length})'),
        GfCard(
          key: const Key('blocked_list'),
          child: Column(
            children: [
              for (final u in Backend.I.chat.blocks)
                ListTile(
                  key: Key('blocked_${u.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: FriendAvatar(name: u.name, url: u.avatarUrl),
                  title: Text(u.name, style: AppText.subtitle(size: 15)),
                  trailing: TextButton(
                    key: Key('unblock_${u.id}'),
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => Backend.I.chat.unblock(u.id),
                            success: '${u.name} est débloqué(e).',
                          ),
                    child: const Text('Débloquer'),
                  ),
                ),
            ],
          ),
        ),
      ],
      SectionHeader('Mes amis (${friends.length})'),
      if (friends.isEmpty)
        const GfCard(
          child: InfoRow(
            Icons.people_outline,
            'Aucun ami pour le moment. Ajoutez-en avec leur adresse e-mail.',
          ),
        )
      else
        GfCard(
          key: const Key('friend_list'),
          child: Column(
            children: [for (final f in friends) _friendTile(f, now)],
          ),
        ),
      const SizedBox(height: Gap.m),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('friends_disable'),
          onPressed: _busy ? null : _disable,
          child: const Text('Désactiver la fonction Amis'),
        ),
      ),
    ];
  }

  Widget _friendTile(Friend f, DateTime now) {
    final online = f.isOnline(now);
    return ListTile(
      key: Key('friend_${f.id}'),
      contentPadding: EdgeInsets.zero,
      leading: FriendAvatar(name: f.name, url: f.avatarUrl, online: online),
      title: Text(f.name, style: AppText.subtitle(size: 15)),
      subtitle: Text(
        f.presenceLabel(now),
        key: Key('presence_${f.id}'),
        style: AppText.label(
          size: 12,
          color: online ? AppColors.success : AppColors.inkSoft,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('chat_${f.id}'),
            tooltip: 'Écrire',
            color: AppColors.navy,
            onPressed: () =>
                Navigator.pushNamed(context, Routes.chat, arguments: f.id),
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            key: Key('poke_${f.id}'),
            tooltip: 'Encourager',
            color: AppColors.red,
            onPressed: _busy ? null : () => _poke(f, PokeKind.encourage),
            icon: const Icon(Icons.bolt),
          ),
          PopupMenuButton<String>(
            key: Key('friend_menu_${f.id}'),
            tooltip: 'Plus d\'actions',
            onSelected: (v) {
              switch (v) {
                case 'challenge':
                  _poke(f, PokeKind.challenge);
                case 'report':
                  _reportPerson(f);
                case 'block':
                  _block(f);
                case 'remove':
                  _remove(f);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'challenge', child: Text('Lancer un défi')),
              PopupMenuItem(
                value: 'report',
                child: Text('Signaler la personne'),
              ),
              PopupMenuItem(value: 'block', child: Text('Bloquer')),
              PopupMenuItem(value: 'remove', child: Text('Retirer cet ami')),
            ],
          ),
        ],
      ),
    );
  }

  static String _pushLabel(PushStatus s) => switch (s) {
    PushStatus.enabled =>
      'Activées : vous êtes prévenu(e) même quand l\'application est fermée.',
    PushStatus.denied =>
      'Refusées : autorisez les notifications de GymFlow dans les réglages du '
          'téléphone.',
    PushStatus.error => 'Indisponibles pour le moment (réseau ou serveur).',
    PushStatus.unavailable =>
      'Non configurées : l\'application ne vous prévient que lorsqu\'elle est '
          'ouverte.',
    PushStatus.off => 'En cours d\'activation…',
  };

  /// Signaler la **personne** (sa conduite en général) : le motif est
  /// obligatoire. Pour signaler des messages précis, on signale la discussion.
  Future<void> _reportPerson(Friend f) async {
    final reason = await askText(
      context,
      title: 'Signaler ${f.name}',
      label: 'Motif du signalement',
      hint: 'Ex. photo inappropriée, harcèlement…',
      validator: Validators.text(field: 'Le motif', min: 5, max: 500),
    );
    if (reason == null || !mounted) return;
    await _run(
      () => Backend.I.chat.reportPerson(f.id, reason),
      success: 'Merci. Le signalement a été transmis à la salle.',
    );
  }

  Future<void> _block(Friend f) async {
    final ok = await confirm(
      context,
      title: 'Bloquer ${f.name} ?',
      message:
          'Vous ne serez plus amis et plus aucun message ne passera. '
          '${f.name} ne saura pas que vous l\'avez bloqué(e).',
      confirmLabel: 'Bloquer',
      destructive: true,
    );
    if (ok) {
      await _run(
        () => Backend.I.chat.block(f.id),
        success: '${f.name} est bloqué(e).',
      );
    }
  }

  Future<void> _poke(Friend f, PokeKind kind) =>
      _run(() => _s.poke(f, kind), success: 'Message envoyé à ${f.name}.');

  Future<void> _remove(Friend f) async {
    final ok = await confirm(
      context,
      title: 'Retirer ${f.name} ?',
      message:
          'Vous ne verrez plus sa présence et ne pourrez plus vous écrire.',
      confirmLabel: 'Retirer',
      destructive: true,
    );
    if (ok) await _run(() => _s.remove(f));
  }
}
