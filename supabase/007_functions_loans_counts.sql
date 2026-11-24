-- =====================================================================
--  007 : ฟังก์ชันชุด 3b  ยืม/คืนยืม · ตรวจนับ · เปิดทางรับพัสดุจากรายการยืม
--  แปลงจาก Code.gs: submitBorrow, returnLoan, closeLoanReplaced, getLoans, getLoansForPart, receiveCore (loanSeq),
--                   getCountLocations, getCountList, submitCount, getCountHistory
-- =====================================================================

-- ปรับยอดค้างยืม และปิดรายการเมื่อครบ ; คืนยอดที่ยังค้าง
create or replace function fn_close_loan_qty(p_seq bigint, p_qty numeric, p_method text, p_doc text, p_text text) returns numeric language plpgsql as $$
declare l loans; v_out numeric;
begin
  select * into l from loans where seq = p_seq;
  v_out := greatest(0, l.qty_open - p_qty);
  update loans set qty_open = v_out, close_method = p_method,
    ref_doc_no = case when coalesce(p_doc,'') <> '' then concat_ws(', ', nullif(l.ref_doc_no,''), p_doc) else l.ref_doc_no end,
    note = concat_ws(' ; ', nullif(l.note,''), fn_thai(fn_today()) || ' ' || p_text),
    status = case when v_out <= 0 then 'ปิดแล้ว' else l.status end,
    closed_date = case when v_out <= 0 then fn_today() else l.closed_date end
  where seq = p_seq;
  return v_out;
end $$;

-- ตรวจรายการยืมที่ยังเปิด และจำนวน
create or replace function fn_loan_out(p_seq bigint, p_qty numeric) returns loans language plpgsql as $$
declare l loans;
begin
  select * into l from loans where seq = p_seq;
  if not found then raise exception 'ไม่พบรายการยืม'; end if;
  if l.status <> 'ยืมอยู่' then raise exception 'รายการยืมนี้ปิดไปแล้ว'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  if p_qty > l.qty_open then raise exception 'เกินจำนวนที่ค้างยืม (ค้าง %)', fn_qtytxt(l.qty_open); end if;
  return l;
end $$;

create or replace function fn_count_overdue_loans() returns int language sql stable as $$
  select count(*)::int from loans where status = 'ยืมอยู่' and due_date < fn_today()
$$;

