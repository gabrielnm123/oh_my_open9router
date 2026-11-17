import { Plugin, usePlugin } from "@opencode/plugin/tui"
import { createSignal, onCleanup, onMount, Show } from "solid-js"
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"

const HOME = process.env.HOME ?? ""
const DATA_DIR = process.env.XDG_DATA_HOME
  ? join(process.env.XDG_DATA_HOME, "9router-tools")
  : join(HOME, ".local/share/9router-tools")
const CONFIG = process.env.XDG_CONFIG_HOME
  ? join(process.env.XDG_CONFIG_HOME, "opencode", "opencode.json")
  : join(HOME, ".config/opencode/opencode.json")
const PANEL_NAME = "venice.monitor"

function readJson(path: string): any {
  try {
    return JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return null
  }
}

function mtime(path: string): number {
  try {
    return statSync(path).mtimeMs
  } catch {
    return 0
  }
}

function procStart(pid: number): number {
  try {
    const up = Number(readFileSync("/proc/uptime", "utf8").split(" ")[0])
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8")
    const after = stat.slice(stat.lastIndexOf(")") + 2).split(" ")
    const ticks = Number(after[19]) // campo 22 do /proc/<pid>/stat
    return Date.now() - up * 1000 + (ticks / 100) * 1000
  } catch {
    return Date.now()
  }
}

function runningJobs(): Array<{ kind: string; pid: number; start: number }> {
  const out: Array<{ kind: string; pid: number; start: number }> = []
  let pids: string[] = []
  try {
    pids = readdirSync("/proc")
  } catch {
    return out
  }
  for (const pid of pids) {
    if (!/^\d+$/.test(pid)) continue
    let cmd = ""
    try {
      cmd = readFileSync(`/proc/${pid}/cmdline`, "utf8").replace(/\0/g, " ").trim()
    } catch {
      continue
    }
    if (!cmd) continue
    let kind: string | null = null
    if (/select-models-uncensored\.sh/.test(cmd)) kind = "uncensored"
    else if (/select-models\.sh/.test(cmd)) kind = "select"
    else if (/probe-models\.sh/.test(cmd)) kind = "probe"
    else if (/quality_probe\.py/.test(cmd)) kind = "quality"
    else if (/(sync-catalog\.sh|refresh-9router-models)/.test(cmd)) kind = "catalog"
    if (!kind) continue
    out.push({ kind, pid: Number(pid), start: procStart(Number(pid)) })
  }
  return out
}

function newestProbeDir(): string | null {
  const bases = [...new Set([tmpdir(), "/tmp"])]
  const dirs: string[] = []
  for (const base of bases) {
    try {
      for (const name of readdirSync(base)) {
        if (!name.startsWith("probe-models.")) continue
        const path = join(base, name)
        try {
          if (statSync(path).isDirectory()) dirs.push(path)
        } catch {}
      }
    } catch {}
  }
  dirs.sort((a, b) => mtime(b) - mtime(a))
  return dirs[0] ?? null
}

function scanRecords(records: any[]) {
  let done = 0
  let approved = 0
  let quality = 0
  let qualityN = 0
  let last = ""
  for (const rec of records) {
    if (!rec || typeof rec !== "object") continue
    done += 1
    if (rec.http_status === 200 && rec.tool_call_ok === true) approved += 1
    const q = rec.quality_score
    if (typeof q === "number" && Number.isFinite(q)) {
      quality += q
      qualityN += 1
    }
    if (rec.model && !last) last = String(rec.model)
  }
  return {
    done,
    approved,
    quality: qualityN ? quality / qualityN : null,
    last,
  }
}

function scanWorkdir(dir: string | null) {
  if (!dir) return scanRecords([])
  const records: any[] = []
  try {
    for (const name of readdirSync(dir)) {
      if (!/^\d+\.json$/.test(name)) continue
      records.push(readJson(join(dir, name)))
    }
  } catch {}
  return scanRecords(records)
}

function readLines(path: string): any[] {
  try {
    return readFileSync(path, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => {
        try {
          return JSON.parse(line)
        } catch {
          return null
        }
      })
  } catch {
    return []
  }
}

function probeFile(): string | null {
  const candidates = [join(DATA_DIR, "probe.jsonl"), join(process.cwd(), "probe.jsonl")]
  candidates.sort((a, b) => mtime(b) - mtime(a))
  return candidates.find((path) => existsSync(path)) ?? null
}

function progressFile(): string | null {
  const candidates = [
    process.env.NINEROUTER_PROGRESS_FILE ?? "",
    join(DATA_DIR, "probe.progress.json"),
    join(process.cwd(), "probe.progress.json"),
  ].filter(Boolean)
  candidates.sort((a, b) => mtime(b) - mtime(a))
  return candidates.find((path) => existsSync(path)) ?? null
}

function configuredModels(): number {
  const cfg = readJson(CONFIG)
  const models = cfg?.providers?.["9router"]?.models
  return models && typeof models === "object" ? Object.keys(models).length : 0
}

function fmtClock(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return "--:--"
  const total = Math.round(ms / 1000)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const pad = (n: number) => String(n).padStart(2, "0")
  return h ? `${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`
}

type Stat = {
  footer: string
  running: boolean
  stage: string
  source: string
  bar: string
  counts: string
  progress: string
  last: string
  times: string
}

