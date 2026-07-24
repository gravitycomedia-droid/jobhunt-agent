import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/chat_message.dart';
import '../services/career_chat.dart';
import '../services/haptic_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/agent_mascot.dart';
import '../widgets/agent_orb.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';

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
      backgroundColor: AppColors.bg,
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
          _iconButton(AppIconName.edit, _newChat),
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
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(11),
        ),
        child: AppIcon(icon, size: 18, color: AppColors.textPrimary),
      ),
    );
  }

  Widget _scrollArea(ChatState state) {
    if (state.initialLoading) {
      return const Center(child: AppLoader());
    }
    if (state.isEmpty) {
      return _greeting(state.greetingName);
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

  /// Empty state: mascot + "Hey {name}, how can I help your career?".
  Widget _greeting(String name) {
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
            'Hey $name,\nhow can I help your career?',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 27,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Ask about your fit, salary, skills to grow, or how to stand out. '
            'I know your résumé and matches.',
            style: AppTypography.bodySm.copyWith(
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
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
      color: isUser ? AppColors.textOnBrand : AppColors.textPrimary,
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
            color: isUser ? AppColors.brand : AppColors.surface,
            border: isUser ? null : Border.all(color: AppColors.border),
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
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
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
        color: AppColors.criticalSoft,
        border: Border.all(color: AppColors.criticalBorder),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Row(
        children: [
          const AppIcon(AppIconName.alertTriangle, size: 18, color: AppColors.criticalText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTypography.bodySm.copyWith(color: AppColors.criticalText),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => ref.read(chatControllerProvider.notifier).retry(),
            child: Text(
              'Retry',
              style: AppTypography.bodySm.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.brand,
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
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          text,
          style: AppTypography.caption.copyWith(
            fontSize: 12.5,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _inputBar(ChatState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 7, 8, 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          // The "◍ Agent" model chip — signals which provider is answering.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.brandSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '◍ Agent',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.brand,
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
                  color: AppColors.textTertiary,
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
          color: sending ? AppColors.brand.withValues(alpha: 0.45) : AppColors.brand,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const AppIcon(AppIconName.send, size: 18, color: AppColors.textOnBrand),
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
        decoration: const BoxDecoration(
          color: AppColors.textTertiary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
