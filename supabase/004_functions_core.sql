-- =====================================================================
--  004 : ฟังก์ชันงานหลักชุดที่ 1  เบิก / รับ / รับหลายรายการ / จ่าย / จ่ายตรง
--  แปลงจาก Code.gs (submitRequisition, submitReceiveCore_, submitReceiveBatch, issueCore_, issueDirectCore_)
--  * ทุกฟังก์ชัน rpc_* เรียกจากหน้าเว็บผ่าน supabase.rpc() ; ใช้ advisory lock แทน LockService (เขียนทีละคน)
--  * ข้อผิดพลาดใช้ raise exception ข้อความไทยเดิม ; รับ/จ่ายหลายรายการ แต่ละรายการแยกธุรกรรมย่อย (พลาดรายการหนึ่งไม่กระทบรายการอื่น)
-- =====================================================================

create table if not exists idempotency (token text primary key, result jsonb not null, at timestamptz not null default now());
alter table idempotency enable row level security;   -- ไม่มี policy : เข้าถึงผ่านฟังก์ชันเท่านั้น

-- ---------- ตัวช่วย ----------
create or replace function fn_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Bangkok')::date $$;
create or replace function fn_thai(d date) returns text language sql immutable as
$$ select case when d is null then '' else to_char(d,'DD/MM/') || (extract(year from d)::int + 543)::text end $$;
create or replace function fn_due(d date, urg text) returns date language sql immutable as
$$ select d + case when upper(btrim(coalesce(urg,''))) in ('AOG','ด่วน','ด่วนมาก') then 7 else 30 end $$;
create or replace function fn_docno(v text) returns text language sql immutable as
$$ select case when btrim(coalesce(v,'')) ~ '^\d+$' then lpad(btrim(v), 9, '0') else btrim(coalesce(v,'')) end $$;
create or replace function fn_kit_of(tail text) returns text language sql immutable as
$$ select case when regexp_replace(upper(coalesce(tail,'')), '[\s_-]+', '', 'g') ~ '^FLYAWAYKIT[12]$'
   then 'FLY AWAY KIT ' || right(regexp_replace(upper(coalesce(tail,'')), '[\s_-]+', '', 'g'), 1) else '' end $$;
create or replace function fn_date(v text) returns date language sql immutable as
$$ select case when nullif(btrim(coalesce(v,'')),'') is null then null else btrim(v)::date end $$;
create or replace function fn_num(v text) returns numeric language sql immutable as
$$ select case when nullif(btrim(coalesce(v,'')),'') is null then null else btrim(v)::numeric end $$;
create or replace function fn_log(p_by text, p_action text, p_doc text, p_detail text) returns void
language sql as $$
  insert into activity_log(user_name, action, doc_no, detail)
  values (coalesce(nullif(btrim(p_by),''), '(ไม่ระบุ)'), p_action, coalesce(p_doc,''), coalesce(p_detail,''));
$$;
create or replace function fn_lock() returns void language sql as $$ select pg_advisory_xact_lock(7001) $$;
create or replace function fn_qtytxt(n numeric) returns text language sql immutable as $$ select trim_scale(n)::text $$;

-- ---------- ใบเบิก ----------
-- ใบเบิกที่น่าจะซ้ำ (เหมือน findDuplicateReqs_)
create or replace function fn_find_dups(p jsonb) returns jsonb language plpgsql stable as $$
declare
  out jsonb := '[]'::jsonb; seen jsonb := '{}'::jsonb; it jsonb; k text; idx int := 0;
  mach text := btrim(coalesce(p->>'machine','')); d0 date := coalesce(fn_date(p->>'date'), fn_today());
  keys text[] := '{}'; hit record;
