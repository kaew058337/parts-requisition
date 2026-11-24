-- =====================================================================
--  009 : ฟังก์ชันชุด 3c-2  KPI · แดชบอร์ด · รายงานความสิ้นเปลืองรายเดือน · reconcile
--  แปลงจาก Code.gs: getKpi (kpiCompute_), getDashboard, getMonthlyReport, getReconcile
-- =====================================================================

-- บรรทัดใบเบิก (ไม่รวมที่ยกเลิก) พร้อมวันที่รับครบ
create or replace view v_kpi_lines with (security_invoker = true) as
select r.seq, r.doc_no as doc, r.part_no as part, r.name, r.qty, r.item_type as type, r.urgency as urg, r.req_date, fn_due(r.req_date, r.urgency) as due,
       coalesce(d.done, r.pay_date) as done, coalesce(d.acc, 0) as recv, r.tai_status as tai, r.tai_po as po, fn_tdate(r.tai_due) as eta,
       (upper(btrim(r.urgency)) in ('AOG', 'ด่วน', 'ด่วนมาก')) as aog
from requisitions r
left join lateral (
  select min(x.day) filter (where x.cum >= r.qty) as done, sum(x.q) as acc
  from (select c.received_date as day, c.qty as q, sum(c.qty) over (order by c.received_date, c.seq) as cum
        from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no and c.received_date is not null) x) d on true
where not r.cancelled and r.req_date is not null and r.doc_no ~ '^\d{9}$' and (r.part_no <> '' or r.name <> '');

create or replace function fn_kpi_avg(a numeric[]) returns numeric language sql immutable as $$
  select case when coalesce(array_length(a,1),0) = 0 then null else round((select avg(x) from unnest(a) x), 1) end $$;
create or replace function fn_kpi_med(a numeric[]) returns numeric language sql immutable as $$
  select case when coalesce(array_length(a,1),0) = 0 then null else round((select percentile_cont(0.5) within group (order by x)::numeric from unnest(a) x), 1) end $$;

create or replace function fn_kpi_month(y int, m int) returns jsonb language plpgsql stable as $$
declare ms date := make_date(y, m, 1); me date := (make_date(y, m, 1) + interval '1 month')::date; due_n int; ok_n int; lead numeric[]; late numeric[]; comp int; late_n int; raised int;
begin
  select count(*) into raised from v_kpi_lines where req_date >= ms and req_date < me;
  select count(*), count(*) filter (where done is not null and done <= due) into due_n, ok_n from v_kpi_lines where due >= ms and due < me;
  select coalesce(array_agg((done - req_date)::numeric), '{}'), coalesce(array_agg((done - due)::numeric) filter (where done > due), '{}'), count(*), count(*) filter (where done > due)
    into lead, late, comp, late_n from v_kpi_lines where done >= ms and done < me;
  return jsonb_build_object('raised', raised, 'dueCount', due_n, 'onTime', ok_n,
    'otd', case when due_n > 0 then round(ok_n::numeric / due_n * 100, 1) end, 'completed', comp,
    'leadAvg', fn_kpi_avg(lead), 'leadMed', fn_kpi_med(lead), 'leadMax', (select max(x) from unnest(lead) x),
    'lateCount', late_n, 'lateAvg', fn_kpi_avg(late));
end $$;

