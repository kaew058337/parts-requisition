-- =====================================================================
--  006 : ฟังก์ชันชุดที่ 3a  สต็อก · ค้นหา · ย้ายที่เก็บ · แก้ล็อต · ยอดยกมา/รับก่อนเบิก · ประกัน/เคลม · ประวัติ Serial
--  แปลงจาก Code.gs: getStock, searchParts, checkSerial, getIssuedSerials, getOpeningLots, addOpeningStock, getAwaitingReq, linkDirectIssue,
--  moveLocation, moveCell, getMoveHistory, moveToKit, editLot, warrantyMap_, getSerialHistory, getClaims, submitClaim, updateClaim, getWarrantyList
-- =====================================================================

alter table move_history add column if not exists serial_no text not null default '';
alter table move_history add column if not exists doc_no text not null default '';

-- ---------- ตัวช่วย ----------
create or replace function fn_shelf_key(loc text) returns text language sql immutable as $$ select upper(regexp_replace(coalesce(loc,''), '\s+', '', 'g')) $$;
create or replace function fn_srch_n(x text) returns text language sql immutable as $$ select regexp_replace(upper(coalesce(x,'')), '[^0-9A-Z฀-๿]', '', 'g') $$;

-- กลุ่มพัสดุ : '-' = ทั่วไป ; ว่าง = ใช้กลุ่มของล็อตล่าสุดของ Part เดียวกัน ถ้าไม่มี ใช้ค่า fallback
create or replace function fn_resolve_grp(g text, part text, fallback text) returns text language plpgsql stable as $$
declare v text := btrim(coalesce(g,'')); r text;
begin
  if v = '-' then return ''; end if;
  if v <> '' then if v <> 'สารเคมี' then raise exception 'กลุ่มพัสดุไม่ถูกต้อง'; end if; return v; end if;
  if btrim(coalesce(part,'')) <> '' then
    select item_group into r from receipts where part_no = btrim(part) order by seq desc limit 1;
    if found then return r; end if;
  end if;
  return coalesce(fallback,'');
end $$;

create or replace function fn_move_log(p_kind text, p_seq bigint, p_part text, p_name text, p_sn text, p_qty numeric, p_from text, p_to text, p_doc text, p_by text) returns void language sql as $$
  insert into move_history(kind, receipt_seq, part_no, name, serial_no, qty, from_loc, to_loc, doc_no, created_by)
  values (p_kind, p_seq, coalesce(p_part,''), coalesce(p_name,''), coalesce(p_sn,''), p_qty, coalesce(p_from,''), coalesce(p_to,''), coalesce(p_doc,''), coalesce(nullif(btrim(p_by),''),'(ไม่ระบุ)'));
$$;

-- คัดลอกแถวรับเป็นล็อตใหม่ (แยกบางส่วน) ; คืนเลขลำดับใหม่
create or replace function fn_clone_receipt(p_seq bigint, p_qty numeric, p_loc text, p_tail text, p_note text) returns bigint language plpgsql as $$
declare n bigint;
begin
  insert into receipts(doc_no, card_id, part_no, name, serial_no, item_type, item_group, qty, unit, unit_price, cond, notified_date, urgency, due_date, received_date,
                       tail_no, tci, expire_date, location, receiver, note, source, ref_seq)
  select doc_no, card_id, part_no, name, serial_no, item_type, item_group, p_qty, unit, unit_price, cond, notified_date, urgency, due_date, received_date,
         p_tail, tci, expire_date, p_loc, receiver, p_note, source, ref_seq from receipts where seq = p_seq
  returning seq into n;
  return n;
end $$;

-- ---------- ประกัน LRU (วันเริ่มประกันแต่ละ Serial) ----------
create or replace view v_warranty with (security_invoker = true) as
with base as (
  select upper(serial_no) k, min(received_date) st from receipts
   where serial_no <> '' and item_type like 'LRU%' and source in ('ใบเบิก','รับก่อนเบิก') and received_date is not null group by 1),
cl as (
  select distinct on (k) k, returned_date st from (
    select upper(case when status = 'ได้ซ่อมกลับ' then serial_no else new_serial end) k, returned_date,
           nullif(regexp_replace(claim_no, '\D', '', 'g'), '')::int n
      from claims where returned_date is not null and status in ('ได้ซ่อมกลับ','ได้ของใหม่') and (item_type = '' or item_type like 'LRU%')) x
  where k <> '' order by k, n desc nulls last),
st as (select k, st from base where k not in (select k from cl) union all select k, st from cl)
select k as sn_key, st as start_date, (st + 365) as end_date, ((st + 365) - (now() at time zone 'Asia/Bangkok')::date) as days_left,
       case when ((st + 365) - (now() at time zone 'Asia/Bangkok')::date) < 0 then 'expired'
            when ((st + 365) - (now() at time zone 'Asia/Bangkok')::date) <= 60 then 'soon' else 'ok' end as status
from st;
grant select on v_warranty to anon;

create or replace function fn_warr_json(k text) returns jsonb language sql stable as $$
  select jsonb_build_object('start', fn_thai(start_date), 'end', fn_thai(end_date), 'left', days_left, 'status', status) from v_warranty where sn_key = upper(k)
$$;

-- ---------- สต็อก ----------
create or replace function rpc_get_stock() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(g order by k collate "C"), '[]'::jsonb) from (
    select coalesce(nullif(l.part_no,''), l.name) as k,
      jsonb_build_object('part', (array_agg(l.part_no order by l.seq))[1], 'name', (array_agg(l.name order by l.seq))[1], 'unit', (array_agg(l.unit order by l.seq))[1],
        'qty', sum(l.remain),
        'lots', jsonb_agg(jsonb_build_object('seq', l.seq, 'free', l.is_free, 'serial', l.serial_no, 'qty', l.remain, 'docNo', l.label, 'type', l.item_type, 'grp', l.item_group,
            'cond', l.cond, 'location', l.location, 'recv', l.receiver, 'kit', fn_kit_of(l.tail_no), 'expire', fn_thai(l.expire_date), 'received', fn_thai(l.received_date),
            'note', l.note, 'issRow', case when l.is_free then 0 else l.seq end, 'issSeq', case when l.is_free then 0 else l.seq end, 'linkNote', '',
            'machine', case when l.is_free then '' else coalesce(q.machine,'') end,
            'warr', case when l.serial_no <> '' and l.item_type like 'LRU%' then fn_warr_json(l.serial_no) end) order by l.seq)) as g
    from v_lots l
    left join lateral (select machine from requisitions r where r.doc_no = l.doc_no and r.part_no = l.part_no order by r.seq desc limit 1) q on true
    where l.remain > 0
    group by coalesce(nullif(l.part_no,''), l.name)
  ) t