begin
  for it in select i from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) i
            where btrim(coalesce(i->>'part','')) <> '' or btrim(coalesce(i->>'name','')) <> '' loop
    k := upper(regexp_replace(coalesce(nullif(btrim(it->>'part'),''), it->>'name'), '\s+', '', 'g'));
    if seen ? k then
      out := out || jsonb_build_object('same', true, 'part', coalesce(it->>'part',''), 'name', coalesce(it->>'name',''),
             'note', 'ซ้ำกับรายการที่ ' || ((seen->>k)::int + 1) || ' ในใบเดียวกัน');
    else seen := seen || jsonb_build_object(k, idx); end if;
    keys := keys || k; idx := idx + 1;
  end loop;
  if array_length(keys,1) is null then return out; end if;
  for hit in
    select r.doc_no, r.part_no, r.name, r.qty, r.req_date, r.urgency, r.machine,
           greatest(r.qty - coalesce((select sum(c.qty) from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no), 0), 0) as remain
    from requisitions r
    where not r.cancelled
      and upper(regexp_replace(coalesce(nullif(r.part_no,''), r.name), '\s+', '', 'g')) = any (keys)
  loop
    continue when not ((hit.remain > 0 and hit.machine = mach) or hit.req_date >= d0 - 30);
    out := out || jsonb_build_object('doc', hit.doc_no, 'part', hit.part_no, 'name', hit.name, 'qty', hit.qty, 'remain', hit.remain,
      'date', fn_thai(hit.req_date), 'urg', hit.urgency, 'machine', hit.machine,
      'status', case when hit.remain <= 0 then 'รับครบแล้ว' when hit.remain < hit.qty then 'รับบางส่วน' else 'ค้างรับ' end,
      '_t', hit.req_date);
  end loop;
  -- เรียงรายการจากฐานข้อมูล ใหม่ -> เก่า สูงสุด 8 รายการ ต่อท้ายรายการซ้ำในใบเดียวกัน
  return (select coalesce(jsonb_agg(e - '_t'), '[]'::jsonb) from (
            select e from jsonb_array_elements(out) e where not (e ? '_t')
            union all
            (select e from jsonb_array_elements(out) e where e ? '_t' order by e->>'_t' desc limit 8)
          ) x(e));
end $$;

-- ออกใบเบิก (ไม่ล็อกเอง : ผู้เรียกล็อกไว้แล้ว)
create or replace function fn_requisition_core(p jsonb) returns jsonb language plpgsql as $$
declare
  items jsonb; it jsonb; n int; idx int := 0;
  d date := coalesce(fn_date(p->>'date'), fn_today());
  dd text := to_char(d,'DD'); mm text := to_char(d,'MM'); yy text := lpad(((extract(year from d)::int + 543) % 100)::text, 2, '0');
  seq0 int; urg text; typ text; docs jsonb := '[]'::jsonb; docno text; req_install boolean := coalesce((p->>'requireInstall')::boolean, false);
begin
  items := coalesce((select jsonb_agg(i) from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) i
                     where btrim(coalesce(i->>'part','')) <> '' or btrim(coalesce(i->>'name','')) <> ''), '[]'::jsonb);
  n := jsonb_array_length(items);
  if n = 0 then raise exception 'กรุณากรอกรายการพัสดุ'; end if;
  if n > 50 then raise exception 'เบิกได้ไม่เกิน 50 รายการต่อครั้ง'; end if;
  for it in select * from jsonb_array_elements(items) loop
    idx := idx + 1;
    typ := coalesce(nullif(btrim(it->>'itemType'),''), nullif(btrim(p->>'itemType'),''), '');
    if btrim(coalesce(it->>'name','')) = '' then raise exception 'รายการที่ %: กรุณากรอกชื่อพัสดุ', idx; end if;
    if coalesce(fn_num(it->>'qty'),0) <= 0 then raise exception 'รายการที่ %: จำนวนต้องมากกว่า 0', idx; end if;
    if req_install and typ in ('LRU(TCI)','SP(TCI)') and btrim(coalesce(it->>'install','')) = '' then
      raise exception 'รายการที่ %: งาน TCI ต้องระบุวันที่ติดตั้ง', idx; end if;
    if typ not in ('LRU','SP','LRU(TCI)','SP(TCI)','สารเคมี') then raise exception 'รายการที่ %: กรุณาเลือกประเภทพัสดุ', idx; end if;
  end loop;
  if btrim(coalesce(p->>'machine','')) = '' then raise exception 'กรุณาเลือกหมายเลขเครื่อง'; end if;
  if btrim(coalesce(p->>'fullName','')) = '' then raise exception 'กรุณากรอกชื่อ-สกุลผู้เบิก'; end if;

  select coalesce(max(substr(doc_no,1,3)::int), 0) + 1 into seq0 from requisitions
   where doc_no ~ '^\d{9}$' and substr(doc_no,6,2) = mm and substr(doc_no,8,2) = yy;
  if seq0 + n - 1 > 999 then raise exception 'ลำดับการเบิกเดือนนี้เกิน 999 แล้ว'; end if;
  urg := case when btrim(coalesce(p->>'urgency','')) = 'AOG' then 'AOG' else 'เบิกธรรมดา' end;

  idx := 0;
  for it in select * from jsonb_array_elements(items) loop
    typ := coalesce(nullif(btrim(it->>'itemType'),''), nullif(btrim(p->>'itemType'),''));
    docno := lpad((seq0 + idx)::text, 3, '0') || dd || mm || yy;
    insert into requisitions(doc_no, part_no, name, qty, unit, req_date, machine, urgency, issue_text, req_rank, req_name, req_position, item_type, tci_install_date)
    values (docno, btrim(coalesce(it->>'part','')), btrim(it->>'name'), fn_num(it->>'qty'), coalesce(nullif(btrim(it->>'unit'),''),'EA'), d,
            btrim(p->>'machine'), urg, btrim(coalesce(p->>'issue','')), btrim(coalesce(p->>'rank','')), btrim(p->>'fullName'), btrim(coalesce(p->>'position','')),
            case when typ = 'สารเคมี' then 'SP' else typ end,
            case when typ in ('LRU(TCI)','SP(TCI)') then fn_date(it->>'install') end);
    docs := docs || jsonb_build_object('docNo', docno, 'part', btrim(coalesce(it->>'part','')), 'name', btrim(it->>'name'),
              'qty', fn_num(it->>'qty'), 'unit', coalesce(nullif(btrim(it->>'unit'),''),'EA'), 'itemType', typ);
    perform fn_log(p->>'by', 'เบิก', docno, concat_ws(' | ', btrim(coalesce(it->>'part','')), btrim(it->>'name'),
      'x' || fn_qtytxt(fn_num(it->>'qty')) || ' ' || coalesce(nullif(btrim(it->>'unit'),''),'EA'), 'เครื่อง ' || btrim(p->>'machine'), typ, urg,
      'ผู้เบิก ' || concat_ws(' ', nullif(btrim(coalesce(p->>'rank','')),''), btrim(p->>'fullName'))));
    idx := idx + 1;
  end loop;
  return jsonb_build_object('docNo', docs->0->>'docNo', 'docs', docs, 'count', n);
