import React from "react";
import {
  AbsoluteFill,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";

export const TEAL = "#14b8a6";
export const TEAL_DARK = "#0d9488";
export const TEAL_LIGHT = "#2dd4bf";
export const TEAL_GLOW = "#5eead4";
export const BG = "#04100e";
export const TEXT = "#eafef9";
export const MUTED = "rgba(234,254,249,0.62)";

/** Flowing teal gradient + soft glow blobs — the living brand backdrop. */
export const GradientBackground: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const a = (frame / 90) * Math.PI * 2;
  const gx = 50 + Math.cos(a) * 28;
  const gy = 42 + Math.sin(a * 0.8) * 22;
  const g2x = 50 - Math.cos(a * 0.7) * 30;
  const g2y = 60 - Math.sin(a) * 20;
  return (
    <AbsoluteFill style={{ backgroundColor: BG }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(${width * 0.9}px ${height * 0.5}px at ${gx}% ${gy}%, rgba(20,184,166,0.34), transparent 60%)`,
        }}
      />
      <AbsoluteFill
        style={{
          background: `radial-gradient(${width}px ${height * 0.55}px at ${g2x}% ${g2y}%, rgba(13,148,136,0.26), transparent 62%)`,
        }}
      />
      <AbsoluteFill
        style={{
          background:
            "linear-gradient(180deg, rgba(0,0,0,0.35), transparent 30%, transparent 70%, rgba(0,0,0,0.45))",
        }}
      />
    </AbsoluteFill>
  );
};

/** Concentric pulsing rings (the Rlink "signal" motif). */
export const PulseRings: React.FC<{ cx?: number; cy?: number }> = ({
  cx = 50,
  cy = 50,
}) => {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();
  return (
    <AbsoluteFill>
      {[0, 1, 2, 3].map((i) => {
        const local = (frame + i * 26) % 104;
        const t = local / 104;
        const size = interpolate(t, [0, 1], [width * 0.18, width * 1.25]);
        const opacity = interpolate(t, [0, 0.25, 1], [0, 0.45, 0]);
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: `${cx}%`,
              top: `${cy}%`,
              width: size,
              height: size,
              marginLeft: -size / 2,
              marginTop: -size / 2,
              borderRadius: "50%",
              border: `2px solid ${TEAL}`,
              opacity,
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};

/** A vibrating-string wave line — matches the app's voice/call waveform. */
export const WaveLine: React.FC<{
  yPct?: number;
  amp?: number;
  color?: string;
  strokeWidth?: number;
}> = ({ yPct = 50, amp = 70, color = TEAL_LIGHT, strokeWidth = 6 }) => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const midY = (height * yPct) / 100;
  const phase = (frame / 18) * Math.PI;
  const steps = 90;
  let d = "";
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    const x = t * width;
    const env = Math.sin(t * Math.PI); // fade at the edges
    const y =
      midY +
      amp *
        env *
        (Math.sin(t * Math.PI * 7 + phase) * 0.72 +
          Math.sin(t * Math.PI * 15 - phase * 1.4) * 0.28);
    d += i === 0 ? `M ${x} ${y}` : ` L ${x} ${y}`;
  }
  return (
    <AbsoluteFill>
      <svg width={width} height={height} style={{ position: "absolute" }}>
        <path
          d={d}
          fill="none"
          stroke={color}
          strokeWidth={strokeWidth}
          strokeLinecap="round"
          strokeLinejoin="round"
          opacity={0.9}
        />
      </svg>
    </AbsoluteFill>
  );
};