create or replace function rpc_get_kpi(p jsonb default '{}'::jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  t date := fn_today(); y int := extract(year from fn_today())::int; m int := extract(month from fn_today())::int; mm text[]; ms date; me date;
  cur jsonb; trend jsonb := '[]'::jsonb; i int; d date; s jsonb; v_open int; v_over int; v_aog int; v_eta int; ag jsonb; dwell numeric[]; recvm int; issm int;
  cs int; cb int; cdays numeric[]; copen int; ccnt int; cok int; by_type jsonb; by_urg jsonb; top_over jsonb; top_late jsonb; taij jsonb;
begin
  mm := regexp_match(coalesce(p->>'ym',''), '^(\d{4})-(\d{2})$');
  if mm is not null then y := mm[1]::int; m := mm[2]::int; end if;
  ms := make_date(y, m, 1); me := (ms + interval '1 month')::date;
  cur := fn_kpi_month(y, m);
  for i in reverse 5..0 loop
    d := (ms - make_interval(months => i))::date;
    s := fn_kpi_month(extract(year from d)::int, extract(month from d)::int);
    trend := trend || jsonb_build_array(jsonb_build_object('y', extract(year from d)::int, 'm', extract(month from d)::int - 1, 'raised', s->'raised', 'completed', s->'completed',
        'otd', s->'otd', 'dueCount', s->'dueCount', 'leadAvg', s->'leadAvg'));
  end loop;
  select count(*), count(*) filter (where t > due), count(*) filter (where aog), count(*) filter (where eta is not null and t > eta),
         jsonb_build_object('a0', count(*) filter (where t - req_date <= 30), 'a31', count(*) filter (where t - req_date > 30 and t - req_date <= 60),
                            'a61', count(*) filter (where t - req_date > 60 and t - req_date <= 90), 'a91', count(*) filter (where t - req_date > 90))
    into v_open, v_over, v_aog, v_eta, ag from v_kpi_lines where done is null;
  select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc, k), '[]'::jsonb) into taij
    from (select coalesce(nullif(tai,''), 'ยังไม่มีข้อมูลจาก TAI') k, count(*) n from v_kpi_lines where done is null group by 1) z;
  select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n, 'ok', ok, 'otd', round(ok::numeric / n * 100, 1)) order by n desc, k), '[]'::jsonb) into by_type
    from (select coalesce(nullif(type,''), 'ไม่ระบุ') k, count(*) n, count(*) filter (where done is not null and done <= due) ok from v_kpi_lines where due >= ms and due < me group by 1) z;
  select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n, 'ok', ok, 'otd', round(ok::numeric / n * 100, 1)) order by n desc, k), '[]'::jsonb) into by_urg
    from (select coalesce(nullif(urg,''), 'ไม่ระบุ') k, count(*) n, count(*) filter (where done is not null and done <= due) ok from v_kpi_lines where due >= ms and due < me group by 1) z;
  select coalesce(jsonb_agg(jsonb_build_object('doc', doc, 'part', part, 'name', name, 'urg', urg, 'due', fn_thai(due), 'req', fn_thai(req_date), 'days', days, 'tai', coalesce(tai,''),
      'po', coalesce(po,''), 'eta', fn_thai(eta)) order by days desc, seq), '[]'::jsonb) into top_over
    from (select *, t - due as days from v_kpi_lines where done is null and t > due order by t - due desc, seq limit 8) z;
  select coalesce(jsonb_agg(jsonb_build_object('doc', doc, 'part', part, 'name', name, 'urg', urg, 'due', fn_thai(due), 'req', fn_thai(req_date), 'days', days, 'tai', coalesce(tai,''),
      'po', coalesce(po,''), 'eta', fn_thai(eta)) order by days desc, seq), '[]'::jsonb) into top_late
    from (select *, done - due as days from v_kpi_lines where done >= ms and done < me and done > due order by done - due desc, seq limit 8) z;
  select count(*) into recvm from receipts where received_date >= ms and received_date < me;
  select count(*) into issm from issues where issue_date >= ms and issue_date < me;
  select coalesce(array_agg(greatest(0, f.d0 - r.received_date)::numeric), '{}') into dwell
    from receipts r join (select receipt_seq, min(issue_date) d0 from issues where issue_date is not null group by 1) f on f.receipt_seq = r.seq
    where r.received_date >= ms and r.received_date < me;
  select count(*) filter (where sent_date >= ms and sent_date < me), count(*) filter (where returned_date >= ms and returned_date < me),
         coalesce(array_agg((returned_date - sent_date)::numeric) filter (where sent_date is not null and returned_date >= ms and returned_date < me), '{}'),
         count(*) filter (where claim_no <> '' and returned_date is null)
    into cs, cb, cdays, copen from claims;
  select count(*), count(*) filter (where diff = 0) into ccnt, cok from counts where count_date >= ms and count_date < me;
  return jsonb_build_object('ym', y || '-' || lpad(m::text, 2, '0'), 'asOf', fn_thai(t),
    'month', cur || jsonb_build_object('received', recvm, 'issued', issm, 'dwellAvg', fn_kpi_avg(dwell), 'claimSent', cs, 'claimBack', cb, 'claimAvg', fn_kpi_avg(cdays),
        'cntLines', ccnt, 'cntOk', cok, 'cntAcc', case when ccnt > 0 then round(cok::numeric / ccnt * 100, 1) end),
    'trend', trend,
    'backlog', jsonb_build_object('open', v_open, 'overdue', v_over, 'aog', v_aog, 'aging', ag, 'claimOpen', copen, 'etaPassed', v_eta),
    'tai', taij, 'byType', by_type, 'byUrg', by_urg, 'topOverdue', top_over, 'topLate', top_late);
