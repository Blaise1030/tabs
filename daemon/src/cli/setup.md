# Connect this coding agent to the tabsh board

You are a coding agent (Claude Code, Gemini CLI, Codex, …). The user runs you inside tabsh, where
every terminal is a card on a kanban board with the statuses backlog, in_progress, needs_input,
completed and archived. Set up your own hooks and instructions so you keep your card current.
tabsh does not know your config format; you do. Follow these steps and report back.

## The contract

Inside a tabsh terminal the environment has `TABSH_SESSION_ID`. These commands set that terminal's
card. With `--hook` they print nothing and always exit 0, even outside tabsh, so they are safe to
run from hooks that fire everywhere.

| When | Run |
|---|---|
| The user sends you a prompt | `{tabsh} status in_progress --hook` |
| You need permission or input from the user | `{tabsh} status needs_input --hook --if-not completed` |
| Your turn ends | `{tabsh} status needs_input --hook --if-not completed --note 'Agent finished its turn'` |
| The user's task is done (you decide; not a hook) | `{tabsh} status completed --note '<one line: what you did>'` |

`--hook` reads JSON on stdin and uses its `message` field as the card's note when there is one,
so a notification hook can pass its payload straight through. Its `session_id` field lets tabsh
resume your conversation in a fresh shell after tabsh restarts, so give every hook the payload. `--note` sets the note explicitly.
Do not use a single quote (') inside a note; escape it as needed by your shell instead.

## Steps

1. **Find your mechanism.** Identify your own hook or notification system and its config file
   (for example Claude Code: `~/.claude/settings.json` hooks `UserPromptSubmit`, `Notification`,
   `Stop`; Gemini CLI: `~/.gemini/settings.json` hooks `BeforeAgent`, `Notification`,
   `AfterAgent`; Codex: `notify` in `~/.codex/config.toml`; OpenCode: a plugin, see
   [OpenCode](#opencode) below). Check your current documentation rather than trusting these
   examples.
2. **Back up** that config file next to itself with a `.bak` suffix before changing it.
3. **Merge, never replace.** Add one entry per row of the contract that you have an event for.
   Keep every existing hook. If an entry whose command contains ` status ` and `--hook` and the
   word `tabsh` is already there, update it instead of adding a second one, so running this setup
   again changes nothing.
4. **Map honestly.** If you have no event for a row (Codex, for example, has no "prompt sent"
   event), leave that row out. Never fake it with an event that means something else. If your
   mechanism cannot run these exact commands (for example it passes the event payload as an extra
   argument), say so in your report instead of wiring something that silently does nothing.
5. **Instruct yourself.** Add to your persistent instructions (a skill, `AGENTS.md`, `GEMINI.md`,
   or whatever you read at the start of every session) a short rule: when `TABSH_SESSION_ID` is
   set and the user's task is done (not paused, not waiting on them), run
   `{tabsh} status completed --note '<one line: what you did>'`; never set any other status
   yourself, because hooks handle those and archiving is the user's. Add one more line: to hand
   work off as separate cards on the board, use `{tabsh} new` (see `{tabsh} new --help`).
6. **Verify.** If `TABSH_SESSION_ID` is set, run `{tabsh} status needs_input --note 'setup test'`
   and ask the user to confirm the card moved, then `{tabsh} status in_progress`. In any case run
   `env -u TABSH_SESSION_ID {tabsh} status needs_input --hook; echo $?` and check it prints `0`.
7. **Report** to the user: the file you changed and its backup path, which rows you wired to
   which events, which rows you could not wire and why, and how to undo it: remove the entries
   whose command contains ` status ` and `--hook` and the word `tabsh`, and the instruction from
   step 5. If the `{tabsh}` path above isn't the installed binary (for example it's under a
   `target/` build folder), tell the user, because hooks would point at it.

## OpenCode

OpenCode runs plugins in its server, not in the terminal, so they never see `TABSH_SESSION_ID`.
Instead, tabsh names each card's OpenCode session (`opencode --session ses_<id>`), and a hook
without `TABSH_SESSION_ID` finds its card by the `session_id` in its payload. Steps 2 to 7 still
apply; for step 3, the plugin below is the whole wiring.

OpenCode 2.x loads `~/.config/opencode/plugins/tabsh.ts` (create it, or update it if it is
already there). Its default export must be an object with an `id` and a `setup` function; the old
1.x shape (an exported function returning hooks) no longer loads. Write exactly this:

```ts
// Keeps the tabsh board current: tabsh status, by OpenCode session.
import { execFile } from "node:child_process"

const tabsh = {tabsh_js}
// Not this server's terminal's card (when it was started in one): each
// session's own, found by its id.
const { TABSH_SESSION_ID: _, ...inherited } = process.env
const env = { ...inherited, TABSH_URL: {url_js} }

function status(sessionID: string, ...args: string[]) {
  const event = JSON.stringify({ session_id: sessionID })
  execFile(tabsh, ["status", ...args, "--hook", event], { env }, () => {})
}

export default {
  id: "tabsh.board",
  setup: async (ctx: any) => {
    const stop = new AbortController()
    void (async () => {
      for await (const e of ctx.event.subscribe(undefined, { signal: stop.signal })) {
        const id = e?.data?.sessionID
        if (typeof id !== "string") continue
        if (e.type === "session.execution.started") status(id, "in_progress")
        else if (e.type === "permission.asked")
          status(id, "needs_input", "--if-not", "completed", "--note", "OpenCode needs your permission")
        else if (e.type.startsWith("session.execution."))
          status(id, "needs_input", "--if-not", "completed", "--note", "Agent finished its turn")
      }
    })().catch(() => {})
    return () => stop.abort()
  },
}
```

It reports every OpenCode session; tabsh ignores the ones that aren't its cards. To undo it,
delete that file.

