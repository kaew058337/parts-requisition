# ย้ายหน้าเว็บไป Cloudflare Pages (ต้นแบบ — ไม่แตะแอปเดิม)

หน้าเว็บอยู่ที่ Cloudflare Pages ส่วนข้อมูล/โค้ดหลังบ้านยังอยู่ที่ Apps Script เดิม  
แอปเดิม (URL Apps Script) ยังใช้ได้ตามปกติ ลองเทียบกันได้

## ฝั่ง Apps Script (ทำครั้งเดียว)
1. วาง `Code.gs` และ `Index.html` ใหม่ → Deploy → Manage deployments → New version  
   (เว็บแอปต้องตั้ง "ผู้มีสิทธิ์เข้าถึง = ทุกคน")
2. ตั้งรหัสเข้าใช้งาน: Project Settings → Script properties → เพิ่ม `API_KEY` = รหัสที่ตั้งเอง (ยาว ≥ 8 ตัว)  
   (ไม่ตั้ง = ระบบจะใช้การตรวจ LINE token แทน ซึ่งไม่เหมาะกับการใช้ผ่านเบราว์เซอร์ทั่วไป)
3. คัดลอก URL เว็บแอป (ลงท้าย `/exec`)

## ฝั่ง Cloudflare Pages
1. แก้ `pages/config.js` ใส่ `API_URL` เป็น URL `/exec` จากข้อ 3
2. เชื่อม repo GitHub `kaew058337/parts-requisition` กับ Cloudflare Pages  
   - Build command: `python3 scripts/build_pages.py`  
   - Build output directory: `pages`
3. ได้ URL `xxx.pages.dev` (ผูกโดเมนของตัวเองภายหลังได้)
4. เปิดบนมือถือ → ใส่รหัสเข้าใช้งานครั้งแรก (จำไว้ในเครื่อง) → "เพิ่มไปหน้าจอหลัก"

## หมายเหตุ
- แก้ `Index.html` แล้วรัน `python3 scripts/build_pages.py` จะได้ `pages/index.html` ใหม่ (Cloudflare รันให้เองทุกครั้งที่ push)
- เปิดครั้งแรกต้องมีสัญญาณ หลังจากนั้นตัวแอปเปิดได้แม้ออฟไลน์ (ข้อมูลที่ดูได้ = ข้อมูลล่าสุดที่เคยโหลด)
- รหัสเข้าใช้งานเปลี่ยนได้ที่ Script properties ; ทุกเครื่องจะถูกขอรหัสใหม่อัตโนมัติ
- แจ้งเตือน LINE, รายงาน PDF, สำรองข้อมูล ยังทำงานที่ Apps Script เหมือนเดิม