-- ---------- ยืม ----------
create or replace function rpc_submit_borrow(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare lot record; v_qty numeric := coalesce(fn_num(p->>'qty'),0); btype text := btrim(coalesce(p->>'borrowerType','')); no bigint; due date := fn_date(p->>'dueDate');
begin
  perform fn_lock();
  select * into lot from v_lots where seq = nullif(p->>'lotSeq','')::bigint;
  if not found or lot.remain <= 0 then raise exception 'ไม่พบล็อตในคลังที่เลือก'; end if;
  if v_qty <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  if v_qty > lot.remain then raise exception 'จำนวนในคลังไม่พอ (เหลือ %)', fn_qtytxt(lot.remain); end if;
  if btrim(coalesce(p->>'borrower','')) = '' then raise exception 'กรุณาระบุชื่อผู้ยืม'; end if;
  if due is null then raise exception 'กรุณาระบุวันกำหนดคืน'; end if;
  if btype not in ('ช่าง','TAI','อื่น ๆ') then btype := 'ช่าง'; end if;
  insert into loans(loan_date, part_no, name, serial_no, item_type, qty, unit, qty_open, borrower, borrower_type, reason, due_date, status, lot_seq)
  values (fn_today(), lot.part_no, lot.name, lot.serial_no, lot.item_type, v_qty, lot.unit, v_qty, btrim(p->>'borrower'), btype, btrim(coalesce(p->>'purpose','')), due, 'ยืมอยู่', lot.seq)
  returning seq into no;
  perform fn_log(p->>'by', 'ยืม', '', concat_ws(' | ', lot.part_no, lot.name, 'x' || fn_qtytxt(v_qty), case when lot.serial_no <> '' then 'S/N ' || lot.serial_no end,
    'ผู้ยืม ' || btrim(p->>'borrower') || ' (' || btype || ')', 'กำหนดคืน ' || fn_thai(due), nullif(btrim(coalesce(p->>'purpose','')),'')));
  return jsonb_build_object('ok', true, 'loanNo', no);
end $$;

-- ผู้ยืมนำของมาคืน (ไม่ได้ใช้) -> กลับเข้าคลังทันที
create or replace function rpc_return_loan(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare l loans; q numeric := coalesce(fn_num(p->>'qty'),0); left_ numeric;
begin
  perform fn_lock();
  l := fn_loan_out(nullif(p->>'seq','')::bigint, q);
  if l.lot_seq is null or not exists (select 1 from receipts where seq = l.lot_seq) then raise exception 'ไม่พบล็อตเดิมในคลัง จึงคืนเข้าคลังไม่ได้'; end if;
  update loans set qty_returned_to_stock = qty_returned_to_stock + q where seq = l.seq;
  left_ := fn_close_loan_qty(l.seq, q, 'คืนเข้าคลัง', '', 'คืนเข้าคลัง x' || fn_qtytxt(q));
  perform fn_log(p->>'by', 'คืนของที่ยืม', '', concat_ws(' | ', l.part_no, l.name, 'x' || fn_qtytxt(q), case when l.serial_no <> '' then 'S/N ' || l.serial_no end,
    'ผู้ยืม ' || l.borrower, case when left_ > 0 then 'ค้างคืนอีก ' || fn_qtytxt(left_) else '(ปิดรายการ)' end));
  return jsonb_build_object('ok', true, 'left', left_);
end $$;

-- ผู้ยืม (เช่น TAI) เบิกคืนให้แล้ว : ปิดยืมโดยอ้างเลขเบิก
create or replace function rpc_close_loan_replaced(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare l loans; q numeric := coalesce(fn_num(p->>'qty'),0); v_doc text := fn_docno(p->>'docNo'); rq requisitions; left_ numeric;
begin
  perform fn_lock();
  l := fn_loan_out(nullif(p->>'seq','')::bigint, q);
  select * into rq from requisitions where doc_no = v_doc order by seq limit 1;
  if not found then raise exception 'ไม่พบใบเบิกเลขที่ %', v_doc; end if;
  if rq.cancelled then raise exception 'ใบเบิกนี้ถูกยกเลิกแล้ว'; end if;
  if not (case when l.part_no <> '' then rq.part_no = l.part_no else rq.name = l.name end) then raise exception 'พัสดุในใบเบิกไม่ตรงกับพัสดุที่ยืม'; end if;
  left_ := fn_close_loan_qty(l.seq, q, 'ผู้ยืมเบิกคืนแล้ว', v_doc, 'ผู้ยืมเบิกคืนแล้ว x' || fn_qtytxt(q) || ' (ใบเบิก ' || v_doc || ')');
  perform fn_log(p->>'by', 'ปิดยืม (เบิกคืนแล้ว)', v_doc, concat_ws(' | ', l.part_no, l.name, 'x' || fn_qtytxt(q), 'ผู้ยืม ' || l.borrower,
    case when left_ > 0 then 'ค้างอีก ' || fn_qtytxt(left_) else '(ปิดรายการ)' end));
  return jsonb_build_object('ok', true, 'left', left_);
end $$;

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
      'out', qty_open, 'borrower', borrower, 'btype', borrower_type, 'purpose', reason, 'due', fn_thai(due_date), 'open', is_open, 'late', late, 'status', status,
      'closed', fn_thai(closed_date), 'method', close_method, 'docRef', ref_doc_no, 'note', note,
      'dueMs', case when due_date is not null then (extract(epoch from due_date::timestamp) * 1000)::bigint else 0 end) order by grp, rn), '[]'::jsonb)
  from u
$$;

create or replace function rpc_get_loans_for_part(p_part text, p_name text default '') returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('seq', l.seq, 'serial', l.serial_no, 'out', l.qty_open, 'borrower', l.borrower, 'btype', l.borrower_type,
      'cond', coalesce(v.cond,''), 'location', coalesce(v.location,''), 'expireIso', coalesce(v.expire_date::text,'')) order by l.seq), '[]'::jsonb)
  from loans l left join v_lots v on v.seq = l.lot_seq
  where l.status = 'ยืมอยู่' and l.qty_open > 0 and case when btrim(coalesce(p_part,'')) <> '' then l.part_no = btrim(p_part) else l.name = btrim(coalesce(p_name,'')) end
$$;

