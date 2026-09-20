"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import type { GameComponentProps } from "@rarefriends/friendsdk/runtime";
import { createFriendSoundKit, type FriendSoundKit, type FriendSoundCue } from "@rarefriends/friendsdk/sounds";
import { GameMenu } from "@rarefriends/friendsdk/frame";
import { formatGameAmount } from "@rarefriends/friendsdk/ui";
import type { GamePlay, GameSnapshot } from "@rarefriends/friendsdk/game";
import { outcomeForRoll, samplePreviewRoll } from "@rarefriends/friendsdk/game";
import "@rarefriends/friendsdk/frame.css";
import "./style.css";

// Menu items — 5 drinks, each with bean cost and base tip.
const MENU = [
  { key: "espresso", name: "Espresso", beanCost: 1, baseTip: 200000000000000000, emoji: "\u2615" },
  { key: "latte", name: "Latte", beanCost: 2, baseTip: 500000000000000000, emoji: "\uD83E\uDD64" },
  { key: "cappuccino", name: "Cappuccino", beanCost: 3, baseTip: 800000000000000000, emoji: "\u2615" },
  { key: "mocha", name: "Mocha", beanCost: 4, baseTip: 1500000000000000000, emoji: "\uD83C\uDF66" },
  { key: "specialty", name: "Daily Special", beanCost: 5, baseTip: 2500000000000000000, emoji: "\u2728" },
];

// Customers per shift.
const CUSTOMERS_PER_SHIFT = 5;

// Barista skill derived from friend token id.
// Real simulation: deterministic, no live RF needed (preview mode).
function deriveBaristaSkill(friendId: bigint | null): { skill: number; name: string } {
  if (friendId === null) return { skill: 50, name: "Apprentice Barista" };
  const v = Number(friendId % 100n);
  return { skill: v + 1, name: v >= 80 ? "Master Barista" : v >= 50 ? "Skilled Barista" : v >= 25 ? "Apprentice Barista" : "Novice Barista" };
}

const rf = (v: bigint) => `${formatGameAmount(v, 18)} RF`;

type Phase = "idle" | "order" | "craft" | "reveal" | "summary";

type Order = {
  index: number;
  drinkKey: string;
  emoji: string;
  name: string;
  expectedBeanCost: number;
  baseTip: bigint;
  faceEmoji: string;
};

const CUSTOMER_FACES = ["\uD83D\uDE0A", "\uD83D\uDE0D", "\uD83E\uDD23", "\uD83D\uDE00", "\uD83D\uDE0E"];

