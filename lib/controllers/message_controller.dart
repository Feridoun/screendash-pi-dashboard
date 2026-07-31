import '../config/app_config.dart';
import '../models/chat_message.dart';
import '../services/backend_client.dart';
import 'polling_controller.dart';

/// Polls messages.json and exposes the recorded chat feed.
class MessageController extends PollingController {
  final AppConfig config;
  final BackendClient client;

  MessageController({required this.config, required this.client});

  @override
  Duration get interval => client.jittered(AppConfig.messagesPollInterval);

  ChatFeed _feed = ChatFeed.empty;
  ChatFeed get feed => _feed;
  List<ChatMessage> get messages => _feed.messages;

  @override
  Future<void> poll({bool force = false}) async {
    final result =
        await client.getJson(config.messagesUri, bypassCache: force);
    if (result.notModified) return;

    _feed = ChatFeed.fromJson(result.json!);
    safeNotify();
  }
}
