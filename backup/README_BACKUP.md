# สำเนาข้อมูลลง Google Sheet ทุกคืน 23:00

1. สร้าง Google Sheet ใหม่ (ว่าง) ตั้งชื่อเช่น "สำเนาระบบพัสดุ"
2. เมนู ส่วนขยาย > Apps Script ลบโค้ดเดิม วางเนื้อหาไฟล์ `Backup.gs`
3. ไอคอนเฟือง Project Settings > Script properties > เพิ่ม 3 ค่า
   - `SUPA_URL` = https://uledkoviboyewqjfowqx.supabase.co
   - `SUPA_KEY` = (publishable key ของโปรเจกต์)
   - `BACKUP_KEY` = (รหัสที่ผู้ดูแลให้ ห้ามเผยแพร่)
4. เลือกฟังก์ชัน `backupNow` กด Run ครั้งแรก (อนุญาตสิทธิ์) ตรวจแท็บ `_สำเนา`
5. เลือก `installBackupTrigger` กด Run หนึ่งครั้ง = ตั้งเวลา 23:00 ทุกวัน
