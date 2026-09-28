import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/message_controller.dart';
import '../../models/chat_message.dart';
import '../theme.dart';
import 'kiosk_scroll_behavior.dart';

/// Scrollable feed of "message" emails, each rendered as "sender - text".
/// Lives in its own bordered container so mouse-wheel or touch scrolling is
/// obviously scoped to the feed rather than the whole column, and long
/// messages wrap instead of overflowing it.
class MessagePanel extends StatelessWidget {
  const MessagePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final messages = context.watch<MessageController>().messages;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: DashTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DashTheme.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: messages.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'No messages yet',
                style: TextStyle(color: DashTheme.inkFaint, fontSize: 16),
              ),
            )
          : ScrollConfiguration(
              behavior: const KioskScrollBehavior(),
              child: RawScrollbar(
                thumbVisibility: true,
                thickness: 5,
                radius: const Radius.circular(3),
                thumbColor: DashTheme.inkFaint.withValues(alpha: 0.55),
                child: ListView.separated(
                  padding: const EdgeInsets.all(14),
                  physics: const ClampingScrollPhysics(),
                  itemCount: messages.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 18,
                    thickness: 1,
                    color: DashTheme.line,
                  ),
                  itemBuilder: (context, i) =>
                      _MessageTile(message: messages[i]),
                ),
              ),
            ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    // Text.rich rather than RichText: RichText ignores the ambient
    // DefaultTextStyle, so a message never picked up the theme's emoji
    // fallback and anything outside the body font's coverage drew as a box --
    // while the same character in a notice, which is a plain Text, came out
    // fine. Styling the span tree from the outside in keeps the fallback.
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${message.sender} - ',
            style: const TextStyle(
              color: DashTheme.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: message.text),
        ],
      ),
      style: const TextStyle(
        color: DashTheme.ink,
        fontSize: 17,
        height: 1.35,
      ),
    );
  }
}
