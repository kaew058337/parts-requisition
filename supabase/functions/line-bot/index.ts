// บอตไลน์ (Supabase Edge Function) — แทนส่วนไลน์ใน Code.gs
//  - POST จากไลน์ (webhook, ตรวจลายเซ็น x-line-signature): จดรหัสกลุ่ม, แชทส่วนตัว: /id และค้นหาพัสดุ
//  - ?job=daily  (เรียกโดย pg_cron ตอน 16:10, ต้องมี header x-cron-key): ส่งสรุป/แจ้งด่วนเข้ากลุ่ม
//  - ?job=test   (x-cron-key): ส่งสรุปเต็มเข้ากลุ่มทันที (ทดสอบ)   ?job=status : ดูสถานะการตั้งค่า
// Secrets: LINE_CHANNEL_SECRET, LINE_CHANNEL_TOKEN ; รหัสเรียกงานตั้งเวลาอยู่ในตาราง app_settings (cron_key)  (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY มีให้อัตโนมัติ)
import * as XLSX from "https://esm.sh/xlsx@0.18.5";
const URL_ = Deno.env.get("SUPABASE_URL")!, KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = (Deno.env.get("LINE_CHANNEL_SECRET") ?? "").trim(), TOKEN = (Deno.env.get("LINE_CHANNEL_TOKEN") ?? "").trim();
const H = { "Content-Type": "application/json", apikey: KEY, Authorization: "Bearer " + KEY };

async function rpc(fn: string, args: Record<string, unknown> = {}) {
  const r = await fetch(`${URL_}/rest/v1/rpc/${fn}`, { method: "POST", headers: H, body: JSON.stringify(args) });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}
async function getSet(key: string): Promise<string> {
  const r = await fetch(`${URL_}/rest/v1/app_settings?key=eq.${encodeURIComponent(key)}&select=value`, { headers: H });
  const j = await r.json();
  return (j && j[0] && j[0].value) || "";
}
async function setSet(key: string, value: string) {
  await fetch(`${URL_}/rest/v1/app_settings?on_conflict=key`, { method: "POST", headers: { ...H, Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify({ key, value, updated_at: new Date().toISOString() }) });
}
async function log(action: string, detail: string) {
  await fetch(`${URL_}/rest/v1/activity_log`, { method: "POST", headers: H, body: JSON.stringify({ user_name: "ไลน์", action, doc_no: "", detail }) });
}
async function verify(body: string, sig: string): Promise<boolean> {
  if (!SECRET || !sig) return false;
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(body)));
  let s = ""; mac.forEach((b) => (s += String.fromCharCode(b)));
  return btoa(s) === sig;
}
async function line(path: string, payload: unknown) {
  const r = await fetch("https://api.line.me/v2/bot/message/" + path, { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + TOKEN }, body: JSON.stringify(payload) });
  if (!r.ok) throw new Error(`LINE ${r.status}: ${(await r.text()).slice(0, 200)}`);
}
const reply = (token: string, text: string) => token && TOKEN ? line("reply", { replyToken: token, messages: [{ type: "text", text: text.slice(0, 4500) }] }) : Promise.resolve();