end $$;

create or replace function rpc_submit_requisition(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare tk text := nullif(btrim(coalesce(p->>'token','')),''); res jsonb; dups jsonb;
begin
  perform fn_lock();
  if tk is not null then select result into res from idempotency where token = tk; if found then return res; end if; end if;
  if coalesce((p->>'confirmDup')::boolean, false) is not true then
    dups := fn_find_dups(p);
    if jsonb_array_length(dups) > 0 then return jsonb_build_object('duplicate', true, 'dups', dups); end if;
  end if;
  res := fn_requisition_core(p || '{"requireInstall": true}'::jsonb);
  if tk is not null then insert into idempotency(token, result) values (tk, res) on conflict do nothing; end if;
  return res;
end $$;

-- ---------- จ่าย ----------
create or replace function fn_issue_core(p jsonb) returns jsonb language plpgsql as $$
declare
  lot record; qty numeric; pay date; tail text; closed boolean := false; loan_open numeric; req record; auto jsonb := null; kit text;
  v_doc text := fn_docno(p->>'docNo');
begin
  select * into lot from v_lots where seq = nullif(coalesce(p->>'seq', p->>'row'),'')::bigint;
  if not found or lot.is_free or (v_doc <> '' and lot.doc_no <> v_doc) then
    raise exception 'ไม่พบรายการรับของใบเบิก % — ต้องรับพัสดุก่อนจึงจะจ่ายได้', v_doc; end if;
  select coalesce(sum(qty_open),0) into loan_open from loans where lot_seq = lot.seq and status = 'ยืมอยู่';
  if lot.remain <= 0 then
    raise exception '%', case when lot.loan_out > 0 then 'พัสดุนี้ถูกยืมออกจากคลังอยู่ ต้องรับคืนก่อนจึงจะจ่ายได้ (แท็บ คลัง > ยืมอยู่)' else 'รายการนี้จ่ายให้ช่างแล้ว' end; end if;
  if loan_open > 0 then raise exception 'พัสดุนี้ถูกยืมออกจากคลังอยู่ ต้องรับคืนก่อนจึงจะจ่ายได้ (แท็บ คลัง > ยืมอยู่)'; end if;
  if btrim(coalesce(p->>'tech','')) = '' then raise exception 'กรุณากรอกชื่อช่างที่รับพัสดุ'; end if;
  qty := case when nullif(btrim(coalesce(p->>'qty','')),'') is null then lot.remain else fn_num(p->>'qty') end;
  if qty <= 0 or qty > lot.remain then raise exception 'จำนวนที่จ่ายไม่ถูกต้อง (เหลือ %)', fn_qtytxt(lot.remain); end if;
  pay := coalesce(fn_date(p->>'payDate'), fn_today());
  tail := coalesce(nullif(btrim(coalesce(p->>'tail','')),''), lot.tail_no);
  insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, tail_no, technician, note, created_by)
  values (pay, lot.doc_no, lot.seq, lot.part_no, lot.name, lot.serial_no, qty, lot.unit, tail, btrim(p->>'tech'),
          concat_ws(' | ', nullif(lot.note,''), nullif(btrim(coalesce(p->>'remark','')),'')), btrim(coalesce(p->>'by','')));
  -- ครบ = รับครบตามใบเบิก และทุกล็อตของใบเบิกนี้จ่ายหมดแล้ว
  select * into req from requisitions where doc_no = lot.doc_no and part_no = lot.part_no and not cancelled order by seq limit 1;
  if found then
    select coalesce(sum(l.qty),0) >= req.qty and bool_and(l.remain <= 0) into closed
      from v_lots l where not l.is_free and l.doc_no = lot.doc_no and l.part_no = lot.part_no;
  end if;
  perform fn_log(p->>'by', 'จ่าย', lot.doc_no, concat_ws(' | ', lot.part_no, lot.name, 'x' || fn_qtytxt(qty),
    case when lot.serial_no <> '' then 'S/N ' || lot.serial_no end, 'ช่าง ' || btrim(p->>'tech'),
    case when tail <> '' then 'TAIL ' || tail end, case when closed then '(จ่ายครบ)' end));
  kit := fn_kit_of(lot.tail_no);
  if kit <> '' then auto := fn_auto_kit_req(lot.part_no, lot.name, lot.unit, lot.item_type, lot.serial_no, kit, qty, p); end if;
  return jsonb_build_object('closed', coalesce(closed,false), 'autoReq', auto);
