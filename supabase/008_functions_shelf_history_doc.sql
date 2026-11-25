-- =====================================================================
--  008 : ฟังก์ชันชุด 3c-1  ผังที่จัดเก็บ · bootstrap · ประวัติ · ข้อมูลเอกสาร TAI · สถานะ TAI · ตรวจ Serial ซ้ำ · ตรวจสุขภาพระบบ · สถานะชุด FLY AWAY KIT
--  แปลงจาก Code.gs: getShelfMap, addShelfSlots, removeShelfSlot, fillShelfGaps, getBootstrap, getHistory, getAwaitingDoc, getDocInfo, saveDocInfo,
--                   scanDuplicateSerials, getSystemHealth, computeKitStatus_, taiOf_
-- =====================================================================

-- ---------- ตัวช่วย ----------
create or replace function fn_nat(s text) returns text language sql immutable as $$
  select coalesce(string_agg(case when m[1] ~ '^\d' then lpad(m[1], 12, '0') else m[1] end, ''), '') from regexp_matches(coalesce(s,''), '\d+|\D+', 'g') m
$$;

create or replace function fn_line_date(d date) returns text language sql immutable as $$
  select case when d is null then '' else extract(day from d)::int || ' ' ||
    (array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'])[extract(month from d)::int] || ' ' ||
    lpad(((extract(year from d)::int + 543) % 100)::text, 2, '0') end
$$;
-- หมายเหตุ: lineDate_ เดิมไม่เติม 0 นำหน้าปี (เช่น 5 → "5") แต่ปีพ.ศ. 25xx ลงท้ายสองหลักเสมอ จึงเหมือนกัน

create or replace function fn_ts(t timestamptz) returns text language sql stable as $$
  select case when t is null then '' else fn_thai((t at time zone 'Asia/Bangkok')::date) || ' ' || to_char(t at time zone 'Asia/Bangkok', 'HH24:MI') end
$$;

create or replace function fn_tdate(v text) returns date language sql immutable as $$
  select case when v ~ '^\d{4}-\d{2}-\d{2}$' then v::date end
$$;

-- ข้อมูล TAI ของแถวใบเบิก สำหรับแสดงผล ; null ถ้าไม่มี
create or replace function fn_tai_obj(r requisitions, inst date) returns jsonb language plpgsql stable as $$
declare stage text := coalesce(r.tai_status,''); dt date := fn_tdate(r.tai_due); asof date := (r.tai_asof at time zone 'Asia/Bangkok')::date;
        today date := fn_today(); label text; lvl text := ''; stale boolean;
begin
  if stage = '' then return null; end if;
  label := stage;
  if stage in ('นำจ่ายคลังฝูงแล้ว','นำจ่ายบางส่วน') then
    label := stage || case when dt is not null then ' ' || fn_line_date(dt) else '' end;
    lvl := case when stage = 'นำจ่ายคลังฝูงแล้ว' then 'bad' else 'warn' end;
    if stage = 'นำจ่ายคลังฝูงแล้ว' then label := label || ' · แต่ยังไม่รับในระบบ'; end if;
  elsif stage = 'สั่งซื้อแล้ว' then
    if dt is not null and dt < today then label := 'เลยกำหนดส่ง ' || (today - dt) || ' วัน (กำหนด ' || fn_line_date(dt) || ')'; lvl := 'bad';
    else label := 'สั่งซื้อแล้ว' || case when dt is not null then ' · คาดส่ง ' || fn_line_date(dt) else '' end; end if;
    if dt is not null and inst is not null and dt > inst then label := label || ' · ช้ากว่าวันติดตั้ง'; lvl := 'bad'; end if;
  end if;
  stale := asof is not null and (today - asof) > 10;
  if stale and lvl = '' then lvl := 'warn'; end if;
  return jsonb_build_object('stage', stage, 'label', label, 'level', lvl, 'note', coalesce(r.tai_note,''), 'po', coalesce(r.tai_po,''), 'supplier', coalesce(r.tai_supplier,''),
    'asof', fn_line_date(asof), 'stale', stale);
end $$;

-- รายการใบเบิกที่รอรับ (เพิ่มสถานะ TAI)
create or replace function rpc_get_pending_receive() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x - '_k' order by x->>'_k' desc), '[]'::jsonb) from (
    select jsonb_build_object('_k', lpad(r.seq::text, 12, '0'), 'row', r.seq, 'docNo', r.doc_no, 'part', r.part_no, 'name', r.name, 'qty', r.qty, 'unit', r.unit,
      'date', fn_thai(r.req_date), 'machine', r.machine, 'urgency', r.urgency, 'issue', r.issue_text, 'due', fn_thai(fn_due(r.req_date, r.urgency)),
      'type', r.item_type, 'received', g.done, 'remain', r.qty - g.done, 'tai', fn_tai_obj(r, r.tci_install_date)) as x
    from requisitions r
    cross join lateral (select coalesce(sum(c.qty),0) as done from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no) g
    where r.pay_date is null and not r.cancelled and r.qty - g.done > 0
  ) t
