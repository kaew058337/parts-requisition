/* สำเนาข้อมูลจาก Supabase ลง Google Sheet ทุกคืน 23:00 (ทางเดียว: Supabase -> ชีท)
 * วิธีติดตั้ง ดูไฟล์ README_BACKUP.md
 * ตั้งค่า (Project Settings > Script properties): SUPA_URL, BACKUP_KEY */
const BK_TABLES = {
  requisitions: 'เบิก', receipts: 'รับ', issues: 'จ่าย', returns_out: 'ส่งคืน', loans: 'ยืม', counts: 'ตรวจนับ', claims: 'เคลม',
  requesters: 'ผู้เบิก', technicians: 'ช่าง', receivers: 'ผู้รับ', holidays: 'วันหยุด', shelf_cells: 'ช่องเก็บ', move_history: 'ประวัติย้ายที่',
  kit_requirements: 'รายการชุดKit', cancelled_records: 'ยกเลิก', activity_log: 'บันทึกกิจกรรม', tci_inbox: 'TCI_รอเบิก'
};

function bkCall_(table) {
  const p = PropertiesService.getScriptProperties();
  const res = UrlFetchApp.fetch(p.getProperty('SUPA_URL') + '/rest/v1/rpc/rpc_backup_export', {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: p.getProperty('SUPA_KEY'), Authorization: 'Bearer ' + p.getProperty('SUPA_KEY') },
    payload: JSON.stringify({ p: { key: p.getProperty('BACKUP_KEY'), table: table } })
  });
  if (res.getResponseCode() !== 200) throw new Error(table + ': HTTP ' + res.getResponseCode() + ' ' + String(res.getContentText()).slice(0, 150));
  return JSON.parse(res.getContentText());
}

function bkWrite_(ss, name, cols, rows) {
  let sh = ss.getSheetByName(name) || ss.insertSheet(name);
  sh.clear();
  const data = [cols].concat(rows.map(r => cols.map(c => {
    const v = r[c];
    if (v === null || v === undefined) return '';
    if (typeof v === 'object') return JSON.stringify(v);
    return v;
  })));
  const isText = cols.map((c, i) => rows.length > 0 && rows.every(r => typeof r[c] === 'string' || r[c] === null));
  cols.forEach((c, i) => { if (isText[i]) sh.getRange(1, i + 1, data.length, 1).setNumberFormat('@'); });
  sh.getRange(1, 1, data.length, cols.length).setValues(data);
  sh.getRange(1, 1, 1, cols.length).setFontWeight('bold').setBackground('#dbeafe');
  sh.setFrozenRows(1);
  return rows.length;
}

/** สำรองทุกตาราง ; เรียกเองได้จากเมนู Run หรือปล่อยให้ตัวตั้งเวลาเรียก */
function backupNow() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const info = [['ตาราง', 'ชื่อแท็บ', 'จำนวนแถว', 'ผล']], errs = [];
  Object.keys(BK_TABLES).forEach(t => {
    try { const r = bkCall_(t); info.push([t, BK_TABLES[t], bkWrite_(ss, BK_TABLES[t], r.cols, r.rows), 'ok']); }
    catch (e) { info.push([t, BK_TABLES[t], '', 'ผิดพลาด: ' + e.message]); errs.push(e.message); }
  });
  let sh = ss.getSheetByName('_สำเนา') || ss.insertSheet('_สำเนา', 0);
  sh.clear();
  sh.getRange(1, 1).setValue('⚠️ ไฟล์นี้เป็นสำเนาจากระบบ Supabase (ห้ามแก้ไขที่นี่ — จะถูกเขียนทับทุกคืน 23:00)').setFontWeight('bold').setFontColor('#b91c1c');
  sh.getRange(2, 1).setValue('สำเนาล่าสุด: ' + Utilities.formatDate(new Date(), 'Asia/Bangkok', 'dd/MM/yyyy HH:mm:ss'));
  sh.getRange(4, 1, info.length, 4).setValues(info);
  sh.getRange(4, 1, 1, 4).setFontWeight('bold').setBackground('#dbeafe');
  sh.setColumnWidth(1, 160); sh.setColumnWidth(2, 140); sh.setColumnWidth(4, 360);
  if (errs.length) {
    try { MailApp.sendEmail(Session.getEffectiveUser().getEmail(), 'สำเนาข้อมูลพัสดุไม่สำเร็จ', errs.join('\n')); } catch (e) { /* ไม่เป็นไร */ }
    throw new Error(errs.join(' | '));
  }
}

/** รันครั้งเดียว: ตั้งเวลาสำรองทุกวัน 23:00 */
function installBackupTrigger() {
  ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === 'backupNow').forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('backupNow').timeBased().everyDays(1).atHour(23).inTimezone('Asia/Bangkok').create();
}
