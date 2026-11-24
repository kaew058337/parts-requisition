-- ระบบตรวจนับแบบรอบนับ (applied live 2026-11-24)
create table if not exists count_rounds(
  id bigserial primary key, name text not null, grp text not null default '', started_at timestamptz not null default now(),
  started_by text not null default '', closed_at timestamptz, closed_by text not null default '', note text not null default '');
alter table counts add column if not exists round_id bigint references count_rounds(id);
create index if not exists counts_round_idx on counts(round_id);
alter table count_rounds enable row level security;

-- rpc_submit_count: เพิ่ม round_id ลงตาราง counts
--   insert into counts(..., counter, witness, round_id) ... values (..., by_, wit, nullif(p->>'roundId','')::bigint)
-- (แก้ในไฟล์ 007_functions_loans_counts.sql ด้วย)

-- ฟังก์ชันใหม่: rpc_start_count_round(p), fn_count_round_json(rid), rpc_get_count_round(p),
-- rpc_close_count_round(p), rpc_get_count_round_report(p)  -- ดูนิยามในฐานข้อมูลจริง (pg_get_functiondef)
-- grant execute on function rpc_start_count_round(jsonb), rpc_get_count_round(jsonb), rpc_close_count_round(jsonb), rpc_get_count_round_report(jsonb) to anon;
