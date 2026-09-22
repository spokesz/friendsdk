/** Reference RF chance-game rules and a wallet-free ledger simulation. No chain calls or signing. */
export const RF = 10n ** 18n;
const UINT256_MAX = (1n << 256n) - 1n;

export type ChanceOutcome = Readonly<{ name: string; chanceBps: number; reward: bigint }>;
export type ChanceGameDefinition = Readonly<{ name: string; consumable: string; price: bigint; outcomes: readonly ChanceOutcome[] }>;
export type GamePlay = Readonly<{ id: bigint; outcomeId: number | null }>;
export type GameSnapshot = Readonly<{
  mode: 'preview' | 'chain'; friendId: bigint; rfBalance: bigint; consumables: bigint;
  stake: bigint; freeStake: bigint; reservedPlays: bigint; rewardLiability: bigint;
  inventory: readonly bigint[]; plays: readonly GamePlay[];
}>;

/** Player actions; randomness and funding are provided separately by the platform. */
export type GameClient = Readonly<{
  mode: 'preview' | 'chain'; definition: ChanceGameDefinition;
  read(): Promise<GameSnapshot>;
  canBuy(quantity: bigint): Promise<boolean>;
  buy(quantity: bigint): Promise<void>;
  play(quantity?: bigint): Promise<readonly GamePlay[]>;
  settle(playId: bigint): Promise<GamePlay>;
  redeem(outcomeId: number, quantity: bigint): Promise<void>;
}>;

export type PreviewGameClient = GameClient & Readonly<{ mode: 'preview' }>;

/** Game server actions defined in the game's server.ts; the host routes them to Nakama or a local preview. */
export type GameServerClient = Readonly<{ rpc(name: string, payload?: unknown): Promise<unknown> }>;

function uint(value: bigint, name: string, positive = false): bigint {
  if (typeof value !== 'bigint' || value < (positive ? 1n : 0n) || value > UINT256_MAX) throw new RangeError(`Invalid ${name}.`);
  return value;
}

export function defineChanceGame(input: ChanceGameDefinition): ChanceGameDefinition {
  uint(input.price, 'price', true);
  if (!input.name.trim() || !input.consumable.trim()) throw new TypeError('Game and consumable names are required.');
  if (!input.outcomes.length) throw new RangeError('Provide at least one outcome.');
  const outcomes = input.outcomes.map(outcome => {
    if (!outcome.name.trim() || !Number.isInteger(outcome.chanceBps) || outcome.chanceBps < 1 || outcome.chanceBps > 10_000) throw new RangeError('Invalid outcome.');
    uint(outcome.reward, 'reward');
    return Object.freeze({ ...outcome });
  });
  if (outcomes.reduce((sum, outcome) => sum + outcome.chanceBps, 0) !== 10_000) throw new RangeError('Outcome chances must total 10000 basis points.');
  if (!outcomes.some(outcome => outcome.reward > 0n)) throw new RangeError('At least one prize is required.');
  return Object.freeze({ ...input, outcomes: Object.freeze(outcomes) });
}

/** Read the reviewable JSON format; RF values are decimal strings in 18-decimal base units. */
export function parseChanceGame(input: unknown): ChanceGameDefinition {
  if (!input || typeof input !== 'object') throw new TypeError('Expected a game definition.');
  const game = input as Record<string, unknown>;
  const amount = (value: unknown): bigint => {
    if (typeof value !== 'string' || !/^[0-9]+$/.test(value)) throw new TypeError('RF amounts must be decimal base-unit strings.');
    return BigInt(value);
  };
  if (typeof game.name !== 'string' || typeof game.consumable !== 'string' || !Array.isArray(game.outcomes)) throw new TypeError('Invalid game definition.');
  return defineChanceGame({ name: game.name, consumable: game.consumable, price: amount(game.price),
    outcomes: game.outcomes.map((row: unknown) => {
      if (!row || typeof row !== 'object') throw new TypeError('Invalid outcome.');
      const outcome = row as Record<string, unknown>;
      if (typeof outcome.name !== 'string' || typeof outcome.chanceBps !== 'number') throw new TypeError('Invalid outcome.');
      return { name: outcome.name, chanceBps: outcome.chanceBps, reward: amount(outcome.reward) };
    }),
  });
}

export function maximumPrize(game: ChanceGameDefinition): bigint {
  return game.outcomes.reduce((max, outcome) => outcome.reward > max ? outcome.reward : max, 0n);
}

/** Exact weighted sum, rounded down once to RF base units. */
export function expectedReward(game: ChanceGameDefinition): bigint {
  return game.outcomes.reduce((sum, outcome) => sum + outcome.reward * BigInt(outcome.chanceBps), 0n) / 10_000n;
}