export default function RareFriendsCafe({ friendId, client, paused = false }: GameComponentProps) {
  const [snapshot, setSnapshot] = useState<GameSnapshot | null>(null);
  const [result, setResult] = useState<GamePlay | null>(null);
  const [menu, setMenu] = useState<"settings" | "summary" | null>(null);
  const [error, setError] = useState("");
  const [muted, setMuted] = useState(true);
  const [reducedMotion, setReducedMotion] = useState(false);
  const [phase, setPhase] = useState<Phase>("idle");
  const [shiftIndex, setShiftIndex] = useState(0);
  const [currentOrder, setCurrentOrder] = useState<Order | null>(null);
  const [beans, setBeans] = useState(20);
  const [tipsEarned, setTipsEarned] = useState<bigint>(0n);
  const [lastResultName, setLastResultName] = useState("");
  const sound = useRef<FriendSoundKit | null>(null);
  const locked = useRef(false);
  const epoch = useRef(0);
  const definition = client.definition;

  // Barista skill from friend token id.
  const { skill: baristaSkill, name: baristaName } = useMemo(
    () => deriveBaristaSkill(friendId ?? null),
    [friendId],
  );

  // Maximum prize from definition.
  const maxPrize = useMemo(() => {
    let max = 0n;
    for (const o of definition.outcomes) {
      if (o.reward > max) max = o.reward;
    }
    return max;
  }, [definition]);

  // Init sound + read snapshot.
  useEffect(() => {
    const version = ++epoch.current;
    sound.current = createFriendSoundKit({ muted: true });
    setSnapshot(null);
    setResult(null);
    setError("");
    setMenu(null);
    setPhase("idle");
    setShiftIndex(0);
    setCurrentOrder(null);
    setBeans(20);
    setTipsEarned(0n);
    setLastResultName("");
    void client.read().then((value) => {
      if (version === epoch.current) setSnapshot(value);
    }).catch((cause) => {
      if (version === epoch.current) setError(cause instanceof Error ? cause.message : "Could not load the preview.");
    });
    const preference = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReducedMotion(preference.matches);
    update();
    preference.addEventListener("change", update);
    return () => {
      epoch.current++;
      sound.current?.dispose();
      sound.current = null;
      preference.removeEventListener("change", update);
    };
  }, [client, friendId]);

  // Locked action runner.
  async function act(work: () => Promise<void>, cue?: FriendSoundCue, after?: () => void) {
    if (locked.current || paused) return;
    const version = epoch.current;
    locked.current = true;
    setError("");
    void sound.current?.unlock();
    try {
      await work();
      const value = await client.read();
      if (version === epoch.current) {
        setSnapshot(value);
        if (cue) sound.current?.play(cue);
        after?.();
      }
    } catch (cause) {
      if (version === epoch.current) setError(cause instanceof Error ? cause.message : "Action failed.");
    } finally {
      if (version === epoch.current) {
        locked.current = false;
      }
    }
  }

  // Brew a drink — calls SDK play, applies skill bonus, then advances.
  function startShift() {
    if (beans <= 0) return;
    setPhase("order");
    const menuItem = MENU[shiftIndex % MENU.length];
    const face = CUSTOMER_FACES[shiftIndex % CUSTOMER_FACES.length];
    setCurrentOrder({
      index: shiftIndex,
      drinkKey: menuItem.key,
      emoji: menuItem.emoji,
      name: menuItem.name,
      expectedBeanCost: menuItem.beanCost,
      baseTip: menuItem.baseTip,
      faceEmoji: face,
    });
  }

  function serveDrink() {
    if (!currentOrder) return;
    if (beans < currentOrder.expectedBeanCost) {
      setError("Not enough beans!");
      return;
    }
    setBeans((b) => b - currentOrder.expectedBeanCost);
    setPhase("reveal");
    void act(async () => {
      // Preview-mode flow: buy -> play -> settle -> redeem.
      // Buy + redeem are wrapped so the cafe stays self-funding in preview.
      if (client.mode === "preview") {
        try { await client.buy(1n); } catch { /* preview never has RF balance */ }
      }
      const plays = await client.play(1n);
      const playId = plays[0]?.id;
      if (typeof playId !== "bigint") throw new Error("Chance game did not return a play id.");
      const settled = await client.settle(playId);
      const outcomeId = settled.outcomeId;
      if (typeof outcomeId !== "number") throw new Error("Settle returned no outcome.");
      if (client.mode === "preview") {
        try { await client.redeem(outcomeId, 1n); } catch { /* ignore in preview */ }
      }
      // Map outcome to UI name. Outcome IDs are 1-indexed into definition.outcomes.
      const outcomeName = client.definition.outcomes[outcomeId - 1]?.name ?? "";
      setLastResultName(outcomeName);
      // Tip scale: Furious 0% / Disappointed 20% / Satisfied 50% / Happy 100% / Delighted 200%
      let tipMultiplier = 0n;
      if (outcomeName === "Delighted customer") tipMultiplier = 2n;
      else if (outcomeName === "Happy customer") tipMultiplier = 1n;
      else if (outcomeName === "Satisfied customer") tipMultiplier = 5n / 10n;
      else if (outcomeName === "Disappointed customer") tipMultiplier = 2n / 10n;
      // Apply barista skill bonus (skill 1-100 -> +0% to +20%)
      const skillBonus = BigInt(baristaSkill) * 20n / 100n;
      const tipBase = currentOrder.baseTip;
      const skillTip = (tipBase * skillBonus) / 100n;
      const finalTip = tipBase * tipMultiplier / 1n + skillTip;
      setTipsEarned((t) => t + finalTip);
      // Next customer or summary
      setTimeout(() => {
        const next = shiftIndex + 1;
        if (next >= CUSTOMERS_PER_SHIFT) {
          setPhase("summary");
          setCurrentOrder(null);
        } else {
          setShiftIndex(next);
          setCurrentOrder(null);
          setPhase("idle");
        }
      }, reducedMotion ? 800 : 1600);
    }, "action-start");
  }

  function dismissSummary() {
    setMenu(null);
    setShiftIndex(0);
    setBeans(20);
    setTipsEarned(0n);
    setPhase("idle");
  }

  return (
    <div className="cafe-root" data-testid="cafe-root">
      <div className="cafe-hud">
        <div className="cafe-barista">
          <div className="cafe-barista-avatar" aria-hidden="true">{"\u2615"}</div>
          <div className="cafe-barista-meta">
            <div className="cafe-barista-name">{baristaName}</div>
            <div className="cafe-barista-skill">Skill {baristaSkill}/100</div>
          </div>
        </div>
        <div className="cafe-stats">
          <div className="cafe-stat">
            <span className="cafe-stat-label">Beans</span>
            <span className="cafe-stat-value">{beans}</span>
          </div>
          <div className="cafe-stat">
            <span className="cafe-stat-label">Tips</span>
            <span className="cafe-stat-value">{rf(tipsEarned)}</span>
          </div>
          <div className="cafe-stat">
            <span className="cafe-stat-label">Shift</span>
            <span className="cafe-stat-value">{shiftIndex + 1}/{CUSTOMERS_PER_SHIFT}</span>
          </div>
        </div>
      </div>

      <div className="cafe-stage" inert={Boolean(menu) || paused || undefined}>
        <div className="cafe-cafe-bg" aria-hidden="true" />
        {phase === "idle" && !currentOrder && (
          <div className="cafe-prompt">
            <div className="cafe-prompt-emoji" aria-hidden="true">{"\uD83D\uDC4B"}</div>
            <h2>Ready for customer {shiftIndex + 1}?</h2>
            <button type="button" className="cafe-btn" disabled={paused} onClick={startShift}>
              Open shop
            </button>
          </div>
        )}

        {phase === "order" && currentOrder && (
          <div className="cafe-order">
            <div className="cafe-order-customer">
              <div className="cafe-order-face" aria-hidden="true">{currentOrder.faceEmoji}</div>
              <div className="cafe-order-bubble">
                <strong>One {currentOrder.name}, please!</strong>
                <span className="cafe-order-emoji">{currentOrder.emoji}</span>
              </div>
            </div>
            <div className="cafe-order-action">
              <button
                type="button"
                className="cafe-btn cafe-btn-primary"
                disabled={beans < currentOrder.expectedBeanCost}
                onClick={serveDrink}
              >
                Brew {currentOrder.name} ({currentOrder.expectedBeanCost} beans)
              </button>
            </div>
          </div>
        )}

        {phase === "reveal" && (
          <div className="cafe-reveal">
            <div className="cafe-reveal-emoji" aria-hidden="true">{currentOrder?.faceEmoji ?? "\uD83D\uDE00"}</div>
            <div className="cafe-reveal-name">{lastResultName}</div>
            <div className="cafe-reveal-spinner">{"\u2615"}</div>
          </div>
        )}

        {phase === "summary" && (
          <div className="cafe-summary">
            <h2>Shift complete!</h2>
            <div className="cafe-summary-tips">Total tips: {rf(tipsEarned)}</div>
            <button type="button" className="cafe-btn" onClick={dismissSummary}>
              Start new shift
            </button>
          </div>
        )}
      </div>

      {error && (
        <div role="alert" className="cafe-error">
          {error}
          <button type="button" className="cafe-btn" onClick={() => void act(async () => {})}>
            Retry
          </button>
        </div>
      )}

      <GameMenu
        paused={paused}
        muted={muted}
        reducedMotion={reducedMotion}
        onToggleMute={() => {
          setMuted((m) => {
            sound.current?.setMuted(!m);
            return !m;
          });
        }}
        onToggleReducedMotion={() => setReducedMotion((r) => !r)}
        onOpenSettings={() => setMenu("settings")}
        onCloseMenu={() => setMenu(null)}
      />

      {menu === "settings" && (
        <div className="cafe-settings">
          <h3>Settings</h3>
          <p>Friend token id: <code>{friendId?.toString() ?? "(none)"}</code></p>
          <p>Barista skill: {baristaSkill}/100 ({baristaName})</p>
          <p>Max prize per cup: {rf(maxPrize)}</p>
          <button type="button" className="cafe-btn" onClick={() => setMenu(null)}>Close</button>
        </div>
      )}
    </div>
  );
}
