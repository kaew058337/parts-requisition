# คู่มือ: push ขึ้น GitHub แล้ว Deploy ไป Apps Script อัตโนมัติ

ทำครั้งเดียว ประมาณ 15–20 นาที หลังจากนั้นทุกครั้งที่ push ไฟล์ `Code.gs`, `Index.html` หรือ `appsscript.json`
ขึ้นแขนง `main` เว็บจะอัปเดตเองที่ลิงก์ `/exec` เดิม

> **ก่อนเริ่ม:** ตั้ง repo เป็น **Private** (Settings → General → Danger Zone → Change visibility)
> เพราะไฟล์ล็อกอิน Google ที่จะเก็บใน Secrets ให้สิทธิ์เปลี่ยนโค้ดระบบจริงได้

## ขั้นที่ 1 เปิดใช้ Apps Script API
1. เปิด https://script.google.com/home/usersettings (ล็อกอินด้วยบัญชี Google เจ้าของโปรเจค)
2. เปิดสวิตช์ **Google Apps Script API** เป็น On

## ขั้นที่ 2 หา Script ID
1. เปิดโปรเจค Apps Script ของระบบ (จากชีท → ส่วนขยาย → Apps Script)
2. เมนูซ้าย **การตั้งค่าโปรเจค (⚙)** → ช่อง **รหัสสคริปต์ (Script ID)** → กดคัดลอก

## ขั้นที่ 3 หา Deployment ID ของเว็บแอปเดิม
1. ในหน้า Apps Script กด **ทำให้ใช้งานได้ → จัดการการทำให้ใช้งานได้**
2. เลือก deployment ประเภท **เว็บแอป** ที่ใช้งานอยู่ ดู **รหัสการทำให้ใช้งานได้ (Deployment ID)** (ขึ้นต้น `AKfycb...`) แล้วคัดลอก
   - อย่าสร้าง deployment ใหม่ เพราะลิงก์ `/exec` จะเปลี่ยน

## ขั้นที่ 4 ล็อกอิน clasp บนคอมพิวเตอร์ของคุณ
ต้องมี Node.js (เวอร์ชัน 18 ขึ้นไป) ติดตั้งในเครื่อง แล้วเปิด Terminal / Command Prompt:
```
npm install -g @google/clasp@2.4.2
clasp login
```
เบราว์เซอร์จะเปิดให้เลือกบัญชี Google → กดอนุญาต เมื่อสำเร็จจะมีไฟล์ล็อกอินที่
- Windows: `C:\Users\<ชื่อคุณ>\.clasprc.json`
- Mac / Linux: `~/.clasprc.json`

เปิดไฟล์นั้นด้วย Notepad / TextEdit แล้วคัดลอก **ข้อความทั้งหมด**

## ขั้นที่ 5 ใส่ค่าใน GitHub Secrets
1. เปิด repo `parts-requisition` → **Settings → Secrets and variables → Actions → New repository secret**
2. สร้าง 3 รายการนี้ (ชื่อต้องตรงเป๊ะ):

| ชื่อ Secret | ค่าที่ใส่ |
|---|---|
| `CLASPRC_JSON` | ข้อความทั้งหมดในไฟล์ `.clasprc.json` จากขั้นที่ 4 |
| `SCRIPT_ID` | Script ID จากขั้นที่ 2 |
| `DEPLOYMENT_ID` | Deployment ID จากขั้นที่ 3 |

## ขั้นที่ 6 ทดสอบ
1. เปิดแท็บ **Actions** ใน repo → เลือก **Deploy to Google Apps Script** → **Run workflow**
2. รอจนขึ้นเครื่องหมายถูกสีเขียว แล้วเปิดลิงก์ `/exec` เดิมเพื่อดูว่าเว็บทำงาน
3. จากนี้ไป แค่ push โค้ดที่แก้ขึ้น `main` ก็ปล่อยเองทันที

## ถ้ามีปัญหา
| อาการ | วิธีแก้ |
|---|---|
| ขั้น "ตรวจโค้ด" ไม่ผ่าน | อ่านข้อความสีแดง มันบอกว่าโค้ดผิดตรงไหน จะไม่ deploy จนกว่าจะแก้ |
| `User has not enabled the Apps Script API` | ทำขั้นที่ 1 ด้วยบัญชีเดียวกับที่ล็อกอิน clasp |
| `invalid_grant` / ล็อกอินหมดอายุ | ทำขั้นที่ 4 ใหม่ แล้วแก้ค่า `CLASPRC_JSON` |
| `Could not find script` / 404 | ตรวจ `SCRIPT_ID` ว่าคัดลอกครบ และบัญชีที่ล็อกอินเป็นเจ้าของหรือแก้ไขโปรเจคได้ |
| `Deployment not found` | ตรวจ `DEPLOYMENT_ID` ว่าเป็นของเว็บแอป ไม่ใช่ HEAD deployment |
| เว็บยังเป็นของเก่า | รอสักครู่แล้วรีเฟรช / ตรวจในแท็บ Actions ว่ารันสำเร็จ |

## ข้อควรรู้
- `clasp push` จะ **เขียนทับ** โค้ดใน Apps Script ทั้งหมดด้วยไฟล์ใน GitHub รวมถึง `appsscript.json`
  ถ้าเคยแก้ในหน้า Apps Script ตรง ๆ ให้นำมาลง GitHub ก่อน ไม่งั้นจะหาย
- ถ้ามี scope หรือการตั้งค่าเพิ่มใน manifest ของโปรเจคจริง ให้ใส่ใน `appsscript.json` ของ repo ด้วย
- ถ้าเพิ่มสิทธิ์ใหม่ (scope) ที่ต้องให้ผู้ใช้อนุญาต ต้องเปิดเว็บแอปหรือรันฟังก์ชันใน Apps Script หนึ่งครั้งเพื่อกดอนุญาต
- เปลี่ยนรหัสผ่าน/ยกเลิกสิทธิ์ clasp ได้ที่ https://myaccount.google.com/permissions
