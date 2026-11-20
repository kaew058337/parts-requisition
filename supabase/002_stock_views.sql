-- =====================================================================
--  002 : วิวคำนวณสต็อก (แทน computeLots_ / getStock ใน Code.gs)
--  ยอดคงเหลือต่อล็อต = รับ − จ่าย − ที่ยืมออกและยังไม่คืนเข้าคลัง   (ไม่เก็บยอดซ้ำ คำนวณสดทุกครั้ง)
-- =====================================================================
create or replace view v_lots with (security_invoker = true) as
select
  r.seq,
  r.doc_no,
  (r.source <> 'ใบเบิก' and r.source <> '')            as is_free,        -- ยอดยกมา/คืนเข้าคลัง/รับก่อนเบิก = ล็อตอิสระ
  case when r.source <> 'ใบเบิก' and r.source <> '' then r.source else r.doc_no end as label,
  r.part_no, r.name, r.serial_no, r.item_type, r.item_group, r.unit,
  r.qty,
  coalesce(i.qty, 0)                                    as issued,
  coalesce(l.out_qty, 0)                                as loan_out,
  r.qty - coalesce(i.qty, 0) - coalesce(l.out_qty, 0)   as remain,
  r.cond, r.location, r.expire_date, r.received_date, r.note, r.tail_no, r.receiver, r.source
from receipts r
left join (select receipt_seq, sum(qty) qty from issues group by receipt_seq) i on i.receipt_seq = r.seq
left join (select lot_seq, sum(greatest(qty - qty_returned_to_stock, 0)) out_qty from loans where lot_seq is not null group by lot_seq) l on l.lot_seq = r.seq;

-- ยอดรวมต่อ Part number (เฉพาะที่ยังมีของ)
create or replace view v_stock_parts with (security_invoker = true) as
select part_no, max(name) as name, max(unit) as unit, sum(remain) as qty, count(*) as lots
from v_lots where remain > 0
group by part_no;

grant select on v_lots, v_stock_parts to anon;