$$;

-- ค้นหา : แสดงสถานะ TAI ในรายการรอรับ
do $$ declare d text;
begin
  d := pg_get_functiondef('rpc_search_parts(jsonb)'::regprocedure);
  d := replace(d, $q$'tai', '')$q$, $q$'tai', coalesce(x->'tai'->>'label', ''))$q$);
  execute d;
end $$;

-- ---------- ผังที่จัดเก็บ ----------
create or replace function fn_shelf_parse(p_loc text) returns jsonb language plpgsql immutable as $$
declare s text := btrim(regexp_replace(coalesce(p_loc,''), '\s+', ' ', 'g')); m text[]; i int; g text;
begin
  m := regexp_match(s, '^(\d+)\s*([A-Za-z]{1,2})\s*(\d+)(?:\s*-\s*(\d+))?$');
  if m is not null then
    return jsonb_build_object('kind','shelf','gkey','S:' || m[1]::bigint::text,'group','Shelf ' || m[1]::bigint::text,'row',upper(m[2]),
      'col', m[3] || coalesce('-' || m[4], ''), 'slot', upper(m[2]) || m[3] || coalesce('-' || m[4], ''));
  end if;
  if position('-' in s) > 0 then
    i := length(s) - position('-' in reverse(s)) + 1;
    if i > 1 and i < length(s) then
      g := btrim(left(s, i - 1));
      return jsonb_build_object('kind','dash','gkey','G:' || upper(g),'group',g,'row','','col','','slot',btrim(substr(s, i + 1)));
    end if;
  end if;
  return jsonb_build_object('kind','dash','gkey','G:อื่น ๆ','group','อื่น ๆ','row','','col','','slot',s);
end $$;

create or replace function rpc_get_shelf_map() returns jsonb language sql stable security definer set search_path = public as $$
with defd as (
  select distinct on (fn_shelf_key(location)) fn_shelf_key(location) k, location loc, note from shelf_cells where btrim(location) <> '' order by fn_shelf_key(location), id),
lots as (select l.*, fn_shelf_key(l.location) k from v_lots l where l.remain > 0),
cl as (select k, (array_agg(location order by seq))[1] loc from lots where k <> '' group by k),
cells as (select coalesce(d.k, c.k) k, coalesce(d.loc, c.loc) loc, (d.k is not null) defined, coalesce(d.note,'') note from defd d full join cl c on c.k = d.k),
cp as (select cells.*, fn_shelf_parse(loc) p from cells),
items as (
  select k, jsonb_agg(jsonb_build_object('seq', seq, 'part', part_no, 'name', name, 'serial', serial_no, 'qty', remain, 'unit', unit, 'type', coalesce(item_type,''),
    'cond', coalesce(cond,''), 'doc', label, 'kit', fn_kit_of(tail_no)) order by seq) it, count(*) n from lots where k <> '' group by k),
cc as (select cp.*, coalesce(i.it, '[]'::jsonb) it, coalesce(i.n, 0) n from cp left join items i on i.k = cp.k),
grp as (
  select p->>'gkey' gkey, p->>'group' gname, p->>'kind' kind,
    jsonb_agg(jsonb_build_object('loc', loc, 'slot', p->>'slot', 'row', p->>'row', 'col', p->>'col', 'defined', defined, 'note', note, 'items', it)
              order by fn_nat(p->>'row') collate "C", fn_nat(coalesce(nullif(p->>'col',''), p->>'slot')) collate "C") cells,
    count(*) nc, count(*) filter (where n > 0) used
  from cc group by 1, 2, 3),
unp as (
  select coalesce(jsonb_agg(jsonb_build_object('seq', seq, 'part', part_no, 'name', name, 'serial', serial_no, 'qty', remain, 'unit', unit, 'type', coalesce(item_type,''),
    'cond', coalesce(cond,''), 'doc', label, 'kit', fn_kit_of(tail_no)) order by seq), '[]'::jsonb) u, count(*) n from lots where k = '')
select jsonb_build_object(
  'groups', coalesce((select jsonb_agg(jsonb_build_object('name', gname, 'kind', kind, 'cells', cells) order by (kind = 'dash'), fn_nat(gkey) collate "C") from grp), '[]'::jsonb),
  'unplaced', (select u from unp),
  'stats', jsonb_build_object('cells', coalesce((select sum(nc) from grp), 0), 'used', coalesce((select sum(used) from grp), 0),
      'empty', coalesce((select sum(nc - used) from grp), 0), 'items', (select count(*) from lots), 'unplaced', (select n from unp),
      'defined', (select count(*) from shelf_cells where btrim(location) <> '')),
  'ts', (extract(epoch from clock_timestamp()) * 1000)::bigint)
