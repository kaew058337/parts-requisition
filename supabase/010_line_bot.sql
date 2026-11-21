-- =====================================================================
--  010 : บอตไลน์ — ตั้งค่า · ข้อความสรุปประจำวัน/แจ้งด่วน · ข้อความค้นหาพัสดุ
--  แปลงจาก Code.gs: buildLineDigest_, lineSearchText_, isWorkday_, isLastWorkdayOfWeek_
--  ส่วนที่ติดต่อไลน์ (webhook/push) อยู่ใน Edge Function: supabase/functions/line-bot
-- =====================================================================

create table if not exists app_settings (key text primary key, value text not null default '', updated_at timestamptz not null default now());
alter table app_settings enable row level security;      -- ไม่มี policy = anon อ่าน/เขียนไม่ได้ (Edge Function ใช้ service role)
revoke all on app_settings from anon, authenticated;

create or replace function fn_ld(d date) returns text language sql immutable as $$
  select extract(day from d)::int || ' ' || (array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'])[extract(month from d)::int]
         || ' ' || ((extract(year from d)::int + 543) % 100)::text $$;
create or replace function fn_ldd(d date) returns text language sql immutable as $$
  select 'วัน' || (array['อาทิตย์','จันทร์','อังคาร','พุธ','พฤหัสบดี','ศุกร์','เสาร์'])[extract(dow from d)::int + 1] || 'ที่ ' || fn_ld(d) $$;

create or replace function fn_is_workday(d date) returns boolean language sql stable as $$
  select extract(dow from d) not in (0, 6) and not exists (select 1 from holidays h where h.day = d) $$;
create or replace function fn_next_workday(d date) returns date language plpgsql stable as $$
declare n date := d + 1; begin while not fn_is_workday(n) loop n := n + 1; end loop; return n; end $$;
create or replace function fn_last_workday_of_week(d date) returns boolean language sql stable as $$
  select date_trunc('week', fn_next_workday(d)) > date_trunc('week', d::timestamp) $$;

-- สถานะใบเบิก (ไม่รวมที่ยกเลิก) พร้อมยอดที่รับแล้ว
create or replace view v_req_status with (security_invoker = true) as
select r.seq, r.doc_no, r.part_no, r.name, r.machine, r.urgency, r.item_type, r.qty, coalesce(g.have, 0) have, greatest(r.qty - coalesce(g.have, 0), 0) remain,
       r.req_date, r.pay_date, r.tci_install_date as install, fn_due(r.req_date, r.urgency) due
from requisitions r
left join lateral (select sum(c.qty) have from receipts c where c.source = 'ใบเบิก' and c.doc_no = r.doc_no and c.part_no = r.part_no) g on true
where not r.cancelled and r.doc_no ~ '^\d{9}$' and (r.part_no <> '' or r.name <> '');

-- ข้อความสรุป ; ว่าง = ไม่มีอะไรจะแจ้ง
create or replace function fn_line_digest(today date, urgent_only boolean) returns text language plpgsql volatile security definer set search_path = public as $$
declare
  tomorrow date := today + 1; target date := fn_next_workday(today); L text[] := '{}'; x record; n int; multi boolean;
  ym text := to_char(today, 'YYYY-MM'); dash jsonb; s jsonb;
begin
  -- 1) งาน TCI ที่จะติดตั้งวันทำงานถัดไป
  select count(*) into n from v_req_status v where v.item_type in ('LRU(TCI)','SP(TCI)') and v.install between tomorrow and target and not (urgent_only and v.remain <= 0);
  if n > 0 then
    multi := tomorrow <> target;
    L := L || ('🔧 งาน TCI ที่จะติดตั้ง ' || case when multi then 'ภายใน' || fn_ldd(target) when target = tomorrow then 'พรุ่งนี้ (' || fn_ld(target) || ')' else fn_ldd(target) end || ' : ' || n || ' รายการ');
    for x in select v.*, case when v.remain > 0 then fn_tai_obj((select q from requisitions q where q.seq = v.seq), v.install) end tai
             from v_req_status v where v.item_type in ('LRU(TCI)','SP(TCI)') and v.install between tomorrow and target and not (urgent_only and v.remain <= 0)
             order by v.install, v.remain limit 12 loop
      L := L || ((case when x.remain > 0 then '❌ ของยังไม่มา ' else '✅ ของมาแล้ว ' end) || coalesce(nullif(x.part_no,''), x.name) || ' ' || x.name || ' (' || x.doc_no || ')'
        || case when x.machine <> '' then ' เครื่อง ' || x.machine else '' end || case when multi then ' · ติดตั้ง ' || fn_ld(x.install) else '' end
        || case when x.remain > 0 then ' · ค้าง ' || x.remain else '' end || case when coalesce(x.tai->>'label','') <> '' then ' · TAI: ' || (x.tai->>'label') else '' end);
    end loop;
    if n > 12 then L := L || ('…และอีก ' || (n - 12) || ' รายการ (ดูในแอป)'); end if;
    L := array_append(L, '');
  end if;
  -- 2) ใบเบิก AOG ค้างรับ
  select count(*) into n from v_req_status v where v.urgency = 'AOG' and v.pay_date is null and v.remain > 0;
  if n > 0 then
    L := L || ('🚨 ใบเบิก AOG ค้างรับ ' || n || ' รายการ');
    for x in select v.*, fn_tai_obj((select q from requisitions q where q.seq = v.seq), null) tai from v_req_status v where v.urgency = 'AOG' and v.pay_date is null and v.remain > 0 order by v.due nulls last, v.seq limit 12 loop
      L := L || ('• ' || x.doc_no || ' ' || x.part_no || ' ' || x.name || ' · ค้าง ' || x.remain
        || case when x.due is null then '' when x.due < today then ' · เลยกำหนด ' || (today - x.due) || ' วัน' else ' · กำหนด ' || fn_ld(x.due) end
        || case when coalesce(x.tai->>'label','') <> '' then ' · TAI: ' || (x.tai->>'label') else '' end);
    end loop;
    if n > 12 then L := L || ('…และอีก ' || (n - 12) || ' รายการ (ดูในแอป)'); end if;
    L := array_append(L, '');
  end if;
  if urgent_only then
    if cardinality(L) = 0 then return ''; end if;
    return left('⚠️ แจ้งด่วน ' || fn_ldd(today) || E'\n────────────\n' || rtrim(array_to_string(L, E'\n'), E'\n'), 4900);
  end if;
  -- 3) พัสดุที่รับวันนี้ (มีใบเบิก)
  select count(*) into n from (select 1 from receipts r where r.doc_no <> '' and coalesce(nullif(r.source,''),'ใบเบิก') = 'ใบเบิก' and r.received_date = today group by r.doc_no, r.part_no) z;
  if n > 0 then
    L := L || ('📦 พัสดุที่รับวันนี้ (มีใบเบิก) ' || n || ' รายการ');
    for x in select r.doc_no, r.part_no, coalesce(nullif(max(r.name),''), max(q.name), '') name, coalesce(max(q.machine),'') machine, sum(r.qty) qty
             from receipts r left join requisitions q on q.doc_no = r.doc_no and q.part_no = r.part_no and not q.cancelled
             where r.doc_no <> '' and coalesce(nullif(r.source,''),'ใบเบิก') = 'ใบเบิก' and r.received_date = today group by r.doc_no, r.part_no order by r.doc_no, r.part_no limit 12 loop
      L := L || ('• ' || coalesce(nullif(x.part_no,''),'-') || ' ' || x.name || case when x.machine <> '' then ' · เครื่อง ' || x.machine else '' end || ' · จำนวน ' || x.qty || ' (' || x.doc_no || ')');
    end loop;
    if n > 12 then L := L || ('…และอีก ' || (n - 12) || ' รายการ (ดูในแอป)'); end if;
    L := array_append(L, '');
  end if;
  -- 4) สถานะงาน TCI เดือนนี้
  dash := rpc_get_dashboard(ym); s := dash->'tciSum';
  if (s->>'total')::int > 0 then
    L := L || ('📊 สถานะงาน TCI เดือน ' || (array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'])[extract(month from today)::int] || ' ' || ((extract(year from today)::int + 543) % 100)
      || ' : รับแล้ว ' || (s->>'done') || '/' || (s->>'total') || case when (s->>'partial')::int > 0 then ' · รับบางส่วน ' || (s->>'partial') else '' end
      || case when (s->>'pending')::int > 0 then ' · ค้างรับ ' || (s->>'pending') else '' end || case when (s->>'overdue')::int > 0 then ' · เกินวันติดตั้ง ' || (s->>'overdue') else '' end);
    n := 0;
    for x in select e from jsonb_array_elements(dash->'tci') e where (e->>'late')::boolean limit 12 loop
      L := L || ('⚠️ ' || coalesce(nullif(x.e->>'part',''), x.e->>'name') || ' ' || (x.e->>'name') || ' (' || (x.e->>'docNo') || ')'
        || case when (x.e->>'instLate')::boolean then ' · เกินวันติดตั้ง ' || (-(x.e->>'daysLeft')::int) || ' วัน' else ' · เลยกำหนด' end || ' · ค้าง ' || (x.e->>'remain'));
    end loop;
    select count(*) into n from jsonb_array_elements(dash->'tci') e where (e->>'late')::boolean;
    if n > 12 then L := L || ('…และอีก ' || (n - 12) || ' รายการ (ดูในแอป)'); end if;
    L := array_append(L, '');
  end if;
  if cardinality(L) = 0 then return ''; end if;
  return left('สรุปประจำวัน ' || fn_ldd(today) || E'\n────────────\n' || rtrim(array_to_string(L, E'\n'), E'\n'), 4900);
end $$;

-- ข้อความที่จะส่งเข้ากลุ่มตอน 16:10 : วันทำงานสุดท้ายของสัปดาห์ = สรุปเต็ม, วันอื่น = แจ้งด่วนเมื่อมีเรื่อง, วันหยุด = ไม่ส่ง
create or replace function fn_line_daily(today date default fn_today()) returns text language sql volatile security definer set search_path = public as $$
  select case when not fn_is_workday(today) then '' else fn_line_digest(today, not fn_last_workday_of_week(today)) end $$;

-- ข้อความตอบการค้นหาพัสดุ (ข้อความธรรมดา)
create or replace function fn_line_search_text(q text) returns text language plpgsql volatile security definer set search_path = public as $$
declare res jsonb := rpc_search_parts(jsonb_build_object('q', q)); out text[] := '{}'; r jsonb; lot jsonb; x jsonb; i int; head text; nl int;
begin
  if jsonb_array_length(res->'results') = 0 then
    return '❌ ไม่พบ "' || q || E'" ในระบบ\nลองพิมพ์เพียงบางส่วนของ P/N หรือชื่อ (ไม่ต้องใส่ขีด/ช่องว่าง)';
  end if;
  for r in select e from jsonb_array_elements(res->'results') e loop
    head := coalesce(nullif(r->>'part',''), '(ไม่มี P/N)') || case when coalesce(r->>'name','') <> '' then ' · ' || (r->>'name') else '' end;
    if r->>'status' = 'stock' then
      out := out || ('✅ ' || head) || ('คงเหลือ ' || (r->>'qty') || case when coalesce(r->>'unit','') <> '' then ' ' || (r->>'unit') else '' end);
      i := 0; nl := jsonb_array_length(r->'lots');
      for lot in select e from jsonb_array_elements(r->'lots') e loop
        i := i + 1; exit when i > 6;
        out := out || ('  • ' || coalesce(nullif(lot->>'loc',''), 'ยังไม่ระบุที่เก็บ') || case when coalesce(lot->>'serial','') <> '' then ' · S/N ' || (lot->>'serial') else ' · ' || (lot->>'qty') || ' ชิ้น' end
          || case when coalesce(lot->>'kit','') <> '' then ' · ' || (lot->>'kit') else '' end || case when coalesce(lot->>'cond','') <> '' then ' · ' || (lot->>'cond') else '' end);
      end loop;
      if nl > 6 then out := out || ('  … อีก ' || (nl - 6) || ' ล็อต'); end if;
    else
      out := out || ('⚪ ' || head) || 'มีในระบบ แต่ไม่มีของคงคลัง';
      if coalesce(r->>'lastRecv','') <> '' or coalesce(r->>'lastIssue','') <> '' then
        out := out || ('  ' || concat_ws(' · ', nullif('รับล่าสุด ' || coalesce(r->>'lastRecv',''), 'รับล่าสุด '),
            nullif('จ่ายล่าสุด ' || coalesce(r->>'lastIssue','') || case when coalesce(r->>'lastIssueTo','') <> '' then ' (' || (r->>'lastIssueTo') || ')' else '' end, 'จ่ายล่าสุด ')));
      end if;
    end if;
    for x in select e from jsonb_array_elements(r->'pending') e loop
      out := out || ('  ⏳ รอรับตามใบเบิก ' || (x->>'doc') || ' เหลือ ' || (x->>'remain') || case when coalesce(x->>'tai','') <> '' then ' · TAI: ' || (x->>'tai') else '' end);
    end loop;
    if (r->>'snHit')::boolean or (r->>'status' <> 'stock' and jsonb_array_length(r->'serialsOut') > 0) then
      i := 0;
      for x in select e from jsonb_array_elements(r->'serialsOut') e loop
        i := i + 1; exit when i > 3;
        out := out || ('  ↗ S/N ' || (x->>'serial') || ' จ่ายออกแล้ว ' || (x->>'date') || case when coalesce(x->>'tech','') <> '' then ' (' || (x->>'tech') || ')' else '' end
          || case when coalesce(x->>'doc','') <> '' then ' · ' || (x->>'doc') else '' end);
      end loop;
    end if;
    L := array_append(out, '');
  end loop;
  if (res->>'total')::int > jsonb_array_length(res->'results') then
    out := out || ('พบทั้งหมด ' || (res->>'total') || ' รายการ แสดง ' || jsonb_array_length(res->'results') || ' — พิมพ์ให้เจาะจงขึ้นเพื่อดูที่เหลือ');
  end if;
  return btrim(array_to_string(out, E'\n'), E'\n ');
end $$;

-- ภายในเท่านั้น (Edge Function ใช้ service role) — ไม่เปิดให้ anon
revoke all on function fn_ld(date), fn_ldd(date), fn_is_workday(date), fn_next_workday(date), fn_last_workday_of_week(date), fn_line_digest(date, boolean), fn_line_daily(date), fn_line_search_text(text) from public, anon, authenticated;
grant execute on function fn_line_digest(date, boolean), fn_line_daily(date), fn_line_search_text(text) to service_role;

-- Edge Function ใช้ service role อ่าน/เขียนตั้งค่าและบันทึกกิจกรรม (ต้องให้สิทธิ์ตารางชัดเจน)
grant select, insert, update, delete on app_settings to service_role;
grant select, insert on activity_log to service_role;
grant usage, select on all sequences in schema public to service_role;