end $$;

-- จ่ายพัสดุที่อยู่ใน FLY AWAY KIT -> ออกใบเบิกทดแทนอัตโนมัติ (พลาดไม่ทำให้การจ่ายย้อนกลับ)
create or replace function fn_auto_kit_req(part text, nm text, unit text, typ text, sn text, kit text, qty numeric, p jsonb) returns jsonb
language plpgsql as $$
declare r jsonb; to_ text := concat_ws(' ', nullif(btrim(coalesce(p->>'tech','')),''), case when btrim(coalesce(p->>'tail','')) <> '' then 'เครื่อง ' || btrim(p->>'tail') end);
begin
  begin
    r := fn_requisition_core(jsonb_build_object('machine', kit, 'urgency', 'เบิกธรรมดา', 'date', fn_today()::text, 'by', coalesce(p->>'by',''),
      'issue', 'เบิกทดแทน ' || kit || ' (จ่ายออก' || case when to_ <> '' then ' ให้ ' || to_ else '' end || case when coalesce(sn,'') <> '' then ' S/N ' || sn else '' end || ')',
      'rank', '', 'fullName', coalesce(nullif(btrim(coalesce(p->>'by','')),''), 'ระบบ (เบิกทดแทนชุดอัตโนมัติ)'), 'position', '',
      'items', jsonb_build_array(jsonb_build_object('part', part, 'name', nm, 'qty', qty, 'unit', coalesce(nullif(unit,''),'EA'), 'itemType', coalesce(nullif(typ,''),'SP')))));
    perform fn_log(p->>'by', 'เบิกทดแทนชุดอัตโนมัติ', r->>'docNo', concat_ws(' | ', part, nm, 'x' || fn_qtytxt(qty), kit));
    return jsonb_build_object('docNo', r->>'docNo', 'kit', kit);
  exception when others then
    return jsonb_build_object('error', sqlerrm, 'kit', kit);
  end;
end $$;

