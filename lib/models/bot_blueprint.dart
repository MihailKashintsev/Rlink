import 'dart:convert';

/// Тип срабатывания правила бота (no-code конструктор).
enum BotTriggerType {
  /// Точная команда: сообщение начинается с "/cmd" (регистр не важен).
  command,

  /// Сообщение содержит слово/фразу (регистр не важен).
  keyword,

  /// Сообщение целиком совпадает с текстом (без учёта регистра/пробелов).
  exact,
}

extension BotTriggerTypeX on BotTriggerType {
  String get wire => switch (this) {
        BotTriggerType.command => 'command',
        BotTriggerType.keyword => 'keyword',
        BotTriggerType.exact => 'exact',
      };

  String get label => switch (this) {
        BotTriggerType.command => 'Команда',
        BotTriggerType.keyword => 'Содержит слово',
        BotTriggerType.exact => 'Точное совпадение',
      };

  String get hint => switch (this) {
        BotTriggerType.command => 'например /price',
        BotTriggerType.keyword => 'например цена',
        BotTriggerType.exact => 'например Привет',
      };

  static BotTriggerType fromWire(String? s) => switch (s) {
        'keyword' => BotTriggerType.keyword,
        'exact' => BotTriggerType.exact,
        _ => BotTriggerType.command,
      };
}

/// Кнопка-чип под ответом. В Rlink кодируется как `[btn:Метка|/команда]`.
class BotButton {
  String label;
  String command;

  BotButton({required this.label, required this.command});

  BotButton clone() => BotButton(label: label, command: command);

  Map<String, dynamic> toJson() => {'label': label, 'command': command};

  factory BotButton.fromJson(Map<String, dynamic> j) => BotButton(
        label: (j['label'] ?? '').toString(),
        command: (j['command'] ?? '').toString(),
      );
}

/// Одно правило: триггер → ответ (+ кнопки).
class BotRule {
  BotTriggerType type;
  String pattern;
  String reply;
  List<BotButton> buttons;

  BotRule({
    required this.type,
    required this.pattern,
    required this.reply,
    List<BotButton>? buttons,
  }) : buttons = buttons ?? <BotButton>[];

  BotRule clone() => BotRule(
        type: type,
        pattern: pattern,
        reply: reply,
        buttons: buttons.map((b) => b.clone()).toList(),
      );

  Map<String, dynamic> toJson() => {
        'type': type.wire,
        'pattern': pattern,
        'reply': reply,
        'buttons': buttons.map((b) => b.toJson()).toList(),
      };

