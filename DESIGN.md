# Rlink Redesign — инструкция (для Claude/Fable, самоприменяемая)

Цель: весь интерфейс должен ощущаться как **интро-анимация** (IntroPromoScreen) —
живой градиент, свечение акцента, крупные скругления, смелая типографика.
Каналы — приоритет (выглядели хуже всего). Старый дизайн обязан оставаться
доступным: **каждое** визуальное изменение гейтится `AppSettings.instance.newDesign`
(тумблер: Настройки → Оформление → «Новый дизайн»).

## 1. Источник эстетики
`lib/ui/screens/intro_promo_screen.dart`: бейджи-круги с LinearGradient
`[accent, lerp(accent, tertiary, .6)]` + BoxShadow(accent α .4, blur 50);
пульс-кольца; тёмный фон с плавающим свечением. Уже перенесено в
`lib/ui/widgets/aurora_background.dart` (AuroraBackground — app-wide в builder
MaterialApp; GlowGradientCircle) и в `_buildTheme` (main.dart): прозрачные
скаффолды, радиусы 22/26/28/16, ZoomPageTransitions.

## 2. Токены (lib/ui/design/rlink_design.dart)
- `RlinkDesign.on` — единственный гейт (== AppSettings.newDesign).
- `accentGradient(cs)` — LinearGradient из `paletteFor(appPalette).gradient[0..1]`.
- `bubbleOut(cs, radius)` — исходящий пузырь: accentGradient + glow(accent .30, blur 12).
- `bubbleIn(cs, radius)` — входящий: surfaceContainerHigh + hairline border(accent .10).
- `floatCard(cs, {radius=22})` — карточка поста/плитки: surface, hairline(accent .18),
  glow(accent .10, blur 18, offset(0,6)).
- `gradientRing(child, {size, width=2})` — аватар в градиентном кольце.
Текст на градиенте: белый/чёрный по luminance акцента (>0.55 → тёмный).

## 3. Правила анимации (emil-design-eng)
UI-переходы ≤300ms, entrances ease-out (Curves.easeOutCubic), нажатия scale(0.97),
ничего не появляется из scale(0) (минимум 0.9+opacity), длительности: кнопки 100–160ms,
листы/диалоги 200–280ms. Постоянное движение — только фон (aurora, 22s loop) и
пульс уведомительных элементов.

## 4. Карта применения (файл → якорь → что)
| Экран | Файл/якорь | Новый вид |
|---|---|---|
| Фон везде | main.dart builder → AuroraBackground | сделано |
| Тема | main.dart `_buildTheme(palette, brightness, newDesign)` | сделано |
| DM-пузыри | chat_screen `decoration: isSticker ? null : BoxDecoration(color: isOut ? cs.primary…` | out=градиент+glow, in=hairline |
| Групповые пузыри | groups_screen `color: msg.isOutgoing ? cs.primary…` | то же |
| Пост канала | channels_screen `_PostCardState.build` Card | floatCard 22 + имя канала жирнее |
| Плитка канала | channels_screen `_ChannelTile`/ListTile(623) | floatCard-обёртка + gradientRing аватара |
| Кнопка «отправить» | composer_input_bar AnimatedContainer(44) | accentGradient + glow |
| Список чатов | chat_list_screen | прозрачный скаффолд (сделано) + сворачивающаяся шапка (сделано) |
| Настройки | _subScaffold + категории | прозрачные (сделано) |

## 5. Как расширять
Новый экран: НЕ задавать backgroundColor (наследует прозрачность) → aurora виден.
Карточки — `RlinkDesign.floatCard`. Главное действие экрана — GlowGradientCircle.
Никаких хардкод-цветов 0xFF121212/0xFF0F0F0F в новых экранах — только из темы.
Всегда: `if (!RlinkDesign.on) → старый вид` (старые ветки не удалять).

## 6. Проверка
flutter analyze == 0 → build web → bump `__rlinkBuildV` → push web-origin+origin main.
Смотреть на палитрах Тиффани / Синий·Золото / Изумруд, оба положения тумблера.
