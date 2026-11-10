import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/backend.dart';
import '../../services/training_chat_service.dart';

Future<void> showTrainingCoachChat(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppColors.background,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => const _TrainingCoachChatSheet(),
    );

class _TrainingCoachChatSheet extends StatefulWidget {
  const _TrainingCoachChatSheet();

  @override
  State<_TrainingCoachChatSheet> createState() =>
      _TrainingCoachChatSheetState();
}

class _TrainingCoachChatSheetState extends State<_TrainingCoachChatSheet> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <TrainingChatMessage>[];
  final _chat = TrainingChatService(Backend.I);
  bool _waiting = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? suggestion]) async {
    final question = (suggestion ?? _input.text).trim();
    if (question.isEmpty || _waiting) return;

    final history = List<TrainingChatMessage>.of(_messages);
    setState(() {
      _messages.add(TrainingChatMessage(true, question));
      _waiting = true;
      _input.clear();
    });
    _toBottom();

    final answer = await _chat.ask(question, history);
    if (!mounted) return;
    setState(() {
      _messages.add(TrainingChatMessage(false, answer));
      _waiting = false;
    });
    _toBottom();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final enabled = _chat.enabled;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.76,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.s),
              child: Row(
                children: [
                  Icon(Icons.fitness_center, color: AppColors.redText),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: Text(
                      'Coach sport et bien-être',
                      style: AppText.title(size: 18),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _messages.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(Gap.m),
                      children: [
                        Text(
                          'Posez vos questions sur les exercices, le sport, '
                          'la récupération ou l’alimentation équilibrée. '
                          'Les réponses sont des informations générales et '
                          'ne remplacent pas un professionnel de santé.',
                          style: AppText.body(color: AppColors.inkSoft),
                        ),
                        if (!enabled) ...[
                          const SizedBox(height: Gap.m),
                          Text(
                            'Le coach sport et bien-être est temporairement '
                            'indisponible.',
                            key: const Key('training_chat_unavailable'),
                            style: AppText.body(color: AppColors.redText),
                          ),
                        ] else ...[
                          const SizedBox(height: Gap.m),
                          for (final suggestion in const [
                            'Comment bien commencer la musculation ?',
                            'Propose un échauffement avant le cardio',
                            'Comment récupérer après une séance ?',
                            'Que manger après le sport, en général ?',
                          ])
                            Padding(
                              padding: const EdgeInsets.only(bottom: Gap.s),
                              child: ActionChip(
                                label: Text(suggestion),
                                onPressed: () => _send(suggestion),
                              ),
                            ),
                        ],
                      ],
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(Gap.m),
                      itemCount: _messages.length + (_waiting ? 1 : 0),
                      itemBuilder: (_, index) {
                        if (index == _messages.length) {
                          return const Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.all(Gap.s),
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        final message = _messages[index];
                        return Align(
                          alignment: message.fromUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: Gap.s),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            constraints: const BoxConstraints(maxWidth: 420),
                            decoration: BoxDecoration(
                              color: message.fromUser
                                  ? AppColors.navy
                                  : AppColors.surface,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: SelectableText(
                              message.text,
                              style: AppText.body(
                                size: 14,
                                color: message.fromUser
                                    ? AppColors.white
                                    : AppColors.ink,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (enabled)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Gap.m,
                    Gap.s,
                    Gap.s,
                    Gap.m,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('training_chat_input'),
                          controller: _input,
                          maxLength: 500,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Votre question…',
                            counterText: '',
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton.filled(
                        key: const Key('training_chat_send'),
                        tooltip: 'Envoyer',
                        onPressed: _waiting ? null : _send,
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.red,
                          foregroundColor: AppColors.white,
                        ),
                        icon: const Icon(Icons.send),
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
}
