import React from "react";
import {
  AbsoluteFill,
  Easing,
  interpolate,
  Sequence,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { TransitionSeries, linearTiming } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { loadFont as loadOrbitron } from "@remotion/google-fonts/Orbitron";
import { loadFont as loadMontserrat } from "@remotion/google-fonts/Montserrat";
import {
  BG,
  GradientBackground,
  MUTED,
  PulseRings,
  TEAL,
  TEAL_GLOW,
  TEAL_LIGHT,
  TEXT,
  WaveLine,
} from "./Brand";

const { fontFamily: display } = loadOrbitron("normal", {
  weights: ["700"],
  subsets: ["latin"],
});
const { fontFamily: body } = loadMontserrat("normal", {
  weights: ["500", "600", "700"],
  subsets: ["cyrillic", "latin"],
});

const EASE = Easing.bezier(0.16, 1, 0.3, 1);

/** Rise + fade a block into its slot. */
const Reveal: React.FC<{
  delay?: number;
  y?: number;
  children: React.ReactNode;
}> = ({ delay = 0, y = 40, children }) => {
  const frame = useCurrentFrame();
  const f = frame - delay;
  const opacity = interpolate(f, [0, 16], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  const ty = interpolate(f, [0, 16], [y, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  return (
    <div style={{ opacity, translate: `0px ${ty}px` }}>{children}</div>
  );
};

const Headline: React.FC<{ children: React.ReactNode; size?: number }> = ({
  children,
  size = 96,
}) => (
  <div
    style={{
      fontFamily: body,
      fontWeight: 600,
      fontSize: size,
      lineHeight: 1.08,
      color: TEXT,
      textAlign: "center",
      maxWidth: 920,
      padding: "0 80px",
      textShadow: "0 6px 40px rgba(0,0,0,0.5)",
    }}
  >
    {children}
  </div>
);

const Sub: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      fontFamily: body,
      fontWeight: 500,
      fontSize: 46,
      color: MUTED,
      textAlign: "center",
      maxWidth: 880,
      padding: "0 80px",
    }}
  >
    {children}
  </div>
);

const Eyebrow: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      fontFamily: body,
      fontWeight: 600,
      fontSize: 30,
      letterSpacing: 8,
      textTransform: "uppercase",
      color: TEAL_LIGHT,
    }}
  >
    {children}
  </div>
);

const Column: React.FC<{ children: React.ReactNode; gap?: number }> = ({
  children,
  gap = 44,
}) => (
  <AbsoluteFill
    style={{
      alignItems: "center",
      justifyContent: "center",
      flexDirection: "column",
      gap,
    }}
  >
    {children}
  </AbsoluteFill>
);

// ── Scene 1: Logo ──────────────────────────────────────────────────────────
const LogoScene: React.FC = () => {
  const frame = useCurrentFrame();
  const scale = interpolate(frame, [0, 24], [0.7, 1], {
    extrapolateRight: "clamp",
    easing: EASE,
  });
  const glow = interpolate(frame % 60, [0, 30, 60], [0.3, 0.8, 0.3]);
  return (
    <AbsoluteFill>
      <PulseRings cx={50} cy={44} />
      <Column gap={36}>
        <div
          style={{
            opacity: interpolate(frame, [0, 18], [0, 1], {
              extrapolateRight: "clamp",
            }),
            scale,
            fontFamily: display,
            fontWeight: 700,
            fontSize: 168,
            letterSpacing: 6,
            color: TEXT,
            textShadow: `0 0 ${40 + glow * 60}px rgba(45,212,191,${glow})`,
          }}
        >
          RLINK
        </div>
        <Reveal delay={22}>
          <Sub>Связь без границ</Sub>
        </Reveal>
      </Column>
    </AbsoluteFill>
  );
};

