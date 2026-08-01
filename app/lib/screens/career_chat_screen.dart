import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/chat_message.dart';
import '../services/career_chat.dart';
import '../services/haptic_service.dart';
import '../services/refresh_throttle.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/agent_mascot.dart';
import '../widgets/agent_orb.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';

/// §4.10 Career chat — the grounded career assistant. Header (back / "Career
/// agent" / new-chat) · mascot greeting when empty · user/agent bubbles · a
/// typing indicator while the reply is in flight · horizontally-scrolling
/// example chips · an input bar with the "◍ Agent" model chip and send.
///
/// All grounding + anti-fabrication is server-side; this screen just renders the
/// conversation [ChatController] drives. Pushed above the shell (see app_router).
class CareerChatScreen extends ConsumerStatefulWidget {
  const CareerChatScreen({super.key});

  @override
  ConsumerState<CareerChatScreen> createState() => _CareerChatScreenState();
}

class _CareerChatScreenState extends ConsumerState<CareerChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// The starter prompts from §4.10 (prototype `CHAT_EXAMPLES`). Tapping one
  /// sends it straight away, like the prototype's `chatAsk`.
  static const _examples = [
    'What roles am I closest to?',
    'What skills am I missing?',
    'Which match should I prioritize?',
    'How do I stand out for these?',
    'How do I explain my career gap?',
  ];

  @override
  void initState() {
    super.initState();
    // Load history after the first frame so the provider is safe to mutate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatControllerProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    // Post-frame: the new bubble/typing row has to be laid out before its
    // extent exists to scroll to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    HapticService.instance.selection();
    _input.clear();
    ref.read(chatControllerProvider.notifier).send(text);
  }

  void _newChat() {
    HapticService.instance.selection();
    _input.clear();
    ref.read(chatControllerProvider.notifier).newChat();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatControllerProvider);

    // Auto-scroll on any new turn or when the typing indicator appears.
    ref.listen(chatControllerProvider, (prev, next) {
      if (prev == null) return;
      if (next.messages.length != prev.messages.length || next.sending != prev.sending) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      backgroundColor: context.c.paper,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(child: _scrollArea(state)),
            _composer(state),
          ],
        ),
      ),
    );
  }

  void _openThread(String threadId) {
    HapticService.instance.selection();
    ref.read(chatControllerProvider.notifier).openThread(threadId);
  }

  /// The "Recent chats" bottom sheet: every past conversation, newest first,
  /// with pull-to-refresh and the last-updated line (§ADR-028 pattern).
  void _showRecentChats() {
    HapticService.instance.selection();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.c.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => _RecentChatsSheet(
        onOpen: (id) {
          Navigator.of(context).pop();
          _openThread(id);
        },
        onNewChat: () {
          Navigator.of(context).pop();
          _newChat();
        },
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _iconButton(AppIconName.chevronLeft, () => context.pop()),
          Text(
            'Career agent',
            style: AppTypography.title.copyWith(fontSize: 15),
          ),
          Row(
            children: [
              _iconButton(AppIconName.clock, _showRecentChats),
              const SizedBox(width: 8),
              _iconButton(AppIconName.edit, _newChat),
            ],
          ),
        ],
      ),
    );
  }

  /// The two 38×38 bordered header buttons (back, new-chat).
  Widget _iconButton(AppIconName icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: context.c.surface,
          border: Border.all(color: context.c.border),
          borderRadius: BorderRadius.circular(11),
        ),
        child: AppIcon(icon, size: 18, color: context.c.ink),
      ),
    );
  }

  Widget _scrollArea(ChatState state) {
    if (state.initialLoading) {
      return const Center(child: AppLoader());
    }
    if (state.isEmpty) {
      return _greeting(state);
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      children: [
        for (final m in state.messages) ...[
          _bubble(m),
          const SizedBox(height: 12),
        ],
        if (state.sending) _typingIndicator(),
        if (state.sendError != null) _errorRow(state.sendError!),
      ],
    );
  }

  /// Empty state: mascot + "Hey {name}, how can I help your career?" — and,
  /// once there's history, the last few conversations so getting back into one
  /// is a tap rather than a re-explanation.
  Widget _greeting(ChatState state) {
    final recent = state.otherThreads.take(4).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: AgentMascot(size: 56),
          ),
          Text(
            'Hey ${state.greetingName},\nhow can I help your career?',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 27,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: context.c.ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Ask about your fit, salary, skills to grow, or how to stand out. '
            'I know your résumé and matches.',
            style: AppTypography.bodySm.copyWith(
              height: 1.5,
              color: context.c.inkSoft,
            ),
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 26),
            Row(
              children: [
                Text('Recent chats', style: AppTypography.title.copyWith(fontSize: 14)),
                const Spacer(),
                if (state.threads.length > recent.length)
                  GestureDetector(
                    onTap: _showRecentChats,
                    child: Text(
                      'See all',
                      style: AppTypography.caption.copyWith(
                        color: context.c.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            for (final thread in recent) ...[
              ChatThreadRow(thread: thread, onTap: () => _openThread(thread.id)),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }

  /// One conversation bubble — user right (accent), agent left (surface).
  Widget _bubble(ChatMessage m) {
    final isUser = m.isUser;
    final bubbleStyle = GoogleFonts.plusJakartaSans(
      fontSize: 13.5,
      height: 1.5,
      fontWeight: FontWeight.w400,
      color: isUser ? context.onAccent : context.c.ink,
    );
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * (isUser ? 0.82 : 0.88),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isUser ? context.c.accent : context.c.surface,
            border: isUser ? null : Border.all(color: context.c.border),
            // Tail on the sender's side (bottom-right for user, bottom-left agent).
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
          ),
          child: Text(m.content, style: bubbleStyle),
        ),
      ),
    );
  }

  /// The "agent is thinking" row: small orb + three pulsing dots.
  Widget _typingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AgentOrb(size: 26),
          const SizedBox(width: 9),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: context.c.surface,
              border: Border.all(color: context.c.border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const _TypingDots(),
          ),
        ],
      ),
    );
  }

  /// A failed turn keeps its user bubble; this row explains + offers Retry.
  Widget _errorRow(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.c.critical.withValues(alpha: 0.12),
        border: Border.all(color: context.c.critical.withValues(alpha: 0.30)),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Row(
        children: [
          AppIcon(AppIconName.alertTriangle, size: 18, color: context.c.critical),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTypography.bodySm.copyWith(color: context.c.critical),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => ref.read(chatControllerProvider.notifier).retry(),
            child: Text(
              'Retry',
              style: AppTypography.bodySm.copyWith(
                fontWeight: FontWeight.w700,
                color: context.c.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(ChatState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Horizontally-scrolling example chips.
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: _examples.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => _exampleChip(_examples[i], state.sending),
            ),
          ),
          const SizedBox(height: 12),
          _inputBar(state),
        ],
      ),
    );
  }

  Widget _exampleChip(String text, bool disabled) {
    return GestureDetector(
      onTap: disabled ? null : () => _send(text),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: context.c.surface,
          border: Border.all(color: context.c.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          text,
          style: AppTypography.caption.copyWith(
            fontSize: 12.5,
            color: context.c.ink,
          ),
        ),
      ),
    );
  }

  Widget _inputBar(ChatState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 7, 8, 7),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border.all(color: context.c.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          // The "◍ Agent" model chip — signals which provider is answering.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: context.c.accentSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '◍ Agent',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.c.accent,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: state.sending ? null : _send,
              style: AppTypography.bodySm.copyWith(fontSize: 13.5),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Ask about your career…',
                hintStyle: AppTypography.bodySm.copyWith(
                  fontSize: 13.5,
                  color: context.c.inkFaint,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _sendButton(state.sending),
        ],
      ),
    );
  }

  Widget _sendButton(bool sending) {
    return GestureDetector(
      onTap: sending ? null : () => _send(_input.text),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          // Dim while a turn is in flight — the controller ignores a second
          // send anyway, this just makes that visible.
          color: sending ? context.c.accent.withValues(alpha: 0.45) : context.c.accent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: AppIcon(AppIconName.send, size: 18, color: context.onAccent),
      ),
    );
  }
}