$$;

-- ---------- ค้นหาพัสดุ (P/N · ชื่อ · S/N) ----------
create or replace function rpc_search_parts(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := btrim(coalesce(p->>'q','')); lim int := greatest(1, least(30, coalesce(nullif(p->>'limit','')::int, 8))); toks text[]; res jsonb; tot int;
begin
  toks := coalesce(array(select t from regexp_split_to_table(q, '\s+') t where t <> '' limit 6), '{}');
  if coalesce(array_length(toks,1),0) = 0 then return jsonb_build_object('q', q, 'total', 0, 'results', '[]'::jsonb); end if;
  with src as (
    select part_no, name, unit from requisitions union all select part_no, name, unit from receipts union all select part_no, name, unit from issues),
  ent as (
    select case when part_no <> '' then coalesce(nullif(fn_srch_n(part_no),''), part_no) else 'N:' || lower(name) end as k,
           max(part_no) as part, (array_agg(name) filter (where name <> ''))[1] as name, (array_agg(unit) filter (where unit <> ''))[1] as unit
    from src where part_no <> '' or name <> '' group by 1),
  lk as (select coalesce(nullif(fn_srch_n(part_no),''), nullif(part_no,''), 'N:' || lower(name)) as k, * from v_lots),
  lots as (
    select k, max(received_date) as last_recv, sum(remain) filter (where remain > 0) as qty,
           coalesce(jsonb_agg(jsonb_build_object('serial', serial_no, 'qty', remain, 'loc', location, 'cond', cond, 'kit', fn_kit_of(tail_no)) order by seq) filter (where remain > 0), '[]'::jsonb) as lots,
           array_agg(upper(serial_no)) filter (where serial_no <> '') as sns
    from lk group by k),
  ik as (select coalesce(nullif(fn_srch_n(part_no),''), nullif(part_no,''), 'N:' || lower(name)) as k, * from issues where part_no <> '' or name <> ''),
  iss as (
    select k, (array_agg(issue_date order by issue_date desc, seq desc))[1] as last_issue, (array_agg(technician order by issue_date desc, seq desc))[1] as last_to,
           array_agg(upper(serial_no)) filter (where serial_no <> '') as sns from ik group by k),
  outs as (
    select k, jsonb_agg(jsonb_build_object('serial', serial_no, 'date', fn_thai(issue_date), 'tech', technician, 'doc', doc_no) order by issue_date desc nulls last) as outs
    from (select distinct on (k, upper(serial_no)) * from ik where serial_no <> '' order by k, upper(serial_no), issue_date desc, seq desc) z
    where not exists (select 1 from lk where lk.k = z.k and upper(lk.serial_no) = upper(z.serial_no) and lk.remain > 0)
    group by k),
  pend as (
    select coalesce(nullif(fn_srch_n(x->>'part'),''), nullif(x->>'part',''), 'N:' || lower(x->>'name')) as k,
           jsonb_agg(jsonb_build_object('doc', x->>'docNo', 'remain', (x->>'remain')::numeric, 'tai', '')) as pend
    from jsonb_array_elements(rpc_get_pending_receive()) x group by 1),
  m as (
    select e.*, coalesce(l.qty, 0) as qty, coalesce(l.lots, '[]'::jsonb) as lots, l.last_recv, i.last_issue, i.last_to,
           coalesce(o.outs, '[]'::jsonb) as outs, coalesce(pd.pend, '[]'::jsonb) as pend,
           (select array_agg(distinct s) from unnest(coalesce(l.sns,'{}') || coalesce(i.sns,'{}')) s) as sns
    from ent e left join lots l on l.k = e.k left join iss i on i.k = e.k left join outs o on o.k = e.k left join pend pd on pd.k = e.k),
  hit as (
    select m.*, (coalesce(qty,0) > 0) as instock,
      (select bool_and(position(lower(t) in lower(coalesce(part,'') || ' ' || coalesce(name,'') || ' ' || coalesce(array_to_string(sns,' '),''))) > 0
                  or (length(fn_srch_n(t)) >= 2 and position(fn_srch_n(t) in (fn_srch_n(part) || ' ' || fn_srch_n(name) || ' ' || coalesce((select string_agg(fn_srch_n(s),' ') from unnest(sns) s),''))) > 0))
         from unnest(toks) t) as ok,
      (select bool_or(length(fn_srch_n(t)) >= 2 and exists (select 1 from unnest(sns) s where position(fn_srch_n(t) in fn_srch_n(s)) > 0) and position(fn_srch_n(t) in fn_srch_n(part)) = 0) from unnest(toks) t) as snhit
    from m),
  ranked as (
    select *, (case when array_length(toks,1) = 1 and fn_srch_n(part) = fn_srch_n(toks[1]) then 0 else 1 end) * 2 + (case when instock then 0 else 1 end) as rk
    from hit where ok),
  built as (
    select jsonb_build_object('part', coalesce(part,''), 'name', coalesce(name,''), 'unit', coalesce(unit,''), 'status', case when instock then 'stock' else 'nostock' end, 'qty', coalesce(qty,0),
      'lots', lots, 'lastRecv', fn_thai(last_recv), 'lastIssue', fn_thai(last_issue), 'lastIssueTo', coalesce(last_to,''),
      'serialsOut', (select coalesce(jsonb_agg(v), '[]'::jsonb) from (select v from jsonb_array_elements(outs) v limit 5) w),
      'pending', (select coalesce(jsonb_agg(v), '[]'::jsonb) from (select v from jsonb_array_elements(pend) v limit 5) w), 'snHit', coalesce(snhit,false)) as x,
      rk, coalesce(part,'') as pp
    from ranked)
  select count(*), (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from built order by rk, pp limit lim) z) into tot, res from built;
  return jsonb_build_object('q', q, 'total', tot, 'results', res);
end $$;

