import "./index.css";
import { Composition } from "remotion";
import { RlinkPromo } from "./promo/RlinkPromo";
import { RlinkPromoReal } from "./promo/RlinkPromoReal";
import { RlinkPromoFull } from "./promo/RlinkPromoFull";
import { RlinkShowcase, SHOWCASE_FRAMES } from "./promo/RlinkShowcase";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      {/* UI-free feature showcase — vertical (Stories/Shorts) + horizontal (YouTube). */}
      <Composition
        id="RlinkShowcaseVertical"
        component={RlinkShowcase}
        durationInFrames={SHOWCASE_FRAMES}
        fps={30}
        width={1080}
        height={1920}
      />
      <Composition
        id="RlinkShowcaseHorizontal"
        component={RlinkShowcase}
        durationInFrames={SHOWCASE_FRAMES}
        fps={30}
        width={1920}
        height={1080}
      />
      <Composition
        id="RlinkPromoFull"
        component={RlinkPromoFull}
        durationInFrames={1336}
        fps={30}
        width={1080}
        height={1920}
      />
      <Composition
        id="RlinkPromoRealMusic"
        component={RlinkPromoReal}
        durationInFrames={520}
        fps={30}
        width={1080}
        height={1920}
        defaultProps={{ voice: false }}
      />
      <Composition
        id="RlinkPromoRealVoice"
        component={RlinkPromoReal}
        durationInFrames={520}
        fps={30}
        width={1080}
        height={1920}
        defaultProps={{ voice: true }}
      />
      <Composition
        id="RlinkPromo"
        component={RlinkPromo}
        durationInFrames={590}
        fps={30}
        width={1080}
        height={1920}
      />
    </>
  );
};