$$;

create or replace function fn_add_shelf_slots(p_list text[], p_by text) returns jsonb language plpgsql as $$
declare add_ text[]; n int; have int; ps jsonb; l text;
begin
  select coalesce(array_agg(x order by o), '{}') into add_ from (
    select distinct on (fn_shelf_key(x)) x, o from unnest(p_list) with ordinality t(x, o)
    where btrim(x) <> '' and not exists (select 1 from shelf_cells s where fn_shelf_key(s.location) = fn_shelf_key(x)) order by fn_shelf_key(x), o) z;
  select count(*) into have from shelf_cells where btrim(location) <> '';
  if have + coalesce(array_length(add_,1),0) > 5000 then raise exception 'ผังมีช่องได้ไม่เกิน 5000 ช่อง'; end if;
  foreach l in array add_ loop
    ps := fn_shelf_parse(l);
    insert into shelf_cells(group_name, slot, location, note) values (ps->>'group', ps->>'slot', btrim(l), '');
  end loop;
  n := coalesce(array_length(add_,1),0);
  if n > 0 then
    perform fn_log(p_by, 'เพิ่มช่องในผัง', '', array_to_string(add_[1:6], ', ') || case when n > 6 then ' ... รวม ' || n || ' ช่อง' else '' end);
  end if;
  return jsonb_build_object('ok', true, 'added', n, 'skipped', coalesce(array_length(p_list,1),0) - n);
end $$;

