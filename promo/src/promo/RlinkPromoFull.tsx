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
import { loadFont as loadOrbitron } from "@remotion/google-fonts/Orbitron";
import { loadFont as loadMontserrat } from "@remotion/google-fonts/Montserrat";
import { PulseRings } from "./Brand";
import {
  BotScreen,
  CallScreen,
  ChannelScreen,
  ChatScreen,
  GroupScreen,
  HomeScreen,
  ON_SURFACE,
  Phone,
  PRIMARY,
  StoriesScreen,
  SURFACE,
  VideoCallScreen,
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

// ── Shared backdrop / caption / phone wrapper ───────────────────────────────
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

// Each scene fades its OWN content in and fully out (to the background) within
// its own window — so there's a clean gap between scenes and nothing stacks.
const Scene: React.FC<{
  durationInFrames: number;
  children: React.ReactNode;
}> = ({ durationInFrames, children }) => {
  const frame = useCurrentFrame();
  const fin = interpolate(frame, [0, 12], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const fout = interpolate(
    frame,
    [durationInFrames - 14, durationInFrames - 4],
    [1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  return <AbsoluteFill style={{ opacity: fin * fout }}>{children}</AbsoluteFill>;
};

const Caption: React.FC<{ eyebrow: string; title: string }> = ({
  eyebrow,
  title,
}) => {
  const frame = useCurrentFrame();
  const op = interpolate(frame - 16, [0, 14], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const ty = interpolate(frame - 16, [0, 14], [30, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  return (
    <div
      style={{
        position: "absolute",
        bottom: 92,
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
          fontSize: 58,
          lineHeight: 1.12,
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
      <div style={{ marginTop: 54, opacity: op, translate: `0px ${y + float}px` }}>
        <Phone width={566} height={1180}>
          {children}
        </Phone>
      </div>
      <Caption eyebrow={eyebrow} title={title} />
    </AbsoluteFill>
  );
};

// ── Universality: laptop + tablet + phone ───────────────────────────────────
const ScreenScaled: React.FC<{
  w: number;
  h: number;
  radius: number;
  children: React.ReactNode;
}> = ({ w, h, radius, children }) => (
  <div
    style={{
      width: w,
      height: h,
      borderRadius: radius,
      overflow: "hidden",
      background: SURFACE,
      position: "relative",
    }}
  >
    <div
      style={{
        width: 566,
        height: 1180,
        transformOrigin: "top left",
        scale: String(w / 566),
      }}
    >
      {children}
    </div>
  </div>
);

const UniversalityScene: React.FC = () => {
  const frame = useCurrentFrame();
  const pop = (d: number) =>
    interpolate(frame - d, [0, 18], [0, 1], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
      easing: EASE,
    });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <div
        style={{
          position: "relative",
          width: 980,
          height: 1080,
          marginTop: -40,
        }}
      >
        {/* Laptop (back-left) */}
        <div
          style={{
            position: "absolute",
            left: -40,
            top: 250,
            opacity: pop(2),
            scale: String(0.86 + 0.14 * pop(2)),
            transformOrigin: "center",
          }}
        >
          <div
            style={{
              width: 720,
              background: "#0b0b0b",
              borderRadius: 22,
              padding: 16,
              boxShadow: "0 40px 100px rgba(0,0,0,0.6)",
              border: "2px solid rgba(45,212,191,0.18)",
            }}
          >
            {/* browser chrome */}
            <div
              style={{
                height: 40,
                background: "#1a1a1a",
                borderRadius: "10px 10px 0 0",
                display: "flex",
                alignItems: "center",
                gap: 8,
                padding: "0 16px",
              }}
            >
              {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
                <div
                  key={c}
                  style={{ width: 14, height: 14, borderRadius: 7, background: c }}
                />
              ))}
              <div
                style={{
                  marginLeft: 14,
                  flex: 1,
                  height: 22,
                  borderRadius: 11,
                  background: "#2a2a2a",
                  color: "#888",
                  fontFamily: body,
                  fontSize: 16,
                  display: "flex",
                  alignItems: "center",
                  padding: "0 14px",
                }}
              >
                rendergames.ru/rlink-web
              </div>
            </div>
            <ScreenScaled w={688} h={430} radius={0}>
              <ChannelScreen />
            </ScreenScaled>
          </div>
          {/* laptop base */}
          <div
            style={{
              width: 820,
              height: 22,
              marginLeft: -50,
              borderRadius: "0 0 16px 16px",
              background: "linear-gradient(#161616,#0a0a0a)",
            }}
          />
        </div>
        {/* Tablet (back-right) */}
        <div
          style={{
            position: "absolute",
            right: -30,
            top: 150,
            opacity: pop(12),
            scale: String(0.86 + 0.14 * pop(12)),
          }}
        >
          <div
            style={{
              width: 380,
              background: "#000",
              borderRadius: 36,
              padding: 14,
              boxShadow: "0 40px 100px rgba(0,0,0,0.55)",
              border: "2px solid rgba(45,212,191,0.16)",
            }}
          >
            <ScreenScaled w={352} h={490} radius={24}>
              <HomeScreen />
            </ScreenScaled>
          </div>
        </div>
        {/* Phone (front-center) */}
        <div
          style={{
            position: "absolute",
            left: "50%",
            top: 70,
            translate: "-50% 0",
            opacity: pop(22),
            scale: String(0.9 + 0.1 * pop(22)),
          }}
        >
          <Phone width={420} height={870}>
            <ChatScreen />
          </Phone>
        </div>
      </div>
      <Caption eyebrow="Везде" title="Телефон, планшет и ноутбук" />
    </AbsoluteFill>
  );
};

// ── Connectivity (Bluetooth offline / server online) ────────────────────────
const MiniPhone: React.FC<{ emoji: string; bg: string }> = ({ emoji, bg }) => (
  <div
    style={{
      width: 150,
      height: 310,
      borderRadius: 30,
      background: "#000",
      padding: 8,
      boxShadow: "0 20px 60px rgba(0,0,0,0.5)",
    }}
  >
    <div
      style={{
        width: "100%",
        height: "100%",
        borderRadius: 24,
        background: SURFACE,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontSize: 70,
      }}
    >
      <div
        style={{
          width: 96,
          height: 96,
          borderRadius: "50%",
          background: bg,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        {emoji}
      </div>
    </div>
  </div>
);

const ConnectivityScene: React.FC<{
  mode: "bt" | "server";
  eyebrow: string;
  title: string;
}> = ({ mode, eyebrow, title }) => {
  const frame = useCurrentFrame();
  const op = interpolate(frame, [0, 16], [0, 1], { extrapolateRight: "clamp" });
  const accent = mode === "bt" ? "#3B9DFF" : PRIMARY;
  // travelling packet 0..1
  const t = (frame % 50) / 50;
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <div
        style={{
          opacity: op,
          display: "flex",
          alignItems: "center",
          gap: 70,
          marginTop: -60,
          position: "relative",
        }}
      >
        <MiniPhone emoji="🦊" bg="#7C4DFF" />
        {/* link */}
        <div
          style={{
            position: "relative",
            width: 260,
            height: 200,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <div
            style={{
              width: 150,
              height: 150,
              borderRadius: 34,
              background:
                mode === "server"
                  ? "rgba(29,185,84,0.16)"
                  : "rgba(59,157,255,0.16)",
              border: `2px solid ${accent}66`,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 78,
            }}
          >
            {mode === "server" ? (
              "☁️"
            ) : (
              <svg
                width={80}
                height={80}
                viewBox="0 0 24 24"
                fill="none"
                stroke={accent}
                strokeWidth={2.2}
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <polyline points="8.5,8.5 15.5,15.5 12,19 12,5 15.5,8.5 8.5,15.5" />
              </svg>
            )}
          </div>
          {/* pulse rings around the link */}
          {[0, 1, 2].map((i) => {
            const p = ((frame / 16 + i * 0.66) % 2) / 2;
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  width: 80 + p * 220,
                  height: 80 + p * 220,
                  borderRadius: "50%",
                  border: `2px solid ${accent}`,
                  opacity: (1 - p) * 0.5,
                }}
              />
            );
          })}
          {/* dashed line + packet */}
          <div
            style={{
              position: "absolute",
              left: -90,
              right: -90,
              height: 4,
              background: `repeating-linear-gradient(90deg, ${accent}, ${accent} 14px, transparent 14px, transparent 28px)`,
              opacity: 0.5,
            }}
          />
          <div
            style={{
              position: "absolute",
              left: interpolate(t, [0, 1], [-90, 350]),
              width: 22,
              height: 22,
              borderRadius: "50%",
              background: accent,
              boxShadow: `0 0 22px ${accent}`,
            }}
          />
        </div>
        <MiniPhone emoji="🐱" bg="#EC407A" />
      </div>
      <div
        style={{
          opacity: op,
          marginTop: 40,
          fontFamily: body,
          fontWeight: 600,
          fontSize: 30,
          color: mode === "bt" ? "#bfe2ff" : "#bff3df",
        }}
      >
        {mode === "bt" ? "Без интернета · рядом · оффлайн" : "Через сервер · по всему миру"}
      </div>
      <Caption eyebrow={eyebrow} title={title} />
    </AbsoluteFill>
  );
};

// ── Logo + CTA ──────────────────────────────────────────────────────────────
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
          fontSize: 58,
          color: "#eafff6",
          textAlign: "center",
          padding: "0 80px",
          marginTop: 30,
        }}
      >
        Скачай и общайся без границ
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

// Sequential scenes with a real gap between them (each scene fades fully out
// before the next fades in — no two scenes/captions ever overlap).
const SCENES: { d: number; el: React.ReactNode }[] = [
  { d: 80, el: <LogoScene /> },
  { d: 100, el: <UniversalityScene /> },
  {
    d: 88,
    el: (
      <PhoneScene eyebrow="Интерфейс" title="Все чаты под рукой">
        <HomeScreen />
      </PhoneScene>
    ),
  },
  {
    d: 106,
    el: (
      <PhoneScene eyebrow="Сообщения" title="Текст, голос и расшифровка">
        <ChatScreen />
      </PhoneScene>
    ),
  },
  {
    d: 100,
    el: (
      <PhoneScene eyebrow="Боты" title="Команды и кнопки">
        <BotScreen />
      </PhoneScene>
    ),
  },
  {
    d: 98,
    el: (
      <PhoneScene eyebrow="Группы" title="Общайтесь компанией">
        <GroupScreen />
      </PhoneScene>
    ),
  },
  {
    d: 94,
    el: (
      <PhoneScene eyebrow="Каналы" title="Делись с тысячами">
        <ChannelScreen />
      </PhoneScene>
    ),
  },
  {
    d: 98,
    el: (
      <PhoneScene eyebrow="Истории" title="Фото, видео и рисунки">
        <StoriesScreen />
      </PhoneScene>
    ),
  },
  {
    d: 90,
    el: (
      <ConnectivityScene
        mode="bt"
        eyebrow="Bluetooth"
        title="Работает без интернета"
      />
    ),
  },
  {
    d: 90,
    el: (
      <ConnectivityScene
        mode="server"
        eyebrow="Сервер"
        title="И на любом расстоянии"
      />
    ),
  },
  {
    d: 94,
    el: (
      <PhoneScene eyebrow="Звонки" title="Голос между странами">
        <CallScreen />
      </PhoneScene>
    ),
  },
  {
    d: 96,
    el: (
      <PhoneScene eyebrow="Видеозвонки" title="Лицом к лицу">
        <VideoCallScreen />
      </PhoneScene>
    ),
  },
  { d: 106, el: <CtaScene /> },
];

const GAP = 8; // frames of just-background between scenes

export const RLINK_FULL_DURATION = (() => {
  let c = 0;
  for (const s of SCENES) c += s.d + GAP;
  return c - GAP;
})();

export const RlinkPromoFull: React.FC = () => {
  let cursor = 0;
  return (
    <AbsoluteFill style={{ backgroundColor: SURFACE }}>
      <Audio src={staticFile("music.wav")} volume={0.7} loop />
      <EmeraldBackground />
      {SCENES.map((s, i) => {
        const from = cursor;
        cursor += s.d + GAP;
        return (
          <Sequence key={i} from={from} durationInFrames={s.d}>
            <Scene durationInFrames={s.d}>{s.el}</Scene>
          </Sequence>
        );
      })}
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