// ── Scene 2: Distance / connection ─────────────────────────────────────────
const DistanceScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();
  const dash = interpolate(frame, [6, 46], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  const ax = width * 0.2;
  const bx = width * 0.8;
  const ay = 560;
  const by = 480;
  const cx = (ax + bx) / 2;
  const cy = 300;
  const pathLen = 1400;
  const pulse = (frame % 48) / 48;
  const px = (1 - pulse) ** 2 * ax + 2 * (1 - pulse) * pulse * cx + pulse ** 2 * bx;
  const py = (1 - pulse) ** 2 * ay + 2 * (1 - pulse) * pulse * cy + pulse ** 2 * by;
  const Dot: React.FC<{ x: number; y: number; label: string }> = ({
    x,
    y,
    label,
  }) => (
    <>
      <div
        style={{
          position: "absolute",
          left: x,
          top: y,
          width: 36,
          height: 36,
          marginLeft: -18,
          marginTop: -18,
          borderRadius: "50%",
          backgroundColor: TEAL_GLOW,
          boxShadow: `0 0 40px ${TEAL_GLOW}`,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: x,
          top: y + 34,
          marginLeft: -90,
          width: 180,
          textAlign: "center",
          fontFamily: body,
          fontSize: 30,
          color: MUTED,
        }}
      >
        {label}
      </div>
    </>
  );
  return (
    <AbsoluteFill>
      <svg width={width} height={1920} style={{ position: "absolute" }}>
        <path
          d={`M ${ax} ${ay} Q ${cx} ${cy} ${bx} ${by}`}
          fill="none"
          stroke={TEAL}
          strokeWidth={6}
          strokeLinecap="round"
          strokeDasharray={pathLen}
          strokeDashoffset={pathLen * dash}
          opacity={0.9}
        />
      </svg>
      <div
        style={{
          position: "absolute",
          left: px,
          top: py,
          width: 22,
          height: 22,
          marginLeft: -11,
          marginTop: -11,
          borderRadius: "50%",
          backgroundColor: "#fff",
          boxShadow: `0 0 30px #fff`,
          opacity: dash < 0.02 ? 1 : 0,
        }}
      />
      <Dot x={ax} y={ay} label="Германия" />
      <Dot x={bx} y={by} label="Россия" />
      <div style={{ position: "absolute", top: 760, width: "100%" }}>
        <Column gap={28}>
          <Reveal delay={20}>
            <Eyebrow>Цель Rlink</Eyebrow>
          </Reveal>
          <Reveal delay={28}>
            <Headline size={88}>Объединяем людей на любых расстояниях</Headline>
          </Reveal>
        </Column>
      </div>
    </AbsoluteFill>
  );
};