-- ---------- รับ (เพิ่มทางรับจากรายการยืม) ----------
create or replace function fn_receive_core(p jsonb) returns jsonb language plpgsql as $$
declare
  v_doc text := fn_docno(p->>'docNo'); v_part text := btrim(coalesce(p->>'part','')); rq record; v_qty numeric := coalesce(fn_num(p->>'qty'),0);
  lot record; have_lot boolean := false; lot_seq bigint := nullif(coalesce(p->>'lotSeq', p->>'lotRow'),'')::bigint;
  ln loans; loan_seq bigint := nullif(p->>'loanSeq','')::bigint; have_loan boolean := false; loan_lot record; have_loan_lot boolean := false;
  itype text; grp text; sn text; v_cond text; v_loc text; v_exp date; rdate date; req_qty numeric; done numeric; remain numeric; inc numeric := null;
  new_seq bigint; v_price numeric := fn_num(p->>'price'); g text := btrim(coalesce(p->>'group','')); iss jsonb := null; seqhint bigint := nullif(coalesce(p->>'reqSeq', p->>'row'),'')::bigint;
  dup_label text;
begin
  select * into lot from v_lots limit 0;
  select * into loan_lot from v_lots limit 0;
  select * into rq from requisitions where doc_no = v_doc and part_no = v_part
   order by (seq = seqhint) desc nulls last, cancelled, (pay_date is not null), seq limit 1;
  if not found then raise exception 'ไม่พบใบเบิกเลขที่ %', v_doc; end if;
  if rq.cancelled then raise exception 'ใบเบิกนี้ถูกยกเลิกแล้ว'; end if;
  if v_qty <= 0 then raise exception 'กรุณากรอกจำนวนที่รับ'; end if;
  if coalesce((p->>'issueNow')::boolean, false) and btrim(coalesce(p->>'tech','')) = '' then
    raise exception 'กรุณากรอกชื่อช่างที่รับพัสดุ (จ่ายทันที)'; end if;
  if lot_seq is not null and lot_seq <> 0 then
    select * into lot from v_lots where seq = lot_seq;
    have_lot := found;
    if not have_lot or not lot.is_free or lot.remain <= 0 or (case when rq.part_no <> '' then lot.part_no <> rq.part_no else lot.name <> rq.name end) then
      raise exception 'ไม่พบล็อตในคลังที่เลือก หรือไม่ตรงกับพัสดุในใบเบิก'; end if;
    if v_qty > lot.remain then raise exception 'จำนวนในล็อตไม่พอ (เหลือ %)', fn_qtytxt(lot.remain); end if;
  else lot_seq := null; end if;
  -- รับจากของที่ยืมไปใช้จริง : ของออกจากคลังตอนยืมแล้ว จึงไม่ตัดล็อตซ้ำ
  if loan_seq is not null and loan_seq <> 0 then
    if lot_seq is not null then raise exception 'เลือกแหล่งที่มาได้อย่างเดียว'; end if;
    select * into ln from loans where seq = loan_seq;
    if not found then raise exception 'ไม่พบรายการยืมที่เลือก'; end if;
    have_loan := true;
    if ln.status <> 'ยืมอยู่' or not (case when rq.part_no <> '' then ln.part_no = rq.part_no else ln.name = rq.name end) then
      raise exception 'รายการยืมไม่ตรงกับพัสดุในใบเบิก หรือปิดไปแล้ว'; end if;
    if v_qty > ln.qty_open then raise exception 'จำนวนที่ยืมค้างอยู่ไม่พอ (เหลือ %)', fn_qtytxt(ln.qty_open); end if;
    if ln.lot_seq is not null then select * into loan_lot from v_lots where seq = ln.lot_seq; have_loan_lot := found; end if;
  end if;
  itype := rq.item_type;
  if g = '-' then grp := '';
  elsif g <> '' then if g <> 'สารเคมี' then raise exception 'กลุ่มพัสดุไม่ถูกต้อง'; end if; grp := g;
  elsif have_lot and lot.item_group <> '' then grp := lot.item_group;
  elsif have_loan_lot and loan_lot.item_group <> '' then grp := loan_lot.item_group;
  else select coalesce((select l2.item_group from v_lots l2 where l2.part_no = rq.part_no and rq.part_no <> '' order by l2.seq desc limit 1), '') into grp; end if;
  sn := coalesce(nullif(btrim(coalesce(p->>'serial','')),''), case when have_lot then lot.serial_no when have_loan then ln.serial_no else '' end);
  if sn <> '' and v_qty <> 1 then
    raise exception 'พัสดุที่มี Serial number ต้องรับทีละ 1 ชิ้น (ไม่มี Serial จึงรับหลายชิ้นพร้อมกันได้)'; end if;
  if sn <> '' then
    select l.label into dup_label from v_lots l where (lot_seq is null or l.seq <> lot_seq) and l.part_no = rq.part_no and upper(l.serial_no) = upper(sn) and l.remain > 0 limit 1;
    if found then raise exception 'Serial % มีอยู่ในคลังแล้ว (%)', sn, dup_label; end if;
    perform 1 from v_lots l where not l.is_free and l.doc_no = v_doc and l.part_no = rq.part_no and upper(l.serial_no) = upper(sn);
    if found then raise exception 'Serial % รับไปแล้วในใบเบิกนี้', sn; end if;
  end if;
  v_cond := coalesce(nullif(btrim(coalesce(p->>'cond','')),''), case when have_lot then lot.cond when have_loan_lot then loan_lot.cond else '' end);
  v_loc  := coalesce(nullif(btrim(coalesce(p->>'location','')),''), case when have_lot then lot.location when have_loan_lot then loan_lot.location else '' end);
  v_exp  := coalesce(fn_date(p->>'expire'), case when have_lot then lot.expire_date when have_loan_lot then loan_lot.expire_date end);
  rdate  := coalesce(fn_date(p->>'receiveDate'), fn_today());

  req_qty := rq.qty;
  select coalesce(sum(c.qty),0) into done from receipts c where c.source = 'ใบเบิก' and c.doc_no = v_doc and c.part_no = rq.part_no;
  if done + v_qty > req_qty then
    req_qty := done + v_qty; update requisitions set qty = req_qty where seq = rq.seq; inc := req_qty; end if;
  remain := req_qty - done - v_qty;

  insert into receipts(doc_no, card_id, part_no, name, serial_no, item_type, item_group, qty, unit, unit_price, cond, notified_date, urgency,
                       due_date, received_date, over_days, tail_no, tci, expire_date, location, receiver, note, source, ref_seq)
  values (v_doc, btrim(coalesce(p->>'cardId','')), rq.part_no, rq.name, sn, itype, grp, v_qty, rq.unit, v_price, v_cond, rq.req_date, rq.urgency,
          fn_due(rq.req_date, rq.urgency), rdate, rdate - fn_due(rq.req_date, rq.urgency), rq.machine, btrim(coalesce(p->>'tci','')), v_exp, v_loc,
          btrim(coalesce(p->>'receiver','')), btrim(coalesce(p->>'remark','')), 'ใบเบิก', lot_seq)
  returning seq into new_seq;
  if remain <= 0 then update requisitions set pay_date = rdate where seq = rq.seq; end if;
  if lot_seq is not null and lot_seq <> 0 then
    insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, tail_no, technician, note, created_by)
    select rdate, v_doc, l.seq, l.part_no, l.name, l.serial_no, v_qty, l.unit, '', '', 'โอนเข้าใบเบิก ' || v_doc, btrim(coalesce(p->>'by','')) from v_lots l where l.seq = lot_seq;
  end if;
  if have_loan then
    perform fn_close_loan_qty(ln.seq, v_qty, 'ใช้งานแล้ว (เบิก)', v_doc, 'ใช้งานจริง x' || fn_qtytxt(v_qty) || ' (ปิดด้วยใบเบิก ' || v_doc || ')');
  end if;
  perform fn_log(p->>'by', 'รับ', v_doc, concat_ws(' | ', rq.part_no, rq.name, 'x' || fn_qtytxt(v_qty), case when sn <> '' then 'S/N ' || sn end,
    case when lot_seq is not null and lot_seq <> 0 then '(จากล็อต ' || lot_seq || ')' when have_loan then '(ปิดยืมเลขที่ ' || ln.seq || ')' end,
    case when inc is not null then 'เพิ่มจำนวนเบิกเป็น ' || fn_qtytxt(inc) end,
    case when btrim(coalesce(p->>'receiver','')) <> '' then 'ผู้รับ ' || btrim(p->>'receiver') end));
  if coalesce((p->>'issueNow')::boolean, false) then
    iss := fn_issue_core(jsonb_build_object('seq', new_seq, 'docNo', v_doc, 'tech', p->>'tech', 'tail', p->>'tail', 'remark', p->>'issueRemark',
                          'payDate', coalesce(p->>'payDate', fn_today()::text), 'by', p->>'by'));
  end if;
  return jsonb_build_object('remain', remain, 'increasedTo', inc, 'issued', iss is not null, 'closed', remain <= 0, 'rcvSeq', new_seq);