create or replace function rpc_add_shelf_slots(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare list text[] := '{}'; g text := btrim(coalesce(p->>'group','')); a int; b int; rows_txt text; rws text[]; rg text[]; r text; i int;
begin
  perform fn_lock();
  if jsonb_typeof(p->'locs') = 'array' and jsonb_array_length(p->'locs') > 0 then
    select coalesce(array_agg(btrim(x)), '{}') into list from jsonb_array_elements_text(p->'locs') x where btrim(x) <> '';
  else
    if g = '' then raise exception 'กรุณาระบุชื่อกลุ่ม/ตู้/ชั้น เช่น B2 หรือหมายเลข Shelf เช่น 1'; end if;
    a := floor(nullif(p->>'from','')::numeric); b := floor(nullif(p->>'to','')::numeric);
    if a is null or b is null or a < 0 or b < a then raise exception 'ช่วงช่องไม่ถูกต้อง (ตั้งแต่ ≤ ถึง)'; end if;
    if b - a > 5000 then raise exception 'ผังมีช่องได้ไม่เกิน 5000 ช่อง'; end if;
    rows_txt := upper(regexp_replace(coalesce(p->>'rows',''), '\s+', '', 'g'));
    if rows_txt <> '' then
      rg := regexp_match(rows_txt, '^([A-Z])-([A-Z])$');
      if rg is not null then
        rws := array(select chr(k) from generate_series(ascii(rg[1]), ascii(rg[2])) k);
      else
        rws := array(select x from regexp_split_to_table(rows_txt, '[,;]|(?=[A-Z])') x where x <> '');
      end if;
      if coalesce(array_length(rws,1),0) = 0 or array_length(rws,1) > 26 then raise exception 'แถวไม่ถูกต้อง เช่น A-D'; end if;
      foreach r in array rws loop for i in a..b loop list := list || (g || r || i); end loop; end loop;
    else
      for i in a..b loop list := list || (g || '-' || i); end loop;
    end if;
  end if;
  return fn_add_shelf_slots(list, p->>'by');
end $$;

create or replace function rpc_remove_shelf_slot(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare k text := fn_shelf_key(p->>'loc'); n int;
begin
  perform fn_lock();
  if exists (select 1 from v_lots where remain > 0 and fn_shelf_key(location) = k) then raise exception 'ช่องนี้ยังมีพัสดุอยู่ ย้ายออกก่อน'; end if;
  delete from shelf_cells where fn_shelf_key(location) = k;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'ช่องนี้ไม่ได้อยู่ในรายการผัง'; end if;
  perform fn_log(p->>'by', 'ลบช่องออกจากผัง', '', btrim(coalesce(p->>'loc','')));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rpc_fill_shelf_gaps(p jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare mp jsonb; g jsonb; list text[] := '{}'; m text; cols int[]; codes int[]; lo int; hi int; r0 int; r1 int; r int; i int; ok boolean; nums int[];
begin
  perform fn_lock();
  mp := rpc_get_shelf_map();
  for g in select * from jsonb_array_elements(mp->'groups') loop
    if g->>'kind' = 'shelf' then
      m := (regexp_match(g->>'name', '(\d+)'))[1];
      if m is null then continue; end if;
      cols := array(select (c2->>'col')::int from jsonb_array_elements(g->'cells') c2 where c2->>'col' ~ '^\d+$');
      if coalesce(array_length(cols,1),0) = 0 then continue; end if;
      select min(x), max(x) into lo, hi from unnest(cols) x;
      codes := array(select ascii(c2->>'row') from jsonb_array_elements(g->'cells') c2);
      select min(x), max(x) into r0, r1 from unnest(codes) x;
      select bool_and(length(c2->>'row') = 1) into ok from jsonb_array_elements(g->'cells') c2;
      if hi - lo > 60 or r1 - r0 > 25 or not coalesce(ok, false) then continue; end if;
      for r in r0..r1 loop for i in lo..hi loop list := list || (m || chr(r) || i); end loop; end loop;
    else
      nums := array(select (c2->>'slot')::int from jsonb_array_elements(g->'cells') c2 where c2->>'slot' ~ '^\d{1,9}$');
      if coalesce(array_length(nums,1),0) < 1 or g->>'name' = 'อื่น ๆ' then continue; end if;
      select min(x), max(x) into lo, hi from unnest(nums) x;
      if hi - lo > 200 then continue; end if;
      for i in lo..hi loop list := list || ((g->>'name') || '-' || i); end loop;
    end if;
  end loop;
  return fn_add_shelf_slots(list, p->>'by');
end $$;

-- ---------- bootstrap ----------
create or replace function rpc_get_bootstrap() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'today', to_char(fn_today(), 'YYYY-MM-DD'),
    'parts', coalesce((select jsonb_agg(jsonb_build_object('part', part, 'name', coalesce(nm,''), 'unit', coalesce(un,'')) order by part collate "C") from (
        select part_no part, (array_agg(name order by o, seq) filter (where name <> ''))[1] nm, (array_agg(unit order by o, seq) filter (where unit <> '' and o < 3))[1] un
        from (select 1 o, seq, part_no, name, unit from requisitions union all select 2, seq, part_no, name, unit from receipts
              union all select 3, seq, part_no, name, '' from returns_out) s where part_no <> '' group by part_no) t), '[]'::jsonb),
    'users', coalesce((select jsonb_agg(jsonb_build_object('rank', "rank", 'fullName', full_name, 'position', "position") order by id) from requesters where full_name <> ''), '[]'::jsonb),
    'techs', coalesce((select jsonb_agg(name order by id) from technicians where name <> ''), '[]'::jsonb),
    'receivers', coalesce((select jsonb_agg(name order by id) from receivers where name <> ''), '[]'::jsonb),
    'loansOverdue', fn_count_overdue_loans(), 'recon', 0, 'synced', 0, 'changes', '[]'::jsonb, 'migrated', '')
$$;

-- ---------- ประวัติ ----------
create or replace function rpc_get_history(p_kind text, p_limit int default 100) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare lim int := greatest(1, coalesce(nullif(p_limit,0), 100)); hdr jsonb; rws jsonb; pd jsonb;
begin
  if p_kind = 'req' then
    hdr := '["ลำดับ","หมายเลขการเบิก","Part number","ชื่อ","จำนวน","หน่วยนับ","วันที่เบิก","วันที่จ่าย","เครื่อง","ความเร่งด่วน","ข้อขัดข้อง","ยศผู้เบิก","ชื่อ-สกุลผู้เบิก","ตำแหน่งผู้เบิก","ประเภทพัสดุ","เหตุผลยกเลิก","วันที่ติดตั้ง (TCI)","สถานะ TAI","หมายเหตุ TAI","P.O. TAI","ผู้จัดหา TAI","กำหนดส่ง/วันนำจ่าย TAI","ข้อมูล TAI ณ วันที่"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(seq::text, doc_no, part_no, name, fn_qtytxt(qty), unit, fn_thai(req_date),
        case when cancelled then 'ยกเลิก' when pay_date is null then 'ค้างจ่าย' else fn_thai(pay_date) end, machine, urgency, issue_text, req_rank, req_name, req_position, item_type,
        cancel_reason, fn_thai(tci_install_date), tai_status, tai_note, tai_po, tai_supplier, coalesce(fn_thai(fn_tdate(tai_due)), ''), fn_thai((tai_asof at time zone 'Asia/Bangkok')::date))
        order by seq desc), '[]'::jsonb) into rws from (select * from requisitions order by seq desc limit lim) t;
    return jsonb_build_object('headers', hdr, 'rows', rws, 'paid', (select coalesce(jsonb_agg(false), '[]'::jsonb) from jsonb_array_elements(rws)), 'skipped', 0);
  elsif p_kind in ('rcv', 'rcv2') then
    hdr := '["ลำดับรับ","เลขเอกสารการเบิก","card ID","Part number","ชื่อพัสดุ","serial number","ประเภทพัสดุ","จำนวน","หน่วยนับ","ราคา/หน่วย","ราคารวม","COND","วันที่แจ้ง","ความเร่งด่วน","วันกำหนดส่งพัสดุ","วันที่รับ","วันที่เกิน","TAIL No.","TCI","หมดอายุ","LOCATION","ผู้รับ","หมายเหตุ","แหล่งที่มา","อ้างอิง","กลุ่ม"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(r.seq::text, r.doc_no, r.card_id, r.part_no, r.name, r.serial_no, r.item_type, fn_qtytxt(r.qty), r.unit, coalesce(fn_qtytxt(r.unit_price), ''),
        case when r.unit_price is null then '' else coalesce(fn_qtytxt(r.total_price), '') end, r.cond, fn_thai(r.notified_date), r.urgency, fn_thai(r.due_date), fn_thai(r.received_date), coalesce(fn_qtytxt(r.over_days), ''), r.tail_no, r.tci,
        fn_thai(r.expire_date), r.location, r.receiver, r.note, r.source, coalesce(r.ref_seq::text, ''), r.item_group) order by r.seq desc),
      '[]'::jsonb),
      coalesce(jsonb_agg(coalesce(l.remain <= 0 and l.issued > 0, false) order by r.seq desc), '[]'::jsonb) into rws, pd
    from (select * from receipts where (source = 'คืนเข้าคลัง') = (p_kind = 'rcv2') order by seq desc limit lim) r left join v_lots l on l.seq = r.seq;
    return jsonb_build_object('headers', hdr, 'rows', rws, 'paid', pd, 'skipped', 0);
  elsif p_kind = 'iss' then
    hdr := '["ลำดับจ่าย","วันที่จ่าย","เลขเอกสารการเบิก","ลำดับรับ (อ้างอิง)","Part number","ชื่อพัสดุ","serial number","จำนวน","หน่วยนับ","TAIL No.","จ่ายให้ช่าง","หมายเหตุ","ผู้บันทึก"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(seq::text, fn_thai(issue_date), doc_no, coalesce(receipt_seq::text, ''), part_no, name, serial_no, fn_qtytxt(qty), unit, tail_no, technician, note, created_by) order by seq desc), '[]'::jsonb),
           coalesce(jsonb_agg(technician <> '' order by seq desc), '[]'::jsonb) into rws, pd
    from (select * from issues order by seq desc limit lim) t;
    return jsonb_build_object('headers', hdr, 'rows', rws, 'paid', pd, 'skipped', 0);
  elsif p_kind = 'ret' then
    hdr := '["ลำดับ","Part number","ชื่อ","จำนวน","serial number ส่งคืน","serial number ที่ใส่","ผู้รับ","ผู้ส่ง","เครื่อง","ข้อขัดข้อง","หมายเหตุ","วันที่บันทึก","ที่หนังสือ","สภาพพัสดุ"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(seq::text, part_no, name, fn_qtytxt(qty), serial_out, serial_in, receiver, sender, machine, issue_text, note, fn_ts(recorded_at), letter_no, condition) order by seq desc), '[]'::jsonb) into rws
    from (select * from returns_out order by seq desc limit lim) t;
    return jsonb_build_object('headers', hdr, 'rows', rws, 'paid', (select coalesce(jsonb_agg(false), '[]'::jsonb) from jsonb_array_elements(rws)), 'skipped', 0);
  elsif p_kind = 'log' then
    hdr := '["เวลา","ผู้ใช้งาน","อีเมล","การกระทำ","เลขเอกสารการเบิก","รายละเอียด"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(fn_ts(at), user_name, '', action, doc_no, detail) order by id desc), '[]'::jsonb) into rws
    from (select * from activity_log order by id desc limit lim) t;
    return jsonb_build_object('headers', hdr, 'rows', rws, 'paid', (select coalesce(jsonb_agg(false), '[]'::jsonb) from jsonb_array_elements(rws)), 'skipped', 0);
  end if;
  raise exception 'ไม่รู้จักชีท';