-- ---------- Serial ----------
create or replace function rpc_check_serial(sn text, except_seq bigint default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k text := upper(btrim(coalesce(sn,''))); l record;
begin
  if k = '' or length(k) < 3 then return jsonb_build_object('state', ''); end if;
  select * into l from v_lots where seq <> coalesce(except_seq,0) and upper(serial_no) = k and remain > 0 order by seq limit 1;
  if found then return jsonb_build_object('state', 'stock', 'label', l.label, 'part', l.part_no, 'loc', l.location); end if;
  select * into l from v_lots where seq <> coalesce(except_seq,0) and upper(serial_no) = k order by seq desc limit 1;
  if found then return jsonb_build_object('state', 'seen', 'label', l.label, 'part', l.part_no); end if;
  return jsonb_build_object('state', 'ok');
end $$;

create or replace function rpc_get_issued_serials(p_part text) returns jsonb language sql stable security definer set search_path = public as $$
  select case when btrim(coalesce(p_part,'')) = '' then '[]'::jsonb else coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('serial', serial_no, 'machine', tail_no, 'tech', technician, 'docNo', doc_no, 'date', fn_thai(issue_date), 'qty', qty) x
    from issues where upper(part_no) = upper(btrim(p_part)) and serial_no <> '' order by seq desc limit 8) t), '[]'::jsonb) end
$$;

create or replace function rpc_get_opening_lots(p_part text, p_name text default '') returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('row', seq, 'source', source, 'serial', serial_no, 'qty', remain, 'cond', cond, 'location', location,
           'expireIso', coalesce(expire_date::text, '')) order by seq), '[]'::jsonb)
  from v_lots where is_free and remain > 0 and case when btrim(coalesce(p_part,'')) <> '' then part_no = btrim(p_part) else name = btrim(coalesce(p_name,'')) end
$$;

-- ---------- ยอดยกมา / รับก่อนเบิก ----------
create or replace function rpc_add_opening_stock(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_qty numeric := coalesce(fn_num(p->>'qty'),0); typ text := btrim(coalesce(p->>'itemType','')); sn text := btrim(coalesce(p->>'serial','')); src text;
        kit text := fn_kit_of(p->>'kit'); issue_now boolean; new_seq bigint; dup text; grp text;
begin
  perform fn_lock();
  if btrim(coalesce(p->>'part','')) = '' and btrim(coalesce(p->>'name','')) = '' then raise exception 'กรุณากรอก Part number หรือชื่อพัสดุ'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'กรุณากรอกชื่อพัสดุ'; end if;
  if v_qty <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  if typ not in ('', 'LRU','SP','LRU(TCI)','SP(TCI)','สารเคมี') then raise exception 'ประเภทพัสดุไม่ถูกต้อง'; end if;
  grp := fn_resolve_grp(p->>'group', p->>'part', case when typ = 'สารเคมี' then 'สารเคมี' else '' end);
  if typ = 'สารเคมี' or typ = '' then typ := case when sn <> '' then 'LRU' else 'SP' end; end if;
  if sn <> '' and v_qty <> 1 then raise exception 'พัสดุที่มี Serial number ต้องจำนวน 1 ต่อ 1 Serial'; end if;
  src := case when btrim(coalesce(p->>'source','')) = 'รับก่อนเบิก' then 'รับก่อนเบิก' else 'ยอดยกมา' end;
  if sn <> '' then
    select label into dup from v_lots where remain > 0 and upper(serial_no) = upper(sn) limit 1;
    if found then raise exception 'Serial % มีอยู่ในคลังแล้ว (%)', sn, dup; end if;
  end if;
  issue_now := src = 'รับก่อนเบิก' and coalesce((p->>'issueNow')::boolean, false);
  if kit <> '' and issue_now then raise exception 'เลือกอย่างใดอย่างหนึ่ง: เข้าชุด FLY AWAY KIT หรือจ่ายให้ช่างทันที'; end if;
  if issue_now and btrim(coalesce(p->>'tech','')) = '' then raise exception 'กรุณากรอกชื่อช่างที่รับพัสดุ (จ่ายทันที)'; end if;
  insert into receipts(doc_no, card_id, part_no, name, serial_no, item_type, item_group, qty, unit, cond, received_date, tail_no, expire_date, location, note, source)
  values ('', btrim(coalesce(p->>'cardId','')), btrim(coalesce(p->>'part','')), btrim(p->>'name'), sn, typ, grp, v_qty, coalesce(nullif(btrim(coalesce(p->>'unit','')),''),'EA'),
          btrim(coalesce(p->>'cond','')), fn_today(), kit, fn_date(p->>'expire'), btrim(coalesce(p->>'location','')), btrim(coalesce(p->>'remark','')), src)
  returning seq into new_seq;
  if issue_now then
    perform fn_issue_direct_core(jsonb_build_object('lotSeq', new_seq, 'qty', v_qty, 'tech', p->>'tech', 'tail', p->>'tail', 'payDate', coalesce(p->>'payDate', fn_today()::text), 'remark', p->>'issueRemark', 'by', p->>'by'));
  end if;
  perform fn_log(p->>'by', src, '', concat_ws(' | ', btrim(coalesce(p->>'part','')), btrim(p->>'name'), 'x' || fn_qtytxt(v_qty), case when sn <> '' then 'S/N ' || sn end, btrim(coalesce(p->>'location','')), nullif(kit,'')));
  return jsonb_build_object('ok', true, 'issued', issue_now, 'kit', kit);
end $$;

create or replace function rpc_get_awaiting_req() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by (x->>'seq')::bigint desc), '[]'::jsonb) from (
    select jsonb_build_object('seq', l.seq, 'part', l.part_no, 'name', l.name, 'serial', l.serial_no, 'type', l.item_type, 'unit', l.unit, 'qty', l.qty,
      'inStock', greatest(l.remain, 0), 'direct', d.direct, 'pending', l.qty - d.xfer, 'loc', l.location, 'received', fn_thai(l.received_date), 'note', l.note) as x
    from v_lots l
    cross join lateral (select coalesce(sum(i.qty) filter (where i.doc_no = 'จ่ายตรง'), 0) as direct,
                               coalesce(sum(i.qty) filter (where i.doc_no <> 'จ่ายตรง' and i.note like 'โอนเข้าใบเบิก%'), 0) as xfer
                        from issues i where i.receipt_seq = l.seq) d
    where l.source = 'รับก่อนเบิก' and l.qty - d.xfer > 0
  ) t
$$;