// ── Scene 3: Messages ──────────────────────────────────────────────────────
const Bubble: React.FC<{
  out?: boolean;
  delay: number;
  children: React.ReactNode;
}> = ({ out, delay, children }) => {
  const frame = useCurrentFrame();
  const f = frame - delay;
  const opacity = interpolate(f, [0, 12], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const tx = interpolate(f, [0, 14], [out ? 60 : -60, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  return (
    <div
      style={{
        opacity,
        translate: `${tx}px 0px`,
        alignSelf: out ? "flex-end" : "flex-start",
        background: out ? TEAL_LIGHT : "rgba(255,255,255,0.1)",
        color: out ? "#04201c" : TEXT,
        fontFamily: body,
        fontSize: 40,
        fontWeight: 500,
        padding: "26px 38px",
        borderRadius: 30,
        maxWidth: 640,
        boxShadow: "0 10px 40px rgba(0,0,0,0.35)",
      }}
    >
      {children}
    </div>
  );
};

const MessagesScene: React.FC = () => (
  <Column gap={50}>
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        gap: 24,
        width: 760,
      }}
    >
      <Bubble delay={4}>Привет! Как ты там? 👋</Bubble>
      <Bubble out delay={16}>
        Отлично! Слышно тебя идеально 🎧
      </Bubble>
      <Bubble delay={28}>🎤 Голосовое · расшифровка ✓</Bubble>
    </div>
    <Reveal delay={40}>
      <Sub>Сообщения и голосовые с расшифровкой</Sub>
    </Reveal>
  </Column>
);

// ── Scene 4: Calls ─────────────────────────────────────────────────────────
const CallsScene: React.FC = () => (
  <AbsoluteFill>
    <WaveLine yPct={42} amp={120} />
    <div style={{ position: "absolute", top: 1040, width: "100%" }}>
      <Column gap={28}>
        <Reveal delay={10}>
          <Eyebrow>Голос и видео</Eyebrow>
        </Reveal>
        <Reveal delay={18}>
          <Headline>Звонки даже между странами</Headline>
        </Reveal>
      </Column>
    </div>
  </AbsoluteFill>
);

// ── Scene 5: Features ──────────────────────────────────────────────────────
const FeatureChip: React.FC<{ icon: string; label: string; delay: number }> = ({
  icon,
  label,
  delay,
}) => {
  const frame = useCurrentFrame();
  const f = frame - delay;
  const s = interpolate(f, [0, 14], [0.6, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  const opacity = interpolate(f, [0, 12], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <div
      style={{
        opacity,
        scale: s,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 18,
      }}
    >
      <div
        style={{
          width: 150,
          height: 150,
          borderRadius: 38,
          background: "rgba(20,184,166,0.16)",
          border: `2px solid rgba(45,212,191,0.5)`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: 74,
        }}
      >
        {icon}
      </div>
      <div style={{ fontFamily: body, fontSize: 34, color: MUTED }}>{label}</div>
    </div>
  );
};

const FeaturesScene: React.FC = () => (
  <Column gap={64}>
    <div style={{ display: "flex", gap: 56 }}>
      <FeatureChip icon="📢" label="Каналы" delay={4} />
      <FeatureChip icon="🖼️" label="Медиа" delay={14} />
      <FeatureChip icon="☁️" label="Drive" delay={24} />
    </div>
    <Reveal delay={34}>
      <Headline size={84}>Каналы, медиа и Google Drive</Headline>
    </Reveal>
  </Column>
);

// ── Scene 6: Privacy ───────────────────────────────────────────────────────
const PrivacyScene: React.FC = () => {
  const frame = useCurrentFrame();
  const s = interpolate(frame, [0, 18], [0.5, 1], {
    extrapolateRight: "clamp",
    easing: EASE,
  });
  return (
    <Column gap={48}>
      <div
        style={{
          scale: s,
          width: 200,
          height: 200,
          borderRadius: 50,
          background: "rgba(20,184,166,0.16)",
          border: `2px solid rgba(45,212,191,0.6)`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: 104,
          boxShadow: `0 0 80px rgba(45,212,191,0.35)`,
        }}
      >
        🔒
      </div>
      <Reveal delay={16}>
        <Headline>Сквозное шифрование. Приватно.</Headline>
      </Reveal>
    </Column>
  );
};

// ── Scene 7: CTA ───────────────────────────────────────────────────────────
const CtaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const glow = interpolate(frame % 60, [0, 30, 60], [0.3, 0.85, 0.3]);
  return (
    <AbsoluteFill>
      <PulseRings cx={50} cy={50} />
      <Column gap={40}>
        <div
          style={{
            fontFamily: display,
            fontWeight: 700,
            fontSize: 150,
            letterSpacing: 6,
            color: TEXT,
            textShadow: `0 0 ${40 + glow * 70}px rgba(45,212,191,${glow})`,
          }}
        >
          RLINK
        </div>
        <Reveal delay={14}>
          <Headline size={80}>Начни общаться прямо сейчас</Headline>
        </Reveal>
        <Reveal delay={24}>
          <div
            style={{
              fontFamily: body,
              fontSize: 40,
              color: TEAL_LIGHT,
              fontWeight: 600,
              letterSpacing: 2,
            }}
          >
            rendergames.ru
          </div>
        </Reveal>
      </Column>
    </AbsoluteFill>
  );
};

// ── Main ───────────────────────────────────────────────────────────────────
const fadeT = () => (
  <TransitionSeries.Transition
    presentation={fade()}
    timing={linearTiming({ durationInFrames: 14 })}
  />
);

export const RlinkPromo: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: BG }}>
      <GradientBackground />
      <TransitionSeries>
        <TransitionSeries.Sequence durationInFrames={96}>
          <LogoScene />
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={104}>
          <DistanceScene />
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={92}>
          <MessagesScene />
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={86}>
          <CallsScene />
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={92}>
          <FeaturesScene />
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={84}>
          <PrivacyScene />
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={120}>
          <CtaScene />
        </TransitionSeries.Sequence>
      </TransitionSeries>
      {/* subtle vignette */}
      <AbsoluteFill
        style={{
          background:
            "radial-gradient(120% 90% at 50% 50%, transparent 60%, rgba(0,0,0,0.45))",
          pointerEvents: "none",
        }}
      />
      <Sequence>{null}</Sequence>
    </AbsoluteFill>
  );
};
