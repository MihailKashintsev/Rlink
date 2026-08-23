import 'ai_bot_constants.dart';
import 'relay_service.dart';

/// Lib / GigaChat или сторонний бот из каталога relay (по bot_dir_snapshot).
bool isDmBotPeerId(String peerId) {
  if (isAiBotPeerId(peerId)) return true;
  return RelayService.instance.isRelayCatalogBot(peerId);
}

/// True for bot DMs that actually need the relay to respond — GigaChat's
/// backend, Lib's registrar commands, any third-party catalog bot's own
/// process. False for the Emoji bot, which is purely on-device and works
/// the same with or without a connection.
bool dmBotNeedsRelay(String peerId) =>
    isDmBotPeerId(peerId) && peerId != kEmojiBotPeerId;
