import { defineFriendGameServer } from "@rarefriends/friendsdk/server";

type Visits = { count: number; lastAt: number };

/** Runs in the browser for previews and on Nakama in production; state is private to the Friend. */
export default defineFriendGameServer({ id: "garden-packs", rpcs: {
  visit(ctx) {
    const record = ctx.storage.get<Visits>("visits");
    const visits = { count: (record?.value.count ?? 0) + 1, lastAt: ctx.now };
    ctx.storage.put("visits", visits, record?.version ?? "*");
    return visits;
  },
} });