/** Return the contract's one-based outcome ID for a roll in [0, 10000). */
export function outcomeForRoll(game: ChanceGameDefinition, roll: number): number {
  if (!Number.isInteger(roll) || roll < 0 || roll >= 10_000) throw new RangeError('Roll must be an integer from 0 to 9999.');
  let boundary = 0;
  for (let index = 0; index < game.outcomes.length; index++) {
    boundary += game.outcomes[index].chanceBps;
    if (roll < boundary) return index + 1;
  }
  throw new RangeError('Invalid outcome table.');
}

/** Browser entropy is for preview only. Rejection sampling keeps all 10000 buckets equal. */
export function samplePreviewRoll(): number {
  const word = new Uint32Array(1);
  do { globalThis.crypto.getRandomValues(word); } while (word[0] >= 4_294_960_000);
  return word[0] % 10_000;
}

export function createGamePreview(input: ChanceGameDefinition, options: Readonly<{
  stake: bigint; rfBalance: bigint; friendId?: bigint; draw?: () => number;
}>) {
  const definition = defineChanceGame(input), maxPrize = maximumPrize(definition);
  const friendId = uint(options.friendId ?? 0n, 'friend ID');
  let stake = uint(options.stake, 'stake'), rfBalance = uint(options.rfBalance, 'RF balance');
  let consumables = 0n, reservedPlays = 0n, rewardLiability = 0n;
  const inventory = definition.outcomes.map(() => 0n), plays: GamePlay[] = [];
  const draw = options.draw ?? samplePreviewRoll;
  const freeStake = () => stake - reservedPlays - rewardLiability;

  function canBuy(quantity: bigint): boolean {
    if (typeof quantity !== 'bigint' || quantity < 1n || quantity > UINT256_MAX) return false;
    const cost = quantity * definition.price, reserve = quantity * maxPrize;
    return cost <= UINT256_MAX && reserve <= UINT256_MAX && stake + cost <= UINT256_MAX &&
      freeStake() >= maxPrize && freeStake() + cost >= reserve;
  }
  function snapshot(): GameSnapshot {
    return Object.freeze({ mode: 'preview', friendId, rfBalance, consumables, stake, freeStake: freeStake(), reservedPlays, rewardLiability,
      inventory: Object.freeze([...inventory]), plays: Object.freeze([...plays]) });
  }
  const client: PreviewGameClient = Object.freeze({
    mode: 'preview', definition,
    read: async () => snapshot(),
    canBuy: async quantity => canBuy(quantity),
    async buy(quantity) {
      uint(quantity, 'quantity', true);
      const cost = quantity * definition.price;
      if (!canBuy(quantity)) throw new Error('Game needs more free stake to back this purchase.');
      if (cost > rfBalance) throw new Error('Insufficient RF.');
      stake += cost; rfBalance -= cost; consumables += quantity; reservedPlays += quantity * maxPrize;
    },
    async play(quantity = 1n) {
      uint(quantity, 'quantity', true);
      if (quantity > consumables) throw new Error('Insufficient consumables.');
      consumables -= quantity;
      const added: GamePlay[] = [];
      for (let index = 0n; index < quantity; index++) {
        const play = Object.freeze({ id: BigInt(plays.length + 1), outcomeId: null });
        plays.push(play); added.push(play);
      }
      return Object.freeze(added);
    },
    async settle(playId) {
      uint(playId, 'play ID', true);
      if (playId > BigInt(plays.length)) throw new RangeError('Unknown play.');
      const index = Number(playId - 1n), play = plays[index];
      if (play.outcomeId !== null) throw new Error('Play is already settled.');
      const outcomeId = outcomeForRoll(definition, draw()), outcome = definition.outcomes[outcomeId - 1];
      const result = Object.freeze({ id: play.id, outcomeId });
      reservedPlays -= maxPrize; rewardLiability += outcome.reward; inventory[outcomeId - 1] += 1n;
      plays[index] = result;
      return result;
    },
    async redeem(outcomeId, quantity) {
      uint(quantity, 'quantity', true);
      if (!Number.isInteger(outcomeId) || outcomeId < 1 || outcomeId > definition.outcomes.length) throw new RangeError('Unknown outcome.');
      const index = outcomeId - 1, reward = definition.outcomes[index].reward;
      if (reward === 0n) throw new Error('This collectible has no RF redemption value.');
      if (inventory[index] < quantity) throw new Error('Insufficient inventory.');
      const amount = reward * quantity;
      uint(rfBalance + amount, 'RF balance');
      inventory[index] -= quantity; rewardLiability -= amount; stake -= amount; rfBalance += amount;
    },
  });
  // Preview controls are deliberately separate from the player's client.
  return Object.freeze({ client,
    fund(amount: bigint) { uint(amount, 'funding', true); stake = uint(stake + amount, 'stake'); },
    withdraw(amount: bigint) {
      uint(amount, 'withdrawal', true);
      if (amount > freeStake()) throw new Error('Cannot withdraw reserved RF.');
      stake -= amount;
    },
  });
}