create or replace function rpc_link_direct_issue(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  lot record; v_doc text := fn_docno(p->>'docNo'); rq requisitions; total_direct numeric; done numeric; need numeric; req_qty numeric; inc numeric := null; d record;
  take numeric; recv_date date; first_date date; linked numeric := 0; new_seq bigint; got numeric; by_ text := btrim(coalesce(p->>'by',''));
begin
  perform fn_lock();
  select * into lot from v_lots where seq = nullif(p->>'lotSeq','')::bigint;
  if not found or not lot.is_free then raise exception 'ไม่พบล็อตรับก่อนเบิกที่เลือก'; end if;
  select * into rq from requisitions where doc_no = v_doc and part_no = lot.part_no order by seq limit 1;
  if not found then raise exception 'ไม่พบใบเบิกเลขที่ % ที่มี Part %', v_doc, lot.part_no; end if;
  if rq.cancelled then raise exception 'ใบเบิกนี้ถูกยกเลิกแล้ว'; end if;
  select coalesce(sum(qty),0) into total_direct from issues where receipt_seq = lot.seq and doc_no = 'จ่ายตรง';
  if total_direct <= 0 then raise exception 'ล็อตนี้ไม่มีรายการจ่ายตรงที่รอผูกใบเบิก'; end if;
  select coalesce(sum(c.qty),0) into done from receipts c where c.source = 'ใบเบิก' and c.doc_no = v_doc and c.part_no = lot.part_no;
  if nullif(btrim(coalesce(p->>'qty','')),'') is null then
    need := least(total_direct, case when greatest(rq.qty - done, 0) > 0 then greatest(rq.qty - done, 0) else total_direct end);
  else need := fn_num(p->>'qty'); end if;
  if need <= 0 then raise exception 'จำนวนที่ผูกต้องมากกว่า 0'; end if;
  if need > total_direct then raise exception 'ผูกได้ไม่เกินที่จ่ายตรงไปแล้ว (%)', fn_qtytxt(total_direct); end if;
  req_qty := rq.qty;
  if done + need > req_qty then req_qty := done + need; update requisitions set qty = req_qty where seq = rq.seq; inc := req_qty; end if;
  first_date := null;
  for d in select * from issues where receipt_seq = lot.seq and doc_no = 'จ่ายตรง' and qty > 0 order by seq loop
    exit when need <= 0;
    take := least(d.qty, need); need := need - take;
    recv_date := coalesce(d.issue_date, fn_today()); first_date := coalesce(first_date, recv_date);
    if d.qty - take <= 0 then delete from issues where seq = d.seq; else update issues set qty = qty - take where seq = d.seq; end if;
    insert into receipts(doc_no, part_no, name, serial_no, item_type, item_group, qty, unit, cond, notified_date, urgency, due_date, received_date, over_days, tail_no, expire_date, location, note, source, ref_seq)
    values (v_doc, lot.part_no, coalesce(nullif(rq.name,''), lot.name), lot.serial_no, coalesce(nullif(rq.item_type,''), lot.item_type), lot.item_group, take, coalesce(nullif(rq.unit,''), lot.unit),
            lot.cond, rq.req_date, rq.urgency, fn_due(rq.req_date, rq.urgency), recv_date, recv_date - fn_due(rq.req_date, rq.urgency), rq.machine, lot.expire_date, lot.location,
            'ผูกใบเบิกย้อนหลังจากรับก่อนเบิก', 'ใบเบิก', lot.seq) returning seq into new_seq;
    insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, tail_no, technician, note, created_by)
    values (recv_date, v_doc, lot.seq, lot.part_no, lot.name, lot.serial_no, take, lot.unit, '', '', 'โอนเข้าใบเบิก ' || v_doc || ' (ผูกย้อนหลัง)', by_);
    insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, tail_no, technician, note, created_by)
    values (recv_date, v_doc, new_seq, lot.part_no, lot.name, lot.serial_no, take, lot.unit, d.tail_no, d.technician, concat_ws(' | ', nullif(d.note,''), 'ผูกใบเบิกย้อนหลัง'), by_);
    perform fn_log(by_, 'ผูกใบเบิกย้อนหลัง', v_doc, concat_ws(' | ', lot.part_no, lot.name, 'x' || fn_qtytxt(take), case when lot.serial_no <> '' then 'S/N ' || lot.serial_no end,
      'ช่าง ' || d.technician, case when d.tail_no <> '' then 'TAIL ' || d.tail_no end));
    linked := linked + take;
  end loop;
  select coalesce(sum(c.qty),0) into got from receipts c where c.source = 'ใบเบิก' and c.doc_no = v_doc and c.part_no = lot.part_no;
  if got >= req_qty then update requisitions set pay_date = coalesce(first_date, fn_today()) where seq = rq.seq; end if;
  return jsonb_build_object('ok', true, 'linked', linked, 'remainReq', greatest(req_qty - got, 0), 'increasedTo', inc);
end $$;

