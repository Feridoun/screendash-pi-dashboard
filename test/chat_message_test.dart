import 'package:flutter_test/flutter_test.dart';

import 'package:screendash/models/chat_message.dart';

void main() {
  group('stripOrganisation', () {
    test('drops the organisation name corporate directories append', () {
      expect(
        stripOrganisation('SMITH, Alex (NORTHERN REGIONAL SERVICES)'),
        'SMITH, Alex',
      );
    });

    test('drops several trailing brackets', () {
      expect(stripOrganisation('Doe, Bob (ACME) (NORTH)'), 'Doe, Bob');
    });

    test('leaves a plain name alone', () {
      expect(stripOrganisation('Jane Doe'), 'Jane Doe');
      expect(stripOrganisation('jane@example.com'), 'jane@example.com');
    });

    test('keeps brackets that are all there is, rather than emptying', () {
      expect(stripOrganisation('(SOME ORG NAME)'), '(SOME ORG NAME)');
    });

    test('leaves brackets that are not trailing', () {
      expect(stripOrganisation('O(Brien), Pat'), 'O(Brien), Pat');
    });
  });

  test('ChatMessage.fromJson strips the organisation off the sender', () {
    final message = ChatMessage.fromJson(const {
      'sender': 'SMITH, Alex (NORTHERN REGIONAL SERVICES)',
      'text': 'Morning all',
      'sent': '2026-07-31T09:00:00Z',
    });

    expect(message.sender, 'SMITH, Alex');
    expect(message.text, 'Morning all');
  });
}