create or replace function rpc_submit_issue(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
begin perform fn_lock(); return fn_issue_core(p); end $$;

-- จ่ายหลายรายการ (วันที่ / TAIL / ช่าง / หมายเหตุ ใช้ร่วมกัน)
create or replace function rpc_submit_issue_batch(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare items jsonb; it jsonb; r jsonb; done int := 0; failed jsonb := '[]'::jsonb; auto int := 0;
begin
  perform fn_lock();
  items := coalesce((select jsonb_agg(i) from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) i
                     where nullif(btrim(coalesce(i->>'qty','')),'') is null or fn_num(i->>'qty') > 0), '[]'::jsonb);
  if jsonb_array_length(items) = 0 then raise exception 'ยังไม่ได้เลือกรายการ'; end if;
  if jsonb_array_length(items) > 60 then raise exception 'จ่ายครั้งละไม่เกิน 60 รายการ'; end if;
  if btrim(coalesce(p->>'tech','')) = '' then raise exception 'กรุณากรอกชื่อช่างที่รับพัสดุ'; end if;
  for it in select * from jsonb_array_elements(items) loop
    begin
      r := fn_issue_core(jsonb_build_object('seq', it->>'seq', 'docNo', coalesce(it->>'docNo',''), 'qty', it->>'qty', 'payDate', p->>'payDate',
            'tail', p->>'tail', 'tech', p->>'tech', 'remark', p->>'remark', 'by', p->>'by'));
      done := done + 1; if r->'autoReq' is not null and r->>'autoReq' <> 'null' then auto := auto + 1; end if;
    exception when others then
      failed := failed || jsonb_build_object('docNo', it->>'docNo', 'seq', it->>'seq', 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', done, 'failed', failed, 'autoReq', auto);
end $$;

-- จ่ายตรงจากล็อตอิสระ (ยอดยกมา / ของคืนคลัง) โดยไม่มีใบเบิก
create or replace function fn_issue_direct_core(p jsonb) returns jsonb language plpgsql as $$
declare lot record; qty numeric; kit text; auto jsonb := null;
begin
  select * into lot from v_lots where seq = nullif(p->>'lotSeq','')::bigint;
  if not found then raise exception 'ไม่พบล็อตในคลังที่เลือก'; end if;
  if not lot.is_free or lot.remain <= 0 then raise exception 'ล็อตนี้ไม่ใช่ยอดยกมา/ของคืนคลัง หรือไม่ได้อยู่ในคลัง'; end if;
  qty := coalesce(fn_num(p->>'qty'), 0);
  if qty <= 0 then raise exception 'กรุณากรอกจำนวนที่จ่าย'; end if;
  if qty > lot.remain then raise exception 'จำนวนในล็อตไม่พอ (เหลือ %)', fn_qtytxt(lot.remain); end if;
  if lot.serial_no <> '' and qty <> 1 then raise exception 'พัสดุที่มี Serial number ต้องจ่ายทีละ 1 ชิ้น'; end if;
  insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, tail_no, technician, note, created_by)
  values (coalesce(fn_date(p->>'payDate'), fn_today()), 'จ่ายตรง', lot.seq, lot.part_no, lot.name, lot.serial_no, qty, lot.unit,
          btrim(coalesce(p->>'tail','')), btrim(coalesce(p->>'tech','')),
          concat_ws(' | ', nullif(btrim(coalesce(p->>'remark','')),''), 'จ่ายตรงจาก' || lot.label), btrim(coalesce(p->>'by','')));
  perform fn_log(p->>'by', 'จ่าย', 'จ่ายตรง', concat_ws(' | ', lot.part_no, lot.name, 'x' || fn_qtytxt(qty),
    case when lot.serial_no <> '' then 'S/N ' || lot.serial_no end, 'ช่าง ' || btrim(coalesce(p->>'tech','')),
    case when btrim(coalesce(p->>'tail','')) <> '' then 'TAIL ' || btrim(p->>'tail') end, '(จ่ายตรงจาก' || lot.label || ' ไม่มีใบเบิก)'));
  kit := fn_kit_of(lot.tail_no);
  if kit <> '' then auto := fn_auto_kit_req(lot.part_no, lot.name, lot.unit, lot.item_type, lot.serial_no, kit, qty, p); end if;
  return jsonb_build_object('closed', false, 'direct', true, 'left', lot.remain - qty, 'autoReq', auto);
end $$;

-- ---------- รับ ----------
create or replace function fn_receive_core(p jsonb) returns jsonb language plpgsql as $$
declare
  v_doc text := fn_docno(p->>'docNo'); v_part text := btrim(coalesce(p->>'part','')); rq record; v_qty numeric := coalesce(fn_num(p->>'qty'),0);
  lot record; have_lot boolean := false; lot_seq bigint := nullif(coalesce(p->>'lotSeq', p->>'lotRow'),'')::bigint;
  itype text; grp text; sn text; v_cond text; v_loc text; v_exp date; rdate date; req_qty numeric; done numeric; remain numeric; inc numeric := null;
  new_seq bigint; v_price numeric := fn_num(p->>'price'); g text := btrim(coalesce(p->>'group','')); iss jsonb := null; seqhint bigint := nullif(coalesce(p->>'reqSeq', p->>'row'),'')::bigint;
  dup_label text;
begin
  select * into lot from v_lots limit 0;   -- กำหนดโครงสร้าง record (plpgsql ไม่ลัดวงจรเมื่อ record ยังว่าง)
  -- หาใบเบิก (เลขเบิก + part ต้องตรงกัน ; ถ้ามีเลขลำดับใบเบิกส่งมาใช้ก่อน)
  select * into rq from requisitions where doc_no = v_doc and part_no = v_part
   order by (seq = seqhint) desc nulls last, cancelled, (pay_date is not null), seq limit 1;
  if not found then raise exception 'ไม่พบใบเบิกเลขที่ %', v_doc; end if;
  if rq.cancelled then raise exception 'ใบเบิกนี้ถูกยกเลิกแล้ว'; end if;
  if v_qty <= 0 then raise exception 'กรุณากรอกจำนวนที่รับ'; end if;
  if coalesce((p->>'issueNow')::boolean, false) and btrim(coalesce(p->>'tech','')) = '' then
    raise exception 'กรุณากรอกชื่อช่างที่รับพัสดุ (จ่ายทันที)'; end if;
  if nullif(p->>'loanSeq','') is not null and (p->>'loanSeq') <> '0' then
    raise exception 'การรับจากรายการยืมยังไม่เปิดใช้ในระบบใหม่ (ชุดฟังก์ชันยืม)'; end if;
  if lot_seq is not null and lot_seq <> 0 then
    select * into lot from v_lots where seq = lot_seq;
    have_lot := found;
    if not have_lot or not lot.is_free or lot.remain <= 0 or (case when rq.part_no <> '' then lot.part_no <> rq.part_no else lot.name <> rq.name end) then
      raise exception 'ไม่พบล็อตในคลังที่เลือก หรือไม่ตรงกับพัสดุในใบเบิก'; end if;
    if v_qty > lot.remain then raise exception 'จำนวนในล็อตไม่พอ (เหลือ %)', fn_qtytxt(lot.remain); end if;
  else lot_seq := null; end if;
  itype := rq.item_type;
  -- กลุ่มพัสดุ : ว่าง = ใช้กลุ่มเดิมของล็อตต้นทาง / ล็อตล่าสุดของ Part นี้ ; '-' = ทั่วไป
  if g = '-' then grp := '';
  elsif g <> '' then if g <> 'สารเคมี' then raise exception 'กลุ่มพัสดุไม่ถูกต้อง'; end if; grp := g;
  elsif have_lot and lot.item_group <> '' then grp := lot.item_group;
  else select coalesce((select l2.item_group from v_lots l2 where l2.part_no = rq.part_no and rq.part_no <> '' order by l2.seq desc limit 1), '') into grp; end if;
  sn := coalesce(nullif(btrim(coalesce(p->>'serial','')),''), case when have_lot then lot.serial_no else '' end);
  if sn <> '' and v_qty <> 1 then
    raise exception 'พัสดุที่มี Serial number ต้องรับทีละ 1 ชิ้น (ไม่มี Serial จึงรับหลายชิ้นพร้อมกันได้)'; end if;
  if sn <> '' then
    select l.label into dup_label from v_lots l where (lot_seq is null or l.seq <> lot_seq) and l.part_no = rq.part_no and upper(l.serial_no) = upper(sn) and l.remain > 0 limit 1;
    if found then raise exception 'Serial % มีอยู่ในคลังแล้ว (%)', sn, dup_label; end if;
    perform 1 from v_lots l where not l.is_free and l.doc_no = v_doc and l.part_no = rq.part_no and upper(l.serial_no) = upper(sn);
    if found then raise exception 'Serial % รับไปแล้วในใบเบิกนี้', sn; end if;
  end if;
  v_cond := coalesce(nullif(btrim(coalesce(p->>'cond','')),''), case when lot_seq is not null then lot.cond else '' end);
  v_loc  := coalesce(nullif(btrim(coalesce(p->>'location','')),''), case when lot_seq is not null then lot.location else '' end);
  v_exp  := coalesce(fn_date(p->>'expire'), case when lot_seq is not null then lot.expire_date end);
  rdate  := coalesce(fn_date(p->>'receiveDate'), fn_today());

  req_qty := rq.qty;
  select coalesce(sum(c.qty),0) into done from receipts c where c.source = 'ใบเบิก' and c.doc_no = v_doc and c.part_no = rq.part_no;
  if done + v_qty > req_qty then   -- รับเกิน -> เพิ่มจำนวนเบิกให้เท่ากับที่รับจริง
    req_qty := done + v_qty; update requisitions set qty = req_qty where seq = rq.seq; inc := req_qty; end if;
  remain := req_qty - done - v_qty;

  insert into receipts(doc_no, card_id, part_no, name, serial_no, item_type, item_group, qty, unit, unit_price, cond, notified_date, urgency,
                       due_date, received_date, over_days, tail_no, tci, expire_date, location, receiver, note, source, ref_seq)
  values (v_doc, btrim(coalesce(p->>'cardId','')), rq.part_no, rq.name, sn, itype, grp, v_qty, rq.unit, v_price, v_cond, rq.req_date, rq.urgency,
          fn_due(rq.req_date, rq.urgency), rdate, rdate - fn_due(rq.req_date, rq.urgency), rq.machine, btrim(coalesce(p->>'tci','')), v_exp, v_loc,
          btrim(coalesce(p->>'receiver','')), btrim(coalesce(p->>'remark','')), 'ใบเบิก', lot_seq)
  returning seq into new_seq;
  if remain <= 0 then update requisitions set pay_date = rdate where seq = rq.seq; end if;
  if lot_seq is not null and lot_seq <> 0 then   -- โอนจากล็อตอิสระเข้าใบเบิก : บันทึกการออกจากล็อตเดิม
    insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, tail_no, technician, note, created_by)
    select rdate, v_doc, l.seq, l.part_no, l.name, l.serial_no, v_qty, l.unit, '', '', 'โอนเข้าใบเบิก ' || v_doc, btrim(coalesce(p->>'by','')) from v_lots l where l.seq = lot_seq;
  end if;
  perform fn_log(p->>'by', 'รับ', v_doc, concat_ws(' | ', rq.part_no, rq.name, 'x' || fn_qtytxt(v_qty), case when sn <> '' then 'S/N ' || sn end,
    case when lot_seq is not null and lot_seq <> 0 then '(จากล็อต ' || lot_seq || ')' end,
    case when inc is not null then 'เพิ่มจำนวนเบิกเป็น ' || fn_qtytxt(inc) end,
    case when btrim(coalesce(p->>'receiver','')) <> '' then 'ผู้รับ ' || btrim(p->>'receiver') end));
  if coalesce((p->>'issueNow')::boolean, false) then   -- รับแล้วจ่ายทันที
    iss := fn_issue_core(jsonb_build_object('seq', new_seq, 'docNo', v_doc, 'tech', p->>'tech', 'tail', p->>'tail', 'remark', p->>'issueRemark',
                          'payDate', coalesce(p->>'payDate', fn_today()::text), 'by', p->>'by'));
  end if;
  return jsonb_build_object('remain', remain, 'increasedTo', inc, 'issued', iss is not null, 'closed', remain <= 0, 'rcvSeq', new_seq);
