import React from "react";
import {
  AbsoluteFill,
  Easing,
  interpolate,
  useCurrentFrame,
} from "remotion";
import { loadFont as loadRoboto } from "@remotion/google-fonts/Roboto";

const { fontFamily: ui } = loadRoboto("normal", {
  weights: ["400", "500", "700"],
  subsets: ["cyrillic", "latin"],
});

// ── Real Rlink design tokens (from the Flutter theme) ───────────────────────
export const PRIMARY = "#1DB954";
export const ON_PRIMARY = "#ffffff";
export const SURFACE = "#121212";
export const SURF_HIGH = "#1e1e1e"; // incoming bubble
export const SURF_HIGHEST = "#262626"; // input bar / chips
export const ON_SURFACE = "#ECECEC";
export const ON_SURFACE_VAR = "#9aa0a6";
export const GRAD = ["#1DB954", "#0F9B8E", "#2BC0A8"];

const EASE = Easing.bezier(0.16, 1, 0.3, 1);

export const rise = (frame: number, delay: number, dist = 28) => ({
  opacity: interpolate(frame - delay, [0, 14], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  }),
  translate: `0px ${interpolate(frame - delay, [0, 14], [dist, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  })}px`,
});

// ── Phone frame ─────────────────────────────────────────────────────────────
export const Phone: React.FC<{
  children: React.ReactNode;
  width?: number;
  height?: number;
}> = ({ children, width = 600, height = 1280 }) => {
  return (
    <div
      style={{
        width,
        height,
        borderRadius: 62,
        background: "#000",
        padding: 12,
        boxShadow:
          "0 40px 120px rgba(0,0,0,0.6), 0 0 0 2px rgba(45,212,191,0.18), 0 0 80px rgba(29,185,84,0.18)",
        position: "relative",
      }}
    >
      <div
        style={{
          width: "100%",
          height: "100%",
          borderRadius: 50,
          overflow: "hidden",
          background: SURFACE,
          position: "relative",
          fontFamily: ui,
        }}
      >
        {children}
        {/* notch */}
        <div
          style={{
            position: "absolute",
            top: 14,
            left: "50%",
            translate: "-50% 0",
            width: 150,
            height: 30,
            borderRadius: 18,
            background: "#000",
          }}
        />
      </div>
    </div>
  );
};

const StatusBar: React.FC<{ dark?: boolean }> = ({ dark }) => {
  const c = dark ? "#fff" : ON_SURFACE;
  return (
    <div
      style={{
        height: 56,
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        padding: "0 38px",
        color: c,
        fontFamily: ui,
        fontWeight: 600,
        fontSize: 26,
      }}
    >
      <span>9:41</span>
      <span style={{ fontSize: 22, letterSpacing: 2 }}>📶 🔋</span>
    </div>
  );
};

const Avatar: React.FC<{
  size: number;
  bg?: string;
  emoji?: string;
  letter?: string;
}> = ({ size, bg = "#3a3f44", emoji, letter }) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: "50%",
      background: bg,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      fontSize: size * 0.5,
      color: "#fff",
      fontWeight: 600,
      flexShrink: 0,
    }}
  >
    {emoji ?? letter}
  </div>
);

