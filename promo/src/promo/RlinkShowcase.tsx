import React from "react";
import {
  AbsoluteFill,
  Audio,
  interpolate,
  Sequence,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { GradientBackground, PulseRings, WaveLine } from "./Brand";

// ── Rlink "Изумруд" brand palette (matches lib/ui/app_palettes.dart) ──────────
const EMERALD = "#1DB954";
const EMERALD_2 = "#0F9B8E";
const EMERALD_3 = "#2BC0A8";
const TEXT = "#EAFEF6";
const MUTED = "rgba(234,254,246,0.66)";

const SCENE = 132; // frames per scene (~4.4s @ 30fps)
const HOLD = 132;

type Feat = {
  glyph: string;
  title: string;
  sub: string;
  wave?: boolean;
  rings?: boolean;
};

// No app UI — features are told through glyphs, motion and type only.
const FEATURES: Feat[] = [
  { glyph: "🛡", title: "Без номера телефона", sub: "Регистрация без SIM и SMS — только вы и ключи", rings: true },
  { glyph: "💬", title: "Сообщения", sub: "Текст, голосовые с расшифровкой, реакции, эмодзи" },
  { glyph: "🤖", title: "Боты", sub: "Команды, кнопки и собственные эмодзи-наборы" },
  { glyph: "👥", title: "Группы", sub: "Общение командой — с ролями и медиа" },
  { glyph: "📣", title: "Каналы", sub: "Публикации, подписки и комментарии" },
  { glyph: "✨", title: "Истории", sub: "Делитесь моментами, которые исчезают" },
  { glyph: "📶", title: "Работает без интернета", sub: "Рядом — напрямую по Bluetooth-сети", wave: true },
  { glyph: "🌍", title: "По всему миру", sub: "Через сервер — между странами и устройствами", rings: true },
  { glyph: "📞", title: "Звонки и видео", sub: "Чистая аудио- и видеосвязь", wave: true },
];

// Strong, intentional easing (animations.dev): fast-out for entrances.
const EASE_OUT = (t: number) =>
  1 - Math.pow(1 - Math.min(Math.max(t, 0), 1), 3);

const FeatureScene: React.FC<{ feat: Feat }> = ({ feat }) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const S = Math.min(width, height) / 1080; // responsive: portrait & landscape

  // Entrance
  const pop = spring({ frame, fps, config: { damping: 14, mass: 0.7, stiffness: 110 } });
  const tIn = EASE_OUT(frame / 16);
  // Exit (fade + drift + blur to mask the cut)
  const out = interpolate(frame, [SCENE - 16, SCENE], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const opacity = Math.min(tIn, 1 - out);
  const blur = out * 10;
  const glyphScale = (0.86 + 0.14 * pop) * (1 + out * 0.06);
  const lift = (1 - tIn) * 26 * S - out * 24 * S;

  const circle = 360 * S;
  const breathe = 1 + 0.02 * Math.sin((frame / fps) * 2.2);

  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      {feat.rings && <PulseRings cx={50} cy={42} />}
      {feat.wave && <WaveLine yPct={50} amp={64 * S} color={EMERALD_3} strokeWidth={6 * S} />}
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          transform: `translateY(${lift}px)`,
          opacity,
          filter: `blur(${blur}px)`,
          padding: `0 ${80 * S}px`,
        }}
      >
        <div
          style={{
            width: circle,
            height: circle,
            borderRadius: "50%",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            transform: `scale(${glyphScale * breathe})`,
            background: `linear-gradient(135deg, ${EMERALD}, ${EMERALD_2} 60%, ${EMERALD_3})`,
            boxShadow: `0 ${30 * S}px ${90 * S}px rgba(29,185,84,0.45), inset 0 0 ${60 * S}px rgba(255,255,255,0.12)`,
          }}
        >
          <span style={{ fontSize: 168 * S, lineHeight: 1 }}>{feat.glyph}</span>
        </div>
        <div
          style={{
            marginTop: 64 * S,
            fontFamily: "Montserrat, system-ui, sans-serif",
            fontWeight: 800,
            fontSize: 70 * S,
            color: TEXT,
            textAlign: "center",
            letterSpacing: 0.5,
          }}
        >
          {feat.title}
        </div>
        <div
          style={{
            marginTop: 22 * S,
            fontFamily: "Montserrat, system-ui, sans-serif",
            fontWeight: 500,
            fontSize: 36 * S,
            color: MUTED,
            textAlign: "center",
            maxWidth: 980 * S,
            lineHeight: 1.35,
          }}
        >
          {feat.sub}
        </div>
      </div>
    </AbsoluteFill>
  );
};

const Wordmark: React.FC<{ cta?: boolean }> = ({ cta }) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const S = Math.min(width, height) / 1080;
  const pop = spring({ frame, fps, config: { damping: 16, mass: 0.8, stiffness: 90 } });
  const tIn = EASE_OUT(frame / 18);
  const out = interpolate(frame, [HOLD - 18, HOLD], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const opacity = Math.min(tIn, 1 - out);
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <PulseRings cx={50} cy={50} />
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", opacity }}>
        <div
          style={{
            transform: `scale(${0.9 + 0.1 * pop})`,
            fontFamily: "Orbitron, Montserrat, sans-serif",
            fontWeight: 900,
            fontSize: 168 * S,
            letterSpacing: 14 * S,
            color: TEXT,
            textShadow: `0 0 ${60 * S}px rgba(29,185,84,0.7)`,
          }}
        >
          RLINK
        </div>
        <div
          style={{
            marginTop: 26 * S,
            fontFamily: "Montserrat, system-ui, sans-serif",
            fontWeight: 600,
            fontSize: 44 * S,
            color: EMERALD_3,
            letterSpacing: 2 * S,
          }}
        >
          {cta ? "Скачайте в RuStore" : "Зашифрованный мессенджер"}
        </div>
        {cta && (
          <div
            style={{
              marginTop: 18 * S,
              fontFamily: "Montserrat, system-ui, sans-serif",
              fontWeight: 500,
              fontSize: 30 * S,
              color: MUTED,
            }}
          >
            Без рекламы · Без слежки · Без номера телефона
          </div>
        )}
      </div>
    </AbsoluteFill>
  );
};

export const RlinkShowcase: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: "#04100e" }}>
      <GradientBackground />
      <Sequence from={0} durationInFrames={HOLD}>
        <Wordmark />
      </Sequence>
      {FEATURES.map((f, i) => (
        <Sequence key={i} from={HOLD + i * SCENE} durationInFrames={SCENE}>
          <FeatureScene feat={f} />
        </Sequence>
      ))}
      <Sequence from={HOLD + FEATURES.length * SCENE} durationInFrames={HOLD}>
        <Wordmark cta />
      </Sequence>
      <Audio src={staticFile("music.wav")} loop volume={0.85} />
    </AbsoluteFill>
  );
};

export const SHOWCASE_FRAMES = HOLD + FEATURES.length * SCENE + HOLD;
