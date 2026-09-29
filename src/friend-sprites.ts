/** Standalone FriendSDK entry: public artwork reads require no wallet. */
import { createGenerationSpriteReader, GENERATION_SPRITE_MANIFEST } from "./generation-sprites.js";
import { createFriendReadClient } from "./read-client.js";

export * from "./generation-sprites.js";

export function createFriendReader() {
  return createGenerationSpriteReader(createFriendReadClient(
    GENERATION_SPRITE_MANIFEST.rpcUrl, { retryCount: 1, timeout: 12_000 },
  ));
}