end $$;

create or replace function rpc_submit_receive(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
begin perform fn_lock(); return fn_receive_core(p); end $$;

-- รับหลายรายการ : แต่ละรายการแยกธุรกรรมย่อย ; จ่ายทันทีพลาดไม่ทำให้การรับย้อนกลับ
create or replace function rpc_submit_receive_batch(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  items jsonb; it jsonb; r jsonb; done int := 0; issued int := 0; failed jsonb := '[]'::jsonb; ifailed jsonb := '[]'::jsonb;
  issue_now boolean := coalesce((p->>'issueNow')::boolean, false); any_closed boolean := false;
begin
  perform fn_lock();
  items := coalesce((select jsonb_agg(i) from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) i where coalesce(fn_num(i->>'qty'),0) > 0), '[]'::jsonb);
  if jsonb_array_length(items) = 0 then raise exception 'ยังไม่ได้กรอกจำนวนที่รับ'; end if;
  if jsonb_array_length(items) > 60 then raise exception 'รับครั้งละไม่เกิน 60 รายการ'; end if;
  if issue_now and btrim(coalesce(p->>'tech','')) = '' then raise exception 'กรุณากรอกชื่อช่างที่รับพัสดุ (จ่ายทันที)'; end if;
  for it in select * from jsonb_array_elements(items) loop
    begin
      r := fn_receive_core(jsonb_build_object('row', it->>'row', 'reqSeq', it->>'reqSeq', 'docNo', coalesce(it->>'docNo',''), 'part', it->>'part', 'qty', it->>'qty',
            'price', coalesce(it->>'price',''), 'cond', it->>'cond', 'group', it->>'group', 'serial', '', 'cardId', p->>'cardId', 'receiver', p->>'receiver',
            'receiveDate', p->>'receiveDate', 'by', p->>'by'));
      done := done + 1; if (r->>'closed')::boolean then any_closed := true; end if;
      if issue_now then
        begin
          perform fn_issue_core(jsonb_build_object('seq', r->>'rcvSeq', 'docNo', coalesce(it->>'docNo',''), 'tech', p->>'tech', 'tail', p->>'tail',
                  'remark', p->>'issueRemark', 'payDate', coalesce(p->>'payDate', fn_today()::text), 'by', p->>'by'));
          issued := issued + 1;
        exception when others then
          ifailed := ifailed || jsonb_build_object('docNo', it->>'docNo', 'part', it->>'part', 'error', sqlerrm);
        end;
      end if;
    exception when others then
      failed := failed || jsonb_build_object('docNo', it->>'docNo', 'part', it->>'part', 'error', sqlerrm);
    end;
  end loop;
  if done > 0 then
    perform fn_log(p->>'by', 'รับหลายรายการ', '', done || ' รายการ' || case when btrim(coalesce(p->>'cardId','')) <> '' then ' | card ID ' || btrim(p->>'cardId') else '' end);
  end if;
  return jsonb_build_object('ok', done, 'failed', failed, 'issued', issued, 'issueFailed', ifailed);
end $$;

-- จ่ายจากล็อตในคลัง : มีใบเบิกอ้างอิง -> รับเข้าใบเบิกแล้วจ่ายต่อ ; ไม่มี -> จ่ายตรง (issueFromLot)
create or replace function rpc_issue_from_lot(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare rc jsonb;
begin
  perform fn_lock();
  if btrim(coalesce(p->>'tech','')) = '' then raise exception 'กรุณากรอกชื่อช่างที่รับพัสดุ'; end if;
  if btrim(coalesce(p->>'docNo','')) = '' then return fn_issue_direct_core(p); end if;
  perform 1 from v_lots where seq = nullif(p->>'lotSeq','')::bigint;
  if not found then raise exception 'ไม่พบล็อตในคลังที่เลือก'; end if;
  rc := fn_receive_core(jsonb_build_object('row', p->>'row', 'docNo', p->>'docNo', 'part', p->>'part', 'qty', p->>'qty', 'lotSeq', p->>'lotSeq',
          'receiver', p->>'tech', 'receiveDate', coalesce(p->>'receiveDate', p->>'payDate'), 'by', p->>'by'));
  begin
    return fn_issue_core(jsonb_build_object('seq', rc->>'rcvSeq', 'docNo', p->>'docNo', 'tech', p->>'tech', 'tail', p->>'tail', 'remark', p->>'remark', 'payDate', p->>'payDate', 'by', p->>'by'));
  exception when others then
    raise exception 'รับเข้าใบเบิกแล้ว แต่จ่ายไม่สำเร็จ: % (ไปจ่ายต่อที่แท็บ จ่าย)', sqlerrm;
  end;
end $$;

-- ---------- ข้อมูลหน้าจอ ----------
-- ใบเบิกที่ยังรับไม่ครบ (getPendingReceive)
create or replace function rpc_get_pending_receive() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x - '_k' order by x->>'_k' desc), '[]'::jsonb) from (
    select jsonb_build_object('_k', lpad(r.seq::text, 12, '0'), 'row', r.seq, 'docNo', r.doc_no, 'part', r.part_no, 'name', r.name, 'qty', r.qty, 'unit', r.unit,
      'date', fn_thai(r.req_date), 'machine', r.machine, 'urgency', r.urgency, 'issue', r.issue_text, 'due', fn_thai(fn_due(r.req_date, r.urgency)),
      'type', r.item_type, 'received', g.done, 'remain', r.qty - g.done) as x
    from requisitions r
    cross join lateral (select coalesce(sum(c.qty),0) as done from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no) g
    where r.pay_date is null and not r.cancelled and r.qty - g.done > 0
  ) t
