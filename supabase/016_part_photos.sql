-- รูปพัสดุ (ผูกกับ Part number) : ไฟล์รูปอยู่ใน Storage bucket 'part-photos' (สาธารณะอ่านได้)
-- ไฟล์: <key>.jpg (ใหญ่ ~800px) และ <key>_t.jpg (ย่อ ~160px); ตาราง part_photos เก็บแค่ key
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types) values ('part-photos','part-photos',true,524288,array['image/jpeg']) on conflict (id) do nothing;
create policy part_photos_read on storage.objects for select to anon using (bucket_id='part-photos');
create policy part_photos_ins on storage.objects for insert to anon with check (bucket_id='part-photos');
create policy part_photos_upd on storage.objects for update to anon using (bucket_id='part-photos') with check (bucket_id='part-photos');
create policy part_photos_del on storage.objects for delete to anon using (bucket_id='part-photos');
create table if not exists public.part_photos(part_no text primary key, path text not null, updated_at timestamptz not null default now(), updated_by text not null default '');
alter table public.part_photos enable row level security;
create or replace function public.rpc_get_part_photos() returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_object_agg(part_no, jsonb_build_object('p',path,'t',(extract(epoch from updated_at)*1000)::bigint)),'{}'::jsonb) from part_photos $$;
create or replace function public.rpc_set_part_photo(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare pn text := btrim(coalesce(p->>'part','')); pa text := btrim(coalesce(p->>'path','')); b text := coalesce(p->>'by','');
begin
  if pn='' or pa='' then raise exception 'ไม่มี Part number หรือไฟล์รูป'; end if;
  insert into part_photos(part_no,path,updated_at,updated_by) values (pn,pa,now(),b)
    on conflict (part_no) do update set path=excluded.path, updated_at=now(), updated_by=excluded.updated_by;
  insert into activity_log(at,user_name,action,doc_no,detail) values (now(), b, 'รูปพัสดุ', '', 'ตั้งรูป '||pn);
  return jsonb_build_object('ok',true);
end $$;
create or replace function public.rpc_delete_part_photo(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare pn text := btrim(coalesce(p->>'part','')); b text := coalesce(p->>'by','');
begin
  delete from part_photos where part_no=pn;
  insert into activity_log(at,user_name,action,doc_no,detail) values (now(), b, 'รูปพัสดุ', '', 'ลบรูป '||pn);
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.rpc_get_part_photos() to anon;
grant execute on function public.rpc_set_part_photo(jsonb) to anon;
grant execute on function public.rpc_delete_part_photo(jsonb) to anon;
