"use client";

import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { formatGameAmount } from "./experience-ui.js";

/** Reference viewport dimensions; hosts may choose another layout through frame.css. */
export const GAME_VIEWPORT = Object.freeze({ width: 960, height: 640 });
export type GameFriend = Readonly<{ id: bigint; label: string; walletAddress?: string; kind: "owned" | "sample" }>;
export type GameWalletState = Readonly<{ balance?: bigint; status?: "ready" | "loading" | "error"; error?: string }>;
export type GameConfirmation = Readonly<{
  title: string; description: string; notice?: string; amount?: bigint; busy?: boolean; error?: string;
  onConfirm: () => void; onCancel: () => void;
}>;
export type GameFrameProps = {
  children: ReactNode; friends: readonly GameFriend[]; selectedFriendId: bigint | null;
  onSelectFriend?: (id: bigint) => void; friendsLoading?: boolean; friendsError?: string;
  /** Only show the empty result after successful discovery; null suppresses it. */
  friendsEmptyMessage?: string | null;
  friendsHiddenCount?: number;
  /** Use host when the surrounding interface already owns selection and connection. */
  selectionMode?: "picker" | "host";
  /** Remove the toolbar and visual shell when embedding in an existing interface. Dialogs and required selection remain available. */
  chrome?: "default" | "none";
  onConnect?: () => void; wallet?: GameWalletState; confirmation?: GameConfirmation | null;
  connection?: ReactNode; walletActions?: ReactNode;
  mode: "preview" | "live"; onMenuChange?: (open: boolean) => void;
};

/** An in-frame menu. Never portals into the website or opens a viewport-sized dialog. */
export function GameMenu({ title, onClose, children, footer }: { title: string; onClose?: () => void; children: ReactNode; footer?: ReactNode }) {
  const id = useId();
  const node = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    node.current?.focus();
    return () => { if (previous?.isConnected) previous.focus(); };
  }, []);
  return <div className="rf-frame-scrim"><div ref={node} className="rf-frame-menu" role="dialog" aria-modal="true" aria-labelledby={id} tabIndex={-1}
    onKeyDown={event => {
      if (event.key === "Escape" && onClose) { event.preventDefault(); onClose(); }
      if (event.key !== "Tab") return;
      const buttons = [...event.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled), input:not(:disabled), a[href], [tabindex="0"]')].filter(element => element.getClientRects().length > 0);
      const first = buttons[0], last = buttons.at(-1);
      if (!first) { event.preventDefault(); return; }
      if (event.shiftKey && (document.activeElement === first || document.activeElement === node.current)) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && (document.activeElement === last || document.activeElement === node.current)) { event.preventDefault(); first.focus(); }
    }}>
    <header className="rf-frame-menu-heading"><h2 id={id}>{title}</h2>{onClose && <button type="button" onClick={onClose} aria-label={`Close ${title}`}>×</button>}</header>
    <div className="rf-frame-menu-body">{children}</div>
    {footer && <footer className="rf-frame-menu-footer">{footer}</footer>}
  </div></div>;
}

