import React from "react";
import {
  AbsoluteFill,
  Audio,
  Easing,
  interpolate,
  Sequence,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { TransitionSeries, linearTiming } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { loadFont as loadOrbitron } from "@remotion/google-fonts/Orbitron";
import { loadFont as loadMontserrat } from "@remotion/google-fonts/Montserrat";
import { PulseRings } from "./Brand";
import {
  ChannelScreen,
  ChatScreen,
  CallScreen,
  HomeScreen,
  ON_SURFACE,
  Phone,
  SURFACE,
} from "./RlinkUI";

const { fontFamily: display } = loadOrbitron("normal", {
  weights: ["700"],
  subsets: ["latin"],
});
const { fontFamily: body } = loadMontserrat("normal", {
  weights: ["500", "600", "700"],
  subsets: ["cyrillic", "latin"],
});

const EASE = Easing.bezier(0.16, 1, 0.3, 1);

// Emerald brand backdrop (the real Rlink gradient: green → teal).
const EmeraldBackground: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const a = (frame / 90) * Math.PI * 2;
  const gx = 50 + Math.cos(a) * 26;
  const gy = 40 + Math.sin(a * 0.8) * 20;
  const g2x = 50 - Math.cos(a * 0.7) * 28;
  const g2y = 62 - Math.sin(a) * 18;
  return (
    <AbsoluteFill style={{ backgroundColor: "#03100c" }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(${width}px ${height * 0.5}px at ${gx}% ${gy}%, rgba(29,185,84,0.30), transparent 60%)`,
        }}
      />
      <AbsoluteFill
        style={{
          background: `radial-gradient(${width}px ${height * 0.55}px at ${g2x}% ${g2y}%, rgba(15,155,142,0.28), transparent 62%)`,
        }}
      />
      <AbsoluteFill
        style={{
          background:
            "linear-gradient(180deg, rgba(0,0,0,0.4), transparent 28%, transparent 72%, rgba(0,0,0,0.5))",
        }}
      />
    </AbsoluteFill>
  );
};

const Caption: React.FC<{ eyebrow: string; title: string }> = ({
  eyebrow,
  title,
}) => {
  const frame = useCurrentFrame();
  const op = interpolate(frame - 18, [0, 14], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const ty = interpolate(frame - 18, [0, 14], [30, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  return (
    <div
      style={{
        position: "absolute",
        bottom: 96,
        width: "100%",
        textAlign: "center",
        opacity: op,
        translate: `0px ${ty}px`,
      }}
    >
      <div
        style={{
          fontFamily: body,
          fontWeight: 700,
          fontSize: 28,
          letterSpacing: 6,
          textTransform: "uppercase",
          color: "#2BC0A8",
          marginBottom: 16,
        }}
      >
        {eyebrow}
      </div>
      <div
        style={{
          fontFamily: body,
          fontWeight: 600,
          fontSize: 62,
          lineHeight: 1.1,
          color: "#eafff6",
          padding: "0 70px",
          textShadow: "0 6px 30px rgba(0,0,0,0.5)",
        }}
      >
        {title}
      </div>
    </div>
  );
};

const PhoneScene: React.FC<{
  eyebrow: string;
  title: string;
  children: React.ReactNode;
}> = ({ eyebrow, title, children }) => {
  const frame = useCurrentFrame();
  const y = interpolate(frame, [0, 24], [140, 0], {
    extrapolateRight: "clamp",
    easing: EASE,
  });
  const op = interpolate(frame, [0, 16], [0, 1], { extrapolateRight: "clamp" });
  const float = Math.sin(frame / 26) * 8;
  return (
    <AbsoluteFill style={{ alignItems: "center" }}>
      <div
        style={{
          marginTop: 64,
          opacity: op,
          translate: `0px ${y + float}px`,
        }}
      >
        <Phone width={604} height={1230}>
          {children}
        </Phone>
      </div>
      <Caption eyebrow={eyebrow} title={title} />
    </AbsoluteFill>
  );
};

// ── Logo ────────────────────────────────────────────────────────────────────
const LogoScene: React.FC = () => {
  const frame = useCurrentFrame();
  const scale = interpolate(frame, [0, 24], [0.7, 1], {
    extrapolateRight: "clamp",
    easing: EASE,
  });
  const glow = interpolate(frame % 60, [0, 30, 60], [0.3, 0.85, 0.3]);
  const op = interpolate(frame, [0, 18], [0, 1], { extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <PulseRings cx={50} cy={46} />
      <div
        style={{
          opacity: op,
          scale,
          fontFamily: display,
          fontWeight: 700,
          fontSize: 168,
          letterSpacing: 6,
          color: ON_SURFACE,
          textShadow: `0 0 ${40 + glow * 70}px rgba(29,185,84,${glow})`,
        }}
      >
        RLINK
      </div>
      <div
        style={{
          opacity: interpolate(frame - 22, [0, 16], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          fontFamily: body,
          fontWeight: 500,
          fontSize: 46,
          color: "rgba(234,255,246,0.7)",
          marginTop: 30,
        }}
      >
        Связь без границ
      </div>
    </AbsoluteFill>
  );
};

// ── CTA ─────────────────────────────────────────────────────────────────────
const CtaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const glow = interpolate(frame % 60, [0, 30, 60], [0.3, 0.9, 0.3]);
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <PulseRings cx={50} cy={50} />
      <div
        style={{
          fontFamily: display,
          fontWeight: 700,
          fontSize: 150,
          letterSpacing: 6,
          color: ON_SURFACE,
          textShadow: `0 0 ${40 + glow * 80}px rgba(29,185,84,${glow})`,
        }}
      >
        RLINK
      </div>
      <div
        style={{
          opacity: interpolate(frame - 14, [0, 16], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          fontFamily: body,
          fontWeight: 600,
          fontSize: 60,
          color: "#eafff6",
          textAlign: "center",
          padding: "0 80px",
          marginTop: 30,
        }}
      >
        Начни общаться прямо сейчас
      </div>
      <div
        style={{
          opacity: interpolate(frame - 24, [0, 16], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          fontFamily: body,
          fontWeight: 600,
          fontSize: 40,
          color: "#2BC0A8",
          letterSpacing: 2,
          marginTop: 28,
        }}
      >
        rendergames.ru
      </div>
    </AbsoluteFill>
  );
};

const fadeT = () => (
  <TransitionSeries.Transition
    presentation={fade()}
    timing={linearTiming({ durationInFrames: 14 })}
  />
);

export const RlinkPromoReal: React.FC<{ voice?: boolean }> = ({
  voice = false,
}) => {
  // Voiceover clip start frames, aligned to each scene (accounts for the
  // 14-frame fade overlaps between TransitionSeries sequences).
  const vo = [4, 70, 151, 247, 333, 414];
  return (
    <AbsoluteFill style={{ backgroundColor: SURFACE }}>
      <Audio src={staticFile("music.wav")} volume={voice ? 0.4 : 0.78} />
      {voice &&
        vo.map((from, i) => (
          <Sequence key={i} from={from}>
            <Audio src={staticFile(`vo/0${i + 1}.wav`)} volume={1} />
          </Sequence>
        ))}
      <EmeraldBackground />
      <TransitionSeries>
        <TransitionSeries.Sequence durationInFrames={80}>
          <LogoScene />
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={95}>
          <PhoneScene eyebrow="Все чаты" title="Зашифрованные сообщения">
            <HomeScreen />
          </PhoneScene>
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={110}>
          <PhoneScene eyebrow="Общение" title="Текст, голос и расшифровка">
            <ChatScreen />
          </PhoneScene>
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={100}>
          <PhoneScene eyebrow="Голос и видео" title="Звонки между странами">
            <CallScreen />
          </PhoneScene>
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={95}>
          <PhoneScene eyebrow="Каналы" title="Делись с тысячами людей">
            <ChannelScreen />
          </PhoneScene>
        </TransitionSeries.Sequence>
        {fadeT()}
        <TransitionSeries.Sequence durationInFrames={110}>
          <CtaScene />
        </TransitionSeries.Sequence>
      </TransitionSeries>
      <AbsoluteFill
        style={{
          background:
            "radial-gradient(120% 90% at 50% 50%, transparent 58%, rgba(0,0,0,0.5))",
          pointerEvents: "none",
        }}
      />
    </AbsoluteFill>
  );
};
