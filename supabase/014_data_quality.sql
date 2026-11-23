-- ตรวจข้อมูล: แถวนำเข้าที่ไม่มีเครื่อง/S/N + Part number ที่เขียนต่างกัน (อ่านอย่างเดียว) และแก้ทีละแถว
create or replace function rpc_get_dq() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ret jsonb; leg jsonb; vr jsonb; c jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', seq, 'part', part_no, 'name', name, 'date', fn_thai((recorded_at at time zone 'Asia/Bangkok')::date), 'sn', serial_out, 'machine', machine, 'doc', letter_no, 'issue', issue_text) order by recorded_at desc, seq desc), '[]'::jsonb)
    into ret from returns_out where note like '[นำเข้าจากไฟล์เดิม]%' and (serial_out = '' or machine = '');
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'part', part_no, 'name', name, 'date', fn_thai(issue_date), 'sn', serial_no, 'tail', tail_no, 'tech', technician, 'orig', orig_text) order by issue_date desc, id desc), '[]'::jsonb)
    into leg from legacy_issues where serial_no = '' or tail_no = '';
  select coalesce(jsonb_agg(jsonb_build_object('forms', forms, 'uses', uses) order by uses desc), '[]'::jsonb) into vr from (
    select jsonb_agg(jsonb_build_object('p', p, 'n', n) order by n desc) forms, sum(n) uses
    from (select upper(regexp_replace(p, '[^A-Za-z0-9]', '', 'g')) k, p, count(*) n from (
            select part_no p from receipts union all select part_no from requisitions union all select part_no from issues
            union all select part_no from returns_out union all select part_no from legacy_issues) a where p <> '' group by 1, 2) b
    where k <> '' group by k having count(*) > 1 limit 120) v;
  return jsonb_build_object('ret', ret, 'leg', leg, 'variants', vr);
end $$;

create or replace function rpc_dq_fix(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare src text := p->>'src'; i bigint := (p->>'id')::bigint; sn text := btrim(coalesce(p->>'serial','')); mc text := btrim(coalesce(p->>'machine','')); tc text := btrim(coalesce(p->>'tech',''));
begin
  if src = 'ret' then
    update returns_out set serial_out = sn, machine = mc where seq = i and note like '[นำเข้าจากไฟล์เดิม]%';
  elsif src = 'leg' then
    update legacy_issues set serial_no = sn, tail_no = mc, technician = tc where id = i;
  else raise exception 'ไม่รู้จักแหล่งข้อมูล'; end if;
  if not found then raise exception 'ไม่พบแถวนี้'; end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function rpc_get_dq() to anon;
grant execute on function rpc_dq_fix(jsonb) to anon;