const Bubble: React.FC<{
  out?: boolean;
  delay: number;
  children: React.ReactNode;
  meta?: string;
}> = ({ out, delay, children, meta }) => {
  const frame = useCurrentFrame();
  const f = frame - delay;
  const opacity = interpolate(f, [0, 10], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const s = interpolate(f, [0, 12], [0.85, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  return (
    <div
      style={{
        opacity,
        scale: s,
        alignSelf: out ? "flex-end" : "flex-start",
        transformOrigin: out ? "bottom right" : "bottom left",
        maxWidth: "76%",
        background: out ? PRIMARY : SURF_HIGH,
        color: out ? ON_PRIMARY : ON_SURFACE,
        fontSize: 28,
        lineHeight: 1.3,
        padding: "16px 22px 14px",
        borderRadius: 22,
        borderBottomRightRadius: out ? 6 : 22,
        borderBottomLeftRadius: out ? 22 : 6,
        marginBottom: 14,
        position: "relative",
      }}
    >
      {children}
      {meta && (
        <span
          style={{
            display: "block",
            textAlign: "right",
            fontSize: 18,
            marginTop: 4,
            color: out ? "rgba(255,255,255,0.7)" : ON_SURFACE_VAR,
          }}
        >
          {meta} {out && "✓✓"}
        </span>
      )}
    </div>
  );
};

const TypingDots: React.FC<{ delay: number; until: number }> = ({
  delay,
  until,
}) => {
  const frame = useCurrentFrame();
  if (frame < delay || frame > until) return null;
  const dot = (i: number) => {
    const o = 0.3 + 0.7 * (0.5 + 0.5 * Math.sin((frame / 6 + i) * 1.4));
    return (
      <div
        key={i}
        style={{
          width: 12,
          height: 12,
          borderRadius: "50%",
          background: ON_SURFACE_VAR,
          opacity: o,
        }}
      />
    );
  };
  return (
    <div
      style={{
        alignSelf: "flex-start",
        background: SURF_HIGH,
        borderRadius: 22,
        borderBottomLeftRadius: 6,
        padding: "20px 24px",
        display: "flex",
        gap: 8,
        marginBottom: 14,
      }}
    >
      {[0, 1, 2].map(dot)}
    </div>
  );
};

// ── Chat conversation screen ────────────────────────────────────────────────
export const ChatScreen: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: SURFACE, fontFamily: ui }}>
      <StatusBar />
      {/* app bar */}
      <div
        style={{
          height: 92,
          display: "flex",
          alignItems: "center",
          gap: 18,
          padding: "0 26px",
          borderBottom: "1px solid rgba(255,255,255,0.06)",
        }}
      >
        <span style={{ color: PRIMARY, fontSize: 34 }}>‹</span>
        <Avatar size={64} bg="#7C4DFF" emoji="🦊" />
        <div style={{ flex: 1 }}>
          <div style={{ color: ON_SURFACE, fontSize: 30, fontWeight: 600 }}>
            Аня
          </div>
          <div style={{ color: PRIMARY, fontSize: 22 }}>в сети</div>
        </div>
        <span style={{ color: ON_SURFACE, fontSize: 30 }}>📞</span>
        <span style={{ color: ON_SURFACE, fontSize: 30, marginLeft: 18 }}>
          🎥
        </span>
      </div>
      {/* messages */}
      <div
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
          padding: "24px 26px 0",
        }}
      >
        <div
          style={{
            alignSelf: "center",
            background: SURF_HIGHEST,
            color: ON_SURFACE_VAR,
            fontSize: 20,
            padding: "6px 18px",
            borderRadius: 16,
            marginBottom: 20,
          }}
        >
          Сегодня
        </div>
        <Bubble delay={6} meta="9:40">
          Привет! Ты как там, далеко? 🌍
        </Bubble>
        <Bubble out delay={22} meta="9:41">
          Другая страна, а связь — будто рядом 💚
        </Bubble>
        <TypingDots delay={40} until={58} />
        <Bubble delay={58} meta="9:41">
          🎤 Голосовое · расшифровка готова
        </Bubble>
      </div>
      {/* input bar */}
      <div style={{ padding: "16px 24px 26px" }}>
        <div
          style={{
            height: 76,
            background: SURF_HIGHEST,
            borderRadius: 38,
            display: "flex",
            alignItems: "center",
            padding: "0 26px",
            gap: 18,
            color: ON_SURFACE_VAR,
            fontSize: 27,
          }}
        >
          <span style={{ fontSize: 30 }}>📎</span>
          <span style={{ flex: 1 }}>Сообщение…</span>
          <span style={{ fontSize: 30 }}>😊</span>
          <div
            style={{
              width: 56,
              height: 56,
              borderRadius: "50%",
              background: PRIMARY,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 28,
            }}
          >
            🎤
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ── Call screen ─────────────────────────────────────────────────────────────
export const CallScreen: React.FC = () => {
  const frame = useCurrentFrame();
  const connected = frame > 34;
  const bars = 36;
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(140% 90% at 50% 18%, rgba(15,155,142,0.55), ${SURFACE} 62%)`,
        fontFamily: ui,
        alignItems: "center",
      }}
    >
      <StatusBar dark />
      <div style={{ height: 120 }} />
      <Avatar size={210} bg="#0F9B8E" emoji="🦊" />
      <div
        style={{ color: "#fff", fontSize: 46, fontWeight: 600, marginTop: 34 }}
      >
        Аня
      </div>
      <div style={{ color: "rgba(255,255,255,0.65)", fontSize: 26, marginTop: 10 }}>
        {connected ? "Аудиозвонок · 00:0" + (Math.floor((frame - 34) / 30) % 10) : "Соединение…"}
      </div>
      {/* waveline */}
      <div
        style={{
          marginTop: 50,
          display: "flex",
          alignItems: "center",
          gap: 7,
          height: 90,
        }}
      >
        {Array.from({ length: bars }).map((_, i) => {
          const env = Math.sin((i / (bars - 1)) * Math.PI);
          const h = connected
            ? 14 +
              78 *
                env *
                Math.abs(
                  Math.sin(i * 0.7 + frame / 4) * 0.7 +
                    Math.sin(i * 1.3 - frame / 6) * 0.3,
                )
            : 10;
          return (
            <div
              key={i}
              style={{
                width: 6,
                height: h,
                borderRadius: 3,
                background: connected
                  ? "rgba(255,255,255,0.92)"
                  : "rgba(255,255,255,0.25)",
              }}
            />
          );
        })}
      </div>
      <div style={{ flex: 1 }} />
      {/* controls */}
      <div style={{ display: "flex", gap: 30, marginBottom: 80 }}>
        {[
          { i: "🎙️", bg: "rgba(255,255,255,0.16)" },
          { i: "🔊", bg: "rgba(255,255,255,0.16)" },
          { i: "🎥", bg: "rgba(255,255,255,0.16)" },
          { i: "📞", bg: "#ef4444" },
        ].map((b, k) => (
          <div
            key={k}
            style={{
              width: 92,
              height: 92,
              borderRadius: "50%",
              background: b.bg,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 40,
              transform: k === 3 ? "rotate(135deg)" : "none",
            }}
          >
            {b.i}
          </div>
        ))}
      </div>
    </AbsoluteFill>
  );
};

// ── Channel screen ──────────────────────────────────────────────────────────
export const ChannelScreen: React.FC = () => {
  const frame = useCurrentFrame();
  const views = Math.floor(interpolate(frame, [20, 70], [0, 12480], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  }));
  return (
    <AbsoluteFill style={{ background: SURFACE, fontFamily: ui }}>
      <StatusBar />
      {/* banner */}
      <div
        style={{
          height: 230,
          background: `linear-gradient(120deg, ${GRAD[0]}, ${GRAD[1]} 60%, ${GRAD[2]})`,
          position: "relative",
        }}
      >
        <div
          style={{
            position: "absolute",
            left: 26,
            top: 18,
            color: "rgba(255,255,255,0.9)",
            fontSize: 30,
          }}
        >
          ‹
        </div>
      </div>
      <div
        style={{
          display: "flex",
          alignItems: "flex-end",
          gap: 22,
          padding: "0 28px",
          marginTop: -56,
        }}
      >
        <div
          style={{
            width: 132,
            height: 132,
            borderRadius: 32,
            background: "#0F9B8E",
            border: `5px solid ${SURFACE}`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: 64,
          }}
        >
          📢
        </div>
        <div style={{ paddingBottom: 10 }}>
          <div style={{ color: ON_SURFACE, fontSize: 36, fontWeight: 700 }}>
            RLINK News
          </div>
          <div style={{ color: ON_SURFACE_VAR, fontSize: 24 }}>
            {(12480).toLocaleString("ru-RU")} подписчиков
          </div>
        </div>
      </div>
      {/* post */}
      <div style={{ padding: "32px 28px 0" }}>
        <div
          style={{
            ...rise(frame, 16),
            background: SURF_HIGH,
            borderRadius: 24,
            padding: 26,
          }}
        >
          <div style={{ color: ON_SURFACE, fontSize: 28, lineHeight: 1.4 }}>
            🚀 Звонки теперь работают между странами — проверьте видеосвязь!
          </div>
          <div
            style={{
              height: 280,
              borderRadius: 18,
              marginTop: 20,
              background: `linear-gradient(135deg, ${GRAD[1]}, #0a3d37)`,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 90,
            }}
          >
            🌍
          </div>
          <div
            style={{
              display: "flex",
              gap: 30,
              marginTop: 20,
              color: ON_SURFACE_VAR,
              fontSize: 24,
            }}
          >
            <span>👁 {views.toLocaleString("ru-RU")}</span>
            <span>❤️ 1.2K</span>
            <span>💬 340</span>
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ── Home / chat list screen ─────────────────────────────────────────────────
export const HomeScreen: React.FC = () => {
  const frame = useCurrentFrame();
  const chats = [
    { e: "🦊", bg: "#7C4DFF", n: "Аня", m: "Другая страна, а связь рядом 💚", t: "9:41", u: 0 },
    { e: "🐧", bg: "#2196F3", n: "Команда Rlink", m: "🎤 Голосовое сообщение", t: "9:38", u: 3 },
    { e: "📢", bg: "#0F9B8E", n: "RLINK News", m: "Звонки между странами!", t: "9:20", u: 12 },
    { e: "🐱", bg: "#EC407A", n: "Максим", m: "Созвонимся вечером?", t: "Вчера", u: 0 },
    { e: "🦉", bg: "#D4A017", n: "Семья", m: "Папа: 📷 Фото", t: "Вчера", u: 0 },
  ];
  return (
    <AbsoluteFill style={{ background: SURFACE, fontFamily: ui }}>
      <StatusBar />
      <div
        style={{
          padding: "10px 30px 18px",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
        }}
      >
        <div style={{ color: ON_SURFACE, fontSize: 44, fontWeight: 700 }}>
          Rlink
        </div>
        <span style={{ color: ON_SURFACE, fontSize: 34 }}>🔍</span>
      </div>
      {chats.map((c, i) => (
        <div
          key={i}
          style={{
            ...rise(frame, 6 + i * 6, 24),
            display: "flex",
            alignItems: "center",
            gap: 22,
            padding: "18px 30px",
          }}
        >
          <Avatar size={84} bg={c.bg} emoji={c.e} />
          <div style={{ flex: 1, borderBottom: "1px solid rgba(255,255,255,0.05)", paddingBottom: 18 }}>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span style={{ color: ON_SURFACE, fontSize: 30, fontWeight: 600 }}>
                {c.n}
              </span>
              <span style={{ color: ON_SURFACE_VAR, fontSize: 22 }}>{c.t}</span>
            </div>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
                marginTop: 6,
              }}
            >
              <span
                style={{
                  color: ON_SURFACE_VAR,
                  fontSize: 25,
                  overflow: "hidden",
                  whiteSpace: "nowrap",
                  textOverflow: "ellipsis",
                  maxWidth: 360,
                }}
              >
                {c.m}
              </span>
              {c.u > 0 && (
                <span
                  style={{
                    background: PRIMARY,
                    color: "#063",
                    fontSize: 22,
                    fontWeight: 700,
                    minWidth: 36,
                    height: 36,
                    borderRadius: 18,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    padding: "0 10px",
                  }}
                >
                  {c.u}
                </span>
              )}
            </div>
          </div>
        </div>
      ))}
    </AbsoluteFill>
  );
};