end $$;

-- ---------- แดชบอร์ด ----------
create or replace function rpc_get_dashboard(p_month text default '') returns jsonb language plpgsql security definer set search_path = public as $$
declare
  today date := fn_today(); ym text := case when coalesce(p_month,'') ~ '^\d{4}-\d{2}$' then p_month else to_char(fn_today(), 'YYYY-MM') end;
  tci jsonb; sm jsonb; pend int; pend_aog int; pend_over int; month_req int; month_done int; tci_late int; tci_soon int;
  stock_lots int; recv_ni int; aw jsonb; dw jsonb; warr int; loans_over int; claims_open int; recent jsonb;
begin
  create temp table if not exists _dash(doc text, part text, name text, type text, qty numeric, got numeric, remain numeric, unit text, req_date date, due date, inst date, days_left int,
    inst_late boolean, on_time boolean, rcv date, status text, urg text, machine text, late boolean, tai jsonb, ord int, sort_key numeric) on commit drop;
  truncate _dash;
  with rq as (
    select r.*, coalesce(g.have, 0) have, g.rcv, coalesce(iss.issued, 0) issued, fn_due(r.req_date, r.urgency) due2,
           (r.item_type in ('LRU(TCI)', 'SP(TCI)')) is_tci
    from requisitions r
    left join lateral (select sum(c.qty) have, max(c.received_date) rcv from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no) g on true
    left join lateral (select sum(l.issued) issued from v_lots l where not l.is_free and l.doc_no = r.doc_no and l.part_no = r.part_no) iss on true
    where not r.cancelled and r.doc_no ~ '^\d{9}$' and (r.part_no <> '' or r.name <> '')),
  x as (
    select rq.*, greatest(qty - have, 0) remain, case when is_tci then tci_install_date end inst2 from rq),
  y as (
    select x.*, (remain > 0 and due2 < today) late, (inst2 is not null and remain > 0 and inst2 - today < 0) inst_late,
           case when inst2 is not null then inst2 - today end dl,
           coalesce(inst2, req_date) basis from x)
  select
    (select count(*) from y where remain > 0), (select count(*) from y where remain > 0 and urgency = 'AOG'), (select count(*) from y where late),
    (select count(*) from y where req_date is not null and to_char(req_date, 'YYYY-MM') = ym), (select count(*) from y where remain <= 0 and req_date is not null and to_char(req_date, 'YYYY-MM') = ym),
    (select count(*) from y where inst2 is not null and remain > 0 and inst_late), (select count(*) from y where inst2 is not null and remain > 0 and not inst_late and dl <= 7)
  into pend, pend_aog, pend_over, month_req, month_done, tci_late, tci_soon;

  insert into _dash
  with rq as (
    select r.*, coalesce(g.have, 0) have, g.rcv, coalesce(iss.issued, 0) issued, fn_due(r.req_date, r.urgency) due2, (r.item_type in ('LRU(TCI)', 'SP(TCI)')) is_tci
    from requisitions r
    left join lateral (select sum(c.qty) have, max(c.received_date) rcv from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no) g on true
    left join lateral (select sum(l.issued) issued from v_lots l where not l.is_free and l.doc_no = r.doc_no and l.part_no = r.part_no) iss on true
    where not r.cancelled and r.doc_no ~ '^\d{9}$' and (r.part_no <> '' or r.name <> '')),
  x as (select rq.*, greatest(qty - have, 0) remain, case when is_tci then tci_install_date end inst2 from rq),
  y as (select x.*, (remain > 0 and due2 < today) late, (inst2 is not null and remain > 0 and inst2 - today < 0) inst_late, case when inst2 is not null then inst2 - today end dl from x)
  select doc_no, part_no, name, item_type, qty, have, remain, unit, req_date, due2, inst2, dl, inst_late,
         case when remain <= 0 and inst2 is not null and rcv is not null then rcv <= inst2 end, rcv,
         case when remain <= 0 then (case when issued >= qty then 'จ่ายให้ช่างแล้ว' else 'รับแล้ว' end) when have > 0 then 'รับบางส่วน' else 'ค้างรับ' end,
         urgency, machine, (case when inst2 is not null then inst_late else late end),
         case when remain > 0 then fn_tai_obj((select q from requisitions q where q.seq = y.seq), inst2) end,
         case when (case when inst2 is not null then inst_late else late end) then 0 when remain > 0 then (case when have > 0 then 2 else 1 end) else 3 end,
         case when inst2 is not null then extract(epoch from inst2::timestamp) * 1000 else 9e15 end
  from y where is_tci and to_char(coalesce(inst2, req_date), 'YYYY-MM') = ym;

  select jsonb_build_object('total', count(*), 'done', count(*) filter (where remain <= 0), 'issued', count(*) filter (where remain <= 0 and status = 'จ่ายให้ช่างแล้ว'),
      'partial', count(*) filter (where remain > 0 and got > 0), 'pending', count(*) filter (where remain > 0 and got <= 0), 'overdue', count(*) filter (where late),
      'aog', count(*) filter (where urg = 'AOG' and remain > 0)) into sm from _dash;
  select coalesce(jsonb_agg(jsonb_build_object('docNo', doc, 'part', part, 'name', name, 'type', type, 'qty', qty, 'got', got, 'remain', remain, 'unit', unit, 'reqDate', fn_thai(req_date),
      'due', fn_thai(due), 'install', fn_thai(inst), 'daysLeft', days_left, 'instLate', inst_late, 'onTime', on_time, 'recvDate', fn_thai(rcv), 'status', status, 'urgency', urg,
      'machine', machine, 'late', late, 'tai', tai, 'order', ord, 'sortKey', sort_key) order by ord, sort_key, doc), '[]'::jsonb) into tci from _dash;

  select count(*), count(*) filter (where not is_free) into stock_lots, recv_ni from v_lots where remain > 0;
  aw := rpc_get_awaiting_req(); dw := rpc_get_awaiting_doc();
  warr := jsonb_array_length(rpc_get_warranty_list(60));
  select count(*) into loans_over from loans where status = 'ยืมอยู่' and due_date < today;
  select count(*) into claims_open from claims where status = 'ส่งเคลมแล้ว';
  select coalesce(jsonb_agg(jsonb_build_object('when', fn_ts(at), 'by', user_name, 'action', action, 'doc', doc_no, 'detail', detail) order by id desc), '[]'::jsonb) into recent
    from (select * from activity_log order by id desc limit 8) z;
  return jsonb_build_object('month', ym, 'tci', tci, 'tciSum', sm, 'kits', fn_kit_status(),
    'alerts', jsonb_build_object('pending', pend, 'pendingAog', pend_aog, 'pendingOverdue', pend_over, 'recvNotIssued', recv_ni, 'awaiting', jsonb_array_length(aw), 'docWait', jsonb_array_length(dw),
        'docWaitDays', case when jsonb_array_length(dw) > 0 then (dw->0->>'days')::int else 0 end, 'warrSoon', warr, 'loansOverdue', loans_over, 'tciLate', tci_late, 'tciSoon', tci_soon),
    'cards', jsonb_build_object('monthReq', month_req, 'monthDone', month_done, 'stockLots', stock_lots, 'claimsOpen', claims_open), 'recent', recent);
