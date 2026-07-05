import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/contact_trust_service.dart';
import '../../services/crypto_service.dart';

/// Экран «Код безопасности» (safety number) между вами и контактом.
/// Оба видят один и тот же код, если никакой relay не подменил ключи. Сверьте
/// код голосом/лично и отметьте контакт проверенным.
class SafetyNumberScreen extends StatefulWidget {
  final String peerId; // Ed25519 public key hex (contact id)
  final String peerName;
  final String peerX25519Key; // текущий ключ шифрования контакта (base64)

  const SafetyNumberScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    required this.peerX25519Key,
  });

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  String _number = '';
  bool _verified = false;
  int? _changedAt;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final number =
        await CryptoService.instance.safetyNumberWith(widget.peerId);
    final verified = await ContactTrustService.instance
        .isVerified(widget.peerId, widget.peerX25519Key);
    final changedAt =
        await ContactTrustService.instance.keyChangedAt(widget.peerId);
    if (!mounted) return;
    setState(() {
      _number = number;
      _verified = verified;
      _changedAt = changedAt;
      _loading = false;
    });
  }

  Future<void> _toggleVerified() async {
    if (_verified) {
      await ContactTrustService.instance.clearVerified(widget.peerId);
    } else {
      await ContactTrustService.instance
          .markVerified(widget.peerId, widget.peerX25519Key);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Код безопасности')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                if (_changedAt != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: cs.onErrorContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Код безопасности изменился. Это бывает при переустановке '
                            'у собеседника — но может означать перехват. Сверьте код '
                            'заново, прежде чем доверять.',
                            style: TextStyle(color: cs.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  'Сверьте этот код с ${widget.peerName} (голосом или лично). '
                  'Если у вас обоих он одинаковый — переписку и звонки никто не '
                  'перехватывает.',
                  style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: SelectableText(
                    _formatGrid(_number),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 22,
                      letterSpacing: 2,
                      height: 1.8,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton.icon(
                    onPressed: _number.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                                ClipboardData(text: _number));
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(const SnackBar(
                                  content: Text('Код скопирован')));
                          },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Скопировать'),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _verified ? cs.surfaceContainerHighest : null,
                    foregroundColor: _verified ? cs.onSurface : null,
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: widget.peerX25519Key.isEmpty ? null : _toggleVerified,
                  icon: Icon(_verified
                      ? Icons.verified_user
                      : Icons.verified_user_outlined),
                  label: Text(_verified
                      ? 'Проверен ✓ — снять отметку'
                      : 'Отметить проверенным'),
                ),
                if (widget.peerX25519Key.isEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Ключ шифрования контакта ещё не получен — код появится, когда '
                    'вы обменяетесь сообщениями.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ],
            ),
    );
  }

  /// Разбивает 12 групп на 4 строки по 3 для читаемости.
  String _formatGrid(String number) {
    final groups = number.split(' ');
    if (groups.length != 12) return number;
    final lines = <String>[];
    for (var i = 0; i < 12; i += 3) {
      lines.add(groups.sublist(i, i + 3).join(' '));
    }
    return lines.join('\n');
  }
}