end $$;

-- ---------- รอเอกสารจาก TAI (card ID ว่าง) ----------
create or replace function fn_doc_row(p_seq bigint) returns jsonb language sql stable as $$
  select jsonb_build_object('seq', r.seq, 'docNo', r.doc_no, 'part', r.part_no, 'name', r.name, 'serial', r.serial_no, 'type', r.item_type, 'unit', r.unit, 'qty', r.qty,
    'remain', greatest(l.remain, 0), 'loc', r.location, 'cond', r.cond, 'price', coalesce(to_jsonb(r.unit_price), '""'::jsonb), 'cardId', r.card_id, 'tci', r.tci,
    'expire', coalesce(r.expire_date::text, ''), 'received', fn_thai(r.received_date),
    'days', case when r.received_date is not null then greatest(0, fn_today() - r.received_date) else 0 end,
    'receiver', r.receiver, 'note', r.note, 'inStock', l.remain > 0)
  from receipts r join v_lots l on l.seq = r.seq where r.seq = p_seq
$$;

create or replace function rpc_get_awaiting_doc() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(fn_doc_row(r.seq) order by greatest(0, fn_today() - r.received_date) desc nulls last, r.seq), '[]'::jsonb)
  from receipts r where r.source = 'ใบเบิก' and btrim(r.card_id) = ''