// ---------- อ่านไฟล์ Excel จากกลุ่ม (ตาราง TCI / ความคืบหน้า TAI) ----------
const MACHINES = ["70201", "70202", "70203", "70204", "70205", "70206", "70207", "ALL SAAB", "FLY AWAY KIT 1", "FLY AWAY KIT 2"];
const TH_MON: Record<string, number> = { "มค": 0, "กพ": 1, "มีค": 2, "เมย": 3, "พค": 4, "มิย": 5, "กค": 6, "สค": 7, "กย": 8, "ตค": 9, "พย": 10, "ธค": 11 };
const norm = (x: unknown) => String(x ?? "").replace(/[ \s]+/g, " ").trim();
const iso = (y: number, m: number, d: number) => `${y}-${String(m + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
// คืน YYYY-MM-DD หรือ null  (รับข้อความ "5 พ.ย. 69", Date, หรือเลขลำดับวันของ Excel)
function thaiDate(v: unknown): string | null {
  if (v instanceof Date) return iso(v.getFullYear(), v.getMonth(), v.getDate());
  if (typeof v === "number" && v > 30000 && v < 80000) { const d = new Date(Math.round((v - 25569) * 86400000)); return iso(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()); }
  const t = norm(v);
  const m = t.match(/^(\d{1,2})\s*([ก-๙.]+)\s*(\d{2,4})$/);
  if (!m) return null;
  const mon = TH_MON[m[2].replace(/\./g, "")];
  if (mon === undefined) return null;
  let y = Number(m[3]); if (y < 100) y += 2500; if (y > 2400) y -= 543;
  return iso(y, mon, Number(m[1]));
}
type Grid = { vals: unknown[][]; merges: { s: { r: number; c: number }; e: { r: number; c: number } }[] };

function parseTci(g: Grid) {
  const { vals, merges } = g;
  let hr = -1; const col: Record<string, number> = {};
  for (let r = 0; r < Math.min(vals.length, 15) && hr < 0; r++) {
    const c: Record<string, number> = {};
    (vals[r] ?? []).forEach((x, i) => {
      const k = norm(x).toLowerCase();
      if (k === "no." || k === "no") c.no = i; else if (k.includes("workname")) c.job = i; else if (k === "due date") c.due = i;
      else if (k === "name") c.name = i; else if (k === "p/n") c.pn = i; else if (k === "ea") c.qty = i; else if (k === "remark") c.remark = i;
    });
    if (c.no !== undefined && c.due !== undefined && c.name !== undefined && c.pn !== undefined && c.qty !== undefined) { hr = r; Object.assign(col, c); }
  }
  if (hr < 0) return null;
  const own = vals.map((r) => r.map(() => true)), fill = vals.map((r) => r.slice());
  for (const m of merges) {
    const v = vals[m.s.r]?.[m.s.c];
    for (let r = m.s.r; r <= m.e.r; r++) for (let c = m.s.c; c <= m.e.c; c++) {
      if (!vals[r]) continue; fill[r][c] = v; if (r !== m.s.r || c !== m.s.c) own[r][c] = false;
    }
  }
  const items: any[] = [], skipped: string[] = [], warnings: string[] = [], seen: Record<string, number> = {};
  let machine = "";
  for (let r = hr + 1; r < vals.length; r++) {
    const a = norm(fill[r][col.no]); if (a) machine = a.replace(/\.0+$/, "");
    const nm = own[r][col.name] ? norm(vals[r][col.name]) : "", pn = own[r][col.pn] ? norm(vals[r][col.pn]) : "";
    if (!nm && !pn) continue;
    const job = norm(fill[r][col.job]), due = fill[r][col.due];
    const remark = col.remark !== undefined && own[r][col.remark] ? norm(vals[r][col.remark]) : "";
    const label = (nm || pn) + (machine ? " เครื่อง " + machine : "");
    if (!pn || /[ก-๙]/.test(pn)) { skipped.push(label + " (ไม่มี P/N)"); continue; }
    if (!MACHINES.includes(machine)) { skipped.push(label + ` (เครื่อง "${machine}" ไม่อยู่ในรายการ)`); continue; }
    const d = thaiDate(due);
    if (!d) { skipped.push(label + ` (อ่านวันที่ "${norm(due)}" ไม่ได้)`); continue; }
    const qty = Number(norm(vals[r][col.qty]).replace(/,/g, ""));
    if (!(qty > 0)) { skipped.push(label + " (จำนวนไม่ถูกต้อง)"); continue; }
    const sn = (remark.match(/S\/N\s*[:：]?\s*(\S+)/i) || [])[1] || "";
    const name = nm.replace(/\s*\([^)]*[ก-๙][^)]*\)\s*/g, " ").trim();
    if (sn) { const k = pn + "|" + sn; if (seen[k]) warnings.push(`S/N ซ้ำ: ${pn} S/N ${sn} (แถว ${seen[k]} และ ${r + 1})`); else seen[k] = r + 1; }
    items.push({ part: pn, name, qty, machine, install: d, sn, issue: [job, sn ? "S/N " + sn : ""].filter(Boolean).join(" · ") });
  }
  return { items, skipped, warnings };
}

function classifyTai(remark: string, po: string, ship: unknown): { stage: string; date: string | null } {
  const t = norm(remark);
  const dm = t.match(/นำจ่าย\s*คลังฝูง\s*(\d{1,2}\s*[ก-๙.]+\s*\d{2,4})/);
  if (dm) return { stage: /ขาด/.test(t) ? "นำจ่ายบางส่วน" : "นำจ่ายคลังฝูงแล้ว", date: thaiDate(dm[1]) };
  if (/สืบราคา/.test(t) && /ซ่อม/.test(t)) return { stage: "สืบราคา/แจ้งซ่อม", date: null };
  if (/ซ่อม/.test(t)) return { stage: "อยู่ระหว่างซ่อม", date: null };
  if (/สืบราคา|เทียบราคา/.test(t)) return { stage: "สืบราคา", date: null };
  if (/รออนุมัติ\s*PO/i.test(t)) return { stage: "รออนุมัติ PO", date: null };
  let d = thaiDate(ship);
  if (!d) { const sm = t.match(/ship\s*due[^0-9]*(\d{1,2}\s*[ก-๙.]+\s*\d{2,4})/i); if (sm) d = thaiDate(sm[1]); }
  if (d || norm(po)) return { stage: "สั่งซื้อแล้ว", date: d };
  return { stage: "รอจัดหา", date: null };
}

function parseTai(g: Grid) {
  const { vals } = g;
  let hr = -1; const c: Record<string, number> = {};
  for (let r = 0; r < Math.min(vals.length, 10) && hr < 0; r++) {
    const k: Record<string, number> = {};
    (vals[r] ?? []).forEach((x, i) => {
      const t = norm(x).toLowerCase();
      if (t === "เลขที่เอกสารผู้เบิก") k.doc = i; else if (t === "part no.") k.pn = i; else if (t === "part name") k.name = i;
      else if (t === "p.o. no.") k.po = i; else if (t.startsWith("ship due")) k.ship = i; else if (t.startsWith("mro supplier")) k.sup = i; else if (t === "remarks") k.rem = i;
    });
    if (k.doc !== undefined && k.pn !== undefined && k.rem !== undefined) { hr = r; Object.assign(c, k); }
  }
  if (hr < 0) return null;
  const get = (row: unknown[], i?: number) => (i === undefined ? "" : row[i]);
  const rows: any[] = []; let noDoc = 0;
  for (let r = hr + 1; r < vals.length; r++) {
    const row = vals[r] ?? [], doc = norm(get(row, c.doc)), part = norm(get(row, c.pn));
    if (!doc && !part) continue;
    if (!/^\d{1,9}$/.test(doc)) { if (norm(get(row, c.name))) noDoc++; continue; }
    const cl = classifyTai(String(get(row, c.rem) ?? ""), String(get(row, c.po) ?? ""), get(row, c.ship));
    rows.push({ doc: doc.padStart(9, "0"), part, name: norm(get(row, c.name)), po: norm(get(row, c.po)), supplier: norm(get(row, c.sup)), note: norm(get(row, c.rem)), stage: cl.stage, date: cl.date });
  }
  return { rows, noDoc };
}

async function handleFile(ev: any) {
  const m = ev.message, name = String(m.fileName ?? ""), src = ev.source ?? {}, gid = src.groupId || src.roomId || "";
  const target = await getSet("line_target");
  if (!target || gid !== target) return;                              // เฉพาะกลุ่มที่ตั้งไว้
  if (!/\.xlsx$/i.test(name)) return;
  const seen = (await getSet("line_seen")).split(",");
  if (seen.includes(m.id)) return;
  await setSet("line_seen", seen.concat([m.id]).slice(-30).join(","));
  await setSet("line_last_file", `${name} · ${new Date().toISOString()} · เริ่มอ่าน`);   // ไว้ตรวจเมื่อฟังก์ชันล้มกลางคัน
  let msg: string;
  try {
    const dl = await fetch(`https://api-data.line.me/v2/bot/message/${m.id}/content`, { headers: { Authorization: "Bearer " + TOKEN } });
    if (!dl.ok) throw new Error("ดาวน์โหลดไฟล์จากไลน์ไม่ได้ (" + dl.status + ")");
    const buf = new Uint8Array(await dl.arrayBuffer());
    if (buf.length > 9 * 1024 * 1024) throw new Error("ไฟล์ใหญ่เกิน 9 MB");
    await setSet("line_last_file", `${name} · ${buf.length} ไบต์ · ${new Date().toISOString()} · ดาวน์โหลดแล้ว`);
    // ประหยัดหน่วยความจำ: ดูชื่อแท็บก่อน ถ้ามีแท็บ TAI อ่านแท็บเดียว ; ปิดสไตล์/สูตร/รูปแบบ ; ใช้โหมด dense
    const lean = { type: "array", dense: true, cellStyles: false, cellNF: false, cellHTML: false, cellFormula: false, cellText: false } as any;
    const names: string[] = XLSX.read(buf, { type: "array", bookSheets: true }).SheetNames;
    const only = names.filter((n) => norm(n) === "พัสดุค้างจ่าย");
    const wb = XLSX.read(buf, only.length ? { ...lean, sheets: only } : lean);
    const grids: { name: string; g: Grid }[] = wb.SheetNames.map((n: string) => {
      const ws = wb.Sheets[n];
      return { name: n, g: { vals: XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: "" }) as unknown[][], merges: (ws["!merges"] ?? []) as Grid["merges"] } };
    });
    msg = "";
    // 1) ไฟล์ TAI (แท็บ พัสดุค้างจ่าย)
    for (const x of grids) {
      const t = parseTai(x.g);
      if (t) {
        const s = await rpc("fn_tai_apply", { rows: t.rows, asof: new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10) });
        const L = [`✅ อ่านความคืบหน้า TAI "${name}" แล้ว`, `ตรงกับใบเบิกที่ยังค้างรับ ${s.matched} รายการ`];
        if (s.finished) L.push(`รับครบแล้ว/ปิดไปแล้ว ${s.finished} รายการ (ไม่ต้องแสดง)`);
        L.push(`ไม่ตรงกับใบเบิกในระบบ ${s.unmatched} รายการ${t.noDoc ? ` · ไม่มีเลขใบเบิก ${t.noDoc} รายการ` : ""} (ข้าม)`);
        if (s.changed.length) L.push(`สถานะเปลี่ยน ${s.changed.length} รายการ: ` + s.changed.slice(0, 5).join(" ; "));
        if (s.delivered.length) L.push(`⚠️ TAI แจ้งนำจ่ายคลังฝูงแล้ว แต่ในระบบยังไม่รับ ${s.delivered.length} รายการ: ` + s.delivered.slice(0, 5).join(" ; "));
        if (s.missing.length) L.push(`⚠️ หายจากไฟล์ใหม่ แต่ในระบบยังค้างรับ ${s.missing.length} รายการ: ` + s.missing.slice(0, 5).join(" ; "));
        msg = L.join("\n"); break;
      }
    }
    // 2) ตาราง Schedule TCI
    if (!msg) {
      const all = { items: [] as any[], skipped: [] as string[], warnings: [] as string[], tabs: 0 };
      for (const x of grids) { const t = parseTci(x.g); if (t) { all.tabs++; all.items.push(...t.items); all.skipped.push(...t.skipped); all.warnings.push(...t.warnings); } }
      if (!all.tabs) msg = `❌ อ่านไฟล์ "${name}" ไม่ได้: รูปแบบตารางไม่ตรงที่คาดไว้ (ไม่ใช่ตาราง TCI หรือไฟล์ TAI)`;
      else if (!all.items.length) msg = `อ่านไฟล์ "${name}" แล้ว แต่ไม่พบรายการพัสดุ` + (all.skipped.length ? ` (ข้าม ${all.skipped.length} รายการ)` : "");
      else {
        const r = await rpc("fn_tci_ingest", { items: all.items, src: name });
        const L = [`✅ อ่านตาราง TCI "${name}" แล้ว ${all.items.length} รายการ`, `เพิ่มเป็น "รายการ TCI รอเบิก" ${r.added} รายการ${r.dup ? ` · ซ้ำ/เบิกไปแล้ว ${r.dup}` : ""}`,
          `เปิดแอป → หน้า เบิก → "รายการ TCI รอเบิก" เพื่อเลือกผู้เบิกและออกใบเบิก (รอทั้งหมด ${r.pending} รายการ)`];
        if (all.skipped.length) L.push(`ข้าม ${all.skipped.length} รายการ: ` + all.skipped.slice(0, 5).join(" ; "));
        if (all.warnings.length) L.push("⚠️ " + all.warnings.slice(0, 3).join(" ; "));
        msg = L.join("\n");
      }
    }
  } catch (e) {
    msg = `❌ อ่านไฟล์ "${name}" ไม่สำเร็จ: ` + (e as Error).message;
    await log("นำเข้า", "อ่านไฟล์จากไลน์ไม่สำเร็จ: " + (e as Error).message);
  }
  await reply(ev.replyToken, msg);
}

