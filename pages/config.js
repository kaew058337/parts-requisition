/* ตั้งค่าหน้าเว็บที่โฮสต์บน Cloudflare Pages
   BACKEND: 'gas' = ใช้ Google Sheet ผ่าน Apps Script (ปัจจุบัน) · 'supabase' = ใช้ Supabase (หลังตัดสลับ)
   ทดสอบโดยไม่แก้ค่า: เติม ?backend=supa ต่อท้ายลิงก์ (ข้อมูลที่บันทึกตอนทดสอบจะลงฐาน Supabase จริง) */
window.APP_CFG = {
  BACKEND: 'gas',
  API_URL: 'https://script.google.com/macros/s/AKfycbxip7ZnA199E65Hbaq4ZBU8y8RLqBnPa57QhV1x6yc5PVz532Kb72c8dhZNor6PbznA/exec',
  SUPA_URL: 'https://uledkoviboyewqjfowqx.supabase.co',
  SUPA_KEY: 'sb_publishable_88rNp2Y5thzJk9Q7b9j3iA_te5U7SIz'
};
