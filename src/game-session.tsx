"use client";

import { useEffect, useState, type ReactNode } from "react";
import { createFrameGameClient } from "./frame-bridge.js";
import type { ChanceGameDefinition, GameClient, GameServerClient } from "./game.js";

export type GameComponentProps = Readonly<{ friendId: bigint; client: GameClient & GameServerClient; paused: boolean }>;

/** Game-side bridge. The runtime supplies one verified Friend and a fixed action client. */
export function GameSession({ definition, children }: {
  definition: ChanceGameDefinition; children: (props: GameComponentProps) => ReactNode;
}) {
  const [session, setSession] = useState<Omit<GameComponentProps, "paused"> | null>(null);
  const [paused, setPaused] = useState(false);
  const [documentId] = useState(() => crypto.getRandomValues(new Uint32Array(4)).join("-"));
  useEffect(() => {
    let connection: ReturnType<typeof createFrameGameClient> | undefined;
    const handshakeId = crypto.getRandomValues(new Uint32Array(4)).join("-");
    const ready = () => window.parent.postMessage({ type: "friendsdk:ready", documentId, handshakeId }, "*");
    const unloading = () => window.parent.postMessage({ type: "friendsdk:unloading", documentId, handshakeId }, "*");
    function receive(event: MessageEvent) {
      if (event.source !== window.parent) return;
      if (event.data?.type === "friendsdk:connect") { ready(); return; }
      if (connection || event.data?.type !== "friendsdk:init" ||
        event.data.documentId !== documentId || event.data.handshakeId !== handshakeId ||
        typeof event.data.friendId !== "bigint" || event.data.friendId < 1n || event.ports.length !== 1) return;
      connection = createFrameGameClient(event.ports[0], definition, setPaused, event.data.mode === "chain" ? "chain" : "preview");
      setSession({ friendId: event.data.friendId, client: connection.client });
    }
    window.addEventListener("message", receive);
    window.addEventListener("pagehide", unloading);
    ready();
    return () => {
      window.removeEventListener("message", receive);
      window.removeEventListener("pagehide", unloading);
      window.parent.postMessage({ type: "friendsdk:reset", documentId, handshakeId }, "*");
      connection?.close(); setSession(null);
    };
  }, [definition, documentId]);
  return session ? children({ ...session, paused }) : <p role="status">Waiting for your Friend…</p>;
}
