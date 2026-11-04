import 'dart:async';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/emoji.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/chat.dart';
import '../../models/friends.dart';
import '../../services/backend.dart';
import '../../services/chat_service.dart';
import '../../widgets/common.dart';
import '../../widgets/emoji_widgets.dart';
import '../../widgets/friend_avatar.dart';
import '../../widgets/share_widgets.dart';

/// Heure locale d'un instant donné par le serveur (en UTC).
String _clock(DateTime d) => Fmt.time(d.toLocal());

String _dayLabel(DateTime d, DateTime now) {
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return "Aujourd'hui";
  if (diff == 1) return 'Hier';
  return Fmt.date(d);
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

// =========================================================================
// Liste des discussions
// =========================================================================

/// Liste des discussions (récentes ou archivées).
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  bool _showArchived = false;
  Object? _error;

  ChatService get _chat => Backend.I.chat;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _chat.refreshConversations();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _newChat() async {
    final friends = Backend.I.friends.friends;
    if (friends.isEmpty) {
      showSnack(context, 'Ajoutez d\'abord un ami dans « Mes amis ».');
      return;
    }
    final picked = await showModalBottomSheet<Friend>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.m),
              child: Text('Écrire à…', style: AppText.title(size: 18)),
            ),
            for (final f in friends)
              ListTile(
                key: Key('new_chat_${f.id}'),
                leading: FriendAvatar(name: f.name, url: f.avatarUrl),
                title: Text(f.name),
                onTap: () => Navigator.pop(ctx, f),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      await Navigator.pushNamed(context, Routes.chat, arguments: picked.id);
      unawaited(_load());
    }
  }

  Future<void> _menu(Conversation c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              key: const Key('conv_archive'),
              leading: Icon(
                c.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
              ),
              title: Text(c.archived ? 'Désarchiver' : 'Archiver'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              key: const Key('conv_mute'),
              leading: Icon(
                c.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(
                c.muted ? 'Réactiver les notifications' : 'Mettre en silence',
              ),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
            ListTile(
              key: const Key('conv_clear'),
              leading: Icon(Icons.delete_outline, color: AppColors.redText),
              title: const Text('Supprimer la discussion'),
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'archive':
        await runAction(
          context,
          () => _chat.setArchived(c.friendId, !c.archived),
          success: c.archived
              ? 'Discussion désarchivée.'
              : 'Discussion archivée.',
        );
      case 'mute':
        await runAction(context, () => _chat.setMuted(c.friendId, !c.muted));
      case 'clear':
        final ok = await confirm(
          context,
          title: 'Supprimer la discussion ?',
          message:
              'Elle disparaît pour vous seulement : ${c.friendName} garde la sienne.',
          confirmLabel: 'Supprimer',
          destructive: true,
        );
        if (ok && mounted) {
          await runAction(context, () => _chat.clear(c.friendId));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchived ? 'Discussions archivées' : 'Messages'),
        actions: [
          IconButton(
            key: const Key('toggle_archived'),
            tooltip: _showArchived ? 'Retour aux messages' : 'Archivées',
            onPressed: () => setState(() => _showArchived = !_showArchived),
            icon: Icon(
              _showArchived ? Icons.inbox_outlined : Icons.archive_outlined,
            ),
          ),
        ],
      ),
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton(
              key: const Key('new_chat'),
              tooltip: 'Nouveau message',
              onPressed: _newChat,
              child: const Icon(Icons.edit_outlined),
            ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_chat, b.friends]),
        builder: (context, _) {
          if (_error != null && _chat.conversations.isEmpty) {
            return ErrorState(error: _error!, onRetry: _load);
          }
          final list = _showArchived ? _chat.archived : _chat.conversations;
          if (list.isEmpty) {
            return EmptyState(
              icon: _showArchived
                  ? Icons.archive_outlined
                  : Icons.chat_bubble_outline,
              title: _showArchived
                  ? 'Aucune discussion archivée'
                  : 'Aucune discussion',
              message: _showArchived
                  ? 'Les discussions que vous archivez apparaissent ici.'
                  : 'Écrivez à un ami avec le bouton en bas à droite.',
            );
          }
          final now = b.now();
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              padding: pagePadding(context, maxWidth: 760),
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = list[i];
                final unread = c.unread > 0 && !c.muted;
                Friend? friend;
                for (final f in b.friends.friends) {
                  if (f.id == c.friendId) friend = f;
                }
                final online = friend != null && b.friends.isOnline(friend);
                return ListTile(
                  key: Key('conv_${c.friendId}'),
                  contentPadding: EdgeInsets.zero,
                  leading: FriendAvatar(
                    name: c.friendName,
                    url: c.avatarUrl,
                    online: friend == null ? null : online,
                  ),
                  title: Text(
                    c.friendName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.subtitle(size: 15),
                  ),
                  subtitle: Text(
                    '${c.lastMine ? 'Vous : ' : ''}${c.lastPreview}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body(
                      size: 13,
                      color: unread ? AppColors.ink : AppColors.inkSoft,
                    ),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        Fmt.relative(c.lastAt.toLocal(), now: now),
                        style: AppText.label(size: 11),
                      ),
                      const SizedBox(height: 4),
                      if (c.muted)
                        Icon(
                          Icons.notifications_off_outlined,
                          size: 16,
                          color: AppColors.inkSoft,
                        )
                      else if (unread)
                        Pill('${c.unread}', color: AppColors.red),
                    ],
                  ),
                  onTap: () async {
                    await Navigator.pushNamed(
                      context,
                      Routes.chat,
                      arguments: c.friendId,
                    );
                    unawaited(_load());
                  },
                  onLongPress: () => _menu(c),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

// =========================================================================
// Discussion
// =========================================================================

/// Une discussion avec un ami.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.friendId});
  final String friendId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _showEmoji = false;
  bool _loading = true;
  Object? _error;

  ChatService get _chat => Backend.I.chat;

  Friend? get _friend {
    for (final f in Backend.I.friends.friends) {
      if (f.id == widget.friendId) return f;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    unawaited(_open());
  }

  Future<void> _open() async {
    _chat.setActive(widget.friendId);
    try {
      await _chat.open(widget.friendId);
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chat.setActive(null);
    _chat.stopTyping(widget.friendId);
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_chat.markRead(widget.friendId));
    }
  }

  void _onScroll() {
    // La liste est inversée : le « haut » de la discussion est le maximum.
    if (_scroll.hasClients &&
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      unawaited(_chat.loadMore(widget.friendId).catchError((Object _) {}));
    }
  }

  Future<void> _send() async {
    final text = _text.text;
    if (text.trim().isEmpty) return;
    _text.clear();
    setState(() {});
    try {
      await _chat.send(widget.friendId, text);
    } catch (e) {
      // Le message reste affiché avec « Échec » : on peut réessayer.
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _messageMenu(ChatMessage m) async {
    if (m.deleted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            if (m.state == SendState.failed)
              ListTile(
                key: const Key('msg_retry'),
                leading: const Icon(Icons.refresh),
                title: const Text('Réessayer'),
                onTap: () => Navigator.pop(ctx, 'retry'),
              ),
            if (m.kind == MessageKind.text && m.text != null)
              ListTile(
                key: const Key('msg_copy'),
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copier'),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
            ListTile(
              key: const Key('msg_delete_me'),
              leading: const Icon(Icons.delete_outline),
              title: const Text('Supprimer pour moi'),
              onTap: () => Navigator.pop(ctx, 'me'),
            ),
            if (m.mine && !m.isLocal)
              ListTile(
                key: const Key('msg_delete_all'),
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: AppColors.redText,
                ),
                title: const Text('Supprimer pour tout le monde'),
                onTap: () => Navigator.pop(ctx, 'all'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'retry':
        await runAction(context, () => _chat.retry(widget.friendId, m.id));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text ?? ''));
        if (mounted) showSnack(context, 'Message copié.');
      case 'me':
        await runAction(
          context,
          () => _chat.delete(widget.friendId, m, forAll: false),
        );
      case 'all':
        final ok = await confirm(
          context,
          title: 'Supprimer pour tout le monde ?',
          message:
              'Le message disparaît chez vous et chez votre ami. Une trace '
              '« Ce message a été supprimé » reste dans la discussion.',
          confirmLabel: 'Supprimer',
          destructive: true,
        );
        if (ok && mounted) {
          await runAction(
            context,
            () => _chat.delete(widget.friendId, m, forAll: true),
          );
        }
    }
  }

  Future<void> _headerMenu(String action) async {
    final id = widget.friendId;
    final name = _friend?.name ?? 'cette personne';
    switch (action) {
      case 'mute':
        final muted = _chat.thread(id).info.muted;
        await runAction(
          context,
          () => _chat.setMuted(id, !muted),
          success: muted
              ? 'Notifications réactivées.'
              : 'Discussion en silence.',
        );
      case 'archive':
        final ok = await runAction(
          context,
          () => _chat.setArchived(id, true),
          success: 'Discussion archivée.',
        );
        if (ok && mounted) Navigator.pop(context);
      case 'clear':
        final ok = await confirm(
          context,
          title: 'Supprimer la discussion ?',
          message:
              'Elle disparaît pour vous seulement : $name garde la sienne.',
          confirmLabel: 'Supprimer',
          destructive: true,
        );
        if (ok && mounted) await runAction(context, () => _chat.clear(id));
      case 'report':
        await Navigator.pushNamed(context, Routes.chatReport, arguments: id);
      case 'block':
        final ok = await confirm(
          context,
          title: 'Bloquer $name ?',
          message:
              'Vous ne serez plus amis et plus aucun message ne passera. '
              '$name ne saura pas que vous l\'avez bloqué(e).',
          confirmLabel: 'Bloquer',
          destructive: true,
        );
        if (ok && mounted) {
          final done = await runAction(
            context,
            () => _chat.block(id),
            success: '$name est bloqué(e).',
          );
          if (done && mounted) Navigator.pop(context);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return ListenableBuilder(
      listenable: Listenable.merge([_chat.thread(widget.friendId), b.friends]),
      builder: (context, _) {
        final friend = _friend;
        final thread = _chat.thread(widget.friendId);
        final now = b.friends.serverNow();
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: friend == null
                ? const Text('Discussion')
                : Row(
                    children: [
                      FriendAvatar(
                        name: friend.name,
                        url: friend.avatarUrl,
                        size: 36,
                        online: friend.isOnline(now),
                      ),
                      const SizedBox(width: Gap.s),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              friend.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.subtitle(
                                color: AppColors.white,
                                size: 16,
                              ),
                            ),
                            Text(
                              thread.peerTyping
                                  ? 'est en train d\'écrire…'
                                  : friend.presenceLabel(now),
                              key: const Key('chat_status'),
                              style: AppText.label(
                                color: AppColors.creamText,
                                size: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
            actions: [
              if (friend != null)
                PopupMenuButton<String>(
                  key: const Key('chat_menu'),
                  onSelected: _headerMenu,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'mute',
                      child: Text(
                        thread.info.muted
                            ? 'Réactiver les notifications'
                            : 'Mettre en silence',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'archive',
                      child: Text('Archiver'),
                    ),
                    const PopupMenuItem(
                      value: 'clear',
                      child: Text('Supprimer la discussion'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'report',
                      child: Text('Signaler la discussion'),
                    ),
                    const PopupMenuItem(value: 'block', child: Text('Bloquer')),
                  ],
                ),
            ],
          ),
          body: _body(friend, thread),
        );
      },
    );
  }

  Widget _body(Friend? friend, ChatThread thread) {
    if (_loading && !thread.loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (friend == null) {
      return const EmptyState(
        icon: Icons.person_off_outlined,
        title: 'Cette personne n\'est plus dans vos amis',
        message: 'La discussion n\'est plus disponible.',
      );
    }
    if (_error != null && !thread.loaded) {
      return ErrorState(
        error: _error!,
        onRetry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          unawaited(_open());
        },
      );
    }
    final now = Backend.I.now();
    final msgs = thread.messages;
    // Du plus récent au plus ancien (la liste est inversée) ; le séparateur
    // de jour se place juste après le premier message du jour.
    final items = <Object>[];
    for (var i = msgs.length - 1; i >= 0; i--) {
      items.add(msgs[i]);
      final day = msgs[i].createdAt.toLocal();
      if (i == 0 || !_sameDay(msgs[i - 1].createdAt.toLocal(), day)) {
        items.add(_dayLabel(day, now));
      }
    }
    String? lastMineId;
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].mine) {
        lastMineId = msgs[i].id;
        break;
      }
    }
    final read = thread.info.peerReadAt;
    return Column(
      children: [
        Expanded(
          child: msgs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Text(
                      'Écrivez le premier message à ${friend.name}.',
                      textAlign: TextAlign.center,
                      style: AppText.body(color: AppColors.inkSoft),
                    ),
                  ),
                )
              : ListView.builder(
                  key: const Key('chat_list'),
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.m,
                    vertical: Gap.s,
                  ),
                  itemCount: items.length + (thread.loadingMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= items.length) {
                      return const Padding(
                        padding: EdgeInsets.all(Gap.s),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final item = items[i];
                    if (item is String) return _DaySeparator(item);
                    final m = item as ChatMessage;
                    final seen =
                        read != null &&
                        !m.isLocal &&
                        !m.createdAt.isAfter(read);
                    return _Bubble(
                      message: m,
                      status: m.id == lastMineId ? _statusOf(m, seen) : null,
                      onLongPress: () => _messageMenu(m),
                      onRetry: m.state == SendState.failed
                          ? () => runAction(
                              context,
                              () => _chat.retry(widget.friendId, m.id),
                            )
                          : null,
                    );
                  },
                ),
        ),
        _inputBar(),
      ],
    );
  }

  String _statusOf(ChatMessage m, bool seen) {
    switch (m.state) {
      case SendState.sending:
        return 'Envoi…';
      case SendState.failed:
        return 'Échec · appuyez pour réessayer';
      case SendState.sent:
        return seen ? 'Vu' : 'Envoyé';
    }
  }

  Widget _inputBar() {
    final bar = Material(
      color: AppColors.surface,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.s, Gap.xs, Gap.s, Gap.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                key: const Key('chat_emoji'),
                tooltip: _showEmoji ? 'Clavier' : 'Emojis',
                color: AppColors.heading,
                onPressed: () {
                  setState(() => _showEmoji = !_showEmoji);
                  if (_showEmoji) {
                    _focus.unfocus();
                  } else {
                    _focus.requestFocus();
                  }
                },
                icon: Icon(
                  _showEmoji
                      ? Icons.keyboard_alt_outlined
                      : Icons.emoji_emotions_outlined,
                ),
              ),
              IconButton(
                key: const Key('chat_attach'),
                tooltip: 'Partager une séance, un workout…',
                color: AppColors.heading,
                onPressed: () => showSharePicker(context, widget.friendId),
                icon: const Icon(Icons.add_circle_outline),
              ),
              Expanded(
                child: TextField(
                  key: const Key('chat_input'),
                  controller: _text,
                  focusNode: _focus,
                  onTap: () {
                    if (_showEmoji) setState(() => _showEmoji = false);
                  },
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(maxMessageLength),
                  ],
                  decoration: const InputDecoration(
                    hintText: 'Votre message',
                    border: InputBorder.none,
                    filled: false,
                  ),
                  onChanged: (v) {
                    setState(() {});
                    _chat.userTyping(widget.friendId, v.trim().isNotEmpty);
                  },
                ),
              ),
              IconButton(
                key: const Key('chat_send'),
                tooltip: 'Envoyer',
                color: AppColors.redText,
                onPressed: _text.text.trim().isEmpty ? null : _send,
                icon: const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [bar, if (_showEmoji) _emojiPanel()],
    );
  }

  Future<void> _sendEmoji(String emoji) async {
    try {
      await _chat.send(widget.friendId, emoji);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  /// Réactions rapides (envoyées tout de suite, animées) puis tous les
  /// emojis (ajoutés au texte en cours de saisie, recherche en français).
  Widget _emojiPanel() {
    return Material(
      key: const Key('emoji_panel'),
      color: AppColors.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                children: [
                  for (final e in Emojis.quickReactions)
                    InkWell(
                      key: Key('react_$e'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _sendEmoji(e),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: EmojiView(e, size: 40),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              height: 260,
              child: EmojiPicker(
                key: const Key('emoji_picker'),
                textEditingController: _text,
                onEmojiSelected: (_, _) {
                  setState(() {});
                  _chat.userTyping(widget.friendId, _text.text.trim().isNotEmpty);
                },
                onBackspacePressed: () => setState(() {}),
                config: Config(
                  height: 260,
                  locale: const Locale('fr'),
                  checkPlatformCompatibility: false,
                  emojiViewConfig: EmojiViewConfig(
                    columns: 8,
                    emojiSizeMax: 30,
                    backgroundColor: AppColors.surface,
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    backgroundColor: AppColors.surface,
                    indicatorColor: AppColors.red,
                    iconColor: AppColors.inkSoft,
                    iconColorSelected: AppColors.red,
                    backspaceColor: AppColors.red,
                  ),
                  bottomActionBarConfig: BottomActionBarConfig(
                    backgroundColor: AppColors.navy,
                    buttonColor: AppColors.heading,
                  ),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: AppColors.surface,
                    hintText: 'Rechercher un emoji',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Gap.s),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label, style: AppText.label(size: 12)),
      ),
    ),
  );
}

/// Une bulle de message (moi à droite, l'autre à gauche).
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.onLongPress,
    this.status,
    this.onRetry,
  });

  final ChatMessage message;
  final String? status;
  final VoidCallback onLongPress;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final mine = m.mine;
    final deleted = m.deleted;
    final emojiOnly =
        !deleted &&
        m.kind == MessageKind.text &&
        m.text != null &&
        Emojis.isEmojiOnly(m.text!);
    final fg = deleted
        ? AppColors.inkSoft
        : (mine ? AppColors.white : AppColors.ink);
    final bg = deleted
        ? AppColors.background
        : (mine ? AppColors.navy : AppColors.surface);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: onLongPress,
            onTap: onRetry,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.78,
              ),
              child: Container(
                key: Key('msg_${m.id}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: emojiOnly
                    ? null
                    : BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(16),
                        border: deleted || !mine
                            ? Border.all(color: AppColors.divider)
                            : null,
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (deleted)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.block, size: 14, color: fg),
                          const SizedBox(width: 6),
                          Text(
                            'Ce message a été supprimé',
                            style: AppText.body(
                              size: 14,
                              color: fg,
                            ).copyWith(fontStyle: FontStyle.italic),
                          ),
                        ],
                      )
                    else if (emojiOnly)
                      EmojiOnlyContent(m.text!)
                    else if (m.share != null)
                      ShareCardBubble(card: m.share!, mine: mine)
                    else
                      Text(m.preview, style: AppText.body(size: 15, color: fg)),
                    const SizedBox(height: 2),
                    Text(
                      _clock(m.createdAt),
                      style: AppText.label(
                        size: 10,
                        color: deleted
                            ? AppColors.inkSoft
                            : (mine ? AppColors.navyMuted : AppColors.inkSoft),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: Text(
                status!,
                key: const Key('msg_status'),
                style: AppText.label(
                  size: 11,
                  color: status!.startsWith('Échec')
                      ? AppColors.red
                      : AppColors.inkSoft,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =========================================================================
// Signaler une discussion
// =========================================================================

/// Signaler la **discussion** : on choisit les messages (au moins un) et on
/// peut ajouter une remarque. Distinct du signalement d'une personne, qui se
/// fait depuis la liste d'amis.
class ReportConversationScreen extends StatefulWidget {
  const ReportConversationScreen({super.key, required this.friendId});
  final String friendId;

  @override
  State<ReportConversationScreen> createState() =>
      _ReportConversationScreenState();
}

class _ReportConversationScreenState extends State<ReportConversationScreen> {
  final _remark = TextEditingController();
  final Set<String> _selected = {};
  List<ChatMessage>? _messages;
  Object? _error;
  bool _alsoBlock = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final list = await Backend.I.chat.messagesForReport(widget.friendId);
      if (mounted) {
        setState(() {
          _messages = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      () => Backend.I.chat.reportConversation(
        widget.friendId,
        _selected.toList(),
        remark: _remark.text,
        alsoBlock: _alsoBlock,
      ),
      success: 'Merci. Le signalement a été transmis à la salle.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final friend = Backend.I.friends.friends
        .where((f) => f.id == widget.friendId)
        .firstOrNull;
    final name = friend?.name ?? 'cette personne';
    final msgs = _messages;
    return Scaffold(
      appBar: AppBar(title: const Text('Signaler la discussion')),
      body: _error != null && msgs == null
          ? ErrorState(error: _error!, onRetry: _load)
          : msgs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: pagePadding(context, maxWidth: 760),
              children: [
                Text('Discussion avec $name', style: AppText.title(size: 18)),
                const SizedBox(height: Gap.xs),
                Text(
                  'Cochez les messages à transmettre à la salle (au moins un). '
                  'Seuls ces messages seront lus par l\'administrateur, et '
                  '$name ne sera pas prévenu(e).',
                  style: AppText.body(size: 14, color: AppColors.inkSoft),
                ),
                const SizedBox(height: Gap.m),
                if (msgs.isEmpty)
                  const GfCard(
                    child: InfoRow(
                      Icons.chat_bubble_outline,
                      'Aucun message à signaler dans cette discussion.',
                    ),
                  )
                else
                  GfCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final m in msgs)
                          CheckboxListTile(
                            key: Key('report_msg_${m.id}'),
                            value: _selected.contains(m.id),
                            onChanged: (v) => setState(() {
                              v == true
                                  ? _selected.add(m.id)
                                  : _selected.remove(m.id);
                            }),
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(
                              m.preview,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${m.mine ? 'Vous' : name} · '
                              '${Fmt.date(m.createdAt.toLocal())} '
                              '${_clock(m.createdAt)}',
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: Gap.m),
                TextField(
                  key: const Key('report_remark'),
                  controller: _remark,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Remarque (facultatif)',
                    hintText:
                        'Dites-nous en quelques mots ce qui pose problème.',
                    alignLabelWithHint: true,
                  ),
                ),
                CheckboxListTile(
                  key: const Key('report_block'),
                  value: _alsoBlock,
                  onChanged: (v) => setState(() => _alsoBlock = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Bloquer aussi $name'),
                  subtitle: const Text(
                    'Vous ne serez plus amis et plus aucun message ne passera.',
                  ),
                ),
                const SizedBox(height: Gap.s),
                ElevatedButton.icon(
                  key: const Key('report_submit'),
                  onPressed: _selected.isEmpty || _busy ? null : _submit,
                  icon: const Icon(Icons.flag_outlined),
                  label: Text(
                    _selected.isEmpty
                        ? 'Sélectionnez au moins un message'
                        : 'Signaler (${_selected.length})',
                  ),
                ),
              ],
            ),
    );
  }
}