end $$;

-- ---------- รายงานความสิ้นเปลืองพัสดุรายเดือน ----------
create or replace function fn_tail_remark(t text) returns text language sql immutable as $$
  select case
    when btrim(coalesce(t,'')) = '' then ''
    when btrim(t) ~* 'ALL\s*-?\s*SAAB|ทุกเครื่อง' then 'ทุกเครื่อง'
    when btrim(t) ~ '7020[1-7]' then (jsonb_build_object('70201','บ.ค.๑ ๑/๕๓','70202','บ.ตล.๑๗ ๑/๕๓','70203','บ.ค.๑ ๒/๕๕','70204','บ.ล.๑๗ ๒/๕๕',
        '70205','บ.ล.๑๗ ๓/๖๐','70206','บ.ล.๑๗ ๔/๖๐','70207','บ.ตล.๑๗ ๕/๖๓') ->> (regexp_match(btrim(t), '7020[1-7]'))[1])
    else btrim(t) end
$$;

create or replace function rpc_get_monthly_report(p jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  y int := extract(year from fn_today())::int; m int := extract(month from fn_today())::int; mm text[]; ms date; me date; out jsonb := '{}'::jsonb; tyn text; n int; yy text;
  mon text[] := array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'];
begin
  mm := regexp_match(coalesce(p->>'ym',''), '^(\d{4})-(\d{2})$');
  if mm is not null then y := mm[1]::int; m := mm[2]::int; end if;
  ms := make_date(y, m, 1); me := (ms + interval '1 month')::date;
  create temp table if not exists _mr(ty text, rn bigint, part text, name text, unit text, price numeric, qty numeric, tail text, serial text, k text) on commit drop;
  truncate _mr;
  insert into _mr
  select case when r.item_type in ('LRU','LRU(TCI)','SP','SP(TCI)') then r.item_type when r.serial_no <> '' then 'LRU' else 'SP' end,
         row_number() over (order by r.received_date, r.seq), r.part_no, r.name, coalesce(nullif(r.unit,''),'EA'), coalesce(r.unit_price, 0),
         r.qty - coalesce((select sum(rr.qty) from receipts rr where rr.source = 'คืนเข้าคลัง' and rr.ref_seq in (select i.seq from issues i where i.receipt_seq = r.seq)), 0),
         fn_tail_remark(r.tail_no), r.serial_no, null
  from receipts r
  where coalesce(nullif(r.source,''),'ใบเบิก') in ('ใบเบิก','รับก่อนเบิก') and r.ref_seq is null and r.received_date >= ms and r.received_date < me;
  delete from _mr where qty <= 0;
  update _mr set k = case when serial <> '' then 'S' || rn else part || '|' || price || '|' || tail end where true;
  select count(*) into n from _mr;
  foreach tyn in array array['LRU','LRU(TCI)','SP','SP(TCI)'] loop
    out := out || jsonb_build_object(tyn, coalesce((select jsonb_agg(jsonb_build_object('part', part, 'name', name, 'qty', q, 'unit', unit, 'price', price, 'total', round(q * price, 2), 'remark', tail, 'serial', serial) order by r0)
      from (select (array_agg(part order by rn))[1] part, (array_agg(name order by rn))[1] name, (array_agg(unit order by rn))[1] unit, (array_agg(price order by rn))[1] price,
                   sum(qty) q, (array_agg(tail order by rn))[1] tail, (array_agg(serial order by rn))[1] serial, min(rn) r0
            from _mr where _mr.ty = tyn group by k) g), '[]'::jsonb));
  end loop;
  yy := translate(lpad(((y + 543) % 100)::text, 2, '0'), '0123456789', '๐๑๒๓๔๕๖๗๘๙');
  return jsonb_build_object('ym', y || '-' || lpad(m::text, 2, '0'), 'monthLabel', mon[m] || yy, 'monthLabelNum', mon[m] || lpad(((y + 543) % 100)::text, 2, '0'), 'sheets', out, 'lines', n);
end $$;

create or replace function rpc_get_reconcile() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', true, 'items', '[]'::jsonb, 'changes', '[]'::jsonb)
$$;

revoke all on function fn_kpi_avg(numeric[]), fn_kpi_med(numeric[]), fn_kpi_month(int,int), fn_tail_remark(text) from public, anon;
grant execute on function rpc_get_kpi(jsonb), rpc_get_dashboard(text), rpc_get_monthly_report(jsonb), rpc_get_reconcile() to anon;