end $$;

-- ---------- ตรวจนับ ----------
create or replace function fn_next_count_no(d date) returns text language sql stable as $$
  select 'ตน.' || fn_fiscal_yy(d) || '-' || lpad((coalesce(max(substring(count_no from '^ตน\.\d{2}-(\d+)$')::int), 0) + 1)::text, 3, '0')
  from counts where count_no ~ ('^ตน\.' || fn_fiscal_yy(d) || '-\d+$')
$$;

create or replace function fn_count_session(p_no text) returns jsonb language sql stable as $$
  with r as (select * from counts where count_no = p_no order by id),
  f as (select * from r order by id limit 1)
  select jsonb_build_object('docNo', p_no, 'date', fn_thai(f.count_date), 'loc', f.location, 'label', coalesce(nullif(f.location,''), '(ไม่ระบุที่เก็บ)'),
    'by', f.counter, 'witness', f.witness,
    'adjusted', exists (select 1 from r where result in ('ปรับยอดแล้ว','ตัดจ่ายแล้ว')),
    'diffs', (select count(*) from r where diff <> 0),
    'reason', coalesce((select note from r where diff <> 0 and note <> '' order by id limit 1), ''),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('part', part_no, 'name', name, 'serial', serial_no, 'type', item_type, 'unit', unit,
              'sys', qty_system, 'cnt', qty_counted, 'diff', diff, 'res', result, 'note', note) order by id), '[]'::jsonb) from r))
  from f
