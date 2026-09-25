/** Wallet sign-in message shared by the trusted host (signs it) and the game server (verifies it). One signature covers every Friend the wallet holds. */
export type WalletLogin = Readonly<{ account: string; expires: string }>;
export type FriendKey = Readonly<{ chainId: number; contract: string; tokenId: string }>;

const MESSAGE = /^Rare Friends login\nSign in every Rare Friend this wallet holds\.\nAccount: (0x[0-9a-f]{40})\nExpires: ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z)$/;
const CUSTOM_ID = /^rf:([1-9][0-9]{0,9}):(0x[0-9a-f]{40}):(0|[1-9][0-9]{0,77})$/;

/** Nakama custom ID: the Friend is the account, whoever controls it. */
export function friendCustomId(friend: FriendKey): string {
  return `rf:${friend.chainId}:${friend.contract.toLowerCase()}:${friend.tokenId}`;
}

export function parseFriendCustomId(id: string): FriendKey | null {
  const match = CUSTOM_ID.exec(id);
  return match ? Object.freeze({ chainId: Number(match[1]), contract: match[2], tokenId: match[3] }) : null;
}

export function walletLoginMessage(login: WalletLogin): string {
  return `Rare Friends login\nSign in every Rare Friend this wallet holds.\nAccount: ${login.account.toLowerCase()}\nExpires: ${login.expires}`;
}

export function parseWalletLogin(message: string): WalletLogin | null {
  const match = MESSAGE.exec(message);
  return match ? Object.freeze({ account: match[1], expires: match[2] }) : null;
}

/**
 * Custody ticket: a grant service's signed statement that `account` may play a
 * Friend held by the custody contract. Expiry bounds how long an off-chain
 * assignment is honoured without asking the service again.
 */
export type CustodyTicket = Readonly<{ friend: string; account: string; expires: string }>;
const TICKET = /^Rare Friends custody ticket\nFriend: (rf:[^\n]+)\nAccount: (0x[0-9a-f]{40})\nExpires: ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z)$/;

export function custodyTicketMessage(ticket: Readonly<{ friend: FriendKey; account: string; expires: string }>): string {
  return `Rare Friends custody ticket\nFriend: ${friendCustomId(ticket.friend)}\nAccount: ${ticket.account.toLowerCase()}\nExpires: ${ticket.expires}`;
}

export function parseCustodyTicket(message: string): CustodyTicket | null {
  const match = TICKET.exec(message);
  return match && parseFriendCustomId(match[1]) ? Object.freeze({ friend: match[1], account: match[2], expires: match[3] }) : null;
}
