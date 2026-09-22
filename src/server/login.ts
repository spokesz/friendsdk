/** Wallet sign-in message shared by the trusted host (signs it) and the game server (verifies it). */
export type FriendLogin = Readonly<{ chainId: number; contract: string; tokenId: string; account: string; expires: string }>;

const MESSAGE = /^Rare Friends login\nFriend: ([1-9][0-9]{0,9}):(0x[0-9a-f]{40}):(0|[1-9][0-9]{0,77})\nAccount: (0x[0-9a-f]{40})\nExpires: ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z)$/;

/** Nakama custom ID: the Friend is the account, whoever controls it. */
export function friendCustomId(friend: Readonly<{ chainId: number; contract: string; tokenId: string }>): string {
  return `rf:${friend.chainId}:${friend.contract.toLowerCase()}:${friend.tokenId}`;
}

export function friendLoginMessage(login: FriendLogin): string {
  return `Rare Friends login\nFriend: ${login.chainId}:${login.contract.toLowerCase()}:${login.tokenId}\nAccount: ${login.account.toLowerCase()}\nExpires: ${login.expires}`;
}

export function parseFriendLogin(message: string): FriendLogin | null {
  const match = MESSAGE.exec(message);
  if (!match) return null;
  return Object.freeze({ chainId: Number(match[1]), contract: match[2], tokenId: match[3], account: match[4], expires: match[5] });
}