  factory BotRule.fromJson(Map<String, dynamic> j) => BotRule(
        type: BotTriggerTypeX.fromWire(j['type']?.toString()),
        pattern: (j['pattern'] ?? '').toString(),
        reply: (j['reply'] ?? '').toString(),
        buttons: ((j['buttons'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => BotButton.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

/// Полное описание бота, собранное в no-code конструкторе.
/// Сериализуется в rules-JSON, который запекается в сгенерированный Python.
class BotBlueprint {
  String id; // локальный uuid черновика
  String name; // отображаемое имя
  String handle; // @ник (a-z0-9_, 2–32)
  String emoji; // эмодзи аватара
  int color; // цвет аватара (ARGB int)
  String description; // короткое описание для каталога
  String welcomeText; // ответ на /start, /menu и первое сообщение
  List<BotButton> welcomeButtons;
  List<BotRule> rules;
  String fallbackText; // ответ, если ничего не совпало
  List<BotButton> fallbackButtons;
  bool echoOnUnmatched; // если true — при отсутствии совпадения вернуть текст пользователя
  DateTime updatedAt;

  BotBlueprint({
    required this.id,
    this.name = '',
    this.handle = '',
    this.emoji = '🤖',
    this.color = 0xFF5C6BC0,
    this.description = '',
    this.welcomeText = '',
    List<BotButton>? welcomeButtons,
    List<BotRule>? rules,
    this.fallbackText = '',
    List<BotButton>? fallbackButtons,
    this.echoOnUnmatched = false,
    DateTime? updatedAt,
  })  : welcomeButtons = welcomeButtons ?? <BotButton>[],
        rules = rules ?? <BotRule>[],
        fallbackButtons = fallbackButtons ?? <BotButton>[],
        updatedAt = updatedAt ?? DateTime.now();

  /// Заготовка нового бота с осмысленными значениями по умолчанию.
  factory BotBlueprint.fresh(String id) => BotBlueprint(
        id: id,
        name: 'Мой бот',
        handle: '',
        emoji: '🤖',
        color: 0xFF5C6BC0,
        welcomeText:
            'Привет! Я бот на Rlink. Выберите действие или напишите сообщение.',
        welcomeButtons: [
          BotButton(label: 'Помощь', command: '/help'),
        ],
        rules: [
          BotRule(
            type: BotTriggerType.command,
            pattern: '/help',
            reply: 'Список команд:\n• /start — меню\n• /help — эта справка',
          ),
        ],
        fallbackText: 'Не понял сообщение. Напишите /help, чтобы увидеть меню.',
        echoOnUnmatched: false,
      );

  BotBlueprint clone() => BotBlueprint(
        id: id,
        name: name,
        handle: handle,
        emoji: emoji,
        color: color,
        description: description,
        welcomeText: welcomeText,
        welcomeButtons: welcomeButtons.map((b) => b.clone()).toList(),
        rules: rules.map((r) => r.clone()).toList(),
        fallbackText: fallbackText,
        fallbackButtons: fallbackButtons.map((b) => b.clone()).toList(),
        echoOnUnmatched: echoOnUnmatched,
        updatedAt: updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        'name': name,
        'handle': handle,
        'emoji': emoji,
        'color': color,
        'description': description,
        'welcomeText': welcomeText,
        'welcomeButtons': welcomeButtons.map((b) => b.toJson()).toList(),
        'rules': rules.map((r) => r.toJson()).toList(),
        'fallbackText': fallbackText,
        'fallbackButtons': fallbackButtons.map((b) => b.toJson()).toList(),
        'echoOnUnmatched': echoOnUnmatched,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory BotBlueprint.fromJson(Map<String, dynamic> j) => BotBlueprint(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        handle: (j['handle'] ?? '').toString(),
        emoji: (j['emoji'] ?? '🤖').toString(),
        color: (j['color'] is int)
            ? j['color'] as int
            : int.tryParse('${j['color']}') ?? 0xFF5C6BC0,
        description: (j['description'] ?? '').toString(),
        welcomeText: (j['welcomeText'] ?? '').toString(),
        welcomeButtons: ((j['welcomeButtons'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => BotButton.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        rules: ((j['rules'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => BotRule.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        fallbackText: (j['fallbackText'] ?? '').toString(),
        fallbackButtons: ((j['fallbackButtons'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => BotButton.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        echoOnUnmatched: j['echoOnUnmatched'] == true,
        updatedAt: DateTime.tryParse('${j['updatedAt']}') ?? DateTime.now(),
      );

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  static BotBlueprint? tryParse(String s) {
    try {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic>) return BotBlueprint.fromJson(j);
    } catch (_) {}
    return null;
  }

  /// Нормализованный @ник: только a-z0-9_, обрезка до 32.
  String get sanitizedHandle {
    final h = handle.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
    return h.length > 32 ? h.substring(0, 32) : h;
  }

  bool get handleValid {
    final h = sanitizedHandle;
    return h.length >= 2 && h.length <= 32;
  }

  // ── Предпросмотр (та же логика, что запекается в Python) ───────────────────

  static String _renderButtons(List<BotButton> bs) {
    final parts = <String>[];
    for (final b in bs) {
      final l = b.label.trim();
      final c = b.command.trim();
      if (l.isNotEmpty && c.isNotEmpty) parts.add('[btn:$l|$c]');
    }
    return parts.join(' ');
  }

  static String _withButtons(String text, List<BotButton> bs) {
    final bar = _renderButtons(bs);
    final t = text.trimRight();
    if (bar.isEmpty) return t;
    return t.isEmpty ? bar : '$t\n\n$bar';
  }

  /// Что ответит бот на [userText] — для живого предпросмотра в конструкторе.
  String previewReply(String userText) {
    final t = userText.trim();
    final low = t.toLowerCase();
    if (t.isEmpty ||
        const ['/start', 'start', '/menu', 'menu', 'меню'].contains(low)) {
      return _withButtons(welcomeText, welcomeButtons);
    }
    for (final r in rules) {
      final pat = r.pattern.trim();
      if (pat.isEmpty) continue;
      var matched = false;
      switch (r.type) {
        case BotTriggerType.command:
          final c = pat.toLowerCase();
          matched = low == c || low.startsWith('$c ');
        case BotTriggerType.keyword:
          matched = low.contains(pat.toLowerCase());
        case BotTriggerType.exact:
          matched = low == pat.toLowerCase();
      }
      if (matched) return _withButtons(r.reply, r.buttons);
    }
    if (echoOnUnmatched) return userText;
    return _withButtons(fallbackText, fallbackButtons);
  }
}
