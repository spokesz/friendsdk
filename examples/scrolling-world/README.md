# Long Meadow: a scrolling world

SDK **v0.1.4**. Explore a **2400 × 1600** meadow through the SDK's **960 × 640**
viewing window. The 576 × 384 ground plane belongs to the optional SDK renderer;
custom worlds and cameras can be any size. This example uses a small custom
top-down canvas renderer with its own terrain, collision and follow camera.

From the SDK checkout:

```sh
npm run dev:game -- examples/scrolling-world
```

Connect your wallet on Robinhood and select an owned hardwired Generations NFT.
The ordinary SDK runtime verifies ownership before play. There is no alternative
identity flow or preview bypass in this component. Automated browser tests can
use the SDK's separate testing harness with mock identities and artwork.
The component calls `client.read()` on mount to initialize runtime state, even
though it has no economy actions.

Move with WASD, arrows or a tap/click destination. Follow the east–west trail to
find three markers, then explore north and south. Press E or tap **Read** near a
marker. Ponds and tree trunks block movement. Tap movement heads toward the
chosen destination and stops at obstacles; tap around them to choose a route.
Settings include reduced motion; this example has no audio to mute.

The camera follows the Friend and stops at this example's map edges. Change
`WORLD`, the terrain and camera in `index.tsx` to extend the meadow or implement
rooms, larger maps or different cameras. The fixed container remains the window
into your world. No renderer or world-size setting in the runtime needs changing.

The render and pointer transforms use the same camera offset and viewport scale.
Collision uses small movement steps, and tree/Friend layering sorts by ground Y.
Friend sprites come from the selected Friend's canonical SDK sprite reader, use
the original frame order, and render at integer 5× scale with a clipped white
halo. The camera uses integer positions and no easing or shake. Pausing, blur
and hidden tabs stop movement. Failed artwork reads show a retry control.

Exploration costs **0 RF** and has no purchases, consumables or rewards. Marker
visits are local session progress and reset on reload; they are not saved to the
Friend. The v0.1.4 runtime still requires a chance-game `game.json`, so this
example includes **unused schema-only terms**: a 1 RF token with a single 100%
(10,000 basis points) 1 RF reward, each encoded as `1000000000000000000` RF base
units. The component never calls `buy`, `play`, `settle` or `redeem`; those terms
do not charge for exploration and do not represent an implemented activity.

World artwork is drawn directly by the included canvas source and CSS. There
are no external scenery assets. Friend pixels remain canonical SDK artwork.
The lower 50–60 CSS pixels are kept clear for the runtime toolbar; controls
adapt when the same frame is displayed at phone sizes.