$$;

create or replace function rpc_get_count_locations(p_grp text default '') returns jsonb language sql stable security definer set search_path = public as $$
  with lt as (select location, max(count_date) d from counts group by location),
  g as (select l.location, count(*) lots, sum(l.remain) qty from v_lots l where l.remain > 0 and (coalesce(p_grp,'') = '' or l.item_group = p_grp) group by l.location)
  select coalesce(jsonb_agg(jsonb_build_object('loc', g.location, 'label', coalesce(nullif(g.location,''), '(ไม่ระบุที่เก็บ)'), 'lots', g.lots, 'qty', g.qty,
         'last', fn_thai(lt.d)) order by (g.location = ''), g.location collate "C"), '[]'::jsonb)
  from g left join lt on lt.location = g.location
$$;

create or replace function rpc_get_count_list(p_loc text, p_grp text default '') returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('loc', coalesce(p_loc,''), 'grp', coalesce(p_grp,''), 'label', coalesce(nullif(p_loc,''), '(ไม่ระบุที่เก็บ)'), 'date', fn_thai(fn_today()),
    'items', coalesce((select jsonb_agg(jsonb_build_object('seq', seq, 'part', part_no, 'name', name, 'serial', serial_no, 'type', item_type, 'unit', unit, 'qty', remain,
        'cond', cond, 'label', label, 'grp', item_group) order by part_no collate "C", serial_no collate "C", seq)
      from v_lots where remain > 0 and location = coalesce(p_loc,'') and (coalesce(p_grp,'') = '' or item_group = p_grp)), '[]'::jsonb))
$$;

