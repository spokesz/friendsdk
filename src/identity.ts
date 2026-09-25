import { isAddress, parseAbi, type Address, type PublicClient } from "viem";
import { GENERATION_SPRITE_MANIFEST } from "./generation-sprites.js";

export const GENERATION_ELIGIBILITY_ABI = parseAbi([
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function generation(uint256 tokenId) view returns (uint8)",
]);
const CUSTODY_ABI = parseAbi(["function beneficiary(uint256 tokenId) view returns (address)"]);
const ZERO = "0x0000000000000000000000000000000000000000";
export type GenerationIdentityClient = Pick<PublicClient, "readContract" | "getChainId" | "getBlockNumber">;
export type GenerationDeployment = Readonly<{ chainId: number; generations: Address }>;

/**
 * Fresh ownership of a hardwired Generations NFT. Artwork and activation confer no permission.
 * With `custody`, a Friend that contract holds is also eligible for `player` unless custody has
 * bound it on chain to another wallet; the game server still requires the grant service's ticket.
 */
export async function readGenerationEligibility(
  client: GenerationIdentityClient, tokenId: bigint, player?: Address,
  deployment: GenerationDeployment = GENERATION_SPRITE_MANIFEST, custody?: Address,
) {
  if (typeof tokenId !== "bigint" || tokenId < 1n || tokenId >= 1n << 256n) throw new RangeError("Token ID must fit uint256 and be positive.");
  if (player !== undefined && !isAddress(player)) throw new TypeError("Invalid player address.");
  if (await client.getChainId() !== deployment.chainId) throw new Error(`Eligibility requires chain ${deployment.chainId}.`);
  const blockNumber = await client.getBlockNumber({ cacheTime: 0 });
  const [owner, generation] = await Promise.all([
    client.readContract({ address: deployment.generations, abi: GENERATION_ELIGIBILITY_ABI,
      functionName: "ownerOf", args: [tokenId], blockNumber }),
    client.readContract({ address: deployment.generations, abi: GENERATION_ELIGIBILITY_ABI,
      functionName: "generation", args: [tokenId], blockNumber }),
  ]);
  const hardwired = generation >= 1;
  const ownedByPlayer = player === undefined ? null : owner.toLowerCase() === player.toLowerCase();
  const custodied = custody !== undefined && owner.toLowerCase() === custody.toLowerCase();
  let controlled = ownedByPlayer;
  if (custodied && player !== undefined) {
    const bound = (await client.readContract({ address: custody, abi: CUSTODY_ABI, functionName: "beneficiary", args: [tokenId], blockNumber })).toLowerCase();
    controlled = bound === ZERO || bound === player.toLowerCase();
  }
  return { owner, generation, hardwired, ownedByPlayer, custodied,
    eligible: controlled === null ? null : controlled && hardwired, blockNumber } as const;
}