$$;

create or replace function rpc_get_doc_info(p_seq bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare j jsonb := fn_doc_row(p_seq);
begin
  if j is null then raise exception 'ไม่พบรายการรับลำดับที่ %', p_seq; end if;
  return j;
end $$;

create or replace function rpc_save_doc_info(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  seqs bigint[]; s bigint; v_card text := btrim(coalesce(p->>'cardId','')); v_cond text := btrim(coalesce(p->>'cond','')); v_expire text := btrim(coalesce(p->>'expire',''));
  v_tci text := btrim(coalesce(p->>'tci','')); v_loc text := btrim(coalesce(p->>'location','')); v_recv text := btrim(coalesce(p->>'receiver','')); v_note text := btrim(coalesce(p->>'remark',''));
  v_grp text := btrim(coalesce(p->>'group','')); has_price boolean := btrim(coalesce(p->>'price','')) <> ''; price numeric; src text; what text; one receipts;
begin
  perform fn_lock();
  seqs := array(select x::bigint from jsonb_array_elements_text(coalesce(p->'seqs','[]'::jsonb)) x where x::bigint <> 0);
  if coalesce(array_length(seqs,1),0) = 0 then raise exception 'ไม่ได้เลือกรายการ'; end if;
  if v_grp <> '' and v_grp <> '-' and v_grp <> 'สารเคมี' then raise exception 'กลุ่มพัสดุไม่ถูกต้อง'; end if;
  if has_price then price := fn_num(p->>'price'); if price is null or price < 0 then raise exception 'ราคาต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป'; end if; end if;
  if array_length(seqs,1) > 1 and (has_price or v_expire <> '' or v_tci <> '' or v_loc <> '' or v_note <> '') then
    raise exception 'หลายรายการพร้อมกัน แก้ได้เฉพาะ card ID, COND, ผู้รับ และกลุ่ม (อย่างอื่นแก้ทีละรายการ)'; end if;
  if v_card = '' and v_cond = '' and not has_price and v_expire = '' and v_tci = '' and v_loc = '' and v_recv = '' and v_note = '' and v_grp = '' then raise exception 'ยังไม่ได้กรอกข้อมูลอะไร'; end if;
  foreach s in array seqs loop
    select source into src from receipts where seq = s;
    if not found then raise exception 'ไม่พบรายการรับลำดับที่ % (อาจถูกยกเลิกไปแล้ว)', s; end if;
    if src <> 'ใบเบิก' then raise exception 'ลำดับที่ % ไม่ใช่รายการรับตามใบเบิก', s; end if;
  end loop;
  update receipts r set
    card_id = case when v_card <> '' then v_card else r.card_id end, cond = case when v_cond <> '' then v_cond else r.cond end,
    unit_price = case when has_price then price else r.unit_price end, expire_date = case when v_expire <> '' then fn_date(v_expire) else r.expire_date end,
    tci = case when v_tci <> '' then v_tci else r.tci end, location = case when v_loc <> '' then v_loc else r.location end,
    receiver = case when v_recv <> '' then v_recv else r.receiver end, note = case when v_note <> '' then v_note else r.note end,
    item_group = case when v_grp = '-' then '' when v_grp <> '' then v_grp else r.item_group end
  where r.seq = any (seqs);
  what := concat_ws(' | ', case when v_card <> '' then case when v_card = '-' then 'ปิดรายการ (ไม่มีเอกสาร)' else 'card ID ' || v_card end end, case when v_cond <> '' then 'COND ' || v_cond end,
    case when has_price then 'ราคา ' || fn_qtytxt(price) end, case when v_expire <> '' then 'หมดอายุ ' || v_expire end, case when v_tci <> '' then 'TCI ' || v_tci end);
  select * into one from receipts where seq = seqs[1];
  perform fn_log(p->>'by', 'เติมข้อมูลเอกสาร TAI', case when array_length(seqs,1) = 1 then one.doc_no else '' end,
    concat_ws(' | ', case when array_length(seqs,1) = 1 then one.part_no || ' ' || one.name else array_length(seqs,1) || ' รายการ' end, what));
  return jsonb_build_object('ok', true, 'count', array_length(seqs,1));
end $$;

-- ---------- ตรวจ Serial ซ้ำ ----------
create or replace function rpc_scan_duplicate_serials() returns jsonb language sql stable security definer set search_path = public as $$
with s as (select l.*, fn_srch_n(l.serial_no) k from v_lots l where l.serial_no <> ''),
g as (
  select k, count(*) n, count(*) filter (where remain > 0) live, count(distinct upper(btrim(part_no))) parts, count(distinct btrim(serial_no)) raws,
         max(qty) maxq, (array_agg(serial_no order by seq))[1] sn,
         (select string_agg(x, ' / ' order by o) from (select btrim(serial_no) x, min(seq) o from s s2 where s2.k = s.k group by 1) z) rawlist
  from s where k <> '' group by k),
lv as (
  select g.*, case when live > 1 then 'bad' when (n > 1 and (parts > 1 or raws > 1)) or (n = 1 and maxq > 1) then 'warn' when n > 1 then 'info' end level,
         array_remove(array[
           case when live > 1 then 'อยู่ในคลังพร้อมกัน ' || live || ' ล็อต' end,
           case when n > 1 and parts > 1 then 'S/N เดียวกันแต่ต่าง Part number' end,
           case when n > 1 and raws > 1 then 'พิมพ์ไม่เหมือนกัน (' || rawlist || ')' end,
           case when n = 1 and maxq > 1 then 'มี S/N แต่จำนวน ' || fn_qtytxt(maxq) || ' (ควรเป็น 1)' end,
           case when live <= 1 and not (parts > 1 or raws > 1) and n > 1 then 'เคยรับ ' || n || ' ครั้ง ปัจจุบัน' || case when live > 0 then 'อยู่ในคลัง 1 ล็อต' else 'ไม่อยู่ในคลัง' end end
         ], null) reasons
  from g),
bad as (select * from lv where level is not null),
top as (select * from bad order by case level when 'bad' then 0 when 'warn' then 1 else 2 end, sn collate "C" limit 300)
select jsonb_build_object('scanned', (select count(*) from s), 'distinct', (select count(*) from g),
  'count', jsonb_build_object('bad', (select count(*) from bad where level = 'bad'), 'warn', (select count(*) from bad where level = 'warn'), 'info', (select count(*) from bad where level = 'info')),
  'groups', coalesce((select jsonb_agg(jsonb_build_object('sn', sn, 'level', level, 'reasons', to_jsonb(reasons), 'lots', (
        select jsonb_agg(jsonb_build_object('seq', s.seq, 'label', s.label, 'part', s.part_no, 'serial', s.serial_no, 'qty', s.qty, 'remain', s.remain, 'loc', s.location, 'recv', fn_thai(s.received_date)) order by s.seq)
        from s where s.k = top.k)) order by case level when 'bad' then 0 when 'warn' then 1 else 2 end, sn collate "C") from top), '[]'::jsonb),
  'truncated', (select count(*) from bad) > 300)
$$;

-- ---------- ตรวจสุขภาพระบบ ----------
create or replace function rpc_get_system_health() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t0 timestamptz := clock_timestamp(); nlots int; ms int; ledger bigint; tl text; rl text; lvl text; sheets jsonb;
        c_req bigint; c_rcv bigint; c_rcv2 bigint; c_iss bigint;
begin
  select count(*) into nlots from v_lots;
  ms := (extract(epoch from clock_timestamp() - t0) * 1000)::int;
  select count(*) into c_req from requisitions;
  select count(*) filter (where source <> 'คืนเข้าคลัง'), count(*) filter (where source = 'คืนเข้าคลัง') into c_rcv, c_rcv2 from receipts;
  select count(*) into c_iss from issues;
  ledger := c_rcv + c_rcv2 + c_iss;
  tl := case when ms < 2000 then 'ok' when ms < 5000 then 'warn' else 'bad' end;
  rl := case when ledger < 8000 then 'ok' when ledger < 20000 then 'warn' else 'bad' end;
  lvl := case when (case tl when 'ok' then 0 when 'warn' then 1 else 2 end) >= (case rl when 'ok' then 0 when 'warn' then 1 else 2 end) then tl else rl end;
  sheets := jsonb_build_array(
    jsonb_build_object('name', 'เบิก', 'rows', c_req), jsonb_build_object('name', 'รับ', 'rows', c_rcv), jsonb_build_object('name', 'รับคืนเข้าคลัง', 'rows', c_rcv2),
    jsonb_build_object('name', 'จ่าย', 'rows', c_iss), jsonb_build_object('name', 'ยืมพัสดุ', 'rows', (select count(*) from loans)),
    jsonb_build_object('name', 'เคลม', 'rows', (select count(*) from claims)), jsonb_build_object('name', 'ตรวจนับ', 'rows', (select count(*) from counts)),
    jsonb_build_object('name', 'ประวัติการย้าย', 'rows', (select count(*) from move_history)), jsonb_build_object('name', 'บันทึกการใช้งาน', 'rows', (select count(*) from activity_log)));
  return jsonb_build_object('asOf', fn_thai(fn_today()), 'dupSeq', '[]'::jsonb, 'sheets', sheets, 'ledger', ledger, 'lots', nlots, 'ms', ms, 'timeLevel', tl, 'rowLevel', rl, 'level', lvl);
end $$;

-- ---------- สถานะชุด FLY AWAY KIT (ใช้ในแดชบอร์ด) ----------
create or replace function fn_kit_status() returns jsonb language plpgsql stable as $$
declare res jsonb := '{}'::jsonb; n int; items int; comp int; miss jsonb; last_use date; loans_ jsonb;
begin
  for n in 1..2 loop
    with spec as (select upper(part_no) pk, part_no, name, case when n = 1 then need_kit1 else need_kit2 end need, ctid from kit_requirements where part_no <> '' or name <> ''),
    inkit as (select * from v_lots where fn_kit_of(tail_no) = 'FLY AWAY KIT ' || n),
    hv as (select upper(part_no) pk, sum(remain) h from inkit where remain > 0 group by 1),
    chk as (select s.*, coalesce(h.h, 0) have from spec s left join hv h on h.pk = s.pk where s.need > 0)
    select count(*), count(*) filter (where have >= need),
           coalesce(jsonb_agg(jsonb_build_object('part', part_no, 'name', name, 'need', need, 'have', have, 'short', need - have) order by ctid) filter (where have < need), '[]'::jsonb)
      into items, comp, miss from chk;
    select max(i.issue_date) into last_use from issues i where i.receipt_seq in (select seq from v_lots where fn_kit_of(tail_no) = 'FLY AWAY KIT ' || n);
    select coalesce(jsonb_agg(jsonb_build_object('part', ln.part_no, 'name', ln.name, 'qty', ln.qty_open, 'who', ln.borrower) order by ln.seq), '[]'::jsonb) into loans_
      from loans ln where ln.status = 'ยืมอยู่' and ln.lot_seq in (select seq from v_lots where fn_kit_of(tail_no) = 'FLY AWAY KIT ' || n);
    res := res || jsonb_build_object(n::text, jsonb_build_object('kit', 'FLY AWAY KIT ' || n, 'total', items, 'complete', comp, 'missing', miss, 'lastUse', fn_thai(last_use), 'loans', loans_));
  end loop;
  return res;
end $$;

revoke all on function fn_nat(text), fn_line_date(date), fn_ts(timestamptz), fn_tdate(text), fn_tai_obj(requisitions,date), fn_shelf_parse(text), fn_add_shelf_slots(text[],text),
  fn_doc_row(bigint), fn_kit_status() from public, anon;
grant execute on function rpc_get_pending_receive(), rpc_get_shelf_map(), rpc_add_shelf_slots(jsonb), rpc_remove_shelf_slot(jsonb), rpc_fill_shelf_gaps(jsonb), rpc_get_bootstrap(),
  rpc_get_history(text,int), rpc_get_awaiting_doc(), rpc_get_doc_info(bigint), rpc_save_doc_info(jsonb), rpc_scan_duplicate_serials(), rpc_get_system_health() to anon;

-- ---------- หน้า FLY AWAY KIT (applied live 2026-11-25) ----------
-- rpc_get_kits(p jsonb) : ต่อ KIT 1/2 คืน items (รายการตายตัว need/have/short/ที่เก็บ/S/N), extra (พัสดุนอกรายการ), loans (ยืมออก), lastUse, total, complete
-- (นิยามเต็มดูในฐานข้อมูลจริง: pg_get_functiondef('rpc_get_kits(jsonb)'::regprocedure))
-- grant execute on function rpc_get_kits(jsonb) to anon;
-- rpc_get_kits: แต่ละ item ที่ขาดมี 'reqs' = ใบเบิกทดแทนที่ค้างรับ (v_req_status.machine = 'FLY AWAY KIT n', part ตรง, remain > 0) (applied live 2026-11-25)