-- ---------- ย้ายที่จัดเก็บ ----------
create or replace function rpc_move_location(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare lot record; loc text := btrim(coalesce(p->>'location','')); v_qty numeric; new_seq bigint := 0;
begin
  perform fn_lock();
  if loc = '' then raise exception 'กรุณาระบุที่จัดเก็บใหม่'; end if;
  select * into lot from v_lots where seq = nullif(p->>'seq','')::bigint and remain > 0;
  if not found then raise exception 'ไม่พบพัสดุในคลัง (อาจถูกจ่ายไปแล้ว) กรุณารีเฟรช'; end if;
  if fn_shelf_key(lot.location) = fn_shelf_key(loc) then return jsonb_build_object('ok', true, 'from', lot.location, 'to', loc, 'same', true); end if;
  v_qty := case when nullif(btrim(coalesce(p->>'qty','')),'') is null then lot.remain else fn_num(p->>'qty') end;
  if not (v_qty > 0) or v_qty > lot.remain then raise exception 'จำนวนที่ย้ายไม่ถูกต้อง (เหลือ %)', fn_qtytxt(lot.remain); end if;
  if lot.serial_no <> '' and v_qty <> lot.remain then raise exception 'พัสดุที่มี S/N ย้ายได้ทั้งชิ้นเท่านั้น'; end if;
  if v_qty = lot.remain then update receipts set location = loc where seq = lot.seq;
  else
    update receipts set qty = qty - v_qty where seq = lot.seq;
    new_seq := fn_clone_receipt(lot.seq, v_qty, loc, lot.tail_no, concat_ws(' | ', nullif(lot.note,''), 'แยกจากลำดับรับ ' || lot.seq));
  end if;
  perform fn_log(p->>'by', 'ย้ายที่จัดเก็บ', lot.doc_no, concat_ws(' | ', lot.part_no, case when lot.serial_no <> '' then 'S/N ' || lot.serial_no end,
    case when v_qty <> lot.remain then 'x' || fn_qtytxt(v_qty) || ' จาก ' || fn_qtytxt(lot.remain) end, coalesce(nullif(lot.location,''),'(ว่าง)') || ' → ' || loc));
  perform fn_move_log(case when new_seq <> 0 then 'แยกบางส่วน' else 'ย้าย' end, case when new_seq <> 0 then new_seq else lot.seq end, lot.part_no, lot.name, lot.serial_no, v_qty, lot.location, loc, lot.label, p->>'by');
  return jsonb_build_object('ok', true, 'from', lot.location, 'to', loc, 'moved', v_qty, 'split', new_seq <> 0, 'newSeq', new_seq);
end $$;

create or replace function rpc_move_cell(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare f text := btrim(coalesce(p->>'from','')); t text := btrim(coalesce(p->>'to','')); l record; n int := 0;
begin
  perform fn_lock();
  if f = '' then raise exception 'ไม่ระบุช่องต้นทาง'; end if;
  if t = '' then raise exception 'กรุณาระบุช่องปลายทาง'; end if;
  if fn_shelf_key(f) = fn_shelf_key(t) then raise exception 'ช่องต้นทางและปลายทางเป็นช่องเดียวกัน'; end if;
  for l in select * from v_lots where remain > 0 and fn_shelf_key(location) = fn_shelf_key(f) order by seq loop
    update receipts set location = t where seq = l.seq; n := n + 1;
    perform fn_move_log('ย้ายทั้งช่อง', l.seq, l.part_no, l.name, l.serial_no, l.remain, l.location, t, l.label, p->>'by');
  end loop;
  if n = 0 then raise exception 'ช่อง % ไม่มีพัสดุแล้ว (อาจมีคนย้ายไปก่อน) กรุณารีเฟรช', f; end if;
  perform fn_log(p->>'by', 'ย้ายที่จัดเก็บทั้งช่อง', '', f || ' → ' || t || ' | ' || n || ' รายการ');
  return jsonb_build_object('ok', true, 'moved', n, 'from', f, 'to', t);
end $$;

create or replace function rpc_get_move_history(p jsonb default '{}'::jsonb) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('t', fn_thai((moved_at at time zone 'Asia/Bangkok')::date) || ' ' || to_char(moved_at at time zone 'Asia/Bangkok', 'HH24:MI'),
      'by', created_by, 'kind', kind, 'seq', coalesce(receipt_seq,0), 'part', part_no, 'name', name, 'serial', serial_no, 'qty', qty, 'from', from_loc, 'to', to_loc, 'doc', doc_no) as x
    from move_history m
    where (coalesce(p->>'loc','') = '' or fn_shelf_key(from_loc) = fn_shelf_key(p->>'loc') or fn_shelf_key(to_loc) = fn_shelf_key(p->>'loc'))
      and (coalesce(p->>'part','') = '' or upper(part_no) = upper(btrim(p->>'part')))
      and (coalesce(p->>'serial','') = '' or upper(serial_no) = upper(btrim(p->>'serial')))
      and (coalesce(nullif(p->>'seq','')::bigint,0) = 0 or coalesce(p->>'part','') <> '' or receipt_seq = nullif(p->>'seq','')::bigint)
    order by id desc limit least(coalesce(nullif(p->>'limit','')::int, 80), 300)
  ) t
$$;

-- ย้ายเข้า/ออก FLY AWAY KIT
create or replace function rpc_move_to_kit(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare lot record; kit text := ''; cur text; v_qty numeric;
begin
  perform fn_lock();
  if btrim(coalesce(p->>'kit','')) <> '' then
    kit := fn_kit_of(p->>'kit'); if kit = '' then raise exception 'ชุดต้องเป็น FLY AWAY KIT 1 หรือ 2'; end if; end if;
  select * into lot from v_lots where seq = nullif(p->>'seq','')::bigint and remain > 0;
  if not found then raise exception 'ไม่พบพัสดุในคลัง (อาจถูกจ่ายไปแล้ว) กรุณารีเฟรช'; end if;
  cur := fn_kit_of(lot.tail_no);
  if cur = kit then return jsonb_build_object('ok', true, 'same', true); end if;
  v_qty := case when nullif(btrim(coalesce(p->>'qty','')),'') is null then lot.remain else fn_num(p->>'qty') end;
  if not (v_qty > 0) or v_qty > lot.remain then raise exception 'จำนวนที่ย้ายไม่ถูกต้อง (เหลือ %)', fn_qtytxt(lot.remain); end if;
  if lot.serial_no <> '' and v_qty <> 1 then raise exception 'พัสดุที่มี S/N ย้ายได้ทีละ 1 ชิ้น'; end if;
  if v_qty = lot.remain then update receipts set tail_no = kit where seq = lot.seq;
  else
    update receipts set qty = qty - v_qty where seq = lot.seq;
    perform fn_clone_receipt(lot.seq, v_qty, lot.location, kit, lot.note);
  end if;
  perform fn_log(p->>'by', case when kit <> '' then 'ย้ายเข้าชุด' else 'ย้ายออกจากชุด' end, lot.doc_no, concat_ws(' | ', lot.part_no, lot.name, 'x' || fn_qtytxt(v_qty),
    case when lot.serial_no <> '' then 'S/N ' || lot.serial_no end, coalesce(nullif(cur,''),'คลังปกติ') || ' → ' || coalesce(nullif(kit,''),'คลังปกติ')));
  return jsonb_build_object('ok', true, 'kit', kit, 'moved', v_qty);
end $$;

-- ---------- แก้ไขล็อตในคลัง ----------
create or replace function rpc_edit_lot(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  lot record; r receipts; seq_ bigint := nullif(p->>'seq','')::bigint; old_sn text; old_loc text; old_part text; old_name text;
  new_loc text; new_sn text; new_part text; new_name text; new_remain numeric; changes text[] := '{}'; ng text; ogp text; n int; seqs bigint[];
  sn_ch boolean; loc_ch boolean; qty_ch boolean; part_ch boolean; name_ch boolean; hits int;
begin
  perform fn_lock();
  select * into lot from v_lots where seq = seq_ and remain > 0;
  if not found then raise exception 'ไม่พบพัสดุในคลัง (อาจถูกจ่ายไปแล้ว) กรุณารีเฟรช'; end if;
  select * into r from receipts where seq = seq_;
  old_sn := r.serial_no; old_loc := r.location; old_part := r.part_no; old_name := r.name;
  new_loc  := case when p ? 'location' then btrim(coalesce(p->>'location','')) else old_loc end;
  new_sn   := case when p ? 'serial'   then btrim(coalesce(p->>'serial','')) else old_sn end;
  new_part := case when p ? 'part'     then btrim(coalesce(p->>'part','')) else old_part end;
  new_name := case when p ? 'name'     then btrim(coalesce(p->>'name','')) else old_name end;
  new_remain := case when nullif(btrim(coalesce(p->>'qty','')),'') is null then lot.remain else fn_num(p->>'qty') end;
  if new_part = '' then raise exception 'Part number ว่างไม่ได้'; end if;
  if new_name = '' then raise exception 'ชื่อพัสดุว่างไม่ได้'; end if;
  if not (new_remain > 0) then raise exception 'จำนวนต้องมากกว่า 0 (ถ้าไม่มีของแล้วให้ใช้ จ่าย)'; end if;
  if new_sn <> '' and new_remain <> 1 then raise exception 'พัสดุที่มี S/N ต้องมีจำนวน 1'; end if;
  if new_sn = '' and old_sn <> '' then raise exception 'ลบ S/N ที่มีอยู่แล้วไม่ได้'; end if;
  sn_ch := new_sn <> old_sn; loc_ch := new_loc <> old_loc; qty_ch := new_remain <> lot.remain; part_ch := new_part <> old_part; name_ch := new_name <> old_name;
  if sn_ch and new_sn <> '' and exists (select 1 from receipts x where x.seq <> seq_ and upper(x.serial_no) = upper(new_sn)) then raise exception 'S/N % ซ้ำกับรายการอื่น', new_sn; end if;

  if btrim(coalesce(p->>'group','')) <> '' then
    ng := case when btrim(p->>'group') = '-' then '' else btrim(p->>'group') end;
    if ng <> '' and ng <> 'สารเคมี' then raise exception 'กลุ่มพัสดุไม่ถูกต้อง'; end if;
    ogp := r.item_group;
    if ng <> ogp or coalesce((p->>'groupAll')::boolean, false) then
      update receipts set item_group = ng where seq = seq_ or (coalesce((p->>'groupAll')::boolean, false) and part_no = old_part);
      get diagnostics n = row_count;
      changes := changes || ('กลุ่ม ' || coalesce(nullif(ogp,''),'ทั่วไป') || ' → ' || coalesce(nullif(ng,''),'ทั่วไป') || case when coalesce((p->>'groupAll')::boolean, false) then ' (ทุกล็อตของ P/N นี้ ' || n || ' แถว)' else '' end);
    end if;
  end if;
  if name_ch then   -- ชื่อ : เปลี่ยนทั้งชุดล็อตที่เกี่ยวข้อง (รับ / จ่าย / ยืม)
    seqs := array[seq_];
    if coalesce((p->>'nameAll')::boolean, false) then seqs := seqs || coalesce(array(select seq from receipts where part_no = old_part and seq <> seq_), '{}'); end if;
    update receipts set name = new_name where seq = any (seqs);
    update issues set name = new_name where receipt_seq = any (seqs);
    update loans set name = new_name where lot_seq = any (seqs);
    changes := changes || ('ชื่อ ' || old_name || ' → ' || new_name || case when coalesce((p->>'nameAll')::boolean, false) then ' (ทุกล็อตของ P/N นี้)' else '' end);
  end if;
  if sn_ch or part_ch then
    update receipts set part_no = new_part, serial_no = new_sn where seq = seq_;
    update issues set part_no = new_part, serial_no = new_sn where receipt_seq = seq_;
    update loans set part_no = new_part, serial_no = new_sn where lot_seq = seq_;
    if part_ch and r.doc_no <> '' and r.source = 'ใบเบิก' then
      select count(*) into hits from requisitions where doc_no = r.doc_no;
      if hits = 1 then update requisitions set part_no = new_part where doc_no = r.doc_no;
      else update requisitions set part_no = new_part where doc_no = r.doc_no and part_no = old_part; end if;
    end if;
    if sn_ch and old_sn <> '' then
      update claims set serial_no = new_sn, part_no = case when part_ch then new_part else part_no end where upper(serial_no) = upper(old_sn);
      update claims set new_serial = new_sn where upper(new_serial) = upper(old_sn);
    end if;
    if part_ch then changes := changes || ('P/N ' || old_part || ' → ' || new_part); end if;
    if sn_ch then changes := changes || ('S/N ' || coalesce(nullif(old_sn,''),'(ว่าง)') || ' → ' || new_sn); end if;
  end if;
  if loc_ch then
    update receipts set location = new_loc where seq = seq_;
    changes := changes || ('ที่เก็บ ' || coalesce(nullif(old_loc,''),'(ว่าง)') || ' → ' || coalesce(nullif(new_loc,''),'(ว่าง)'));
    perform fn_move_log('แก้ไขที่เก็บ', lot.seq, case when part_ch then new_part else old_part end, case when name_ch then new_name else old_name end,
                        case when sn_ch then new_sn else old_sn end, lot.remain, old_loc, new_loc, lot.label, p->>'by');
  end if;
  if qty_ch then
    update receipts set qty = new_remain + lot.issued + lot.loan_out where seq = seq_;
    changes := changes || ('จำนวน ' || fn_qtytxt(lot.remain) || ' → ' || fn_qtytxt(new_remain));
  end if;
  if coalesce(array_length(changes,1),0) = 0 then return jsonb_build_object('ok', true, 'same', true, 'changes', '[]'::jsonb); end if;
  perform fn_log(p->>'by', 'แก้ไขล็อตในคลัง', lot.doc_no, concat_ws(' | ', case when part_ch then new_part else old_part end, array_to_string(changes, ' | ')));
  return jsonb_build_object('ok', true, 'changes', to_jsonb(changes));
end $$;

-- ---------- ประวัติ Serial ----------
create or replace function fn_sn_chain(k text) returns text[] language sql stable as $$
  with recursive ch(sn) as (
    select upper(btrim(k))
    union
    select case when upper(c.serial_no) = ch.sn then upper(c.new_serial) else upper(c.serial_no) end
    from claims c join ch on (upper(c.serial_no) = ch.sn or upper(c.new_serial) = ch.sn) where c.new_serial <> ''
  ) select array_agg(distinct sn) from ch
$$;

create or replace function rpc_get_serial_history(p_serial text) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  key text := upper(btrim(coalesce(p_serial,''))); chain text[]; e record; part text := ''; name text := ''; typ text := '';
  stints jsonb := '[]'::jsonb; opn jsonb := '{}'::jsonb; cur jsonb; state text := ''; lastev record; first_d date; on_air int := 0; today date := fn_today(); lotrow record; open_claim bigint := 0;
  tmp jsonb; evj jsonb;
begin
  if key = '' then raise exception 'กรุณากรอก Serial'; end if;
  chain := fn_sn_chain(key);
  create temp table if not exists _ev(k text, sn text, t text, d date, o int, txt text, machine text, tech text, issue text, docref text, loc text, claim_id text) on commit drop;
  truncate _ev;
  insert into _ev select upper(serial_no), serial_no, 'rcv', received_date, 1,
      case source when 'ใบเบิก' then 'รับตามใบเบิก ' || doc_no when 'ยอดยกมา' then 'ยอดยกมา (ไม่มีวันที่รับ)' when 'รับก่อนเบิก' then 'รับก่อนเบิก' else source end, '', '', '', '', location, null
    from receipts where upper(serial_no) = any (chain);
  insert into _ev select upper(serial_no), serial_no, case when technician <> '' then 'install' else 'out' end, issue_date, 2,
      case when technician <> '' then 'จ่ายให้ช่าง/ติดตั้ง' else 'จ่ายออก' end, tail_no, technician, '', doc_no, '', null
    from issues where upper(serial_no) = any (chain) and qty > 0;
  insert into _ev select upper(serial_out), serial_out, 'remove', (recorded_at at time zone 'Asia/Bangkok')::date, 3, 'ส่งคืน/ถอดออก', machine, '', issue_text, letter_no, '', null
    from returns_out where upper(serial_out) = any (chain);
  insert into _ev select upper(serial_no), serial_no, 'claim', sent_date, 4, 'ส่งเคลม #' || claim_no || case when vendor <> '' then ' → ' || vendor else '' end, '', '', '', letter_no, '', claim_no
    from claims where upper(serial_no) = any (chain) or upper(new_serial) = any (chain);
  insert into _ev select upper(serial_no), serial_no, 'claimback', coalesce(returned_date, sent_date), 5,
      status || case when status = 'ได้ของใหม่' and new_serial <> '' then ' (S/N ใหม่ ' || new_serial || ')' else '' end ||
        case when status in ('ได้ซ่อมกลับ','ได้ของใหม่') then ' · ประกันนับใหม่' else '' end, '', '', '', '', '', claim_no
    from claims where (upper(serial_no) = any (chain) or upper(new_serial) = any (chain)) and status <> '' and status <> 'ส่งเคลมแล้ว';
  if not exists (select 1 from _ev) then raise exception 'ไม่พบ Serial % ในระบบ', p_serial; end if;
  select r.part_no, r.name, r.item_type into part, name, typ from receipts r where upper(r.serial_no) = any (chain) order by r.seq desc limit 1;
  typ := coalesce(typ,'');
  for e in select * from _ev order by coalesce(d, date '0001-01-01'), o loop
    if e.t = 'install' then
      if opn ? e.k then stints := stints || jsonb_build_array(opn->e.k); end if;
      opn := opn || jsonb_build_object(e.k, jsonb_build_object('sn', e.sn, 'machine', e.machine, 'from', e.d, 'to', null));
    elsif e.t = 'remove' and opn ? e.k then
      stints := stints || jsonb_build_array((opn->e.k) || jsonb_build_object('to', e.d)); opn := opn - e.k;
    end if;
  end loop;
  for tmp in select value from jsonb_each(opn) loop stints := stints || jsonb_build_array(tmp); end loop;
  select coalesce(jsonb_agg(jsonb_build_object('sn', s->>'sn', 'machine', s->>'machine', 'from', fn_thai((s->>'from')::date),
          'to', case when s->>'to' is not null then fn_thai((s->>'to')::date) else '' end,
          'days', case when s->>'from' is not null then coalesce((s->>'to')::date, today) - (s->>'from')::date end, 'ongoing', s->>'to' is null)), '[]'::jsonb) into stints from jsonb_array_elements(stints) s;
  select coalesce(sum((s->>'days')::int),0) into on_air from jsonb_array_elements(stints) s;
  select * into lastev from _ev where k = key order by coalesce(d, date '0001-01-01') desc, o desc limit 1;
  if found then
    state := case lastev.t when 'install' then 'ติดตั้งอยู่ที่ ' || coalesce(nullif(lastev.machine,''),'-') when 'remove' then 'ส่งคืน/ถอดออกแล้ว' when 'claim' then 'ส่งเคลมอยู่'
                  when 'claimback' then 'ได้รับกลับจากเคลม' else 'อยู่ในคลัง' end;
  end if;
  select * into lotrow from v_lots where upper(serial_no) = key and remain > 0 limit 1;
  if found and (lastev.t is null or lastev.t = 'rcv') then state := 'อยู่ในคลัง' || case when lotrow.location <> '' then ' (' || lotrow.location || ')' else '' end; end if;
  select min(d) into first_d from _ev where k = key and d is not null;
  select coalesce(max(nullif(regexp_replace(claim_no,'\D','','g'),'')::bigint),0) into open_claim from claims where upper(serial_no) = key and status = 'ส่งเคลมแล้ว';
  select coalesce(jsonb_agg(jsonb_build_object('t', t, 'date', fn_thai(d), 'sn', sn, 'main', k = key, 'text', txt, 'machine', machine, 'tech', tech,
                'issue', issue, 'docRef', docref, 'loc', loc, 'claimId', claim_id) order by coalesce(d, date '0001-01-01'), o), '[]'::jsonb) into evj from _ev;
  return jsonb_build_object('serial', btrim(p_serial), 'part', part, 'name', name, 'type', typ, 'state', state, 'warranty', fn_warr_json(key), 'isLRU', typ like 'LRU%',
    'ageDays', case when first_d is not null then today - first_d end, 'installs', jsonb_array_length(stints), 'onAirDays', on_air,
    'avgStint', case when jsonb_array_length(stints) > 0 then round(on_air::numeric / jsonb_array_length(stints)) end, 'openClaim', open_claim,
    'events', evj, 'stints', stints);
end $$;

-- ---------- เคลม ----------
create or replace function rpc_get_claims() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by (x->>'open') desc, (x->>'id')::int desc), '[]'::jsonb) from (
    select jsonb_build_object('id', nullif(regexp_replace(claim_no,'\D','','g'),'')::int, 'sn', serial_no, 'part', part_no, 'name', name, 'type', item_type, 'sent', fn_thai(sent_date),
      'docRef', letter_no, 'vendor', vendor, 'status', status, 'back', fn_thai(returned_date), 'newSn', new_serial, 'note', note,
      'days', case when sent_date is not null then coalesce(returned_date, fn_today()) - sent_date end, 'open', status = 'ส่งเคลมแล้ว') x
    from claims
  ) t
$$;

create or replace function rpc_submit_claim(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare sn text := btrim(coalesce(p->>'serial','')); h jsonb; id int;
begin
  perform fn_lock();
  if sn = '' then raise exception 'กรุณากรอก Serial'; end if;
  h := rpc_get_serial_history(sn);
  if not (h->>'isLRU')::boolean then raise exception 'ประกัน/เคลมใช้กับ LRU และ LRU(TCI) เท่านั้น'; end if;
  if exists (select 1 from claims where upper(serial_no) = upper(sn) and status = 'ส่งเคลมแล้ว') then raise exception 'Serial นี้มีรายการส่งเคลมค้างอยู่แล้ว'; end if;
  select coalesce(max(nullif(regexp_replace(claim_no,'\D','','g'),'')::int),0) + 1 into id from claims;
  insert into claims(claim_no, serial_no, part_no, name, item_type, sent_date, letter_no, vendor, status, note, created_by)
  values (id::text, sn, h->>'part', h->>'name', h->>'type', coalesce(fn_date(p->>'sentDate'), fn_today()), btrim(coalesce(p->>'docRef','')), btrim(coalesce(p->>'vendor','')),
          'ส่งเคลมแล้ว', btrim(coalesce(p->>'note','')), btrim(coalesce(p->>'by','')));
  perform fn_log(p->>'by', 'ส่งเคลม', '', concat_ws(' | ', sn, h->>'part', h->>'name', nullif(btrim(coalesce(p->>'docRef','')),''), nullif(btrim(coalesce(p->>'vendor','')),'')));
  return jsonb_build_object('ok', true, 'id', id, 'warranty', h->'warranty');
end $$;

create or replace function rpc_update_claim(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare c claims; st text := btrim(coalesce(p->>'status','')); back date; nsn text := ''; cid text := btrim(coalesce(p->>'id',''));
begin
  perform fn_lock();
  select * into c from claims where claim_no = cid;
  if not found then raise exception 'ไม่พบรายการเคลม'; end if;
  if st not in ('ส่งเคลมแล้ว','ได้ซ่อมกลับ','ได้ของใหม่','ถูกปฏิเสธ') then raise exception 'สถานะไม่ถูกต้อง'; end if;
  if st in ('ได้ซ่อมกลับ','ได้ของใหม่') then
    if btrim(coalesce(p->>'backDate','')) = '' then raise exception 'กรุณาระบุวันที่ได้รับกลับ'; end if;
    back := fn_date(p->>'backDate');
    if c.sent_date is not null and back < c.sent_date then raise exception 'วันที่ได้รับกลับต้องไม่ก่อนวันที่ส่งเคลม'; end if;
  end if;
  if st = 'ได้ของใหม่' then
    nsn := btrim(coalesce(p->>'newSerial',''));
    if nsn = '' then raise exception 'กรุณาระบุ Serial ใหม่'; end if;
    if upper(nsn) = upper(c.serial_no) then raise exception 'Serial ใหม่ต้องไม่ซ้ำกับ Serial เดิม'; end if;
  end if;
  if st = 'ถูกปฏิเสธ' and btrim(coalesce(p->>'note','')) = '' and c.note = '' then raise exception 'กรุณาระบุเหตุผลที่ถูกปฏิเสธ (หมายเหตุ)'; end if;
  update claims set status = st, returned_date = back, new_serial = nsn, note = coalesce(nullif(btrim(coalesce(p->>'note','')),''), note) where claim_no = cid;
  perform fn_log(p->>'by', 'อัปเดตเคลม', '', concat_ws(' | ', '#' || cid, c.serial_no, st, case when nsn <> '' then 'S/N ใหม่ ' || nsn end));
  return jsonb_build_object('ok', true, 'status', st);
end $$;

create or replace function rpc_get_warranty_list(days int default 60) returns jsonb language sql stable security definer set search_path = public as $$
  with w as (select * from v_warranty where days_left >= 0 and days_left <= coalesce(nullif(days,0), 60)),
  info as (select distinct on (upper(serial_no)) upper(serial_no) k, serial_no, part_no, name, item_type from receipts where serial_no <> '' order by upper(serial_no), seq desc),
  inst as (select distinct on (upper(serial_no)) upper(serial_no) k, issue_date d, tail_no from issues where serial_no <> '' and technician <> '' and issue_date is not null order by upper(serial_no), issue_date desc, seq desc),
  rem as (select upper(serial_out) k, max((recorded_at at time zone 'Asia/Bangkok')::date) d from returns_out where serial_out <> '' group by 1),
  stk as (select distinct on (upper(serial_no)) upper(serial_no) k, location from v_lots where remain > 0 and serial_no <> '' order by upper(serial_no), seq),
  openc as (select upper(serial_no) k from claims where status = 'ส่งเคลมแล้ว')
  select coalesce(jsonb_agg(x order by (x->>'left')::int), '[]'::jsonb) from (
    select jsonb_build_object('serial', i.serial_no, 'part', i.part_no, 'name', i.name, 'type', i.item_type, 'start', fn_thai(w.start_date), 'end', fn_thai(w.end_date), 'left', w.days_left,
      'where', case when s.k is not null then 'อยู่ในคลัง' || case when s.location <> '' then ' (' || s.location || ')' else '' end
                    when n.k is not null and (r.d is null or r.d < n.d) then 'ติดตั้งอยู่ที่ ' || coalesce(nullif(n.tail_no,''),'-') end) x
    from w join info i on i.k = w.sn_key left join stk s on s.k = w.sn_key left join inst n on n.k = w.sn_key left join rem r on r.k = w.sn_key
    where not exists (select 1 from openc o where o.k = w.sn_key) and (s.k is not null or (n.k is not null and (r.d is null or r.d < n.d)))
  ) t
$$;

revoke all on function fn_resolve_grp(text,text,text), fn_move_log(text,bigint,text,text,text,numeric,text,text,text,text), fn_clone_receipt(bigint,numeric,text,text,text), fn_warr_json(text), fn_sn_chain(text) from public, anon;
grant execute on function rpc_get_stock(), rpc_search_parts(jsonb), rpc_check_serial(text,bigint), rpc_get_issued_serials(text), rpc_get_opening_lots(text,text), rpc_add_opening_stock(jsonb),
  rpc_get_awaiting_req(), rpc_link_direct_issue(jsonb), rpc_move_location(jsonb), rpc_move_cell(jsonb), rpc_get_move_history(jsonb), rpc_move_to_kit(jsonb), rpc_edit_lot(jsonb),
  rpc_get_serial_history(text), rpc_get_claims(), rpc_submit_claim(jsonb), rpc_update_claim(jsonb), rpc_get_warranty_list(int) to anon;