async function weeklyLink(): Promise<string> {
  const site = (await getSet("site_url")).replace(/\/$/, "");
  return site ? `\n\nดูรายงานฉบับเต็ม (พิมพ์/บันทึกเป็น PDF ได้): ${site}/weekly.html` : "";
}

async function onEvent(ev: any) {
  const src = ev.source ?? {}, gid = src.groupId || src.roomId || "";
  if (gid) {
    await setSet("line_last_group", gid);
    if (!(await getSet("line_target"))) await setSet("line_target", gid);   // ยังไม่เคยตั้งกลุ่มปลายทาง: ใช้กลุ่มแรกที่บอตเห็น
  }
  if (ev.type === "message" && ev.message?.type === "file") return handleFile(ev);
  if (ev.type !== "message" || ev.message?.type !== "text") return;
  if (src.type && src.type !== "user") return;                // ตอบเฉพาะแชทส่วนตัว
  const text = String(ev.message.text ?? "").trim(), uid = src.userId ?? "";
  if (!text) return;
  if (/^\/id$/i.test(text)) return reply(ev.replyToken, "รหัสไลน์ของคุณ:\n" + uid + "\n\nส่งรหัสนี้ให้ผู้ดูแลระบบเพื่อเพิ่มสิทธิ์ค้นหา");
  const allow = (await getSet("line_search_users")).split(",").map((x) => x.trim()).filter(Boolean);
  if (!uid || !allow.includes(uid)) return reply(ev.replyToken, "ยังไม่ได้รับสิทธิ์ค้นหา\nพิมพ์ /id เพื่อรับรหัสของคุณ แล้วส่งให้ผู้ดูแลระบบ");
  let msg: string;
  try { msg = await rpc("fn_line_search_text", { q: text }); } catch (e) { msg = "⚠️ ค้นหาไม่สำเร็จ: " + (e as Error).message; }
  return reply(ev.replyToken, msg);
}

