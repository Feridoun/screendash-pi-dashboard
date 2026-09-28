import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/message_controller.dart';
import 'package:screendash/models/chat_message.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/ui/theme.dart';
import 'package:screendash/ui/widgets/message_panel.dart';

/// A controller whose feed is set directly, so the panel can be pumped without
/// a backend.
class _FakeMessages extends MessageController {
  _FakeMessages(this._messages)
      : super(config: const AppConfig(), client: BackendClient());

  final List<ChatMessage> _messages;

  @override
  List<ChatMessage> get messages => _messages;
}

Widget _harness(MessageController messages) =>
    ChangeNotifierProvider<MessageController>.value(
      value: messages,
      child: MaterialApp(
        theme: DashTheme.build(),
        home: const Scaffold(
          body: Center(child: SizedBox(width: 640, child: MessagePanel())),
        ),
      ),
    );

void main() {
  group('MessagePanel', () {
    testWidgets('draws a message through the theme font, fallback and all',
        (tester) async {
      // The regression this guards: as a bare RichText the tile took no style
      // from the theme, so a message containing an emoji drew boxes on the
      // wall while the same character in a notice rendered.
      final messages = _FakeMessages(const [
        ChatMessage(sender: 'Lauren', text: 'Kettle is fixed 🎉'),
      ]);
      await tester.pumpWidget(_harness(messages));

      final style = (tester.widget<RichText>(find.byType(RichText)).text
              as TextSpan)
          .style!;
      expect(style.fontFamily, 'Roboto');
      expect(style.fontFamilyFallback, contains('NotoColorEmoji'));
      // The tile's own styling still wins over the inherited body style.
      expect(style.fontSize, 17);

      messages.client.close();
    });
  });
}