/// One past conversation: the thread's title (seeded server-side from the first
/// message) and when it was last active. Shared by the greeting's short list and
/// the full recent-chats sheet.
class ChatThreadRow extends StatelessWidget {
  const ChatThreadRow({super.key, required this.thread, required this.onTap, this.isOpen = false});

  final ChatThread thread;
  final VoidCallback onTap;

  /// The conversation currently on screen — marked, and still tappable.
  final bool isOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surface,
      borderRadius: AppRadius.mdRadius,
      child: InkWell(
        borderRadius: AppRadius.mdRadius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            border: Border.all(color: isOpen ? c.accent : c.border),
            borderRadius: AppRadius.mdRadius,
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.accentSoft, borderRadius: AppRadius.smRadius),
                child: AppIcon(AppIconName.messageCircle, size: 16, color: c.accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      thread.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (thread.updatedAt != null)
                      Text(
                        _relative(thread.updatedAt!),
                        style: AppTypography.caption.copyWith(fontSize: 11.5, color: c.inkFaint),
                      ),
                  ],
                ),
              ),
              if (isOpen)
                Text(
                  'OPEN',
                  style: AppTypography.label.copyWith(color: c.accent, letterSpacing: 0.6),
                )
              else
                AppIcon(AppIconName.chevronRight, size: 16, color: c.inkFaint),
            ],
          ),
        ),
      ),
    );
  }

  static String _relative(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month - 1]} ${t.day}';
  }
}