Deno.serve(async (req) => {
  const u = new URL(req.url), job = u.searchParams.get("job");
  try {
    if (job) {
      const CRON = await getSet("cron_key");
      if (!CRON || req.headers.get("x-cron-key") !== CRON) return new Response("forbidden", { status: 403 });
      if (job === "status") {
        return Response.json({ secret: !!SECRET, secretLen: SECRET.length, token: !!TOKEN, tokenLen: TOKEN.length, target: !!(await getSet("line_target")), lastGroup: await getSet("line_last_group"),
          users: (await getSet("line_search_users")).split(",").filter(Boolean).length });
      }
      const to = await getSet("line_target");
      if (!TOKEN || !to) return Response.json({ sent: false, why: "ยังไม่ได้ตั้ง LINE_CHANNEL_TOKEN หรือยังไม่มีกลุ่มปลายทาง" }, { status: 200 });
      const today = new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
      let text: string;
      if (job === "test") text = await rpc("fn_line_digest", { today, urgent_only: false });
      else if (job === "weekly") { text = await rpc("fn_line_weekly_text", { today }); text += await weeklyLink(); }
      else {
        const d = await rpc("fn_line_daily2"); text = d.text;
        if (d.weekly) { const parts = text.split("\n\n"); text = parts[0] + (await weeklyLink()) + (parts.length > 1 ? "\n\n" + parts.slice(1).join("\n\n") : ""); }
      }
      if (!text) return Response.json({ sent: false, why: "ไม่มีเรื่องที่ต้องแจ้งวันนี้" });
      await line("push", { to, messages: [{ type: "text", text }] });
      await log("สรุปไลน์", "ส่งเข้ากลุ่มแล้ว: " + text.split("\n")[0]);
      return Response.json({ sent: true });
    }
    if (req.method !== "POST") return new Response("OK");
    const body = await req.text();
    if (!(await verify(body, req.headers.get("x-line-signature") ?? ""))) return new Response("bad signature", { status: 401 });
    await setSet("line_last_post", new Date().toISOString());
    for (const ev of JSON.parse(body).events ?? []) { try { await onEvent(ev); } catch (e) { console.error(e); } }
    return new Response("OK");
  } catch (e) {
    console.error(e);
    return new Response("error: " + (e as Error).message, { status: 500 });
  }
});
