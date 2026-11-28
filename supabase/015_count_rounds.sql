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

-- ใบนับรวม: ดึงรายการพัสดุของหลาย LOCATION ในครั้งเดียว (สูงสุด 200 ที่เก็บต่อครั้ง)
create or replace function rpc_get_count_lists(p jsonb) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(rpc_get_count_list(t.loc, coalesce(p->>'grp','')) order by t.ord), '[]'::jsonb)
  from jsonb_array_elements_text(case when jsonb_array_length(coalesce(p->'locs','[]'::jsonb)) <= 200 then coalesce(p->'locs','[]'::jsonb) else '[]'::jsonb end) with ordinality as t(loc, ord)
$$;
grant execute on function rpc_get_count_lists(jsonb) to anon;

-- สรุปตัวเลขสำหรับหน้า "ภาพรวมคลัง (จอคอม)" : รีเฟรชอัตโนมัติดึงแค่ก้อนเล็กนี้ (ไม่ดึงรายการทั้งคลัง)
create or replace function public.rpc_get_pc_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := rpc_get_count_round('{}'::jsonb)->'round'; k jsonb := rpc_get_kits('{}'::jsonb); l jsonb := rpc_get_loans();
begin
  return jsonb_build_object(
    'rcv', jsonb_array_length(rpc_get_pending_receive()),
    'iss', jsonb_array_length(rpc_get_pending_issue()),
    'loansOpen', (select count(*) from jsonb_array_elements(l) x where (x->>'open')::boolean),
    'loansLate', (select count(*) from jsonb_array_elements(l) x where (x->>'open')::boolean and coalesce((x->>'late')::int,0)>0),
    'k1', (select count(*) from jsonb_array_elements(k->'1'->'items') x where (x->>'short')::int>0),
    'k2', (select count(*) from jsonb_array_elements(k->'2'->'items') x where (x->>'short')::int>0),
    'kt1', jsonb_array_length(k->'1'->'items'), 'kt2', jsonb_array_length(k->'2'->'items'),
    'round', case when r is null or jsonb_typeof(r)='null' then null else jsonb_build_object('name', r->>'name',
        'total', jsonb_array_length(r->'locs'), 'done', (select count(*) from jsonb_array_elements(r->'locs') x where (x->>'done')::boolean)) end);
end $$;
grant execute on function public.rpc_get_pc_summary() to anon;
