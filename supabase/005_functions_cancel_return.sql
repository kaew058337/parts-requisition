-- =====================================================================
--  005 : ฟังก์ชันชุดที่ 2  แก้/ยกเลิกใบเบิก · ยกเลิกรายการ รับ/จ่าย/ส่งคืน · คืนเข้าคลัง · ส่งคืน (TAI) · เตือน Serial ซ้ำ
--  แปลงจาก Code.gs: editRequisition, cancelRequisition, cancelEntry (cancelIssue_/cancelReceive_/cancelReturn_),
--  submitReturnToStock, submitReturn, serialAlert_, getReturnable, getNextReturnNo
--  * การยกเลิก = เก็บหลักฐานลง cancelled_records แล้วลบแถวจริง (ผ่านฟังก์ชันเท่านั้น) ; เลขลำดับ identity ไม่ถูกใช้ซ้ำอยู่แล้ว
-- =====================================================================

create or replace function fn_cxl(p_kind text, p_seq bigint, p_doc text, p_part text, p_name text, p_sn text, p_qty numeric, p_reason text, p_by text, p_orig jsonb) returns void
language sql as $$
  insert into cancelled_records(cancelled_by, kind, orig_seq, doc_no, part_no, name, serial_no, qty, reason, original)
  values (coalesce(nullif(btrim(p_by),''),'(ไม่ระบุ)'), p_kind, p_seq, coalesce(p_doc,''), coalesce(p_part,''), coalesce(p_name,''), coalesce(p_sn,''), p_qty, coalesce(p_reason,''), coalesce(p_orig,'{}'::jsonb));
$$;

create or replace function fn_fiscal_yy(d date) returns text language sql immutable as
$$ select lpad((((extract(year from d)::int + 543) + case when extract(month from d) >= 10 then 1 else 0 end) % 100)::text, 2, '0') $$;

create or replace function fn_next_return_no(d date) returns text language sql stable as $$
  select fn_fiscal_yy(d) || '-' || lpad((coalesce(max(substr(letter_no, 4)::int), 0) + 1)::text, 3, '0')
  from returns_out where letter_no ~ '^\d{2}-\d+$' and substr(letter_no, 1, 2) = fn_fiscal_yy(d)
$$;
create or replace function rpc_get_next_return_no(date_iso text default null) returns text language sql stable security definer set search_path = public as
$$ select fn_next_return_no(coalesce(fn_date(date_iso), fn_today())) $$;

create or replace function fn_split_serials(v text) returns text[] language sql immutable as
$$ select coalesce(array(select btrim(x) from regexp_split_to_table(coalesce(v,''), '[\n\r,;]+') x where btrim(x) <> ''), '{}') $$;

-- ---------- เตือน : ส่งคืนด้วย Serial เดิมภายใน 365 วันนับจากวันที่รับ ----------
create or replace function fn_serial_alert(p_serial text, p_part text) returns jsonb language plpgsql stable as $$
declare i record; recv date; d int; prior int;
begin
  if btrim(coalesce(p_serial,'')) = '' then return null; end if;
  select * into i from issues where technician <> '' and upper(serial_no) = upper(btrim(p_serial))
     and (btrim(coalesce(p_part,'')) = '' or part_no = btrim(p_part)) order by seq desc limit 1;
  if not found then return null; end if;
  select received_date into recv from receipts where seq = i.receipt_seq;
  if recv is null then return null; end if;
  d := fn_today() - recv;
  if d > 365 or d < 0 then return null; end if;
  select count(*) into prior from returns_out where upper(serial_out) = upper(btrim(p_serial));
  return jsonb_build_object('alert', true, 'serial', btrim(p_serial), 'part', i.part_no, 'name', i.name, 'docNo', i.doc_no,
    'receiveDate', fn_thai(recv), 'issueDate', fn_thai(i.issue_date), 'days', d, 'limit', 365, 'tail', i.tail_no, 'tech', i.technician, 'priorReturns', prior);
end $$;

create or replace function rpc_check_serial_alert(p_serial text, p_part text default '') returns jsonb language sql stable security definer set search_path = public as
$$ select coalesce(fn_serial_alert(p_serial, p_part), '{"alert": false}'::jsonb) $$;
create or replace function rpc_check_serial_alerts(p_serials text, p_part text default '') returns jsonb language sql stable security definer set search_path = public as
$$ select coalesce(jsonb_agg(a), '[]'::jsonb) from (select fn_serial_alert(s, p_part) a from unnest(fn_split_serials(p_serials)) s) t where a is not null $$;