/// The full conversation history, in a bottom sheet: cached list painted
/// instantly, pull-to-refresh, and the "Updated …" line so the passive
/// freshness window is visible rather than looking stuck.
class _RecentChatsSheet extends ConsumerWidget {
  const _RecentChatsSheet({required this.onOpen, required this.onNewChat});

  final ValueChanged<String> onOpen;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final c = context.c;
    final label = lastUpdatedLabel(state.threadsUpdatedAt);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: c.border, borderRadius: AppRadius.pillRadius),
              ),
            ),
            Row(
              children: [
                Text('Recent chats', style: AppTypography.headingSm),
                const Spacer(),
                TextButton.icon(
                  onPressed: onNewChat,
                  icon: AppIcon(AppIconName.edit, size: 15, color: c.accent),
                  label: const Text('New chat'),
                ),
              ],
            ),
            if (label != null || state.refreshing)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  state.refreshing ? 'Refreshing…' : '$label · pull to refresh',
                  style: AppTypography.caption.copyWith(color: c.inkFaint),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => ref.read(chatControllerProvider.notifier).refresh(),
                child: state.threads.isEmpty
                    ? ListView(
                        controller: scrollController,
                        children: [
                          const SizedBox(height: AppSpacing.space8),
                          EmptyState(
                            icon: AppIconName.messageCircle,
                            title: 'No chats yet',
                            message: 'Ask the agent something and the conversation shows up here.',
                          ),
                        ],
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.only(top: 4, bottom: AppSpacing.space6),
                        itemCount: state.threads.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final thread = state.threads[i];
                          return ChatThreadRow(
                            thread: thread,
                            isOpen: thread.id == state.threadId,
                            onTap: () => onOpen(thread.id),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three dots that pulse in sequence — the chat typing animation.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              _dot(i),
            ],
          ],
        );
      },
    );
  }

  Widget _dot(int i) {
    // Each dot leads the next by a phase, so the pulse ripples left→right.
    final phase = (_ac.value - i * 0.2) % 1.0;
    final t = (phase < 0.5) ? phase * 2 : (1 - phase) * 2; // 0→1→0 triangle
    return Opacity(
      opacity: 0.35 + 0.65 * t,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: context.c.inkFaint,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
