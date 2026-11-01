# ระบบเบิก-จ่าย-ส่งคืนพัสดุ (Google Apps Script + Google Sheets)

Web app มือถือสำหรับเบิก / รับ / จ่าย / ส่งคืน / ยืม / ตรวจนับ / FLY AWAY KIT
ใช้ Google Sheets เป็นฐานข้อมูล

## ไฟล์
| ไฟล์ | หน้าที่ |
|---|---|
| `Code.gs` | Backend (Apps Script) |
| `Index.html` | หน้าเว็บทั้งหมด |
| `appsscript.json` | ตั้งค่า manifest |

## ติดตั้ง
1. เปิด Google Sheet ใหม่ → **ส่วนขยาย → Apps Script**
2. วางโค้ด `Code.gs`, สร้างไฟล์ HTML ชื่อ `Index` วาง `Index.html`, เปิดแสดง manifest แล้ววาง `appsscript.json`
3. รันฟังก์ชัน setup ครั้งแรก (สร้างชีทต่าง ๆ) แล้วอนุญาตสิทธิ์
4. **ทำให้ใช้งานได้ → การทำให้ใช้งานได้รายการใหม่ → เว็บแอป** (Execute as: Me, Access: Anyone) แล้วคัดลอก URL `/exec`

หรือใช้ [clasp](https://github.com/google/clasp): `clasp login && clasp create --type sheets && clasp push && clasp deploy`

## เชื่อม LINE LIFF
1. LINE Developers → Channel (LINE Login) → แท็บ **LIFF** → Add
2. **Endpoint URL** = URL `/exec` ของเว็บแอป, Size = Full, Scope = `profile`
3. คัดลอก **LIFF ID** ไปใส่ใน `Index.html` ที่ตัวแปร `LIFF_ID`
4. Deploy ใหม่ (เวอร์ชันใหม่) แล้วเปิดลิงก์ `https://liff.line.me/<LIFF ID>` ใน LINE
5. ชื่อ LINE จะถูกตั้งเป็นชื่อผู้ใช้อัตโนมัติ (ถ้ายังไม่เคยตั้งชื่อ)

> หมายเหตุ: ทุกครั้งที่แก้โค้ดต้อง Deploy เวอร์ชันใหม่ จึงจะมีผลที่ URL เดิม