function readStats(): Stat {
  const jobs = runningJobs()
  const running = jobs.length > 0
  const kinds = new Set(jobs.map((j) => j.kind))
  const stage = kinds.has("catalog")
    ? "catálogo"
    : kinds.has("probe")
      ? "sonda + qualidade"
      : kinds.has("quality")
        ? "qualidade"
        : kinds.has("select") || kinds.has("uncensored")
          ? "seleção"
          : "ocioso"

  const pf = progressFile()
  const progress = pf ? readJson(pf) : null
  const useProgress = Boolean(running && progress && typeof progress.done === "number")
  const scanned = useProgress
    ? {
        done: Number(progress!.done) || 0,
        approved: Number(progress!.approved) || 0,
        quality: typeof progress!.quality === "number" ? progress!.quality : null,
        last: String(progress!.last ?? ""),
      }
    : scanWorkdir(newestProbeDir())

  let done = scanned.done
  let approved = scanned.approved
  let quality = scanned.quality
  let last = scanned.last
  let total = useProgress ? Number(progress!.total) || 0 : configuredModels()

  if (done === 0) {
    const file = probeFile()
    const rows = file ? readLines(file) : []
    if (rows.length) {
      const fallback = scanRecords(rows)
      done = fallback.done
      approved = fallback.approved
      quality = fallback.quality
      last = fallback.last
      total = rows.length
    }
  }
  if (!total) total = configuredModels()

  const pct = total > 0 ? Math.min(100, (100 * done) / total) : 0
  const filled = Math.round((pct / 100) * 20)
  const bar = `[${"█".repeat(filled)}${"·".repeat(20 - filled)}]`

  const start = jobs.length ? Math.min(...jobs.map((j) => j.start)) : Date.now()
  const elapsed = running ? Date.now() - start : 0
  const eta = running && done > 0 && total > done ? ((total - done) * elapsed) / done : 0
  const times = running
    ? `decorrido ${fmtClock(elapsed)} · restante ~${fmtClock(eta)}`
    : "última rodada encerrada"

  const counts = `aprovados ${approved} · falhas ${Math.max(0, done - approved)} · qualidade ${
    quality === null ? "—" : quality.toFixed(2)
  }`
  const source = useProgress ? "progresso estruturado" : "leve (/tmp/probe-models.*)"
  const progress = `${done}/${total || "?"} (${pct.toFixed(1)}%)`
  const footer = running
    ? `9router ● ${stage} ${progress} · ok ${approved} · ${fmtClock(elapsed)}`
    : "9router ○ ocioso"

  return { footer, running, stage, source, bar, counts, progress, last, times }
}

const [stats, setStats] = createSignal<Stat>(readStats())

function MonitorPanel(props: any) {
  const context = usePlugin()
  onMount(() => {
    const stop = context.keymap.layer(() => ({
      mode: "global",
      commands: [
        {
          id: "venice.monitor.fullscreen",
          title: "Alternar tela cheia do painel 9router",
          bind: "f",
          run: () => props.panel.toggleFullscreen(),
        },
      ],
    }))
    onCleanup(() => stop?.())
  })
  const fg = context.theme?.text?.base ?? "#e5e7eb"
  return (
    <box flexDirection="column" padding={1} width="100%">
      <text fg={fg}>9router · painel ao vivo</text>
      <text fg={fg}>{`etapa   ${stats().stage}`}</text>
      <text fg={fg}>{`fonte   ${stats().source}`}</text>
      <text fg={fg}>{`progresso ${stats().bar} ${stats().progress}`}</text>
      <text fg={fg}>{stats().counts}</text>
      <text fg={fg}>{stats().times}</text>
      <text fg={fg}>{stats().last ? `último   ${stats().last}` : ""}</text>
      <text fg={fg}>f tela cheia · esc fecha</text>
    </box>
  )
}

export default Plugin.define({
  id: "venice.9router-monitor",
  setup(context: any) {
    const fg = context.theme?.text?.base ?? "#e5e7eb"
    let wasRunning: boolean | null = null
    let announced = false

    const tick = () => {
      const next = readStats()
      setStats(next)
      if (wasRunning === true && !next.running && !announced) {
        announced = true
        context.ui.toast.show({
          title: "9router",
          message: "Sonda/seleção concluída. O painel voltou para ocioso.",
        })
      }
      if (!next.running) announced = false
      wasRunning = next.running
    }

    const timer = setInterval(tick, 1000)

    const stopFooter = context.ui.slot({
      append: "home.footer.status",
      render: () => <text fg={fg}>{stats().footer}</text>,
    })

    const stopPanel = context.ui.slot({
      append: "session.panel",
      render: (panel: any) => (
        <Show when={panel?.name === PANEL_NAME}>
          <MonitorPanel panel={panel} />
        </Show>
      ),
    })

    const stopKeys = context.keymap.layer(() => ({
      mode: "global",
      priority: 10,
      commands: [
        {
          id: "venice.monitor.open",
          title: "Abrir painel ao vivo do 9router",
          palette: true,
          slash: { name: "painel_9router", aliases: ["monitor_9router"] },
          run: () => {
            tick()
            const opened = context.ui.panel.open(PANEL_NAME)
            if (opened === false) {
              context.ui.toast.show({
                title: "9router",
                message: "Abra uma sessão para ver o painel.",
              })
            }
          },
        },
      ],
    }))

    return () => {
      clearInterval(timer)
      stopFooter?.()
      stopPanel?.()
      stopKeys?.()
    }
  },
})