// ── Group chat screen (multiple coloured senders) ───────────────────────────
const GroupBubble: React.FC<{
  delay: number;
  sender?: string;
  senderColor?: string;
  out?: boolean;
  children: React.ReactNode;
}> = ({ delay, sender, senderColor, out, children }) => {
  const frame = useCurrentFrame();
  const f = frame - delay;
  const opacity = interpolate(f, [0, 10], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const s = interpolate(f, [0, 12], [0.85, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: EASE,
  });
  return (
    <div
      style={{
        opacity,
        scale: s,
        alignSelf: out ? "flex-end" : "flex-start",
        transformOrigin: out ? "bottom right" : "bottom left",
        maxWidth: "74%",
        background: out ? PRIMARY : SURF_HIGH,
        color: out ? ON_PRIMARY : ON_SURFACE,
        fontSize: 27,
        lineHeight: 1.3,
        padding: "12px 22px 14px",
        borderRadius: 22,
        borderBottomRightRadius: out ? 6 : 22,
        borderBottomLeftRadius: out ? 22 : 6,
        marginBottom: 14,
      }}
    >
      {sender && !out && (
        <div
          style={{
            color: senderColor,
            fontWeight: 700,
            fontSize: 23,
            marginBottom: 3,
          }}
        >
          {sender}
        </div>
      )}
      {children}
    </div>
  );
};

export const GroupScreen: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: SURFACE, fontFamily: ui }}>
      <StatusBar />
      <div
        style={{
          height: 92,
          display: "flex",
          alignItems: "center",
          gap: 18,
          padding: "0 26px",
          borderBottom: "1px solid rgba(255,255,255,0.06)",
        }}
      >
        <span style={{ color: PRIMARY, fontSize: 34 }}>‹</span>
        <Avatar size={64} bg="#26A69A" emoji="👥" />
        <div style={{ flex: 1 }}>
          <div style={{ color: ON_SURFACE, fontSize: 30, fontWeight: 600 }}>
            Друзья Rlink
          </div>
          <div style={{ color: ON_SURFACE_VAR, fontSize: 22 }}>
            8 участников, 5 в сети
          </div>
        </div>
        <span style={{ color: ON_SURFACE, fontSize: 28 }}>⋮</span>
      </div>
      <div
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
          padding: "24px 26px 0",
        }}
      >
        <GroupBubble delay={6} sender="Аня" senderColor="#7C4DFF">
          Кто идёт вечером на созвон? 🎥
        </GroupBubble>
        <GroupBubble delay={22} sender="Максим" senderColor="#EC407A">
          Я за! Захвачу демку
        </GroupBubble>
        <GroupBubble delay={40} out>
          Создаю групповой звонок 🚀
        </GroupBubble>
        <GroupBubble delay={58} sender="Лена" senderColor="#FFA726">
          🔥🔥🔥
        </GroupBubble>
      </div>
      <div style={{ padding: "16px 24px 26px" }}>
        <div
          style={{
            height: 76,
            background: SURF_HIGHEST,
            borderRadius: 38,
            display: "flex",
            alignItems: "center",
            padding: "0 26px",
            gap: 18,
            color: ON_SURFACE_VAR,
            fontSize: 27,
          }}
        >
          <span style={{ fontSize: 30 }}>📎</span>
          <span style={{ flex: 1 }}>Сообщение…</span>
          <div
            style={{
              width: 56,
              height: 56,
              borderRadius: "50%",
              background: PRIMARY,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 28,
            }}
          >
            🎤
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ── Bot chat screen (slash commands + inline buttons) ───────────────────────
export const BotScreen: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: SURFACE, fontFamily: ui }}>
      <StatusBar />
      <div
        style={{
          height: 92,
          display: "flex",
          alignItems: "center",
          gap: 18,
          padding: "0 26px",
          borderBottom: "1px solid rgba(255,255,255,0.06)",
        }}
      >
        <span style={{ color: PRIMARY, fontSize: 34 }}>‹</span>
        <Avatar size={64} bg="#0F9B8E" emoji="🤖" />
        <div style={{ flex: 1 }}>
          <div
            style={{
              color: ON_SURFACE,
              fontSize: 30,
              fontWeight: 600,
              display: "flex",
              alignItems: "center",
              gap: 8,
            }}
          >
            Emoji-бот <span style={{ color: PRIMARY, fontSize: 26 }}>✔</span>
          </div>
          <div style={{ color: ON_SURFACE_VAR, fontSize: 22 }}>бот</div>
        </div>
      </div>
      <div
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
          padding: "24px 26px 0",
        }}
      >
        <Bubble delay={6}>
          Привет! Я добавляю кастомные эмодзи 😎{"\n"}Выбери команду:
        </Bubble>
        <div
          style={{
            ...rise(frame, 22),
            display: "flex",
            flexWrap: "wrap",
            gap: 12,
            alignSelf: "flex-start",
            marginBottom: 16,
            maxWidth: "78%",
          }}
        >
          {["/new — новый набор", "/add :код:", "/packs"].map((b, i) => (
            <div
              key={i}
              style={{
                background: SURF_HIGHEST,
                border: `1.5px solid ${PRIMARY}55`,
                color: PRIMARY,
                fontSize: 24,
                fontWeight: 600,
                padding: "12px 20px",
                borderRadius: 16,
              }}
            >
              {b}
            </div>
          ))}
        </div>
        <Bubble out delay={40} meta="9:42">
          /new Мемы
        </Bubble>
        <Bubble delay={56}>
          Набор «Мемы» создан ✅ Пришли картинку с командой /add :lol:
        </Bubble>
      </div>
      <div style={{ padding: "16px 24px 26px" }}>
        <div
          style={{
            height: 76,
            background: SURF_HIGHEST,
            borderRadius: 38,
            display: "flex",
            alignItems: "center",
            padding: "0 26px",
            gap: 18,
            color: ON_SURFACE_VAR,
            fontSize: 27,
          }}
        >
          <span style={{ fontSize: 30 }}>/</span>
          <span style={{ flex: 1 }}>Команда…</span>
          <div
            style={{
              width: 56,
              height: 56,
              borderRadius: "50%",
              background: PRIMARY,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 26,
            }}
          >
            ➤
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ── Stories viewer ──────────────────────────────────────────────────────────
export const StoriesScreen: React.FC = () => {
  const frame = useCurrentFrame();
  const prog = interpolate(frame, [0, 110], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <AbsoluteFill style={{ fontFamily: ui }}>
      <AbsoluteFill
        style={{
          background: `linear-gradient(160deg, ${GRAD[2]}, ${GRAD[1]} 45%, #0a3d37)`,
        }}
      />
      {/* drawn doodle + text overlay */}
      <div
        style={{
          position: "absolute",
          top: "34%",
          left: 0,
          width: "100%",
          textAlign: "center",
          color: "#fff",
          fontSize: 64,
          fontWeight: 800,
          textShadow: "0 6px 24px rgba(0,0,0,0.45)",
        }}
      >
        Поездка мечты ✈️
      </div>
      <div
        style={{
          position: "absolute",
          top: "50%",
          left: "26%",
          fontSize: 120,
        }}
      >
        🏔️
      </div>
      <svg
        style={{ position: "absolute", inset: 0 }}
        width="100%"
        height="100%"
        viewBox="0 0 600 1230"
        preserveAspectRatio="none"
      >
        <path
          d="M120 760 C 200 700, 300 860, 420 720"
          stroke="#FFD60A"
          strokeWidth={14}
          strokeLinecap="round"
          fill="none"
        />
      </svg>
      {/* progress segments */}
      <div
        style={{
          position: "absolute",
          top: 64,
          left: 20,
          right: 20,
          display: "flex",
          gap: 8,
        }}
      >
        {[0, 1, 2].map((i) => (
          <div
            key={i}
            style={{
              flex: 1,
              height: 6,
              borderRadius: 3,
              background: "rgba(255,255,255,0.3)",
              overflow: "hidden",
            }}
          >
            <div
              style={{
                width: i === 0 ? `${prog * 100}%` : i < 0 ? "100%" : "0%",
                height: "100%",
                background: "#fff",
              }}
            />
          </div>
        ))}
      </div>
      {/* author header */}
      <div
        style={{
          position: "absolute",
          top: 88,
          left: 24,
          display: "flex",
          alignItems: "center",
          gap: 14,
        }}
      >
        <Avatar size={62} bg="#7C4DFF" emoji="🦊" />
        <div style={{ color: "#fff", fontSize: 28, fontWeight: 600 }}>Аня</div>
        <div style={{ color: "rgba(255,255,255,0.7)", fontSize: 24 }}>5 мин</div>
      </div>
      {/* reply + reactions */}
      <div
        style={{
          position: "absolute",
          bottom: 60,
          left: 24,
          right: 24,
          display: "flex",
          alignItems: "center",
          gap: 14,
        }}
      >
        <div
          style={{
            flex: 1,
            height: 72,
            borderRadius: 36,
            border: "1.5px solid rgba(255,255,255,0.4)",
            background: "rgba(255,255,255,0.12)",
            display: "flex",
            alignItems: "center",
            padding: "0 26px",
            color: "rgba(255,255,255,0.85)",
            fontSize: 26,
          }}
        >
          Ответить…
        </div>
        <div style={{ fontSize: 40 }}>❤️</div>
      </div>
    </AbsoluteFill>
  );
};