create or replace function rpc_submit_count(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  loc text := btrim(coalesce(p->>'location','')); by_ text := btrim(coalesce(p->>'by','')); wit text := btrim(coalesce(p->>'witness',''));
  adj boolean := coalesce((p->>'adjust')::boolean, false); reason text := btrim(coalesce(p->>'reason','')); use_mode boolean := coalesce((p->>'useMode')::boolean, false);
  rows jsonb := '[]'::jsonb; it jsonb; x jsonb; r jsonb; lot record; c numeric; d numeric; q numeric; typ text; v_no text; tag text; today date := fn_today();
  res text; note text; used boolean; newseq bigint; kind text; n_acts int := 0; n_nonuse int := 0;
begin
  perform fn_lock();
  if by_ = '' then raise exception 'กรุณาตั้งชื่อผู้ใช้ก่อนบันทึก'; end if;
  if jsonb_array_length(coalesce(p->'items','[]')) = 0 and jsonb_array_length(coalesce(p->'extras','[]')) = 0 then raise exception 'ไม่มีรายการตรวจนับ'; end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items','[]')) loop
    select * into lot from v_lots where seq = nullif(it->>'seq','')::bigint;
    if not found or lot.remain <= 0 then raise exception 'ไม่พบพัสดุลำดับรับ % ในคลัง (อาจมีการจ่าย/ย้ายระหว่างนับ) กรุณาเริ่มนับใหม่', it->>'seq'; end if;
    if lot.location <> loc then raise exception '% ถูกย้ายไปที่ % ระหว่างนับ กรุณาเริ่มนับใหม่', lot.part_no, coalesce(nullif(lot.location,''), '(ไม่ระบุที่เก็บ)'); end if;
    if coalesce(fn_num(it->>'sys'), -1) <> lot.remain then
      raise exception 'ยอดในระบบของ % เปลี่ยนไประหว่างนับ (ตอนนี้ %) กรุณาเริ่มนับใหม่', lot.part_no || case when lot.serial_no <> '' then ' S/N ' || lot.serial_no else '' end, fn_qtytxt(lot.remain); end if;
    if nullif(btrim(coalesce(it->>'counted','')),'') is null then raise exception 'ยังไม่ได้กรอกจำนวนที่นับได้ของ %', lot.part_no; end if;
    c := fn_num(it->>'counted');
    if c < 0 then raise exception 'จำนวนที่นับได้ต้องไม่ติดลบ (%)', lot.part_no; end if;
    if lot.serial_no <> '' and c > 1 then raise exception 'พัสดุที่มี Serial number นับได้ไม่เกิน 1 ชิ้น (% S/N %)', lot.part_no, lot.serial_no; end if;
    d := c - lot.remain;
    rows := rows || jsonb_build_array(jsonb_build_object('lot', lot.seq, 'part', lot.part_no, 'name', lot.name, 'serial', lot.serial_no, 'type', lot.item_type, 'unit', lot.unit,
        'sys', lot.remain, 'cnt', c, 'diff', d, 'note', btrim(coalesce(it->>'note','')), 'cond', lot.cond, 'grp', lot.item_group, 'extra', false));
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p->'extras','[]')) loop
    q := coalesce(fn_num(x->>'qty'), 0); typ := btrim(coalesce(x->>'type',''));
    if btrim(coalesce(x->>'name','')) = '' then raise exception 'รายการที่พบเพิ่ม: กรุณากรอกชื่อพัสดุ'; end if;
    if q <= 0 then raise exception 'รายการที่พบเพิ่ม: จำนวนต้องมากกว่า 0'; end if;
    if typ not in ('','LRU','SP','LRU(TCI)','SP(TCI)') then raise exception 'ประเภทพัสดุไม่ถูกต้อง'; end if;
    if btrim(coalesce(x->>'serial','')) <> '' and q <> 1 then raise exception 'พัสดุที่มี Serial number ต้องจำนวน 1 ต่อ 1 Serial'; end if;
    rows := rows || jsonb_build_array(jsonb_build_object('lot', null, 'part', btrim(coalesce(x->>'part','')), 'name', btrim(x->>'name'), 'serial', btrim(coalesce(x->>'serial','')),
        'type', coalesce(nullif(typ,''), case when btrim(coalesce(x->>'serial','')) <> '' then 'LRU' else 'SP' end), 'unit', coalesce(nullif(btrim(coalesce(x->>'unit','')),''), 'EA'),
        'sys', 0, 'cnt', q, 'diff', q, 'note', btrim(coalesce(x->>'note','')), 'cond', btrim(coalesce(x->>'cond','')), 'grp', '', 'extra', true));
  end loop;
  -- ตัวนับ : จำนวนที่ต้องปรับ และที่ไม่ใช่การตัดจ่ายสารเคมี
  for r in select * from jsonb_array_elements(rows) loop
    if (r->>'diff')::numeric <> 0 then
      n_acts := n_acts + 1;
      if not (use_mode and (r->>'diff')::numeric < 0 and (r->>'grp') = 'สารเคมี' and not (r->>'extra')::boolean) then n_nonuse := n_nonuse + 1; end if;
    end if;
  end loop;
  if adj and n_nonuse > 0 and reason = '' then raise exception 'กรุณาระบุเหตุผลการปรับยอด'; end if;

  v_no := fn_next_count_no(today);
  tag := 'ปรับยอดตรวจนับ ' || v_no || case when reason <> '' then ': ' || reason else '' end;

  for r in select * from jsonb_array_elements(rows) loop
    d := (r->>'diff')::numeric; used := false; newseq := null;
    if adj and d <> 0 then
      if (r->>'extra')::boolean then
        insert into receipts(part_no, name, serial_no, item_type, item_group, qty, unit, cond, received_date, location, note, source)
        values (r->>'part', r->>'name', r->>'serial', r->>'type', '', abs(d), r->>'unit', r->>'cond', today, loc, 'พบเกินจากตรวจนับ ' || v_no || case when reason <> '' then ': ' || reason else '' end, 'ยอดยกมา')
        returning seq into newseq;
      elsif d < 0 then
        if use_mode and (r->>'grp') = 'สารเคมี' then
          insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, note, created_by)
          values (today, 'ตัดจ่ายตามตรวจนับ', (r->>'lot')::bigint, r->>'part', r->>'name', r->>'serial', abs(d), r->>'unit', 'ช่างหยิบใช้เอง (ตัดจ่ายตามตรวจนับ ' || v_no || ')', by_);
          used := true;
        else
          insert into issues(issue_date, doc_no, receipt_seq, part_no, name, serial_no, qty, unit, note, created_by)
          values (today, 'ปรับยอดตรวจนับ', (r->>'lot')::bigint, r->>'part', r->>'name', r->>'serial', abs(d), r->>'unit', tag, by_);
        end if;
      else
        insert into receipts(part_no, name, serial_no, item_type, item_group, qty, unit, cond, received_date, location, note, source)
        values (r->>'part', r->>'name', '', r->>'type', r->>'grp', d, r->>'unit', r->>'cond', today, loc, 'พบเกินจากตรวจนับ ' || v_no || case when reason <> '' then ': ' || reason else '' end, 'ยอดยกมา')
        returning seq into newseq;
      end if;
    end if;
    res := case when d = 0 then 'ตรง' when adj then (case when used then 'ตัดจ่ายแล้ว' else 'ปรับยอดแล้ว' end) else 'ไม่ปรับยอด' end;
    note := concat_ws(' | ', nullif(case when used then 'ช่างหยิบใช้เอง (ตัดจ่าย)' when d <> 0 then reason else '' end, ''), nullif(r->>'note',''));
    insert into counts(count_no, count_date, location, receipt_seq, part_no, name, serial_no, item_type, unit, qty_system, qty_counted, diff, result, note, counter, witness, round_id)
    values (v_no, today, loc, coalesce(newseq, nullif(r->>'lot','')::bigint), r->>'part', r->>'name', r->>'serial', r->>'type', r->>'unit', (r->>'sys')::numeric, (r->>'cnt')::numeric, d, res, note, by_, wit, nullif(p->>'roundId','')::bigint);
  end loop;
  perform fn_log(by_, 'ตรวจนับ', v_no, concat_ws(' | ', coalesce(nullif(loc,''), '(ไม่ระบุที่เก็บ)'), jsonb_array_length(rows) || ' รายการ', 'ผลต่าง ' || n_acts,
    case when n_acts > 0 then case when adj then 'ปรับยอดแล้ว: ' || reason else 'ไม่ปรับยอด' end end));
  return fn_count_session(v_no);
end $$;

create or replace function rpc_get_count_history(p_limit int default 12) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(fn_count_session(no) order by m desc), '[]'::jsonb) from (
    select count_no no, max(id) m from (select * from counts order by id desc limit 600) x where count_no <> '' group by count_no order by m desc limit coalesce(nullif(p_limit,0), 12)) t
$$;

revoke all on function fn_close_loan_qty(bigint,numeric,text,text,text), fn_loan_out(bigint,numeric), fn_count_overdue_loans(), fn_next_count_no(date), fn_count_session(text) from public, anon;
grant execute on function rpc_submit_borrow(jsonb), rpc_return_loan(jsonb), rpc_close_loan_replaced(jsonb), rpc_get_loans(), rpc_get_loans_for_part(text,text),
  rpc_get_count_locations(text), rpc_get_count_list(text,text), rpc_submit_count(jsonb), rpc_get_count_history(int) to anon;
