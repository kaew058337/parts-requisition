-- ขยายระยะเวลายืม
create or replace function rpc_extend_loan(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare l loans; nd date := nullif(p->>'due','')::date; old text;
begin
  perform fn_lock();
  select * into l from loans where seq = nullif(p->>'seq','')::bigint;
  if l.seq is null then raise exception 'ไม่พบรายการยืม'; end if;
  if l.status <> 'ยืมอยู่' then raise exception 'รายการนี้ปิดแล้ว ขยายเวลาไม่ได้'; end if;
  if nd is null then raise exception 'กรุณาระบุวันครบกำหนดใหม่'; end if;
  if nd <= coalesce(l.due_date, fn_today()) then raise exception 'วันใหม่ต้องเลยกำหนดเดิม'; end if;
  old := fn_thai(l.due_date);
  update loans set due_date = nd,
    note = concat_ws(' | ', nullif(note,''), 'ขยายเวลา ' || old || ' → ' || fn_thai(nd) || coalesce(' (' || nullif(p->>'reason','') || ')',''))
  where seq = l.seq;
  perform fn_log(p->>'by', 'ขยายเวลายืม', '', concat_ws(' | ', 'ยืม #' || l.seq, l.part_no, l.name, 'ผู้ยืม ' || l.borrower, old || ' → ' || fn_thai(nd), nullif(p->>'reason','')));
  return jsonb_build_object('ok', true, 'due', fn_thai(nd));
end $$;
grant execute on function rpc_extend_loan(jsonb) to anon;

create or replace function rpc_get_loans() returns jsonb language sql stable security definer set search_path = public as $$
  with x as (
    select l.*, (l.status = 'ยืมอยู่') as is_open,
           case when l.status = 'ยืมอยู่' and l.due_date < fn_today() then fn_today() - l.due_date else 0 end as late
    from loans l),
  o as (select * from x where is_open order by late desc, due_date, seq),
  c as (select * from x where not is_open order by seq desc limit 100),
  u as (select *, 0 as grp, row_number() over (order by late desc, due_date, seq) as rn from o
        union all select *, 1, row_number() over (order by seq desc) from c)
  select coalesce(jsonb_agg(jsonb_build_object('seq', seq, 'date', fn_thai(loan_date), 'part', part_no, 'name', name, 'serial', serial_no, 'type', item_type, 'qty', qty, 'unit', unit,
      'out', qty_open, 'borrower', borrower, 'btype', borrower_type, 'purpose', reason, 'due', fn_thai(due_date), 'dueIso', to_char(due_date,'YYYY-MM-DD'), 'open', is_open, 'late', late, 'status', status,
      'closed', fn_thai(closed_date), 'method', close_method, 'docRef', ref_doc_no, 'note', note,
      'dueMs', case when due_date is not null then (extract(epoch from due_date::timestamp) * 1000)::bigint else 0 end) order by grp, rn), '[]'::jsonb)
  from u
$$;
grant execute on function rpc_get_loans() to anon;