// ── Video call screen ───────────────────────────────────────────────────────
export const VideoCallScreen: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: "#05140f", fontFamily: ui }}>
      {/* remote video */}
      <AbsoluteFill
        style={{
          background: `radial-gradient(120% 80% at 50% 35%, #15705f, #06231c 75%)`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <div style={{ fontSize: 220, opacity: 0.92 }}>🦊</div>
      </AbsoluteFill>
      <StatusBar dark />
      {/* timer pill */}
      <div
        style={{
          position: "absolute",
          top: 84,
          left: "50%",
          translate: "-50% 0",
          background: "rgba(0,0,0,0.4)",
          color: "#fff",
          fontSize: 26,
          padding: "8px 22px",
          borderRadius: 20,
        }}
      >
        🔴 Видеозвонок · 00:1{Math.floor(frame / 30) % 10}
      </div>
      {/* self PiP */}
      <div
        style={{
          position: "absolute",
          top: 150,
          right: 26,
          width: 200,
          height: 280,
          borderRadius: 24,
          overflow: "hidden",
          border: "2px solid rgba(255,255,255,0.25)",
          background: `linear-gradient(150deg, #2b3a52, #11161f)`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: 120,
        }}
      >
        🙂
      </div>
      {/* controls */}
      <div
        style={{
          position: "absolute",
          bottom: 72,
          left: 0,
          width: "100%",
          display: "flex",
          justifyContent: "center",
          gap: 28,
        }}
      >
        {[
          { i: "🎙️", bg: "rgba(255,255,255,0.18)" },
          { i: "🎥", bg: "rgba(255,255,255,0.18)" },
          { i: "🔄", bg: "rgba(255,255,255,0.18)" },
          { i: "📞", bg: "#ef4444" },
        ].map((b, k) => (
          <div
            key={k}
            style={{
              width: 92,
              height: 92,
              borderRadius: "50%",
              background: b.bg,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 40,
              transform: k === 3 ? "rotate(135deg)" : "none",
            }}
          >
            {b.i}
          </div>
        ))}
      </div>
    </AbsoluteFill>
  );
};