$$;

-- ล็อตที่รับตามใบเบิกแล้วและยังไม่จ่ายให้ช่าง (getPendingIssue)
create or replace function rpc_get_pending_issue() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by (x->>'seq')::bigint desc), '[]'::jsonb) from (
    select jsonb_build_object('row', l.seq, 'seq', l.seq, 'docNo', l.doc_no, 'part', l.part_no, 'name', l.name, 'serial', l.serial_no, 'qty', l.remain, 'unit', l.unit,
      'urgency', rc.urgency, 'due', fn_thai(rc.due_date), 'location', l.location, 'receiver', l.receiver,
      'machine', coalesce(q.machine,''), 'issue', coalesce(q.issue_text,''), 'reqQty', coalesce(q.qty,0), 'type', coalesce(nullif(l.item_type,''), q.item_type, '')) as x
    from v_lots l
    join receipts rc on rc.seq = l.seq
    left join lateral (select * from requisitions r where r.doc_no = l.doc_no and r.part_no = l.part_no order by r.seq limit 1) q on true
    where not l.is_free and l.remain > 0
  ) t
$$;

-- สิทธิ์ : หน้าเว็บ (anon) เรียกได้เฉพาะ rpc_* ; ฟังก์ชันภายในไม่เปิด
revoke all on function fn_find_dups(jsonb), fn_requisition_core(jsonb), fn_issue_core(jsonb), fn_issue_direct_core(jsonb), fn_receive_core(jsonb), fn_auto_kit_req(text,text,text,text,text,text,numeric,jsonb) from public, anon;
grant execute on function rpc_submit_requisition(jsonb), rpc_submit_issue(jsonb), rpc_submit_issue_batch(jsonb), rpc_submit_receive(jsonb), rpc_submit_receive_batch(jsonb),
  rpc_issue_from_lot(jsonb), rpc_get_pending_receive(), rpc_get_pending_issue() to anon;