-- ---------- รายการจ่ายที่คืนเข้าคลังได้ ----------
create or replace function rpc_get_returnable() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by (x->>'seq')::bigint desc), '[]'::jsonb) from (
    select jsonb_build_object('seq', i.seq, 'docNo', i.doc_no, 'part', i.part_no, 'name', i.name, 'serial', i.serial_no, 'qty', i.qty, 'remain', i.qty - b.back,
      'unit', i.unit, 'type', coalesce(nullif(q.item_type,''), case when i.serial_no <> '' then 'LRU' else 'SP' end), 'machine', coalesce(q.machine,''),
      'tail', i.tail_no, 'tech', i.technician, 'cond', coalesce(l.cond,''), 'location', coalesce(l.location,''), 'payDate', fn_thai(i.issue_date)) as x
    from issues i
    cross join lateral (select coalesce(sum(r.qty),0) back from receipts r where r.source = 'คืนเข้าคลัง' and r.ref_seq = i.seq) b
    left join lateral (select * from requisitions r where r.doc_no = i.doc_no and r.part_no = i.part_no order by r.seq desc limit 1) q on true
    left join receipts l on l.seq = i.receipt_seq
    where i.technician <> '' and i.qty - b.back > 0
  ) t
$$;

-- ---------- คืนเข้าคลัง ----------
create or replace function rpc_submit_return_to_stock(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare iss record; q record; lot record; v_qty numeric := coalesce(fn_num(p->>'qty'), 0); back numeric; remain numeric;
        typ text; al jsonb; v_note text; v_cond text; v_loc text; alnote text;
begin
  perform fn_lock();
  select * into iss from issues where seq = nullif(p->>'seq','')::bigint and technician <> '';
  if not found then raise exception 'ไม่พบรายการจ่ายที่เลือก'; end if;
  if btrim(coalesce(p->>'reason','')) = '' then raise exception 'กรุณาระบุเหตุผลที่คืนเข้าคลัง'; end if;
  if v_qty <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  select coalesce(sum(r.qty),0) into back from receipts r where r.source = 'คืนเข้าคลัง' and r.ref_seq = iss.seq;
  remain := iss.qty - back;
  if v_qty > remain then raise exception 'คืนเกินจำนวนที่จ่าย (คืนได้อีก %)', fn_qtytxt(remain); end if;
  select * into q from requisitions r where r.doc_no = iss.doc_no and r.part_no = iss.part_no order by r.seq desc limit 1;
  typ := coalesce(nullif(q.item_type,''), case when iss.serial_no <> '' then 'LRU' else 'SP' end);
  select * into lot from v_lots where seq = iss.receipt_seq;
  v_cond := coalesce(nullif(btrim(coalesce(p->>'cond','')),''), lot.cond, '');
  v_loc  := coalesce(nullif(btrim(coalesce(p->>'location','')),''), lot.location, '');
  al := fn_serial_alert(iss.serial_no, iss.part_no);
  alnote := case when al is not null then ' · ⚠ คืนซ้ำ Serial เดิมภายใน 365 วัน (รับ ' || (al->>'receiveDate') || ' · ผ่านมา ' || (al->>'days') || ' วัน)' else '' end;
  v_note := 'คืนจากใบเบิก ' || iss.doc_no || ' · ' || btrim(p->>'reason') || alnote;
  insert into receipts(doc_no, card_id, part_no, name, serial_no, item_type, item_group, qty, unit, cond, received_date, expire_date, location, note, source, ref_seq)
  values ('', '', iss.part_no, iss.name, iss.serial_no, typ, coalesce(lot.item_group,''), v_qty, iss.unit, v_cond, fn_today(), lot.expire_date, v_loc, v_note, 'คืนเข้าคลัง', iss.seq);
  insert into returns_out(part_no, name, qty, serial_out, serial_in, receiver, sender, machine, issue_text, note, letter_no, condition)
  values (iss.part_no, iss.name, v_qty, iss.serial_no, '', btrim(coalesce(p->>'by','')), iss.technician, coalesce(q.machine,''), '', v_note, '', '');
  perform fn_log(p->>'by', 'คืนเข้าคลัง', iss.doc_no, concat_ws(' | ', iss.part_no, iss.name, 'x' || fn_qtytxt(v_qty),
    case when iss.serial_no <> '' then 'S/N ' || iss.serial_no end, 'เหตุผล: ' || btrim(p->>'reason')));
  return jsonb_build_object('ok', true, 'left', remain - v_qty, 'alert', al);
end $$;

-- ---------- ส่งคืน (ส่งของกลับ TAI) ----------
create or replace function rpc_submit_return(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  sns text[] := fn_split_serials(p->>'serialReturn'); ins text[] := fn_split_serials(p->>'serialInstalled');
  base date := coalesce(fn_date(p->>'date'), fn_today()); v_when timestamptz; doc text := btrim(coalesce(p->>'docNo',''));
  i int; n int; inst text; al jsonb; alerts jsonb := '[]'::jsonb; alnote text; dupsn text; cnt int := 0; total numeric := 0; q numeric := coalesce(fn_num(p->>'qty'), 0);
begin
  perform fn_lock();
  if btrim(coalesce(p->>'part','')) = '' and btrim(coalesce(p->>'name','')) = '' then raise exception 'กรุณากรอก Part number หรือชื่อพัสดุ'; end if;
  select x into dupsn from unnest(sns) x group by upper(x), x having (select count(*) from unnest(sns) y where upper(y) = upper(x)) > 1 limit 1;
  if dupsn is not null then raise exception 'Serial ซ้ำกัน: %', dupsn; end if;
  if coalesce(array_length(ins,1),0) > greatest(1, coalesce(array_length(sns,1),0)) then raise exception 'Serial ที่ใส่ มากกว่า Serial ส่งคืน'; end if;
  if coalesce(array_length(sns,1),0) = 0 and q <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  v_when := ((base + (now() at time zone 'Asia/Bangkok')::time)::timestamp) at time zone 'Asia/Bangkok';
  if doc <> '' then
    if doc !~ '^\d{2}-\d{1,4}$' then raise exception 'ที่หนังสือต้องเป็นรูปแบบ 70-001 (ปีงบ 2 หลัก-ลำดับ)'; end if;
    doc := split_part(doc,'-',1) || '-' || lpad(split_part(doc,'-',2)::int::text, 3, '0');
    if exists (select 1 from returns_out where letter_no = doc) then raise exception 'ที่หนังสือ % ถูกใช้แล้ว', doc; end if;
  else doc := fn_next_return_no(base); end if;
  n := greatest(coalesce(array_length(sns,1),0), 1);
  for i in 1..n loop
    inst := case when coalesce(array_length(sns,1),0) = 0 then coalesce(ins[1],'')
                 when coalesce(array_length(ins,1),0) = array_length(sns,1) then ins[i]
                 when coalesce(array_length(ins,1),0) = 1 then ins[1] else '' end;
    al := case when coalesce(array_length(sns,1),0) > 0 then fn_serial_alert(sns[i], p->>'part') end;
    if al is not null then alerts := alerts || al; end if;
    alnote := case when al is not null then '⚠ ส่งคืนซ้ำ Serial เดิมภายใน 365 วัน (รับ ' || (al->>'receiveDate') || ' · ผ่านมา ' || (al->>'days') || ' วัน)' else '' end;
    insert into returns_out(part_no, name, qty, serial_out, serial_in, receiver, sender, machine, issue_text, note, recorded_at, letter_no, condition)
    values (btrim(coalesce(p->>'part','')), btrim(coalesce(p->>'name','')), case when coalesce(array_length(sns,1),0) > 0 then 1 else q end,
            coalesce(sns[i],''), inst, btrim(coalesce(p->>'receiver','')), btrim(coalesce(p->>'sender','')), btrim(coalesce(p->>'machine','')),
            btrim(coalesce(p->>'issue','')), concat_ws(' | ', nullif(btrim(coalesce(p->>'remark','')),''), nullif(alnote,'')), v_when, doc, btrim(coalesce(p->>'condition','')));
    cnt := cnt + 1; total := total + case when coalesce(array_length(sns,1),0) > 0 then 1 else q end;
  end loop;
  perform fn_log(p->>'by', 'ส่งคืน', '', concat_ws(' | ', doc, btrim(coalesce(p->>'part','')), btrim(coalesce(p->>'name','')), 'x' || fn_qtytxt(total),
    case when coalesce(array_length(sns,1),0) > 0 then 'S/N คืน ' || array_to_string(sns, ', ') end,
    case when btrim(coalesce(p->>'machine','')) <> '' then 'เครื่อง ' || btrim(p->>'machine') end,
    case when jsonb_array_length(alerts) > 0 then '⚠ เตือนส่งคืนซ้ำ ' || jsonb_array_length(alerts) || ' Serial' end));
  return jsonb_build_object('ok', true, 'count', cnt, 'docNo', doc, 'alert', alerts->0, 'alerts', alerts);
end $$;

-- ---------- แก้ / ยกเลิกใบเบิก ----------
create or replace function fn_req_editable(p_doc text) returns requisitions language plpgsql stable as $$
declare r requisitions; got numeric; d text := fn_docno(p_doc);
begin
  select * into r from requisitions where doc_no = d order by seq limit 1;
  if not found then raise exception 'ไม่พบใบเบิกเลขที่ %', p_doc; end if;
  if r.cancelled then raise exception 'ใบเบิกนี้ถูกยกเลิกแล้ว'; end if;
  if r.pay_date is not null then raise exception 'ใบเบิกนี้จ่ายแล้ว แก้ไขหรือยกเลิกไม่ได้'; end if;
  select coalesce(sum(c.qty),0) into got from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no;
  if got > 0 then raise exception 'มีการรับพัสดุตามใบเบิกนี้ไปแล้ว แก้ไขหรือยกเลิกไม่ได้'; end if;
  return r;
end $$;

create or replace function rpc_cancel_requisition(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare r requisitions;
begin
  perform fn_lock();
  r := fn_req_editable(p->>'docNo');
  if btrim(coalesce(p->>'reason','')) = '' then raise exception 'กรุณาระบุเหตุผลที่ยกเลิก'; end if;
  update requisitions set cancelled = true, cancel_reason = btrim(p->>'reason') where seq = r.seq;
  perform fn_log(p->>'by', 'ยกเลิกใบเบิก', r.doc_no, concat_ws(' | ', r.part_no, r.name, 'x' || fn_qtytxt(r.qty), 'เหตุผล: ' || btrim(p->>'reason')));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rpc_edit_requisition(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare r requisitions; urg text; diffs text[] := '{}'; nq numeric := coalesce(fn_num(p->>'qty'),0); nu text := coalesce(nullif(btrim(coalesce(p->>'unit','')),''),'EA');
        np text := btrim(coalesce(p->>'part','')); nn text := btrim(coalesce(p->>'name','')); nm text := btrim(coalesce(p->>'machine','')); ni text := btrim(coalesce(p->>'issue',''));
        nr text := btrim(coalesce(p->>'rank','')); nf text := btrim(coalesce(p->>'fullName','')); npos text := btrim(coalesce(p->>'position','')); nt text := btrim(coalesce(p->>'itemType',''));
begin
  perform fn_lock();
  r := fn_req_editable(p->>'docNo');
  if nn = '' then raise exception 'กรุณากรอกชื่อพัสดุ'; end if;
  if nq <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  if nm = '' then raise exception 'กรุณาเลือกหมายเลขเครื่อง'; end if;
  if nf = '' then raise exception 'กรุณากรอกชื่อ-สกุลผู้เบิก'; end if;
  if nt = 'สารเคมี' then nt := 'SP'; end if;
  if nt not in ('LRU','SP','LRU(TCI)','SP(TCI)') then raise exception 'กรุณาเลือกประเภทพัสดุ'; end if;
  urg := case when btrim(coalesce(p->>'urgency','')) = 'AOG' then 'AOG' else 'เบิกธรรมดา' end;
  if r.part_no <> np then diffs := diffs || ('Part: ' || r.part_no || ' → ' || np); end if;
  if r.name <> nn then diffs := diffs || ('ชื่อ: ' || r.name || ' → ' || nn); end if;
  if r.qty <> nq then diffs := diffs || ('จำนวน: ' || fn_qtytxt(r.qty) || ' → ' || fn_qtytxt(nq)); end if;
  if r.unit <> nu then diffs := diffs || ('หน่วย: ' || r.unit || ' → ' || nu); end if;
  if r.machine <> nm then diffs := diffs || ('เครื่อง: ' || r.machine || ' → ' || nm); end if;
  if r.urgency <> urg then diffs := diffs || ('ความเร่งด่วน: ' || r.urgency || ' → ' || urg); end if;
  if r.issue_text <> ni then diffs := diffs || ('ข้อขัดข้อง: ' || r.issue_text || ' → ' || ni); end if;
  if r.req_rank <> nr then diffs := diffs || ('ยศ: ' || r.req_rank || ' → ' || nr); end if;
  if r.req_name <> nf then diffs := diffs || ('ผู้เบิก: ' || r.req_name || ' → ' || nf); end if;
  if r.req_position <> npos then diffs := diffs || ('ตำแหน่ง: ' || r.req_position || ' → ' || npos); end if;
  if r.item_type <> nt then diffs := diffs || ('ประเภท: ' || r.item_type || ' → ' || nt); end if;
  update requisitions set part_no = np, name = nn, qty = nq, unit = nu, machine = nm, urgency = urg, issue_text = ni, req_rank = nr, req_name = nf, req_position = npos, item_type = nt
   where seq = r.seq;
  perform fn_log(p->>'by', 'แก้ใบเบิก', r.doc_no, case when array_length(diffs,1) > 0 then array_to_string(diffs, ' | ') else '(ไม่มีการเปลี่ยนแปลง)' end);
  return jsonb_build_object('ok', true, 'changed', coalesce(array_length(diffs,1),0));
end $$;

-- ---------- ยกเลิกรายการ รับ / จ่าย / ส่งคืน ----------
create or replace function fn_cancel_receive(p_seq bigint, p_reason text, p_by text) returns jsonb language plpgsql as $$
declare
  r receipts; lot record; xfer issues; pair returns_out; ret_removed boolean := false; xfer_removed boolean := false; reopened boolean := false;
  done numeric; rq requisitions;
begin
  select * into r from receipts where seq = p_seq;
  if not found then raise exception 'ไม่พบรายการรับลำดับที่ % (อาจถูกยกเลิกไปแล้ว)', p_seq; end if;
  select * into lot from v_lots where seq = p_seq;
  if lot.issued > 0 then raise exception 'รายการนี้จ่ายออกไปแล้ว % % ต้องยกเลิกรายการ "จ่าย" ก่อน', fn_qtytxt(lot.issued), r.unit; end if;
  if lot.loan_out > 0 or exists (select 1 from loans where lot_seq = p_seq and status = 'ยืมอยู่') then raise exception 'พัสดุนี้ถูกยืมออกจากคลังอยู่ ต้องรับคืนการยืมก่อน'; end if;
  if exists (select 1 from loans where lot_seq = p_seq) then raise exception 'พัสดุล็อตนี้มีประวัติการยืม จึงยกเลิกไม่ได้'; end if;
  if r.note ~ '^แยกจากลำดับรับ' or position('| แยกจากลำดับรับ' in r.note) > 0 then
    raise exception 'รายการนี้เกิดจากการแยก/ย้ายบางส่วน ยกเลิกแล้วจำนวนจะหาย ให้ย้ายกลับแทน'; end if;
  if exists (select 1 from receipts x where x.seq <> p_seq and x.note ~ ('แยกจากลำดับรับ ' || p_seq || '(\D|$)')) then
    raise exception 'มีรายการที่ถูกแยกออกไปจากล็อตนี้ ต้องย้ายกลับหรือยกเลิกรายการนั้นก่อน'; end if;
  if r.source = 'ใบเบิก' and r.doc_no <> '' and exists (select 1 from loans l where l.close_method = 'ใช้งานแล้ว (เบิก)' and r.doc_no = any (string_to_array(regexp_replace(btrim(l.ref_doc_no), '[,\s]+', ',', 'g'), ','))) then
    raise exception 'รายการรับนี้ใช้ปิดการยืมของใบเบิก % ยกเลิกไม่ได้', r.doc_no; end if;

  -- 1) รับที่โอนมาจากล็อตในคลัง -> ลบแถวโอนใน จ่าย เพื่อคืนของให้ล็อตเดิม
  if r.source = 'ใบเบิก' and r.ref_seq is not null then
    select * into xfer from issues where receipt_seq = r.ref_seq and doc_no = r.doc_no and technician = '' and qty = r.qty and note like 'โอนเข้าใบเบิก%' order by seq desc limit 1;
    if found then
      perform fn_cxl('จ่าย(โอนเข้าใบเบิก)', xfer.seq, r.doc_no, xfer.part_no, xfer.name, xfer.serial_no, xfer.qty, p_reason, p_by, to_jsonb(xfer));
      delete from issues where seq = xfer.seq; xfer_removed := true;
    end if;
  end if;
  -- 2) รับคืนเข้าคลัง -> ลบแถวใน ส่งคืน ที่บันทึกคู่กันไว้
  if r.source = 'คืนเข้าคลัง' then
    select * into pair from returns_out where note = r.note and part_no = r.part_no and serial_out = r.serial_no and qty = r.qty order by seq desc limit 1;
    if found then
      perform fn_cxl('ส่งคืน(คู่กับรับคืนเข้าคลัง)', pair.seq, pair.letter_no, pair.part_no, pair.name, pair.serial_out, pair.qty, p_reason, p_by, to_jsonb(pair));
      delete from returns_out where seq = pair.seq; ret_removed := true;
    end if;
  end if;
  perform fn_cxl(case when r.source = 'คืนเข้าคลัง' then 'รับคืนเข้าคลัง' else 'รับ' end, r.seq, coalesce(nullif(r.doc_no,''), r.source), r.part_no, r.name, r.serial_no, r.qty, p_reason, p_by, to_jsonb(r));
  delete from receipts where seq = p_seq;

  -- 3) รับตามใบเบิก -> ใบเบิกกลับเป็นค้างจ่าย ถ้ารับไม่ครบแล้ว
  if r.source = 'ใบเบิก' and r.doc_no <> '' then
    select coalesce(sum(c.qty),0) into done from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no;
    select * into rq from requisitions where doc_no = r.doc_no and part_no = r.part_no order by seq limit 1;
    if found and rq.pay_date is not null and done < rq.qty then
      update requisitions set pay_date = null where seq = rq.seq; reopened := true; end if;
  end if;
  perform fn_log(p_by, case when r.source = 'คืนเข้าคลัง' then 'ยกเลิกการรับคืนเข้าคลัง' else 'ยกเลิกการรับ' end, r.doc_no, concat_ws(' | ', r.part_no, r.name, 'x' || fn_qtytxt(r.qty),
    case when r.serial_no <> '' then 'S/N ' || r.serial_no end, case when r.source <> 'ใบเบิก' then '(' || r.source || ')' end,
    case when xfer_removed then 'คืนยอดให้ล็อตเดิม' end, case when reopened then 'ใบเบิกกลับเป็นค้างรับ' end, 'เหตุผล: ' || p_reason));
  return jsonb_build_object('ok', true, 'msg', 'ยกเลิกการรับแล้ว' || case when reopened then ' · ใบเบิก ' || r.doc_no || ' กลับเป็น "ค้างจ่าย" (รอรับ)' else '' end ||
    case when xfer_removed then ' · คืนจำนวนให้ล็อตเดิมในคลังแล้ว' else '' end || case when ret_removed then ' · รายการส่งคืนคู่กันถูกยกเลิกด้วย' else '' end);
end $$;

create or replace function fn_cancel_issue(p_seq bigint, p_reason text, p_by text) returns jsonb language plpgsql as $$
declare i issues; back numeric; lot record; kit text;
begin
  select * into i from issues where seq = p_seq;
  if not found then raise exception 'ไม่พบรายการจ่ายลำดับที่ % (อาจถูกยกเลิกไปแล้ว)', p_seq; end if;
  if i.technician = '' and i.doc_no <> 'จ่ายตรง' then
    raise exception '%', case when i.doc_no in ('ปรับยอดตรวจนับ','ตัดจ่ายตามตรวจนับ') then 'รายการนี้เกิดจากการตรวจนับ ยกเลิกตรงนี้ไม่ได้ (ให้ตรวจนับใหม่)'
      else 'รายการนี้เป็นการโอนเข้าใบเบิก ให้ยกเลิกที่ประวัติ "รับ" ของใบเบิกนั้นแทน' end;
  end if;
  select coalesce(sum(r.qty),0) into back from receipts r where r.source = 'คืนเข้าคลัง' and r.ref_seq = p_seq;
  if back > 0 then raise exception 'รายการจ่ายนี้มีการคืนเข้าคลังแล้ว % ชิ้น ต้องยกเลิกรายการ "รับคืนเข้าคลัง" นั้นก่อน', fn_qtytxt(back); end if;
  select * into lot from v_lots where seq = i.receipt_seq;
  if not found then raise exception 'ไม่พบล็อตต้นทางของรายการจ่ายนี้ จึงคืนของเข้าคลังให้ไม่ได้'; end if;
  perform fn_cxl('จ่าย', i.seq, i.doc_no, i.part_no, i.name, i.serial_no, i.qty, p_reason, p_by, to_jsonb(i));
  delete from issues where seq = p_seq;
  perform fn_log(p_by, 'ยกเลิกการจ่าย', i.doc_no, concat_ws(' | ', i.part_no, i.name, 'x' || fn_qtytxt(i.qty), case when i.serial_no <> '' then 'S/N ' || i.serial_no end,
    'ช่าง ' || i.technician, 'เหตุผล: ' || p_reason));
  kit := fn_kit_of(lot.tail_no);
  return jsonb_build_object('ok', true, 'msg', 'ยกเลิกการจ่ายแล้ว พัสดุกลับเข้าคลัง' || case when lot.location <> '' then ' (' || lot.location || ')' else '' end ||
    case when kit <> '' then ' · ใบเบิกทดแทน ' || kit || ' ที่ออกอัตโนมัติยังอยู่ ถ้าไม่ต้องการให้ยกเลิกใบเบิกนั้นเอง' else '' end);
end $$;

create or replace function fn_cancel_return(p_seq bigint, p_reason text, p_by text) returns jsonb language plpgsql as $$
declare r returns_out; pr receipts;
begin
  select * into r from returns_out where seq = p_seq;
  if not found then raise exception 'ไม่พบรายการส่งคืนลำดับที่ % (อาจถูกยกเลิกไปแล้ว)', p_seq; end if;
  if r.note like 'คืนจากใบเบิก%' then   -- แถวที่เกิดจาก "คืนเข้าคลัง" : ยกเลิกผ่านรายการรับคืนเข้าคลังคู่กัน (ลบทั้งสองฝั่ง)
    select * into pr from receipts x where x.source = 'คืนเข้าคลัง' and x.note = r.note and x.part_no = r.part_no and x.serial_no = r.serial_out and x.qty = r.qty order by x.seq limit 1;
    if found then return fn_cancel_receive(pr.seq, p_reason, p_by); end if;
  end if;
  perform fn_cxl('ส่งคืน', r.seq, r.letter_no, r.part_no, r.name, r.serial_out, r.qty, p_reason, p_by, to_jsonb(r));
  delete from returns_out where seq = p_seq;
  perform fn_log(p_by, 'ยกเลิกการส่งคืน', '', concat_ws(' | ', r.letter_no, r.part_no, r.name, 'x' || fn_qtytxt(r.qty), case when r.serial_out <> '' then 'S/N ' || r.serial_out end, 'เหตุผล: ' || p_reason));
  return jsonb_build_object('ok', true, 'msg', 'ยกเลิกรายการส่งคืนแล้ว');
end $$;

create or replace function rpc_cancel_entry(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare k text := btrim(coalesce(p->>'kind','')); s bigint := nullif(p->>'seq','')::bigint; rs text := btrim(coalesce(p->>'reason',''));
begin
  perform fn_lock();
  if rs = '' then raise exception 'กรุณาระบุเหตุผลที่ยกเลิก'; end if;
  if s is null or s = 0 then raise exception 'ไม่พบลำดับของรายการ'; end if;
  if k = 'iss' then return fn_cancel_issue(s, rs, p->>'by');
  elsif k in ('rcv','rcv2') then return fn_cancel_receive(s, rs, p->>'by');
  elsif k = 'ret' then return fn_cancel_return(s, rs, p->>'by');
  else raise exception 'ไม่รู้จักประเภทรายการ'; end if;
end $$;

revoke all on function fn_cxl(text,bigint,text,text,text,text,numeric,text,text,jsonb), fn_cancel_receive(bigint,text,text), fn_cancel_issue(bigint,text,text), fn_cancel_return(bigint,text,text),
  fn_req_editable(text), fn_serial_alert(text,text) from public, anon;
grant execute on function rpc_get_next_return_no(text), rpc_check_serial_alert(text,text), rpc_check_serial_alerts(text,text), rpc_get_returnable(), rpc_submit_return_to_stock(jsonb),
  rpc_submit_return(jsonb), rpc_cancel_requisition(jsonb), rpc_edit_requisition(jsonb), rpc_cancel_entry(jsonb) to anon;