export function GameFrame({ children, friends, selectedFriendId, onSelectFriend, friendsLoading, friendsError, friendsEmptyMessage = "No playable Friends found.", friendsHiddenCount = 0, onConnect, wallet, confirmation, connection, walletActions, selectionMode = "picker", chrome = "default", mode, onMenuChange }: GameFrameProps) {
  const [menu, setMenu] = useState<"friends" | "wallet" | null>(null);
  const visibleMenu = chrome === "none" ? null : menu;
  const friend = friends.find(value => value.id === selectedFriendId);
  const selecting = selectionMode === "picker" && (!friend || visibleMenu === "friends");
  const menuOpen = selecting || visibleMenu === "wallet" || Boolean(confirmation);
  useEffect(() => { onMenuChange?.(menuOpen); }, [menuOpen, onMenuChange]);
  return <section className="rf-game-frame" aria-label="Game container" data-mode={mode} data-chrome={chrome}>
    <div className="rf-frame-chrome" inert={menuOpen || undefined}>
      {chrome !== "none" && <div className="rf-frame-toolbar">
        <span className="rf-frame-mode">{mode === "preview" ? "Local preview" : "Live · Robinhood"}</span>
        {selectionMode === "host" ? <span className="rf-frame-selected-friend">{friend?.label ?? "Choose a Friend"}</span>
          : <button type="button" onClick={() => setMenu("friends")} aria-label="Choose Friend">{friend?.label ?? "Choose Friend"}</button>}
        <button type="button" onClick={() => setMenu("wallet")} disabled={!friend} aria-label="Open Friend wallet">Friend wallet</button>
      </div>}
      <div className="rf-frame-viewport">{children}</div>
    </div>
    {confirmation ? <GameMenu title={confirmation.title} onClose={confirmation.busy ? undefined : confirmation.onCancel}
      footer={<><button type="button" disabled={confirmation.busy} onClick={confirmation.onCancel}>Cancel</button><button type="button" className="rf-frame-primary" disabled={confirmation.busy} onClick={confirmation.onConfirm}>{confirmation.busy ? "Waiting…" : mode === "preview" ? "Confirm preview" : "Confirm"}</button></>}>
      <p>{confirmation.description}</p>{confirmation.amount !== undefined && <p><strong>{formatGameAmount(confirmation.amount, 18)} RF</strong></p>}
      {confirmation.notice && <p>{confirmation.notice}</p>}
      <p>{friend?.label}</p><p className="rf-frame-note">{mode === "preview" ? "Simulated RF. No transaction will be sent." : "This action uses the selected Friend’s canonical wallet. A result is confirmed only after its receipt."}</p>
      {confirmation.error && <p role="alert">{confirmation.error}</p>}
    </GameMenu> : selecting ? <GameMenu title="Choose your Friend" onClose={friend ? () => setMenu(null) : undefined}>
      <p>{mode === "preview" ? !friends.some(value => value.kind === "sample") ? "Choose your Friend for this local preview. Balances, items and outcomes are simulated." : "Choose a sample Friend. Each has separate simulated balances and items." : "Choose an owned, hardwired Generations NFT. Its inventory and RF stay with its wallet."}</p>
      {connection}
      {friendsLoading && <p role="status">Loading your Friends…</p>}
      {friendsError && <p role="alert">{friendsError}</p>}
      <div className="rf-frame-friends">{friends.map(value => <button type="button" key={value.id.toString()} aria-pressed={value.id === selectedFriendId} onClick={() => { onSelectFriend?.(value.id); setMenu(null); }}><strong>{value.label}</strong><small>{value.kind === "sample" ? "Sample · no ownership claim" : "Hardwired Generations"}</small></button>)}</div>
      {!friendsLoading && !friendsError && friendsHiddenCount > 0 && <p>{friendsHiddenCount} {friendsHiddenCount === 1 ? "Friend" : "Friends"} hidden: not hardwired (generation 0). Playing requires generation 1 or higher.</p>}
      {!friendsLoading && !friendsError && !friends.length && friendsEmptyMessage && <p>{friendsEmptyMessage}</p>}
      {onConnect && <button type="button" className="rf-frame-primary" onClick={onConnect}>Connect wallet</button>}
    </GameMenu> : visibleMenu === "wallet" ? <GameMenu title="Friend wallet" onClose={() => setMenu(null)}>
      <h3>{friend?.label}</h3><p>{mode === "preview" ? "Preview balance. RF is simulated and no transactions are sent." : "Items and RF belong to this Friend’s canonical wallet."}</p>
      {friend?.walletAddress && <p className="rf-frame-address">{friend.walletAddress}</p>}
      {wallet?.status === "loading" ? <p role="status">Loading RF balance…</p> : wallet?.balance !== undefined ? <p className="rf-frame-wallet-balance">{formatGameAmount(wallet.balance, 18)} RF</p> : <p>RF balance unavailable.</p>}
      {wallet?.error && <p role="alert">{wallet.error}</p>}
      {walletActions}
      {selectionMode === "picker" && <button type="button" onClick={() => setMenu("friends")}>Change Friend</button>}
    </GameMenu> : null}
  </section>;
}
