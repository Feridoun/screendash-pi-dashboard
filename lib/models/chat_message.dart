import 'package:flutter/foundation.dart';

/// One recorded chat entry, from an email whose subject starts with
/// "message:".
@immutable
class ChatMessage {
  final String sender;
  final String text;
  final DateTime? sent;

  const ChatMessage({required this.sender, required this.text, this.sent});

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        sender: stripOrganisation(json['sender'] as String? ?? ''),
        text: json['text'] as String? ?? '',
        sent: DateTime.tryParse(json['sent'] as String? ?? '')?.toLocal(),
      );
}

/// Drop the trailing organisation that corporate directories append to a
/// display name — "SMITH, Alex (NORTHERN REGIONAL SERVICES)" is far too long
/// for a message line, and the org name says nothing the board needs.
///
/// The worker strips this when it records a message; this repeats it on the
/// way in so entries recorded before it did still read cleanly on the board.
///
/// Only trailing brackets go, and only while a name is left over, so a sender
/// whose whole display name is bracketed keeps it rather than becoming blank.
String stripOrganisation(String name) {
  final bracketed = RegExp(r'\s*[(\[{][^)\]}]*[)\]}]$');
  var out = name.trim();
  while (true) {
    final shorter = out.replaceFirst(bracketed, '').trim();
    if (shorter.isEmpty || shorter == out) return out;
    out = shorter;
  }
}

/// The recorded chat feed, newest first — mirrors `messages.json`.
@immutable
class ChatFeed {
  final List<ChatMessage> messages;

  const ChatFeed(this.messages);

  static const ChatFeed empty = ChatFeed(<ChatMessage>[]);

  bool get isEmpty => messages.isEmpty;

  factory ChatFeed.fromJson(Map<String, dynamic> json) {
    final messages = (json['messages'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .where((m) => m.text.trim().isNotEmpty)
            .toList() ??
        const <ChatMessage>[];
    return ChatFeed(List.unmodifiable(messages));
  }
}
