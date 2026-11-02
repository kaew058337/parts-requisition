/**
 * ระบบเบิก-จ่าย-ส่งคืนพัสดุ  (Google Apps Script + Google Sheet)
 * วางไฟล์นี้ใน Apps Script ที่สร้างจากเมนู ส่วนขยาย > Apps Script ของ Google Sheet
 */

const SHEET_REQ = 'เบิก';
const SHEET_RCV = 'รับ';
const SHEET_ISS = 'จ่าย';
const SHEET_OLD_ISS = 'จ่าย-รับ';
const SHEET_RET = 'ส่งคืน';
const SHEET_USR = 'ผู้เบิก';
const SHEET_TECH = 'ช่าง';
const SHEET_RCVR = 'ผู้รับ';
const SHEET_STK = 'คลังพัสดุ';
const SHEET_LOG = 'บันทึกการใช้งาน';
const SHEET_LOAN = 'ยืมพัสดุ';
const SHEET_CNT = 'ตรวจนับ';
const SHEET_KIT = 'ชุดพัสดุ';
const SHEET_CLAIM = 'เคลม';
const SHEET_RCV2 = 'รับคืนเข้าคลัง';   // ประวัติรับ "คืนเข้าคลัง" แยกจากรับปกติ (โครงสร้างเหมือนชีท รับ)
const WARRANTY_DAYS = 365;        // ประกัน 1 ปี นับจากวันที่รับ (LRU / LRU(TCI)) ; ของที่เคลมกลับมานับใหม่จากวันที่ได้รับกลับ
const WARRANTY_SOON_DAYS = 60;    // เตือน "ใกล้หมดประกัน" เมื่อเหลือไม่เกินกี่วัน
const CLAIM_SENT = 'ส่งเคลมแล้ว';
const CLAIM_REPAIRED = 'ได้ซ่อมกลับ';
const CLAIM_NEW = 'ได้ของใหม่';
const CLAIM_DENIED = 'ถูกปฏิเสธ';
const CLAIM_STATUS = [CLAIM_SENT, CLAIM_REPAIRED, CLAIM_NEW, CLAIM_DENIED];
const LOAN_OPEN = 'ยืมอยู่';
const LOAN_CLOSED = 'ปิดแล้ว';
const LOAN_RETURNED = 'คืนเข้าคลัง';
const LOAN_USED = 'ใช้งานแล้ว (เบิก)';
const LOAN_REPLACED = 'ผู้ยืมเบิกคืนแล้ว';
const LOAN_BORROWER_TYPES = ['ช่าง', 'TAI', 'อื่น ๆ'];
const SERIAL_ALERT_DAYS = 365;
const TZ = 'Asia/Bangkok';
const OPENING = 'ยอดยกมา';
const RETURNED = 'คืนเข้าคลัง';
/** ล็อตที่เลือกรับเข้าใบเบิกใหม่ได้: ยอดยกมา และของที่คืนเข้าคลัง */
function isFreeLot_(d) { return str_(d) === OPENING || str_(d) === RETURNED; }
/** SP / SP(TCI) ไม่มี Serial ; LRU / LRU(TCI) ต้องมี Serial */
function isSP_(t) { return String(t || '').indexOf('SP') === 0; }
function isLRU_(t) { return String(t || '').indexOf('LRU') === 0; }

const ITEM_TYPES = ['LRU', 'SP', 'LRU(TCI)', 'SP(TCI)', 'สารเคมี'];   // สารเคมี: ไม่บังคับ Serial เหมือน SP

const HEADERS = {
  [SHEET_REQ]: ['ลำดับ', 'หมายเลขการเบิก', 'Part number', 'ชื่อ', 'จำนวน', 'หน่วยนับ', 'วันที่เบิก', 'วันที่จ่าย', 'เครื่อง', 'ความเร่งด่วน', 'ข้อขัดข้อง', 'ยศผู้เบิก', 'ชื่อ-สกุลผู้เบิก', 'ตำแหน่งผู้เบิก', 'ประเภทพัสดุ', 'เหตุผลยกเลิก'],
  [SHEET_RCV]: ['ลำดับรับ', 'เลขเอกสารการเบิก', 'card ID', 'Part number', 'ชื่อพัสดุ', 'serial number', 'ประเภทพัสดุ', 'จำนวน', 'หน่วยนับ', 'ราคา/หน่วย', 'ราคารวม', 'COND', 'วันที่แจ้ง', 'ความเร่งด่วน', 'วันกำหนดส่งพัสดุ', 'วันที่รับ', 'วันที่เกิน', 'TAIL No.', 'TCI', 'หมดอายุ', 'LOCATION', 'ผู้รับ', 'หมายเหตุ', 'แหล่งที่มา', 'อ้างอิง'],
  [SHEET_ISS]: ['ลำดับจ่าย', 'วันที่จ่าย', 'เลขเอกสารการเบิก', 'ลำดับรับ (อ้างอิง)', 'Part number', 'ชื่อพัสดุ', 'serial number', 'จำนวน', 'หน่วยนับ', 'TAIL No.', 'จ่ายให้ช่าง', 'หมายเหตุ', 'ผู้บันทึก'],
  [SHEET_CNT]: ['เลขที่ตรวจนับ', 'วันที่ตรวจนับ', 'LOCATION', 'ลำดับรับ', 'Part number', 'ชื่อพัสดุ', 'serial number', 'ประเภทพัสดุ', 'หน่วยนับ', 'ยอดในระบบ', 'นับได้จริง', 'ผลต่าง', 'ผลการปรับ', 'เหตุผล / หมายเหตุ', 'ผู้ตรวจนับ', 'ผู้ตรวจสอบ / กรรมการ', 'เวลาบันทึก'],
  [SHEET_CLAIM]: ['เลขที่เคลม', 'serial number', 'Part number', 'ชื่อพัสดุ', 'ประเภทพัสดุ', 'วันที่ส่งเคลม', 'ที่หนังสือ', 'ผู้รับเคลม/หน่วยงาน', 'สถานะ', 'วันที่ได้รับกลับ', 'serial number ใหม่', 'หมายเหตุ', 'ผู้บันทึก'],
  [SHEET_KIT]: ['ชุด', 'Part number', 'ชื่อพัสดุ', 'ประเภทพัสดุ', 'serial number', 'จำนวนมาตรฐาน', 'LOCATION', 'หมายเหตุ'],
  [SHEET_USR]: ['ยศ', 'ชื่อ-สกุล', 'ตำแหน่ง'],
  [SHEET_TECH]: ['ยศ-ชื่อ นามสกุล'],
  [SHEET_RCVR]: ['ยศ-ชื่อ นามสกุล'],
  [SHEET_LOAN]: ['เลขที่ยืม', 'วันที่ยืม', 'Part number', 'ชื่อพัสดุ', 'serial number', 'ประเภทพัสดุ', 'จำนวน', 'หน่วยนับ', 'จำนวนคงค้าง', 'ผู้ยืม', 'ประเภทผู้ยืม', 'เหตุผล/เครื่อง', 'กำหนดคืน', 'สถานะ', 'วันที่ปิด', 'วิธีปิด', 'เลขเบิกอ้างอิง', 'ลำดับล็อต (อ้างอิง)', 'หมายเหตุ', 'คืนเข้าคลังแล้ว (จำนวน)'],
  [SHEET_LOG]: ['เวลา', 'ผู้ใช้งาน', 'อีเมล', 'การกระทำ', 'เลขเอกสารการเบิก', 'รายละเอียด'],
  [SHEET_STK]: ['ลำดับรับ', 'เลขเอกสารการเบิก', 'Part number', 'ชื่อพัสดุ', 'serial number', 'ประเภทพัสดุ', 'หน่วยนับ', 'จำนวนรับ', 'จำนวนคงเหลือ', 'COND', 'LOCATION', 'หมดอายุ', 'วันที่รับ', 'สถานะ', 'หมายเหตุ'],
  [SHEET_RET]: ['ลำดับ', 'Part number', 'ชื่อ', 'จำนวน', 'serial number ส่งคืน', 'serial number ที่ใส่', 'ผู้รับ', 'ผู้ส่ง', 'เครื่อง', 'ข้อขัดข้อง', 'หมายเหตุ', 'วันที่บันทึก', 'ที่หนังสือ', 'สภาพพัสดุ']
};

/* ---------- Web app entry ---------- */

function doGet() {
  return HtmlService.createHtmlOutputFromFile('Index')
    .setTitle('ระบบเบิก-จ่าย-ส่งคืน')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1, viewport-fit=cover')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}


/* ---------- API สำหรับหน้าเว็บที่โฮสต์ภายนอก (GitHub Pages + LINE LIFF) ----------
   หน้าเว็บส่ง POST (text/plain, JSON) { fn, args, idToken } มาที่ URL /exec
   - ตรวจ LINE ID token กับ LINE ทุกครั้ง (cache ไว้ตามอายุ token)
   - จำกัดผู้ใช้ได้ที่ Script property ALLOWED_LINE_IDS (คั่นด้วย ,) เว้นว่าง = LINE ทุกบัญชีที่เข้าได้
   - Script property API_REQUIRE_LINE = 0 ปิดการตรวจ (ใช้ทดสอบเท่านั้น) */
const LINE_CHANNEL_ID = '2012314415';
const API_FUNCS_ = {
  getBootstrap: getBootstrap,
  addOpeningStock: addOpeningStock,
  cancelRequisition: cancelRequisition,
  checkSerialAlert: checkSerialAlert,
  checkSerialAlerts: checkSerialAlerts,
  closeLoanReplaced: closeLoanReplaced,
  editRequisition: editRequisition,
  getCountHistory: getCountHistory,
  getCountList: getCountList,
  getCountLocations: getCountLocations,
  getHistory: getHistory,
  getSerialHistory: getSerialHistory,
  getClaims: getClaims,
  getWarrantyList: getWarrantyList,
  submitClaim: submitClaim,
  updateClaim: updateClaim,
  getKits: getKits,
  getLoans: getLoans,
  getLoansForPart: getLoansForPart,
  getNextReturnNo: getNextReturnNo,
  getOpeningLots: getOpeningLots,
  getPendingIssue: getPendingIssue,
  getPendingReceive: getPendingReceive,
  getReconcile: getReconcile,
  getReturnable: getReturnable,
  getStock: getStock,
  issueFromLot: issueFromLot,
  kitBack: kitBack,
  kitCheckout: kitCheckout,
  moveLocation: moveLocation,
  returnLoan: returnLoan,
  submitBorrow: submitBorrow,
  submitCount: submitCount,
  submitIssue: submitIssue,
  submitReceive: submitReceive,
  submitRequisition: submitRequisition,
  submitReturn: submitReturn,
  submitReturnToStock: submitReturnToStock,
};

function authErr_(msg) { const e = new Error(msg); e.auth = true; return e; }

function verifyLine_(tok) {
  const props = PropertiesService.getScriptProperties();
  if (props.getProperty('API_REQUIRE_LINE') === '0') return { sub: '(open)', name: '' };
  if (!tok) throw authErr_('กรุณาเปิดผ่าน LINE (ไม่พบ token)');
  const cache = CacheService.getScriptCache();
  const key = 'lt_' + Utilities.base64EncodeWebSafe(
    Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, tok)).slice(0, 40);
  let prof = null;
  const hit = cache.get(key);
  if (hit) prof = JSON.parse(hit);
  else {
    const r = UrlFetchApp.fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'post', payload: { id_token: tok, client_id: LINE_CHANNEL_ID }, muteHttpExceptions: true
    });
    if (r.getResponseCode() !== 200) throw authErr_('LINE token ไม่ถูกต้องหรือหมดอายุ');
    const j = JSON.parse(r.getContentText());
    prof = { sub: j.sub, name: j.name || '' };
    const ttl = Math.min(1800, Math.max(60, (Number(j.exp) || 0) - Math.floor(Date.now() / 1000) - 30));
    cache.put(key, JSON.stringify(prof), ttl);
  }
  const allow = (props.getProperty('ALLOWED_LINE_IDS') || '').split(',').map(x => x.trim()).filter(Boolean);
  if (allow.length && allow.indexOf(prof.sub) < 0) throw authErr_('บัญชี LINE นี้ยังไม่ได้รับอนุญาต (รหัส: ' + prof.sub + ')');
  return prof;
}

function doPost(e) {
  let out;
  try {
    const req = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    const fn = String(req.fn || '');
    if (!Object.prototype.hasOwnProperty.call(API_FUNCS_, fn)) throw new Error('ไม่รู้จักคำสั่ง: ' + fn);
    verifyLine_(req.idToken);
    const data = API_FUNCS_[fn].apply(null, Array.isArray(req.args) ? req.args : []);
    out = { ok: true, data: data === undefined ? null : data };
  } catch (err) {
    out = { ok: false, error: String((err && err.message) || err), auth: !!(err && err.auth) };
  }
  return ContentService.createTextOutput(JSON.stringify(out)).setMimeType(ContentService.MimeType.JSON);
}

/* ---------- Setup ---------- */

/** รันครั้งแรก 1 ครั้ง (เลือกฟังก์ชัน setup แล้วกด Run) เพื่อสร้าง 3 ชีท */
function setup() {
  Object.keys(HEADERS).forEach(getSheet_);
  SpreadsheetApp.getActiveSpreadsheet().toast('สร้างชีทเรียบร้อย');
}

let MIGRATING_ = false;
let MIGRATION_NOTE_ = '';
HEADERS[SHEET_RCV2] = HEADERS[SHEET_RCV];
const HDR_STYLE_ = (rg) => rg.setFontWeight('bold').setBackground('#1a56db').setFontColor('#ffffff')
  .setHorizontalAlignment('center').setVerticalAlignment('middle').setWrap(true);

function getSheet_(name) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!MIGRATING_ && (name === SHEET_RCV || name === SHEET_RCV2 || name === SHEET_ISS || name === SHEET_STK || name === SHEET_LOAN)) ensureMigrated_(ss);
  let sh = ss.getSheetByName(name);
  if (sh && (name === SHEET_RCV || name === SHEET_RCV2) && sh.getLastColumn() >= 18 && sh.getRange(1, 3).getValue() !== 'card ID' && sh.getRange(1, 18).getValue() === 'card ID') {
    // ชีทเดิม: ย้ายคอลัมน์ card ID (R) มาไว้ถัดจาก เลขเอกสารการเบิก (C)
    sh.moveColumns(sh.getRange(1, 18, sh.getMaxRows(), 1), 3);
    sh.getRange(1, 3).setNumberFormat('General');
  }
  if (sh && name === SHEET_REQ && sh.getRange(1, 16).getValue() === '') {
    // ชีทเบิกเดิม: เติมหัวคอลัมน์ผู้เบิก ประเภทพัสดุ และเหตุผลยกเลิกท้ายตาราง
    HDR_STYLE_(sh.getRange(1, 12, 1, 5).setValues([HEADERS[SHEET_REQ].slice(11, 16)]));
  }
  if (sh && name === SHEET_LOAN && sh.getRange(1, 20).getValue() === '') {
    // ชีทยืมเดิม: เติมคอลัมน์ จำนวนที่คืนเข้าคลังแล้ว ท้ายตาราง
    if (sh.getMaxColumns() < 20) sh.insertColumnsAfter(sh.getMaxColumns(), 20 - sh.getMaxColumns());
    HDR_STYLE_(sh.getRange(1, 20).setValue(HEADERS[SHEET_LOAN][19]));
  }
  if (sh && name === SHEET_RET && sh.getRange(1, 14).getValue() === '') {
    // ชีทส่งคืนเดิม: เติมคอลัมน์ ที่หนังสือ / สภาพพัสดุ ท้ายตาราง
    if (sh.getMaxColumns() < 14) sh.insertColumnsAfter(sh.getMaxColumns(), 14 - sh.getMaxColumns());
    HDR_STYLE_(sh.getRange(1, 13, 1, 2).setValues([HEADERS[SHEET_RET].slice(12, 14)]));
    sh.getRange('M2:M').setNumberFormat('@');
  }
  if (!sh) {
    sh = ss.insertSheet(name);
    const h = HEADERS[name];
    HDR_STYLE_(sh.getRange(1, 1, 1, h.length).setValues([h]));
    sh.setFrozenRows(1);
    sh.setRowHeight(1, 36);
    if (name === SHEET_REQ) {
      sh.getRange('B2:B').setNumberFormat('@');
      sh.getRange('G2:H').setNumberFormat('dd/mm/yyyy');
    } else if (name === SHEET_RCV || name === SHEET_RCV2) {
      sh.getRange('B2:C').setNumberFormat('@');
      sh.getRange(2, rcCol_(RC.NOTIFY), 999, 1).setNumberFormat('dd/mm/yyyy');
      sh.getRange(2, rcCol_(RC.DUE), 999, 2).setNumberFormat('dd/mm/yyyy');
      sh.getRange(2, rcCol_(RC.EXP), 999, 1).setNumberFormat('dd/mm/yyyy');
      sh.getRange(2, rcCol_(RC.OVER), 999, 1).setNumberFormat('0');
      sh.getRange(2, rcCol_(RC.PRICE), 999, 2).setNumberFormat('#,##0.00');
    } else if (name === SHEET_ISS) {
      sh.getRange('B2:B').setNumberFormat('dd/mm/yyyy');
      sh.getRange('C2:C').setNumberFormat('@');
    } else if (name === SHEET_LOAN) {
      sh.getRange('B2:B').setNumberFormat('dd/mm/yyyy');
      sh.getRange('M2:M').setNumberFormat('dd/mm/yyyy');
      sh.getRange('O2:O').setNumberFormat('dd/mm/yyyy');
      sh.getRange('Q2:Q').setNumberFormat('@');
    } else if (name === SHEET_LOG) {
      sh.getRange('A2:A').setNumberFormat('dd/mm/yyyy hh:mm:ss');
      sh.getRange('E2:E').setNumberFormat('@');
    } else if (name === SHEET_STK) {
      sh.getRange('B2:B').setNumberFormat('@');
      sh.getRange('L2:M').setNumberFormat('dd/mm/yyyy');
    } else if (name === SHEET_KIT) {
      sh.getRange('B2:B').setNumberFormat('@');
      sh.getRange('E2:E').setNumberFormat('@');
    } else if (name === SHEET_CNT) {
      sh.getRange('A2:A').setNumberFormat('@');
      sh.getRange('B2:B').setNumberFormat('dd/mm/yyyy');
      sh.getRange('Q2:Q').setNumberFormat('dd/mm/yyyy hh:mm');
    } else if (name === SHEET_RET) {
      sh.getRange('L2:L').setNumberFormat('dd/mm/yyyy hh:mm');
      sh.getRange('M2:M').setNumberFormat('@');
    }
    sh.autoResizeColumns(1, h.length);
  }
  ensureTextCols_(sh, name);
  return sh;
}

/* ---------- กัน Google Sheets แปลง Part number / Serial เป็นวันที่ (เช่น 5-12, 3/4) ---------- */
// คอลัมน์ Part number / Serial ของแต่ละชีท (เลขคอลัมน์ เริ่ม 1) ตั้งเป็นรูปแบบ "ข้อความ" ทั้งคอลัมน์
const TEXT_COLS_ = {};
TEXT_COLS_[SHEET_REQ] = [3];
TEXT_COLS_[SHEET_RCV] = [3, 4, 6];   // Part, serial (หลังย้าย card ID มาคอลัมน์ C)
TEXT_COLS_[SHEET_RCV2] = [3, 4, 6];
TEXT_COLS_[SHEET_ISS] = [5, 7];
TEXT_COLS_[SHEET_STK] = [3, 5];
TEXT_COLS_[SHEET_LOAN] = [3, 5];
TEXT_COLS_[SHEET_RET] = [2, 5, 6];
TEXT_COLS_[SHEET_KIT] = [2, 5];
TEXT_COLS_[SHEET_CNT] = [5, 7];
TEXT_COLS_[SHEET_CLAIM] = [2, 3, 11];
const TXT_DONE_ = {};

/** ตั้งรูปแบบข้อความให้คอลัมน์ Part/Serial (ทำครั้งเดียวต่อชีท) ; ช่องที่ถูกแปลงเป็นวันที่ไปแล้วจะไม่ถูกแตะ แต่ระบายสีเหลืองไว้ให้แก้ */
function ensureTextCols_(sh, name, force) {
  const cols = TEXT_COLS_[name];
  if (!cols || !sh || (!force && TXT_DONE_[name])) return;
  TXT_DONE_[name] = true;
  // เหลือแถวว่างไม่พอ → เพิ่มแถวและตั้งเป็นข้อความล่วงหน้า (แถวที่ Sheets เพิ่มเองตอนเขียนเกินขอบ จะเป็นรูปแบบทั่วไป ทำให้เลข 0 นำหน้าหาย)
  try {
    const mx = sh.getMaxRows();
    if (mx - sh.getLastRow() < 300) {
      sh.insertRowsAfter(mx, 1000);
      cols.forEach(c => sh.getRange(mx + 1, c, 1000, 1).setNumberFormat('@'));
    }
  } catch (e) { /* ไม่ให้ล้ม */ }
  let props = null;
  try { props = PropertiesService.getDocumentProperties(); } catch (e) { props = null; }
  const key = 'txtcols2:' + name;
  if (!force && props && props.getProperty(key)) return;
  try {
    const max = Math.max(sh.getMaxRows(), 2), last = sh.getLastRow();
    cols.forEach(c => {
      const rng = sh.getRange(2, c, max - 1, 1);
      const dateRows = [];
      if (last >= 2) sh.getRange(2, c, last - 1, 1).getValues().forEach((r, i) => { if (r[0] instanceof Date) dateRows.push(i + 2); });
      rng.setNumberFormat('@');
      dateRows.forEach(r => sh.getRange(r, c).setNumberFormat('dd/mm/yyyy').setBackground('#fff2a8'));
    });
    if (props) props.setProperty(key, '1');
  } catch (e) { /* ไม่ให้การตั้งรูปแบบทำให้ระบบหลักล้ม */ }
}

/**
 * นำค่า Part number / Serial ที่แก้ไว้ในชีท "คลังพัสดุ" ไปแก้ที่ชีทต้นทางให้ (รับ, จ่าย, ยืมพัสดุ, ใบเบิก, ชุดพัสดุ, เคลม)
 * ใช้: แก้ช่อง Part / serial ในคลังพัสดุ แล้วกดเมนูนี้ทันที (ก่อนมีการเคลื่อนไหวอื่นที่ทำให้ชีทถูกสร้างใหม่)
 */
function applyStockEdits() {
  return withLock_(() => {
    const stk = getSheet_(SHEET_STK), last = stk.getLastRow();
    const out = { applied: [], skipped: [] };
    if (last >= 2) {
      const sRows = stk.getRange(2, 1, last - 1, HEADERS[SHEET_STK].length).getValues();
      const iss = getSheet_(SHEET_ISS), loan = getSheet_(SHEET_LOAN);
      const rc = readRcv_();
      const rcBySeq = {};
      rc.forEach((r, i) => { rcBySeq[str_(r[RC.SEQ])] = i; });
      const snUsed = {};
      rc.forEach(r => { const k = snKey_(r[RC.SN]); if (k) snUsed[k] = (snUsed[k] || 0) + 1; });
      const setTxt = (sh, row, col, v) => sh.getRange(row, col).setNumberFormat('@').setValue(v);
      const issRows = readIss_(), loanRows = readLoans_();
      sRows.forEach((sr, i) => {
        const seq = str_(sr[0]);
        if (!seq || rcBySeq[seq] === undefined) return;
        const idx = rcBySeq[seq], r = rc[idx];
        const oldPart = str_(r[RC.PART]), oldSn = str_(r[RC.SN]);
        const newPart = sr[2] instanceof Date ? null : str_(sr[2]);
        const newSn = sr[4] instanceof Date ? null : str_(sr[4]);
        if (newPart === null || newSn === null) { out.skipped.push('แถว ' + (i + 2) + ' ยังเป็นวันที่ — พิมพ์ค่าที่ถูกต้องทับก่อน'); return; }
        const partCh = newPart !== oldPart, snCh = newSn !== oldSn;
        if (!partCh && !snCh) return;
        if (!newPart) { out.skipped.push('แถว ' + (i + 2) + ' Part ว่างไม่ได้'); return; }
        if (snCh && newSn && snKey_(newSn) !== snKey_(oldSn) && snUsed[snKey_(newSn)]) {
          out.skipped.push('แถว ' + (i + 2) + ' S/N ' + newSn + ' ซ้ำกับรายการอื่น'); return;
        }
        if (snCh && !newSn && oldSn) { out.skipped.push('แถว ' + (i + 2) + ' ลบ S/N ไม่ได้ (ต้องมีค่า)'); return; }
        const rrow = r._row, rcv = getSheet_(r._sh), doc = str_(r[RC.DOC]);
        if (partCh) setTxt(rcv, rrow, rcCol_(RC.PART), newPart);
        if (snCh) { setTxt(rcv, rrow, rcCol_(RC.SN), newSn); snUsed[snKey_(oldSn)] = 0; if (newSn) snUsed[snKey_(newSn)] = 1; }
        // จ่าย
        issRows.forEach((ir, j) => {
          if (str_(ir[IS.RSEQ]) !== seq) return;
          if (partCh) setTxt(iss, j + 2, IS.PART + 1, newPart);
          if (snCh) setTxt(iss, j + 2, IS.SN + 1, newSn);
        });
        // ยืมพัสดุ (ลำดับล็อต col 18)
        loanRows.forEach((lr, j) => {
          if (str_(lr[17]) !== seq) return;
          if (partCh) setTxt(loan, j + 2, 3, newPart);
          if (snCh) setTxt(loan, j + 2, 5, newSn);
        });
        // ใบเบิก (ให้ยังจับคู่ รับ↔เบิก ได้)
        if (partCh && doc && (str_(r[RC.SRC]) || SRC_REQ) === SRC_REQ) {
          const req = getSheet_(SHEET_REQ), rl = req.getLastRow();
          if (rl >= 2) {
            const rv = req.getRange(2, 1, rl - 1, 3).getValues();
            const hit = rv.map((x, k) => ({ x, k })).filter(o => pad_(o.x[1], 9) === pad_(doc, 9));
            const pick = hit.length === 1 ? hit : hit.filter(o => str_(o.x[2]) === oldPart);
            pick.forEach(o => setTxt(req, o.k + 2, 3, newPart));
          }
        }
        // ชุดพัสดุ / เคลม ที่อ้าง S/N เดิม
        if (snCh && oldSn) {
          readKit_().forEach(k => { if (snKey_(k.serial) === snKey_(oldSn)) { setTxt(getSheet_(SHEET_KIT), k.row, 5, newSn); if (partCh) setTxt(getSheet_(SHEET_KIT), k.row, 2, newPart); } });
          readClaims_().forEach(c => {
            const sh = getSheet_(SHEET_CLAIM);
            if (snKey_(c.sn) === snKey_(oldSn)) { setTxt(sh, c.row, 2, newSn); if (partCh) setTxt(sh, c.row, 3, newPart); }
            if (snKey_(c.newSn) === snKey_(oldSn)) setTxt(sh, c.row, 11, newSn);
          });
        }
        out.applied.push('ลำดับรับ ' + seq + ': ' + (partCh ? 'Part ' + oldPart + ' → ' + newPart + ' ' : '') + (snCh ? 'S/N ' + (oldSn || '(ว่าง)') + ' → ' + (newSn || '(ว่าง)') : ''));
        log_('แก้ Part/S/N จากคลังพัสดุ', doc, out.applied[out.applied.length - 1], 'เมนูชีท');
      });
    }
    rebuildStock_();
    try {
      const ui = SpreadsheetApp.getUi();
      ui.alert(out.applied.length ? 'นำค่าที่แก้ไปใช้แล้ว ' + out.applied.length + ' รายการ' : 'ไม่พบค่าที่แก้ต่างจากต้นทาง',
        out.applied.slice(0, 20).join('\n') + (out.skipped.length ? '\n\nข้าม ' + out.skipped.length + ' รายการ:\n' + out.skipped.slice(0, 15).join('\n') : '') +
        (out.applied.length || out.skipped.length ? '' : '\nแก้ช่อง Part number หรือ serial number ในชีทคลังพัสดุ แล้วกดเมนูนี้อีกครั้ง'), ui.ButtonSet.OK);
    } catch (e) { /* ไม่มี UI */ }
    return out;
  });
}

/** หา Part number / Serial ที่ถูก Google Sheets แปลงเป็นวันที่ไปแล้ว : ระบายสีเหลืองและรายงาน (ต้องพิมพ์ค่าที่ถูกต้องใหม่เอง) */
function findDateParts() {
  const ss = SpreadsheetApp.getActiveSpreadsheet(), found = [];
  Object.keys(TEXT_COLS_).forEach(name => {
    const sh = ss.getSheetByName(name);
    if (!sh) return;
    ensureTextCols_(sh, name, true);
    const last = sh.getLastRow();
    if (last < 2) return;
    TEXT_COLS_[name].forEach(c => {
      sh.getRange(2, c, last - 1, 1).getValues().forEach((r, i) => {
        if (r[0] instanceof Date) found.push({ sheet: name, row: i + 2, col: sh.getRange(1, c).getValue(), shown: Utilities.formatDate(r[0], TZ, 'dd/MM/yyyy') });
      });
    });
  });
  try {
    const ui = SpreadsheetApp.getUi();
    ui.alert(found.length ? 'พบ ' + found.length + ' ช่องที่ถูกแปลงเป็นวันที่' : 'ไม่พบ Part number / Serial ที่ถูกแปลงเป็นวันที่',
      found.length ? found.slice(0, 25).map(f => f.sheet + ' แถว ' + f.row + ' (' + f.col + ') = ' + f.shown).join('\n') +
        (found.length > 25 ? '\n... และอีก ' + (found.length - 25) + ' ช่อง' : '') +
        '\n\nช่องเหล่านี้ถูกระบายสีเหลืองแล้ว ให้พิมพ์ Part/Serial ที่ถูกต้องทับ (แก้ที่ชีท รับ / จ่าย / เบิก ซึ่งเป็นต้นทาง) ชีท คลังพัสดุ จะอัปเดตตามเอง' : 'ทุกคอลัมน์ Part/Serial ถูกตั้งเป็นข้อความแล้ว',
      ui.ButtonSet.OK);
  } catch (e) { /* ไม่มี UI */ }
  return found;
}

/* ---------- ย้ายข้อมูลจากชีท จ่าย-รับ เดิม (ทำครั้งเดียวอัตโนมัติ ไม่ลบข้อมูลเดิม) ---------- */

function ensureMigrated_(ss) {
  if (MIGRATING_ || ss.getSheetByName(SHEET_RCV)) return;
  const old = ss.getSheetByName(SHEET_OLD_ISS);
  if (!old) return; // ติดตั้งใหม่ ไม่มีข้อมูลเดิม
  MIGRATING_ = true;
  try { migrateFromOld_(ss, old); } finally { MIGRATING_ = false; }
}

function padRow_(r, n) { const o = r.slice(0, n); while (o.length < n) o.push(''); return o; }

function migrateFromOld_(ss, old) {
  const rd = (sh, w) => {
    if (!sh) return [];
    const last = sh.getLastRow();
    return last >= 2 ? sh.getRange(2, 1, last - 1, Math.min(w, sh.getMaxColumns())).getValues().map(r => padRow_(r, w)) : [];
  };
  const oldIss = rd(old, 26);
  const stkSh = ss.getSheetByName(SHEET_STK);
  const oldStk = rd(stkSh, 17);
  const loanSh = ss.getSheetByName(SHEET_LOAN);
  const loans = rd(loanSh, 20);
  const reqRows = rd(ss.getSheetByName(SHEET_REQ), 15);
  const typeOf = {};
  reqRows.forEach(r => { typeOf[pad_(r[1], 9) + '|' + str_(r[2])] = str_(r[14]); });

  const OLD_FREE = (d) => str_(d) === SRC_OPEN || str_(d) === SRC_RET;
  const issSet = {};
  oldIss.forEach(r => { if (str_(r[1])) issSet[Number(r[0])] = true; });
  const sn_ = x => str_(x).toUpperCase();

  // ล็อตเก่าที่ใช้เก็บพัสดุของแต่ละแถวรับ (ผูกด้วยลำดับอ้างอิง ถ้าไม่มี จับคู่ด้วยเลขใบเบิก+Part+Serial)
  const lotOfIss = {}, usedStk = {};
  oldStk.forEach((x, i) => {
    if (OLD_FREE(x[1])) return;
    const ref = Number(x[15]);
    if (ref && issSet[ref] && !lotOfIss[ref]) { lotOfIss[ref] = { v: x, i: i }; usedStk[i] = true; }
  });
  oldIss.forEach(r => {
    const seq = Number(r[0]);
    if (!str_(r[1]) || lotOfIss[seq]) return;
    for (let i = 0; i < oldStk.length; i++) {
      const x = oldStk[i];
      if (usedStk[i] || OLD_FREE(x[1]) || (Number(x[15]) && issSet[Number(x[15])])) continue;
      if (docStr_(x[1]) === docStr_(r[1]) && str_(x[2]) === str_(r[2]) && sn_(x[4]) === sn_(r[4])) { lotOfIss[seq] = { v: x, i: i }; usedStk[i] = true; break; }
    }
  });

  // ยอดที่ยืมออกและยังไม่คืน แยกตามลำดับล็อตเก่า
  const loanUnret = {};
  loans.forEach(r => {
    const k = Number(r[17]); if (!k) return;
    const returned = str_(r[15]) === LOAN_RETURNED ? num_(r[6]) - num_(r[8]) : 0;
    r[19] = returned;
    loanUnret[k] = (loanUnret[k] || 0) + Math.max(0, num_(r[6]) - returned);
  });

  let maxSeq = 0;
  oldIss.forEach(r => { if (Number(r[0]) > maxSeq) maxSeq = Number(r[0]); });
  let nextRcv = maxSeq + 1;
  const seqOfStk = {};          // ลำดับล็อตเก่า -> ลำดับรับใหม่
  const rcvRows = [], issRows = [];
  const issNewSeq = {};         // ลำดับแถวรับเก่า -> ลำดับจ่ายใหม่ (เฉพาะที่จ่ายให้ช่างแล้ว)
  let issN = 1;
  const missing = [];
  const mk = (seq, doc, part, name, sn, type, qty, unit, price, cond, notify, urg, due, rdate, tail, card, tci, exp, loc, recv, note, src, ref) =>
    [seq, doc, part, name, sn, type, qty, unit, price, '', cond, notify, urg, due, rdate, '', tail, card, tci, exp, loc, recv, note, src, ref];

  oldIss.forEach(r => {
    if (!str_(r[1])) return;
    const doc = docStr_(r[1]);
    if (doc === DIRECT) return;      // จัดการในขั้นถัดไป
    const seq = Number(r[0]);
    const lot = lotOfIss[seq];
    const issued = str_(r[20]) !== '';
    const qtyOld = num_(r[5]);
    let qty = qtyOld;
    if (!issued) {
      if (lot) {
        const st = str_(lot.v[14]);
        const eff = num_(lot.v[8]) + (loanUnret[Number(lot.v[0])] || 0);
        if ((st === 'ในคลัง' || st === 'ถูกยืม') && eff > 0) qty = eff;      // ยึดจำนวนจากคลังพัสดุ
      } else missing.push(doc + ' (' + str_(r[2]) + ')');
    }
    if (lot) seqOfStk[Number(lot.v[0])] = seq;
    const rdate = lot && lot.v[12] instanceof Date ? lot.v[12] : (r[13] instanceof Date ? r[13] : '');
    rcvRows.push(mk(seq, doc, str_(r[2]), str_(r[3]), str_(r[4]), typeOf[doc + '|' + str_(r[2])] || (lot ? str_(lot.v[5]) : ''), qty,
      str_(r[6]), r[7], str_(r[8]), r[10], str_(r[11]), r[12], rdate, str_(r[15]), str_(r[17]), str_(r[19]),
      r[21], str_(r[22]), str_(r[23]), str_(r[16]), SRC_REQ, ''));
    if (issued) {
      issNewSeq[seq] = issN;
      issRows.push([issN++, r[25] instanceof Date ? r[25] : (r[13] instanceof Date ? r[13] : ''), doc, seq, str_(r[2]), str_(r[3]), str_(r[4]),
        qtyOld, str_(r[6]), str_(r[15]), str_(r[20]), '', 'ย้ายข้อมูล']);
    }
  });

  // ล็อตยอดยกมา / คืนเข้าคลัง (และล็อตที่ไม่มีแถวรับคู่กัน)
  const freeLots = [];
  oldStk.forEach((x, i) => {
    const free = OLD_FREE(x[1]);
    if (!free && usedStk[i]) return;
    const oseq = Number(x[0]);
    const unret = loanUnret[oseq] || 0;
    if (free) {
      const seq = nextRcv++;
      seqOfStk[oseq] = seq;
      const ref = str_(x[1]) === SRC_RET ? (issNewSeq[Number(x[15])] || '') : '';
      const fl = { seq: seq, part: str_(x[2]), name: str_(x[3]), sn: str_(x[4]), unit: str_(x[6]), left: Math.max(0, num_(x[7]) - num_(x[8]) - unret), recv: x[12] };
      freeLots.push(fl);
      rcvRows.push(mk(seq, '', str_(x[2]), str_(x[3]), str_(x[4]), str_(x[5]), num_(x[7]), str_(x[6]), '', str_(x[9]), '', '', '',
        x[12] instanceof Date ? x[12] : '', '', '', '', x[11], str_(x[10]), '', str_(x[16]), str_(x[1]), ref));
    } else {                              // ล็อตตามใบเบิกที่ไม่มีแถวรับคู่กัน
      const q = num_(x[8]) + unret;
      if (q <= 0) return;
      const seq = nextRcv++;
      seqOfStk[oseq] = seq;
      rcvRows.push(mk(seq, docStr_(x[1]), str_(x[2]), str_(x[3]), str_(x[4]), str_(x[5]), q, str_(x[6]), '', str_(x[9]), '', '', '',
        x[12] instanceof Date ? x[12] : '', '', '', '', x[11], str_(x[10]), '', 'ย้ายข้อมูล: ไม่พบแถวรับคู่กัน', SRC_REQ, ''));
      missing.push(docStr_(x[1]) + ' (ล็อตไม่มีแถวรับ)');
    }
  });

  // แถว "จ่ายตรง" เดิม -> แถวจ่าย โดยผูกกับล็อตยอดยกมาที่ Part/Serial ตรงกัน
  oldIss.forEach(r => {
    if (!str_(r[1]) || docStr_(r[1]) !== DIRECT) return;
    const qty = num_(r[5]);
    let lot = freeLots.filter(l => l.left > 0 && l.part === str_(r[2]) && sn_(l.sn) === sn_(r[4]))[0] ||
              freeLots.filter(l => l.left > 0 && l.part === str_(r[2]))[0] || null;
    if (lot) lot.left = Math.max(0, lot.left - qty);
    issRows.push([issN++, r[25] instanceof Date ? r[25] : (r[13] instanceof Date ? r[13] : ''), DIRECT, lot ? lot.seq : '',
      str_(r[2]), str_(r[3]), str_(r[4]), qty, str_(r[6]), str_(r[15]), str_(r[20]), str_(r[16]), 'ย้ายข้อมูล']);
  });
  // ส่วนที่ล็อตยอดยกมาถูกใช้ไปแล้ว (โอนเข้าใบเบิก) -> บันทึกเป็นแถวจ่ายออกจากล็อต
  freeLots.forEach(l => {
    if (l.left > 0) issRows.push([issN++, l.recv instanceof Date ? l.recv : '', '', l.seq, l.part, l.name, l.sn, l.left, l.unit, '', '',
      XFER_NOTE + ' (ย้ายข้อมูล)', 'ย้ายข้อมูล']);
  });

  // เขียนชีทใหม่
  const rsh = getSheet_(SHEET_RCV);
  const ish = getSheet_(SHEET_ISS);
  rcvRows.sort((a, b) => a[0] - b[0]);
  if (rcvRows.length) {
    writeRcvRows_(rsh, 2, rcvRows);
  }
  if (issRows.length) {
    ish.getRange(2, 3, issRows.length, 1).setNumberFormat('@');
    ish.getRange(2, 1, issRows.length, HEADERS[SHEET_ISS].length).setValues(issRows);
    ish.getRange(2, 2, issRows.length, 1).setNumberFormat('dd/mm/yyyy');
  }

  // ยืมพัสดุ: อ้างอิงล็อตใหม่ + จำนวนที่คืนเข้าคลังแล้ว
  if (loanSh && loans.length) {
    if (loanSh.getMaxColumns() < 20) loanSh.insertColumnsAfter(loanSh.getMaxColumns(), 20 - loanSh.getMaxColumns());
    HDR_STYLE_(loanSh.getRange(1, 20).setValue(HEADERS[SHEET_LOAN][19]));
    loanSh.getRange(2, 18, loans.length, 1).setValues(loans.map(r => [seqOfStk[Number(r[17])] || '']));
    loanSh.getRange(2, 20, loans.length, 1).setValues(loans.map(r => [num_(r[19])]));
  }

  // คลังพัสดุ: ล้างรูปแบบเก่า แล้วให้ระบบคำนวณใหม่
  if (stkSh) {
    stkSh.getRange(1, 1, Math.max(stkSh.getMaxRows(), 2), Math.max(stkSh.getMaxColumns(), 17)).clearContent();
    HDR_STYLE_(stkSh.getRange(1, 1, 1, HEADERS[SHEET_STK].length).setValues([HEADERS[SHEET_STK]]));
    stkSh.getRange('L2:N').setNumberFormat('dd/mm/yyyy');
  }
  old.setName(SHEET_OLD_ISS + ' (เก่า)');
  MIGRATING_ = false;
  rebuildStock_();
  MIGRATING_ = true;
  MIGRATION_NOTE_ = 'ย้ายข้อมูลจากชีท จ่าย-รับ เดิมแล้ว: รับ ' + rcvRows.length + ' แถว, จ่าย ' + issRows.length + ' แถว' +
    (missing.length ? ' · ตรวจสอบ: ' + missing.join(', ') : '');
  log_('ย้ายข้อมูล', '', MIGRATION_NOTE_, 'ระบบ');
}

/* ---------- Helpers ---------- */

function pad_(n, len) { return String(n).padStart(len, '0'); }

function todayStr_() { return Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd'); }

function parseDate_(s) {
  if (!s) return '';
  const p = String(s).split('-').map(Number);
  return new Date(p[0], p[1] - 1, p[2]);
}

function fmtThai_(d) {
  if (!(d instanceof Date)) return d === null || d === undefined ? '' : String(d);
  const be = Number(Utilities.formatDate(d, TZ, 'yyyy')) + 543;
  return Utilities.formatDate(d, TZ, 'dd/MM/') + be;
}

function fmtCell_(v) {
  if (v instanceof Date) {
    const hasTime = v.getHours() || v.getMinutes();
    return fmtThai_(v) + (hasTime ? Utilities.formatDate(v, TZ, ' HH:mm') : '');
  }
  return v === null || v === undefined ? '' : String(v);
}

const UNPAID = 'ค้างจ่าย';
const CANCELLED = 'ยกเลิก';

/** วันที่จ่ายในชีทเบิก: ถือว่าจ่ายแล้วเมื่อมีค่า และไม่ใช่ว่าง/ค้างจ่าย */
function isPaid_(v) { return v !== '' && v !== null && v !== undefined && v !== UNPAID && v !== CANCELLED; }
function isCancelled_(v) { return v === CANCELLED; }

/** กำหนดส่งพัสดุ = วันที่เบิก + (ปกติ 30 วัน / AOG 7 วัน) */
function urgencyDays_(u) {
  const t = String(u || '').trim().toUpperCase();
  return t === 'AOG' || t === 'ด่วน' || t === 'ด่วนมาก' ? 7 : 30;
}

function dueDate_(reqDate, urgency) {
  if (!(reqDate instanceof Date)) return '';
  return new Date(reqDate.getFullYear(), reqDate.getMonth(), reqDate.getDate() + urgencyDays_(urgency));
}

/** เลขเอกสาร: เลขเบิก 9 หลักเติม 0 นำหน้า / ข้อความอื่น (เช่น ยอดยกมา) คงเดิม */
function docStr_(v) { return /^\d+$/.test(String(v)) ? pad_(v, 9) : str_(v); }

function str_(v) { return v === null || v === undefined ? '' : String(v).trim(); }

function num_(v) {
  const n = Number(v);
  return isFinite(n) ? n : 0;
}

/** บันทึกการใช้งาน (ผู้ใช้งานตามชื่อที่ตั้งในแอป + อีเมลถ้าระบบระบุได้) ; ล้มเหลวไม่กระทบงานหลัก */
function log_(action, docNo, detail, by) {
  try {
    const sh = getSheet_(SHEET_LOG);
    let mail = '';
    try { mail = Session.getActiveUser().getEmail() || ''; } catch (e) { mail = ''; }
    const r = sh.getLastRow() + 1;
    sh.getRange(r, 5).setNumberFormat('@');
    sh.getRange(r, 1).setNumberFormat('dd/mm/yyyy hh:mm:ss');
    sh.getRange(r, 1, 1, 6).setValues([[new Date(), str_(by) || '(ไม่ระบุ)', mail, action, docNo || '', detail || '']]);
  } catch (e) { /* ignore */ }
}

function withLock_(fn) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try { return fn(); } finally { lock.releaseLock(); }
}

function nextSeq_(sh) {
  const last = sh.getLastRow();
  if (last < 2) return 1;
  const v = sh.getRange(2, 1, last - 1, 1).getValues();
  let max = 0;
  v.forEach(r => { const n = Number(r[0]); if (n > max) max = n; });
  return max + 1;
}

/** หมายเลขการเบิก 9 หลัก: ลำดับ(3) + วัน(2) + เดือน(2) + ปี พ.ศ. 2 หลักท้าย(2) ; ลำดับเริ่มใหม่ทุกเดือน */
function nextReqSeq_(sh, mm, yy) {
  const last = sh.getLastRow();
  let max = 0;
  if (last >= 2) {
    sh.getRange(2, 2, last - 1, 1).getValues().forEach(r => {
      const s = pad_(r[0], 9);
      if (s.length === 9 && s.substr(5, 2) === mm && s.substr(7, 2) === yy) {
        const n = parseInt(s.substr(0, 3), 10);
        if (n > max) max = n;
      }
    });
  }
  return max + 1;
}

/* ---------- API: ข้อมูลเริ่มต้น ---------- */

function getBootstrap() {
  let note = '';
  try { withLock_(() => { rebuildStock_(); }); note = MIGRATION_NOTE_; MIGRATION_NOTE_ = ''; } catch (e) { /* คำนวณคลังไม่สำเร็จไม่ควรทำให้เปิดแอปไม่ได้ */ }
  return { today: todayStr_(), parts: getParts_(), users: getRequesters_(), techs: getTechs_(), receivers: getReceivers_(), loansOverdue: countOverdueLoans_(),
           recon: 0, synced: 0, changes: [], migrated: note };
}

/** รายชื่อผู้เบิก จากชีท "ผู้เบิก" (แก้ไขรายชื่อได้ในชีทโดยตรง) */
/** รายชื่อช่างผู้รับพัสดุ (ชีท "ช่าง" คอลัมน์ A : ยศ-ชื่อ นามสกุล ในช่องเดียว) */
function getTechs_() {
  const sh = getSheet_(SHEET_TECH);
  const last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, 1).getValues().map(r => str_(r[0])).filter(Boolean);
}
/** รายชื่อเจ้าหน้าที่ผู้รับพัสดุ (ชีท "ผู้รับ" คอลัมน์ A : ยศ-ชื่อ นามสกุล) */
function getReceivers_() {
  const sh = getSheet_(SHEET_RCVR);
  const last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, 1).getValues().map(r => str_(r[0])).filter(Boolean);
}
function getRequesters_() {
  const sh = getSheet_(SHEET_USR);
  const last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, 3).getValues()
    .map(r => ({ rank: str_(r[0]), fullName: str_(r[1]), position: str_(r[2]) }))
    .filter(u => u.fullName);
}

function getParts_() {
  const map = {};
  [[SHEET_REQ, 3, 4, 6], [SHEET_RCV, 4, 5, 9], [SHEET_RCV2, 4, 5, 9], [SHEET_RET, 2, 3, 0]].forEach(cfg => {
    const sh = getSheet_(cfg[0]);
    const last = sh.getLastRow();
    if (last < 2) return;
    const w = Math.max(cfg[1], cfg[2], cfg[3]);
    sh.getRange(2, 1, last - 1, w).getValues().forEach(r => {
      const pn = str_(r[cfg[1] - 1]);
      if (!pn) return;
      if (!map[pn]) map[pn] = { part: pn, name: '', unit: '' };
      if (!map[pn].name) map[pn].name = str_(r[cfg[2] - 1]);
      if (cfg[3] && !map[pn].unit) map[pn].unit = str_(r[cfg[3] - 1]);
    });
  });
  return Object.keys(map).map(k => map[k]);
}

/* ---------- API: แก้ไข / ยกเลิกใบเบิก (ได้ก่อนมีการรับพัสดุ) ---------- */

function findReq_(req, docNo) {
  const last = req.getLastRow();
  if (last < 2) return null;
  const all = req.getRange(2, 1, last - 1, 16).getValues();
  for (let i = 0; i < all.length; i++) {
    if (pad_(all[i][1], 9) === String(docNo)) return { row: i + 2, v: all[i] };
  }
  return null;
}

function assertEditable_(f, docNo) {
  if (!f) throw new Error('ไม่พบใบเบิกเลขที่ ' + docNo);
  const v = f.v;
  if (isCancelled_(v[7])) throw new Error('ใบเบิกนี้ถูกยกเลิกแล้ว');
  if (isPaid_(v[7])) throw new Error('ใบเบิกนี้จ่ายแล้ว แก้ไขหรือยกเลิกไม่ได้');
  if ((receivedMap_()[pad_(v[1], 9) + '|' + str_(v[2])] || 0) > 0) {
    throw new Error('มีการรับพัสดุตามใบเบิกนี้ไปแล้ว แก้ไขหรือยกเลิกไม่ได้');
  }
}

function editRequisition(p) {
  return withLock_(() => {
    const req = getSheet_(SHEET_REQ);
    const f = findReq_(req, p.docNo);
    assertEditable_(f, p.docNo);
    if (!str_(p.name)) throw new Error('กรุณากรอกชื่อพัสดุ');
    if (num_(p.qty) <= 0) throw new Error('จำนวนต้องมากกว่า 0');
    if (!str_(p.machine)) throw new Error('กรุณาเลือกหมายเลขเครื่อง');
    if (!str_(p.fullName)) throw new Error('กรุณากรอกชื่อ-สกุลผู้เบิก');
    if (ITEM_TYPES.indexOf(str_(p.itemType)) < 0) throw new Error('กรุณาเลือกประเภทพัสดุ');
    const urgency = str_(p.urgency) === 'AOG' ? 'AOG' : 'เบิกธรรมดา';
    const nv = {
      3: str_(p.part), 4: str_(p.name), 5: num_(p.qty), 6: str_(p.unit) || 'EA',
      9: str_(p.machine), 10: urgency, 11: str_(p.issue),
      12: str_(p.rank), 13: str_(p.fullName), 14: str_(p.position), 15: str_(p.itemType)
    };
    const labels = { 3: 'Part', 4: 'ชื่อ', 5: 'จำนวน', 6: 'หน่วย', 9: 'เครื่อง', 10: 'ความเร่งด่วน', 11: 'ข้อขัดข้อง', 12: 'ยศ', 13: 'ผู้เบิก', 14: 'ตำแหน่ง', 15: 'ประเภท' };
    const diffs = [];
    Object.keys(nv).forEach(k => {
      const oldV = f.v[Number(k) - 1];
      const same = typeof nv[k] === 'number' ? num_(oldV) === nv[k] : str_(oldV) === nv[k];
      if (!same) diffs.push(labels[k] + ': ' + str_(oldV) + ' → ' + nv[k]);
    });
    req.getRange(f.row, 3, 1, 4).setValues([[nv[3], nv[4], nv[5], nv[6]]]);
    req.getRange(f.row, 9, 1, 7).setValues([[nv[9], nv[10], nv[11], nv[12], nv[13], nv[14], nv[15]]]);
    log_('แก้ใบเบิก', p.docNo, diffs.length ? diffs.join(' | ') : '(ไม่มีการเปลี่ยนแปลง)', p.by);
    return { ok: true, changed: diffs.length };
  });
}

function cancelRequisition(p) {
  return withLock_(() => {
    const req = getSheet_(SHEET_REQ);
    const f = findReq_(req, p.docNo);
    assertEditable_(f, p.docNo);
    if (!str_(p.reason)) throw new Error('กรุณาระบุเหตุผลที่ยกเลิก');
    req.getRange(f.row, 8).setNumberFormat('General').setValue(CANCELLED);
    req.getRange(f.row, 16).setValue(str_(p.reason));
    log_('ยกเลิกใบเบิก', p.docNo, [str_(f.v[2]), str_(f.v[3]), 'x' + num_(f.v[4]), 'เหตุผล: ' + str_(p.reason)].filter(Boolean).join(' | '), p.by);
    return { ok: true };
  });
}

/* ---------- API: เบิก ---------- */

function submitRequisition(p) {
  return withLock_(() => submitRequisitionCore_(p));
}

/** ออกใบเบิก (ไม่ล็อกเอง : ผู้เรียกต้องล็อกไว้แล้ว) */
function submitRequisitionCore_(p) {
  {
    const items = (p.items || []).filter(i => str_(i.part) || str_(i.name));
    if (!items.length) throw new Error('กรุณากรอกรายการพัสดุ');
    if (items.length > 50) throw new Error('เบิกได้ไม่เกิน 50 รายการต่อครั้ง');
    items.forEach((i, idx) => {
      if (!str_(i.name)) throw new Error('รายการที่ ' + (idx + 1) + ': กรุณากรอกชื่อพัสดุ');
      if (num_(i.qty) <= 0) throw new Error('รายการที่ ' + (idx + 1) + ': จำนวนต้องมากกว่า 0');
      if (ITEM_TYPES.indexOf(str_(i.itemType) || str_(p.itemType)) < 0) throw new Error('รายการที่ ' + (idx + 1) + ': กรุณาเลือกประเภทพัสดุ');
    });

    if (!str_(p.machine)) throw new Error('กรุณาเลือกหมายเลขเครื่อง');
    if (!str_(p.fullName)) throw new Error('กรุณากรอกชื่อ-สกุลผู้เบิก');
    const sh = getSheet_(SHEET_REQ);
    const date = parseDate_(p.date || todayStr_());
    const dd = Utilities.formatDate(date, TZ, 'dd');
    const mm = Utilities.formatDate(date, TZ, 'MM');
    const yy = pad_((Number(Utilities.formatDate(date, TZ, 'yyyy')) + 543) % 100, 2);
    const seq0 = nextReqSeq_(sh, mm, yy);
    if (seq0 + items.length - 1 > 999) throw new Error('ลำดับการเบิกเดือนนี้เกิน 999 แล้ว');
    const urg = str_(p.urgency) === 'AOG' ? 'AOG' : 'เบิกธรรมดา';

    /* 1 ใบเบิก = 1 รายการ : แต่ละรายการได้เลขใบเบิกของตัวเอง ต่อเลขกัน */
    const docs = [];
    const rows = items.map((i, k) => {
      const seq = seq0 + k, docNo = pad_(seq, 3) + dd + mm + yy, type = str_(i.itemType) || str_(p.itemType);
      docs.push({ docNo: docNo, part: str_(i.part), name: str_(i.name), qty: num_(i.qty), unit: str_(i.unit) || 'EA', itemType: type });
      return [seq, docNo, str_(i.part), str_(i.name), num_(i.qty), str_(i.unit) || 'EA',
        date, UNPAID, str_(p.machine), urg, str_(p.issue), str_(p.rank), str_(p.fullName), str_(p.position), type];
    });
    const start = sh.getLastRow() + 1;
    sh.getRange(start, 2, rows.length, 1).setNumberFormat('@');
    sh.getRange(start, 7, rows.length, 2).setNumberFormat('dd/mm/yyyy');
    sh.getRange(start, 1, rows.length, rows[0].length).setValues(rows);
    docs.forEach(d => log_('เบิก', d.docNo, [d.part, d.name, 'x' + d.qty + ' ' + d.unit, 'เครื่อง ' + str_(p.machine),
      d.itemType, urg, 'ผู้เบิก ' + [str_(p.rank), str_(p.fullName)].filter(Boolean).join(' ')].join(' | '), p.by));
    return { docNo: docs[0].docNo, docs: docs, count: rows.length };
  }
}

/* ---------- โครงสร้างชีท รับ / จ่าย / คลังพัสดุ ----------
 *  รับ        : บันทึกทุกครั้งที่รับพัสดุเข้า (เพิ่มแถวอย่างเดียว) 1 แถว = 1 ล็อต อ้างอิงด้วย "ลำดับรับ"
 *  จ่าย       : บันทึกทุกครั้งที่พัสดุออกจากล็อต (จ่ายให้ช่าง / โอนเข้าใบเบิก) อ้างอิง "ลำดับรับ"
 *  คลังพัสดุ  : คำนวณจากสองชีทข้างบน  คงเหลือ = รับ − จ่าย − ที่ยืมออกและยังไม่คืน (แสดงเฉพาะล็อตที่ยังเหลือ)
 */
const RC = { SEQ: 0, DOC: 1, PART: 2, NAME: 3, SN: 4, TYPE: 5, QTY: 6, UNIT: 7, PRICE: 8, TOTAL: 9, COND: 10, NOTIFY: 11,
  URG: 12, DUE: 13, RDATE: 14, OVER: 15, TAIL: 16, CARD: 17, TCI: 18, EXP: 19, LOC: 20, RECV: 21, NOTE: 22, SRC: 23, REF: 24 };
const IS = { SEQ: 0, DATE: 1, DOC: 2, RSEQ: 3, PART: 4, NAME: 5, SN: 6, QTY: 7, UNIT: 8, TAIL: 9, TECH: 10, NOTE: 11, BY: 12 };
/* ชีท รับ: คอลัมน์ card ID อยู่ถัดจาก เลขเอกสารการเบิก (คอลัมน์ C) ; โค้ดภายในยังใช้ลำดับ RC เดิม แล้วแปลงตอนอ่าน/เขียนชีท */
const RC_PHYS_ = [0, 1, 17, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24];
function rcCol_(i) { return RC_PHYS_.indexOf(i) + 1; }                       // ลำดับ RC -> เลขคอลัมน์ในชีท (เริ่ม 1)
function rcLetter_(i) { return String.fromCharCode(64 + rcCol_(i)); }
function rcFromSheet_(row) { const o = new Array(RC_PHYS_.length); RC_PHYS_.forEach((li, k) => { o[li] = row[k]; }); return o; }
function rcToSheet_(vals) { return RC_PHYS_.map(li => vals[li]); }
const SRC_REQ = 'ใบเบิก';
const SRC_OPEN = 'ยอดยกมา';
const SRC_RET = 'คืนเข้าคลัง';
const DIRECT = 'จ่ายตรง';
const XFER_NOTE = 'โอนเข้าใบเบิก';

/** อ่านรับทั้งหมด = ชีท รับ + ชีท รับคืนเข้าคลัง (แต่ละแถวมี _sh = ชื่อชีท, _row = เลขแถวจริง) */
function readRcv_() {
  splitReturnRows_();
  const out = [];
  [SHEET_RCV, SHEET_RCV2].forEach(name => {
    const sh = getSheet_(name), last = sh.getLastRow();
    if (last < 2) return;
    sh.getRange(2, 1, last - 1, HEADERS[SHEET_RCV].length).getValues().forEach((pr, i) => { const r = rcFromSheet_(pr); r._sh = name; r._row = i + 2; out.push(r); });
  });
  return out;
}

/** ลำดับรับถัดไป (นับรวมทั้งสองชีท) */
function nextRcvSeq_() {
  let max = 0;
  [SHEET_RCV, SHEET_RCV2].forEach(name => {
    const sh = getSheet_(name), last = sh.getLastRow();
    if (last < 2) return;
    sh.getRange(2, 1, last - 1, 1).getValues().forEach(r => { const n = Number(r[0]); if (n > max) max = n; });
  });
  return max + 1;
}

/** ย้ายแถวเดิมที่ แหล่งที่มา = คืนเข้าคลัง จากชีท รับ ไปชีท รับคืนเข้าคลัง (ทำครั้งเดียว) */
let SPLIT_DONE_ = false;
function splitReturnRows_() {
  if (SPLIT_DONE_) return;
  SPLIT_DONE_ = true;
  let props = null;
  try { props = PropertiesService.getDocumentProperties(); } catch (e) { props = null; }
  if (props && props.getProperty('retsplit1')) return;
  const src = getSheet_(SHEET_RCV), dst = getSheet_(SHEET_RCV2), last = src.getLastRow();
  if (last >= 2) {
    const w = HEADERS[SHEET_RCV].length;
    const vals = src.getRange(2, 1, last - 1, w).getValues().map(rcFromSheet_);
    const move = [];
    vals.forEach((r, i) => { if (str_(r[RC.SRC]) === SRC_RET) move.push({ row: i + 2, v: r }); });
    if (move.length) {
      move.forEach(m => writeRcvRow_(dst, dst.getLastRow() + 1, m.v));
      for (let k = move.length - 1; k >= 0; k--) src.deleteRow(move[k].row);   // ลบจากล่างขึ้นบน
      log_('แยกชีท', '', 'ย้ายประวัติคืนเข้าคลัง ' + move.length + ' แถว ไปชีท ' + SHEET_RCV2, 'ระบบ');
    }
  }
  if (props) props.setProperty('retsplit1', '1');
}
function readIss_() {
  const sh = getSheet_(SHEET_ISS), last = sh.getLastRow();
  return last >= 2 ? sh.getRange(2, 1, last - 1, HEADERS[SHEET_ISS].length).getValues() : [];
}
function readLoans_() {
  const sh = getSheet_(SHEET_LOAN), last = sh.getLastRow();
  return last >= 2 ? sh.getRange(2, 1, last - 1, HEADERS[SHEET_LOAN].length).getValues() : [];
}

/** คำนวณล็อตทั้งหมดจาก รับ − จ่าย − ที่ยืมออกและยังไม่คืน */
function computeLots_() {
  const R_ = readRcv_(), I_ = readIss_(), L_ = readLoans_();
  const issued = {}, loanOut = {}, loanOpen = {};
  I_.forEach(r => { const k = Number(r[IS.RSEQ]); if (k) issued[k] = (issued[k] || 0) + num_(r[IS.QTY]); });
  L_.forEach(r => {
    const k = Number(r[17]); if (!k) return;
    const unret = num_(r[6]) - num_(r[19]);        // ยืมออกไปแล้วยังไม่ได้คืนเข้าคลัง (รวมที่ปิดด้วยใช้งานจริง/เบิกคืน)
    if (unret > 0) loanOut[k] = (loanOut[k] || 0) + unret;
    if (str_(r[13]) === LOAN_OPEN) loanOpen[k] = (loanOpen[k] || 0) + num_(r[8]);
  });
  return R_.map((r, i) => {
    const seq = Number(r[RC.SEQ]);
    const src = str_(r[RC.SRC]) || SRC_REQ;
    const free = src === SRC_OPEN || src === SRC_RET;
    const remain = num_(r[RC.QTY]) - (issued[seq] || 0) - (loanOut[seq] || 0);
    return {
      seq: seq, row: r._row || (i + 2), sh: r._sh || SHEET_RCV, doc: docStr_(r[RC.DOC]), label: free ? src : docStr_(r[RC.DOC]), free: free, src: src,
      part: str_(r[RC.PART]), name: str_(r[RC.NAME]), serial: str_(r[RC.SN]), type: str_(r[RC.TYPE]), unit: str_(r[RC.UNIT]),
      qty: num_(r[RC.QTY]), issued: issued[seq] || 0, loanOut: loanOut[seq] || 0, loanOpen: loanOpen[seq] || 0,
      remain: remain, cond: str_(r[RC.COND]), loc: str_(r[RC.LOC]), expire: r[RC.EXP] instanceof Date ? r[RC.EXP] : '',
      recvDate: r[RC.RDATE] instanceof Date ? r[RC.RDATE] : '', note: str_(r[RC.NOTE]), v: r
    };
  });
}

function findLot_(seq) {
  if (!seq) return null;
  return computeLots_().filter(l => l.seq === Number(seq))[0] || null;
}

/** เขียนชีท คลังพัสดุ ใหม่จากการคำนวณ (แสดงเฉพาะล็อตที่ยังเหลือ เรียงตามเลขใบเบิก ยอดยกมา/คืนเข้าคลังอยู่ท้าย) */
function rebuildStock_() {
  const lots = computeLots_().filter(l => l.remain > 0);
  lots.sort((a, b) => (a.free - b.free) || (a.label < b.label ? -1 : a.label > b.label ? 1 : 0) || (a.seq - b.seq));
  const stk = getSheet_(SHEET_STK);
  const last = stk.getLastRow();
  const w = HEADERS[SHEET_STK].length;
  if (last >= 2) stk.getRange(2, 1, last - 1, w).clearContent();
  if (!lots.length) return;
  const rows = lots.map(l => [l.seq, l.label, l.part, l.name, l.serial, l.type, l.unit, l.qty, l.remain, l.cond, l.loc, l.expire,
    l.recvDate, l.loanOut > 0 ? 'ในคลัง (ยืมออก ' + l.loanOut + ')' : 'ในคลัง', l.note]);
  stk.getRange(2, 2, rows.length, 1).setNumberFormat('@');
  stk.getRange(2, 1, rows.length, w).setValues(rows);
  stk.getRange(2, 12, rows.length, 2).setNumberFormat('dd/mm/yyyy');
}

/** เปิดแอป / ตรวจสอบ: คลังพัสดุคำนวณจาก รับ-จ่าย จึงตรงกันเสมอ (คงฟังก์ชันไว้ให้หน้าเว็บเรียก) */
function getReconcile() {
  return withLock_(() => { rebuildStock_(); return { ok: true, items: [], changes: [] }; });
}

/* ---------- API: รับ (ต้องรับตามเลขเบิกก่อน จึงจะจ่ายได้) ---------- */

/** จำนวนที่รับแล้วตามใบเบิก แยกตาม เลขเบิก|part */
function receivedMap_() {
  const m = {};
  readRcv_().forEach(r => {
    if (!str_(r[RC.DOC]) || (str_(r[RC.SRC]) || SRC_REQ) !== SRC_REQ) return;
    const k = pad_(r[RC.DOC], 9) + '|' + str_(r[RC.PART]);
    m[k] = (m[k] || 0) + num_(r[RC.QTY]);
  });
  return m;
}

function reqInfoMap_() {
  const req = getSheet_(SHEET_REQ);
  const last = req.getLastRow();
  const m = {};
  if (last < 2) return m;
  req.getRange(2, 1, last - 1, 15).getValues().forEach(r => {
    m[pad_(r[1], 9) + '|' + str_(r[2])] = { machine: str_(r[8]), issue: str_(r[10]), qty: num_(r[4]), type: str_(r[14]) };
  });
  return m;
}

/** ใบเบิกที่ยังรับพัสดุไม่ครบ */
function getPendingReceive() {
  const req = getSheet_(SHEET_REQ);
  const last = req.getLastRow();
  if (last < 2) return [];
  const got = receivedMap_();
  const out = [];
  req.getRange(2, 1, last - 1, 15).getValues().forEach((r, i) => {
    if (isPaid_(r[7]) || isCancelled_(r[7])) return; // รับครบแล้ว / ยกเลิก
    const docNo = pad_(r[1], 9);
    const part = str_(r[2]);
    const done = got[docNo + '|' + part] || 0;
    const remain = Math.max(0, num_(r[4]) - done);
    if (remain <= 0) return;
    out.push({
      row: i + 2, docNo: docNo, part: part, name: str_(r[3]),
      qty: num_(r[4]), unit: str_(r[5]), date: fmtThai_(r[6]),
      machine: str_(r[8]), urgency: str_(r[9]), issue: str_(r[10]),
      due: fmtThai_(dueDate_(r[6], r[9])), type: str_(r[14]),
      received: done, remain: remain
    });
  });
  return out.reverse();
}

function appendRcv_(vals) {
  splitReturnRows_();
  const sh = getSheet_(str_(vals[RC.SRC]) === SRC_RET ? SHEET_RCV2 : SHEET_RCV);
  return writeRcvRow_(sh, sh.getLastRow() + 1, vals);
}

function writeRcvRow_(sh, r, vals) { writeRcvRows_(sh, r, [vals]); return r; }

/** เขียนแถวรับ (ลำดับ RC) ลงชีทตั้งแต่แถว start : ใส่สูตร ยอดรวม/วันที่เกิน + จัดรูปแบบ */
function writeRcvRows_(sh, start, rows) {
  const n = rows.length;
  const out = rows.map((v, k) => {
    v = v.slice(); const r = start + k;
    v[RC.TOTAL] = '=IF(AND(ISNUMBER(' + rcLetter_(RC.QTY) + r + '),ISNUMBER(' + rcLetter_(RC.PRICE) + r + ')),' + rcLetter_(RC.QTY) + r + '*' + rcLetter_(RC.PRICE) + r + ',"")';
    v[RC.OVER] = '=IF(AND(ISNUMBER(' + rcLetter_(RC.DUE) + r + '),ISNUMBER(' + rcLetter_(RC.RDATE) + r + ')),' + rcLetter_(RC.RDATE) + r + '-' + rcLetter_(RC.DUE) + r + ',"")';
    return rcToSheet_(v);
  });
  sh.getRange(start, 2, n, 1).setNumberFormat('@');
  sh.getRange(start, rcCol_(RC.CARD), n, 1).setNumberFormat('@');
  sh.getRange(start, 1, n, out[0].length).setValues(out);
  sh.getRange(start, rcCol_(RC.NOTIFY), n, 1).setNumberFormat('dd/mm/yyyy');
  sh.getRange(start, rcCol_(RC.DUE), n, 2).setNumberFormat('dd/mm/yyyy');
  sh.getRange(start, rcCol_(RC.EXP), n, 1).setNumberFormat('dd/mm/yyyy');
  sh.getRange(start, rcCol_(RC.OVER), n, 1).setNumberFormat('0');
  sh.getRange(start, rcCol_(RC.PRICE), n, 1).setNumberFormat('#,##0.00');
  sh.getRange(start, rcCol_(RC.TOTAL), n, 1).setNumberFormat('#,##0.00');
}

function appendIss_(vals) {
  const sh = getSheet_(SHEET_ISS);
  const r = sh.getLastRow() + 1;
  sh.getRange(r, 3).setNumberFormat('@');
  sh.getRange(r, 1, 1, vals.length).setValues([vals]);
  sh.getRange(r, 2).setNumberFormat('dd/mm/yyyy');
  return r;
}

function submitReceive(p) {
  return withLock_(() => {
    const req = getSheet_(SHEET_REQ);

    // หาใบเบิกจากเลขเบิก (ตรวจซ้ำว่า เลขเบิก และ part ตรงกัน)
    let row = Number(p.row);
    let rv = row >= 2 && row <= req.getLastRow() ? req.getRange(row, 1, 1, 15).getValues()[0] : null;
    if (!rv || pad_(rv[1], 9) !== p.docNo || str_(rv[2]) !== str_(p.part)) {
      row = 0;
      const last = req.getLastRow();
      const all = last >= 2 ? req.getRange(2, 1, last - 1, 15).getValues() : [];
      for (let i = 0; i < all.length; i++) {
        if (pad_(all[i][1], 9) === p.docNo && str_(all[i][2]) === str_(p.part)) { row = i + 2; rv = all[i]; break; }
      }
      if (!row) throw new Error('ไม่พบใบเบิกเลขที่ ' + p.docNo);
    }
    if (isCancelled_(rv[7])) throw new Error('ใบเบิกนี้ถูกยกเลิกแล้ว');

    const qty = num_(p.qty);
    if (qty <= 0) throw new Error('กรุณากรอกจำนวนที่รับ');
    if (p.issueNow && !str_(p.tech)) throw new Error('กรุณากรอกชื่อช่างที่รับพัสดุ (จ่ายทันที)');

    const lots = computeLots_();
    // รับจากยอดยกมา/ของคืนคลัง (ถ้าเลือก) : ตรวจล็อตก่อนบันทึกอะไรทั้งสิ้น
    const lotSeq = Number(p.lotSeq || p.lotRow) || 0;
    let lot = null;
    if (lotSeq) {
      lot = lots.filter(l => l.seq === lotSeq)[0] || null;
      const samePart = lot && (str_(rv[2]) ? lot.part === str_(rv[2]) : lot.name === str_(rv[3]));
      if (!lot || !lot.free || lot.remain <= 0 || !samePart) throw new Error('ไม่พบล็อตในคลังที่เลือก หรือไม่ตรงกับพัสดุในใบเบิก');
      if (qty > lot.remain) throw new Error('จำนวนในล็อตไม่พอ (เหลือ ' + lot.remain + ')');
    }
    // รับจากของที่ยืมไปใช้จริง (ปิดยืมด้วยใบเบิกนี้) : ของออกจากคลังตอนยืมแล้ว จึงไม่ตัดล็อตซ้ำ
    let loanSeq = Number(p.loanSeq) || 0;
    const lsh = getSheet_(SHEET_LOAN);
    if (!loanSeq && !lotSeq) loanSeq = findKitLoanForDoc_(lsh, p.docNo, str_(rv[2]), qty) || 0;   // ใบเบิกทดแทนของชุดพัสดุ : ผูกกับรายการที่ใช้ติดตั้งให้อัตโนมัติ
    let loan = null, loanRow = 0, loanLot = null;
    if (loanSeq) {
      if (lotSeq) throw new Error('เลือกแหล่งที่มาได้อย่างเดียว');
      const fl = findLoan_(lsh, loanSeq);
      if (!fl) throw new Error('ไม่พบรายการยืมที่เลือก');
      loan = fl.v; loanRow = fl.row;
      const samePartL = str_(rv[2]) ? str_(loan[2]) === str_(rv[2]) : str_(loan[3]) === str_(rv[3]);
      if (str_(loan[13]) !== LOAN_OPEN || !samePartL) throw new Error('รายการยืมไม่ตรงกับพัสดุในใบเบิก หรือปิดไปแล้ว');
      if (qty > num_(loan[8])) throw new Error('จำนวนที่ยืมค้างอยู่ไม่พอ (เหลือ ' + num_(loan[8]) + ')');
      loanLot = lots.filter(l => l.seq === Number(loan[17]))[0] || null;
    }
    const src = lot || loanLot;
    const itype = str_(rv[14]);
    // Serial ไม่บังคับทุกประเภท ; ถ้ามี Serial ต้องรับทีละ 1 ชิ้น
    const sn = str_(p.serial) || (lot ? lot.serial : (loan ? str_(loan[4]) : ''));
    if (sn && qty !== 1) throw new Error('พัสดุที่มี Serial number ต้องรับทีละ 1 ชิ้น (ไม่มี Serial จึงรับหลายชิ้นพร้อมกันได้)');
    // Serial ต้องไม่ซ้ำกับของที่อยู่ในคลังแล้ว และไม่ซ้ำกับที่รับไปแล้วในใบเบิกเดียวกัน
    if (sn) {
      lots.forEach(l => {
        if (l.seq !== lotSeq && l.part === str_(rv[2]) && l.serial.toUpperCase() === sn.toUpperCase() && l.remain > 0) {
          throw new Error('Serial ' + sn + ' มีอยู่ในคลังแล้ว (' + l.label + ')' + (l.free ? ' ให้เลือกล็อตนั้นที่ "แหล่งที่มาของพัสดุ"' : ''));
        }
        if (!l.free && l.doc === p.docNo && l.part === str_(rv[2]) && l.serial.toUpperCase() === sn.toUpperCase()) {
          throw new Error('Serial ' + sn + ' รับไปแล้วในใบเบิกนี้');
        }
      });
    }
    const cond = str_(p.cond) || (src ? src.cond : '');
    const loc = str_(p.location) || (src ? src.loc : '');
    const expireVal = p.expire ? parseDate_(p.expire) : (src && src.expire ? src.expire : '');
    const recvDate = parseDate_(p.receiveDate || todayStr_()); // วันที่รับ = วันที่จ่ายในชีทเบิก

    let reqQty = num_(rv[4]);
    const done = receivedMap_()[p.docNo + '|' + str_(rv[2])] || 0;
    // รับเกินจำนวนที่เบิก -> เพิ่มจำนวนเบิกให้เท่ากับที่รับจริง (รับไม่ครบ ไม่ปรับจำนวนเบิก)
    let increasedTo = null;
    if (done + qty > reqQty) {
      reqQty = done + qty;
      req.getRange(row, 5).setValue(reqQty);
      increasedTo = reqQty;
    }
    const remain = reqQty - done - qty; // ยังค้างรับตามใบเบิก

    const rsh = getSheet_(SHEET_RCV);
    const seq = nextRcvSeq_();
    appendRcv_([
      seq, p.docNo, str_(rv[2]), str_(rv[3]), sn, itype, qty, str_(rv[5]),
      p.price === '' || p.price === null || p.price === undefined ? '' : num_(p.price), '',
      cond, rv[6], str_(rv[9]), dueDate_(rv[6], rv[9]), recvDate, '',
      str_(rv[8]), str_(p.cardId), str_(p.tci), expireVal, loc, str_(p.receiver), str_(p.remark), SRC_REQ, lot ? lot.seq : ''
    ]);
    if (remain <= 0) req.getRange(row, 8).setNumberFormat('dd/mm/yyyy').setValue(recvDate); // รับครบ = วันที่จ่ายในชีทเบิก
    if (lot) { // โอนจากยอดยกมา/ของคืนคลัง เข้าใบเบิกนี้ : บันทึกการออกจากล็อตเดิมในชีท จ่าย
      appendIss_([nextSeq_(getSheet_(SHEET_ISS)), recvDate, p.docNo, lot.seq, lot.part, lot.name, lot.serial, qty, lot.unit, '', '',
        XFER_NOTE + ' ' + p.docNo, str_(p.by)]);
    }
    if (loan) {
      closeLoanQty_(lsh, loanRow, loan, qty, LOAN_USED, p.docNo, 'ใช้งานจริง x' + qty + ' (ปิดด้วยใบเบิก ' + p.docNo + ')');
      kitAfterReceive_(loan, sn);
    }
    log_('รับ', p.docNo, [str_(rv[2]), str_(rv[3]), 'x' + qty, sn ? 'S/N ' + sn : '',
      lot ? '(จาก' + lot.label + ')' : (loan ? '(ปิดยืมเลขที่ ' + loanSeq + ')' : ''),
      increasedTo ? 'เพิ่มจำนวนเบิกเป็น ' + increasedTo : '', str_(p.receiver) ? 'ผู้รับ ' + str_(p.receiver) : ''].filter(Boolean).join(' | '), p.by);
    // รับจากคลังแล้วจ่ายทันที (ยังอ้างอิงเลขเบิกเดิม: รับก่อน แล้วจ่ายล็อตที่เพิ่งรับ)
    let issued = null;
    if (p.issueNow) {
      issued = issueCore_({ seq: seq, docNo: p.docNo, tech: p.tech, tail: p.tail, remark: p.issueRemark, payDate: p.payDate || todayStr_(), by: p.by });
    }
    rebuildStock_();
    return { remain: remain, increasedTo: increasedTo, issued: !!issued, closed: remain <= 0, rcvSeq: seq };
  });
}

/* ---------- จ่ายจากคลังโดยตรง (ยอดยกมา / ของที่คืนเข้าคลัง) ---------- */

/** จ่ายจากล็อตในคลังโดยไม่ต้องมีใบเบิก : เลขเอกสาร = "จ่ายตรง" */
function issueDirect_(p) {
  return withLock_(() => {
    const lot = findLot_(p.lotSeq);
    if (!lot) throw new Error('ไม่พบล็อตในคลังที่เลือก');
    if (!lot.free || lot.remain <= 0) throw new Error('ล็อตนี้ไม่ใช่ยอดยกมา/ของคืนคลัง หรือไม่ได้อยู่ในคลัง');
    const qty = num_(p.qty);
    if (qty <= 0) throw new Error('กรุณากรอกจำนวนที่จ่าย');
    if (qty > lot.remain) throw new Error('จำนวนในล็อตไม่พอ (เหลือ ' + lot.remain + ')');
    if (lot.serial && qty !== 1) throw new Error('พัสดุที่มี Serial number ต้องจ่ายทีละ 1 ชิ้น');
    const payDate = parseDate_(p.payDate || todayStr_());
    appendIss_([nextSeq_(getSheet_(SHEET_ISS)), payDate, DIRECT, lot.seq, lot.part, lot.name, lot.serial, qty, lot.unit,
      str_(p.tail), str_(p.tech), [str_(p.remark), 'จ่ายตรงจาก' + lot.label].filter(Boolean).join(' | '), str_(p.by)]);
    log_('จ่าย', DIRECT, [lot.part, lot.name, 'x' + qty, lot.serial ? 'S/N ' + lot.serial : '',
      'ช่าง ' + str_(p.tech), str_(p.tail) ? 'TAIL ' + str_(p.tail) : '', '(จ่ายตรงจาก' + lot.label + ' ไม่มีใบเบิก)'].filter(Boolean).join(' | '), p.by);
    rebuildStock_();
    return { closed: false, direct: true, left: lot.remain - qty };
  });
}

/** จ่ายจากล็อตในคลัง: มีใบเบิกอ้างอิง -> รับเข้าใบเบิกแล้วจ่ายต่อ ; ไม่มีใบเบิก -> จ่ายตรง */
function issueFromLot(p) {
  if (!str_(p.tech)) throw new Error('กรุณากรอกชื่อช่างที่รับพัสดุ');
  if (!str_(p.docNo)) return issueDirect_(p);
  const lot = findLot_(p.lotSeq);
  if (!lot) throw new Error('ไม่พบล็อตในคลังที่เลือก');
  const rc = submitReceive({ row: p.row, docNo: p.docNo, part: p.part, qty: p.qty, lotSeq: lot.seq, receiver: p.tech,
    receiveDate: p.receiveDate || p.payDate, by: p.by });
  try {
    return submitIssue({ seq: rc.rcvSeq, docNo: p.docNo, tech: p.tech, tail: p.tail, remark: p.remark, payDate: p.payDate, by: p.by });
  } catch (e) {
    throw new Error('รับเข้าใบเบิกแล้ว แต่จ่ายไม่สำเร็จ: ' + e.message + ' (ไปจ่ายต่อที่แท็บ จ่าย)');
  }
}

/* ---------- API: จ่าย (เฉพาะที่รับแล้ว) ---------- */

/** ล็อตที่รับตามใบเบิกแล้วและยังไม่จ่ายให้ช่าง (ยังเหลือในคลัง) */
function getPendingIssue() {
  const info = reqInfoMap_();
  return computeLots_().filter(l => !l.free && l.remain > 0).map(l => {
    const q = info[l.doc + '|' + l.part] || {};
    return {
      row: l.seq, seq: l.seq, docNo: l.doc, part: l.part, name: l.name, serial: l.serial,
      qty: l.remain, unit: l.unit, urgency: str_(l.v[RC.URG]), due: fmtThai_(l.v[RC.DUE]),
      location: l.loc, receiver: str_(l.v[RC.RECV]),
      machine: q.machine || '', issue: q.issue || '', reqQty: q.qty || 0, type: l.type || q.type || ''
    };
  }).reverse();
}

function submitIssue(p) {
  return withLock_(() => { const res = issueCore_(p); rebuildStock_(); return res; });
}

/** จ่ายล็อตที่รับตามใบเบิก ให้ช่าง (เรียกซ้ำได้ภายใน lock เดียวกัน เช่น รับแล้วจ่ายทันที) */
function issueCore_(p) {
  const lot = findLot_(Number(p.seq) || Number(p.row));
  if (!lot || lot.free || (p.docNo && lot.doc !== p.docNo)) {
    throw new Error('ไม่พบรายการรับของใบเบิก ' + p.docNo + ' — ต้องรับพัสดุก่อนจึงจะจ่ายได้');
  }
  if (lot.remain <= 0) throw new Error(lot.loanOut > 0 ? 'พัสดุนี้ถูกยืมออกจากคลังอยู่ ต้องรับคืนก่อนจึงจะจ่ายได้ (แท็บ คลัง > ยืมอยู่)' : 'รายการนี้จ่ายให้ช่างแล้ว');
  if (lot.loanOpen > 0) throw new Error('พัสดุนี้ถูกยืมออกจากคลังอยู่ ต้องรับคืนก่อนจึงจะจ่ายได้ (แท็บ คลัง > ยืมอยู่)');
  if (!str_(p.tech)) throw new Error('กรุณากรอกชื่อช่างที่รับพัสดุ');
  const qty = p.qty === undefined || p.qty === '' || p.qty === null ? lot.remain : num_(p.qty);
  if (qty <= 0 || qty > lot.remain) throw new Error('จำนวนที่จ่ายไม่ถูกต้อง (เหลือ ' + lot.remain + ')');
  const payDate = parseDate_(p.payDate || todayStr_());   // วันที่จ่ายให้ช่าง
  const tail = str_(p.tail) || str_(lot.v[RC.TAIL]);
  appendIss_([nextSeq_(getSheet_(SHEET_ISS)), payDate, lot.doc, lot.seq, lot.part, lot.name, lot.serial, qty, lot.unit, tail,
    str_(p.tech), [str_(lot.v[RC.NOTE]), str_(p.remark)].filter(Boolean).join(' | '), str_(p.by)]);

  // ครบ = รับครบตามใบเบิก และทุกล็อตของใบเบิกนี้จ่ายหมดแล้ว
  const req = getSheet_(SHEET_REQ);
  const rl = req.getLastRow();
  let closed = false;
  if (rl >= 2) {
    const all = req.getRange(2, 1, rl - 1, 5).getValues();
    for (let i = 0; i < all.length; i++) {
      if (pad_(all[i][1], 9) === lot.doc && str_(all[i][2]) === lot.part) {
        const mine = computeLots_().filter(l => !l.free && l.doc === lot.doc && l.part === lot.part);
        closed = mine.reduce((s, l) => s + l.qty, 0) >= num_(all[i][4]) && mine.every(l => l.remain <= 0);
        break;
      }
    }
  }
  log_('จ่าย', lot.doc, [lot.part, lot.name, 'x' + qty, lot.serial ? 'S/N ' + lot.serial : '',
    'ช่าง ' + str_(p.tech), tail ? 'TAIL ' + tail : '', closed ? '(จ่ายครบ)' : ''].filter(Boolean).join(' | '), p.by);
  return { closed: closed };
}

/* ---------- คลังพัสดุ (อ่านจากการคำนวณ) ---------- */

function getStock() {
  const info = reqInfoMap_();
  const kitRows_ = readKit_();
  const warr_ = warrantyMap_();
  const groups = {};
  computeLots_().filter(l => l.remain > 0).forEach(l => {
    const key = l.part || l.name;
    const g = groups[key] || (groups[key] = { part: l.part, name: l.name, unit: l.unit, qty: 0, lots: [] });
    g.qty += l.remain;
    g.lots.push({
      seq: l.seq, free: l.free, serial: l.serial, qty: l.remain, docNo: l.label, type: l.type, cond: l.cond,
      location: l.loc, expire: fmtThai_(l.expire), received: fmtThai_(l.recvDate), note: l.note,
      issRow: l.free ? 0 : l.seq, issSeq: l.free ? 0 : l.seq, linkNote: '',
      machine: l.free ? '' : ((info[l.doc + '|' + l.part] || {}).machine || ''),
      kit: kitOfLot_(l, kitRows_).kit,
      warr: l.serial && isLRU_(l.type) ? (warr_[snKey_(l.serial)] || null) : null
    });
  });
  return Object.keys(groups).sort().map(k => groups[k]);
}

/* ---------- ย้ายที่จัดเก็บ (LOCATION) ---------- */

/** ย้ายล็อตไปที่จัดเก็บใหม่ : แก้ที่ชีท รับ (ต้นทาง) แล้วสร้างชีท คลังพัสดุ ใหม่ ทุกชีทจึงตรงกัน */
function moveLocation(p) {
  return withLock_(() => {
    const loc = str_(p.location);
    if (!loc) throw new Error('กรุณาระบุที่จัดเก็บใหม่');
    const lot = computeLots_().filter(l => l.seq === Number(p.seq))[0];
    if (!lot || lot.remain <= 0) throw new Error('ไม่พบพัสดุในคลัง (อาจถูกจ่ายไปแล้ว) กรุณารีเฟรช');
    const cur = kitOfLot_(lot);                                                       // ชุดที่ล็อตนี้อยู่ตอนนี้ ('' = ไม่อยู่ในชุด)
    const want = p.kit === undefined || p.kit === null ? cur.kit : str_(p.kit);       // ไม่ส่งมา = คงสถานะชุดเดิม
    if (want && kitNames_().indexOf(want) < 0) throw new Error('ไม่รู้จักชุด ' + want);
    const sameLoc = lot.loc === loc;
    if (sameLoc && want === cur.kit) return { ok: true, from: lot.loc, to: loc, same: true, kit: cur.kit };
    if (cur.kit && want !== cur.kit) kitLeaveCheck_(cur.kit, lot);                    // ชิ้นที่ถูกนำออกไปราชการอยู่ ห้ามย้ายออกจากชุด
    if (!sameLoc) getSheet_(lot.sh || SHEET_RCV).getRange(lot.row, rcCol_(RC.LOC)).setValue(loc);   // LOCATION = ที่จัดเก็บจริง ไม่เกี่ยวกับชุด
    let kitNote = '';
    if (cur.kit && want === cur.kit) {                                                // อยู่ชุดเดิม: ให้ LOCATION ของรายการชุดตามไปด้วย
      if (!sameLoc) getSheet_(SHEET_KIT).getRange(cur.row, 7).setValue(loc);
    } else {
      if (cur.kit) kitLeave_(cur.kit, lot);
      if (want) kitNote = ensureKitRow_(want, lot, loc).added;
    }
    log_('ย้ายที่จัดเก็บ', lot.doc, [lot.part, lot.serial ? 'S/N ' + lot.serial : '', (lot.loc || '(ว่าง)') + ' → ' + loc,
      cur.kit !== want ? 'ชุด: ' + (cur.kit || '-') + ' → ' + (want || '-') : ''].filter(Boolean).join(' | '), p.by);
    rebuildStock_();
    return { ok: true, from: lot.loc, to: loc, kit: want, kitFrom: cur.kit, kitAdded: kitNote };
  });
}

function kitNames_() {
  const n = KIT_NAMES.slice();
  readKit_().forEach(r => { if (n.indexOf(r.kit) < 0) n.push(r.kit); });
  return n;
}
/** ล็อตนี้อยู่ในชุดไหน: มี S/N = ตรงตาม Part+S/N ; ไม่มี S/N = Part เดียวกันและ LOCATION ตรงกับรายการชุด */
function kitOfLot_(lot, kitRows) {
  const sn = snKey_(lot.serial);
  const r = (kitRows || readKit_()).filter(x => kitSamePart_(x, lot.part, lot.name) &&
    (sn ? snKey_(x.serial) === sn : (!x.serial && x.loc === lot.loc)))[0];
  return r ? { kit: r.kit, row: r.row, qty: r.qty } : { kit: '', row: 0, qty: 0 };
}

/** ตรวจก่อนย้ายพัสดุออกจากชุด: ถ้าชิ้นนั้นถูกนำออกไปราชการ/รอเบิกทดแทนอยู่ ให้ย้ายไม่ได้ */
function kitLeaveCheck_(kit, lot) {
  const st = kitState_(kit);
  st.items.forEach(i => {
    if (kitSamePart_(i, lot.part, lot.name) && (!i.serial || snKey_(i.serial) === snKey_(lot.serial)) && (i.out > 0 || i.waiting > 0))
      throw new Error('พัสดุนี้ถูกนำออกไปราชการ/รอเบิกทดแทนอยู่ ย้ายออกจาก ' + kit + ' ไม่ได้ ให้ปิดรายการนำออกก่อน');
  });
}
/** ย้ายพัสดุออกจากชุด: เอาออกจากรายการชุด (มี S/N = ลบแถว, ไม่มี S/N = ลดจำนวนมาตรฐาน) */
function kitLeave_(kit, lot) {
  const sh = getSheet_(SHEET_KIT), sn = snKey_(lot.serial);
  const r = readKit_().filter(x => x.kit === kit && kitSamePart_(x, lot.part, lot.name) &&
    (sn ? snKey_(x.serial) === sn : (!x.serial && x.loc === lot.loc)))[0];
  if (!r) return;
  const left = sn ? 0 : r.qty - lot.remain;
  if (left > 0) sh.getRange(r.row, 6).setValue(left); else sh.deleteRow(r.row);
}

/** เพิ่มพัสดุเข้ารายการของชุด (ชีท ชุดพัสดุ) โดยเก็บ LOCATION = ที่จัดเก็บจริงของล็อต */
function ensureKitRow_(kit, lot, loc) {
  const sn = snKey_(lot.serial), sh = getSheet_(SHEET_KIT);
  const rows = readKit_().filter(r => r.kit === kit && kitSamePart_(r, lot.part, lot.name));
  if (sn) {
    const same = rows.filter(r => snKey_(r.serial) === sn)[0];
    if (same) { sh.getRange(same.row, 7).setValue(loc); return { added: 'exists' }; }
  } else {
    const r = rows.filter(x => !x.serial && x.loc === loc)[0];
    if (r) { sh.getRange(r.row, 6).setValue(r.qty + lot.remain); return { added: 'qty' }; }
  }
  const row = [kit, lot.part, lot.name, lot.type, lot.serial, sn ? 1 : lot.remain, loc, 'เพิ่มจากหน้าย้ายที่จัดเก็บ'];
  sh.getRange(sh.getLastRow() + 1, 1, 1, row.length).setValues([row]);
  return { added: 'new' };
}

/** เมื่อแก้ LOCATION ในชีท คลังพัสดุ หรือ รับ ด้วยมือ -> แก้อีกชีทให้ตรงกันทันที (simple trigger ทำงานเอง ไม่ต้องตั้งค่า) */
function onEdit(e) {
  try {
    if (!e || !e.range) return;
    const sh = e.range.getSheet(), name = sh.getName();
    if (name !== SHEET_STK && name !== SHEET_RCV && name !== SHEET_RCV2) return;
    const col = name === SHEET_STK ? 11 : rcCol_(RC.LOC);
    splitReturnRows_();
    const c1 = e.range.getColumn(), c2 = c1 + e.range.getNumColumns() - 1;
    if (col < c1 || col > c2) return;
    const r1 = Math.max(e.range.getRow(), 2), r2 = e.range.getRow() + e.range.getNumRows() - 1;
    if (r2 < r1) return;
    const n = r2 - r1 + 1;
    const seqs = sh.getRange(r1, 1, n, 1).getValues();
    const locs = sh.getRange(r1, col, n, 1).getValues();
    const others = name === SHEET_STK ? [SHEET_RCV, SHEET_RCV2] : [SHEET_STK];
    const oCol = name === SHEET_STK ? rcCol_(RC.LOC) : 11;
    const pos = {};   // ลำดับรับ -> {sh, row}
    others.forEach(on => {
      const other = getSheet_(on), oLast = other.getLastRow();
      if (oLast < 2) return;
      other.getRange(2, 1, oLast - 1, 1).getValues().forEach((r, i) => { if (r[0] !== '') pos[Number(r[0])] = { sh: other, row: i + 2 }; });
    });
    let changed = 0;
    seqs.forEach((r, i) => {
      const t = pos[Number(r[0])];
      if (!t || r[0] === '') return;
      t.sh.getRange(t.row, oCol).setValue(str_(locs[i][0]));
      changed++;
    });
    if (changed) log_('ย้ายที่จัดเก็บ', '', 'แก้ LOCATION ในชีท ' + name + ' ' + changed + ' รายการ (ซิงค์ชีทอื่นให้ตรงกัน)', 'แก้ในชีท');
  } catch (err) { /* ไม่ขัดจังหวะการแก้ชีท */ }
}

/* ---------- ตรวจนับพัสดุ (ตามที่จัดเก็บ) + ปรับยอดอย่างมีหลักฐาน ---------- */
const CNT = { DOC: 0, DATE: 1, LOC: 2, SEQ: 3, PART: 4, NAME: 5, SN: 6, TYPE: 7, UNIT: 8, SYS: 9, CNT: 10, DIFF: 11, RES: 12, NOTE: 13, BY: 14, WIT: 15, AT: 16 };
const ADJ_DOC = 'ปรับยอดตรวจนับ';
const CNT_OK = 'ตรง';
const CNT_ADJ = 'ปรับยอดแล้ว';
const CNT_NOADJ = 'ไม่ปรับยอด';
const NO_LOC = '(ไม่ระบุที่เก็บ)';

/** เลขที่ตรวจนับถัดไป รูปแบบ ตน.ปีงบ-ลำดับ เช่น ตน.70-001 (เริ่มใหม่ทุกปีงบประมาณ) */
function nextCountNo_(sh, date) {
  const yy = fiscalYY_(date);
  let max = 0;
  const last = sh.getLastRow();
  if (last >= 2) sh.getRange(2, 1, last - 1, 1).getValues().forEach(r => {
    const m = str_(r[0]).match(/^ตน\.(\d{2})-(\d+)$/);
    if (m && m[1] === yy) max = Math.max(max, Number(m[2]));
  });
  return 'ตน.' + yy + '-' + pad_(max + 1, 3);
}

/** รายการ LOCATION ที่มีพัสดุอยู่ พร้อมวันที่ตรวจนับล่าสุด */
function getCountLocations() {
  const lots = computeLots_().filter(l => l.remain > 0);
  const sh = getSheet_(SHEET_CNT), last = sh.getLastRow();
  const lastCnt = {};
  if (last >= 2) sh.getRange(2, 1, last - 1, 3).getValues().forEach(r => {
    const d = r[CNT.DATE], k = str_(r[CNT.LOC]);
    if (d instanceof Date && (!lastCnt[k] || d > lastCnt[k])) lastCnt[k] = d;
  });
  const g = {};
  lots.forEach(l => {
    const k = l.loc;
    const o = g[k] || (g[k] = { loc: k, label: k || NO_LOC, lots: 0, qty: 0, last: lastCnt[k] ? fmtThai_(lastCnt[k]) : '' });
    o.lots++; o.qty += l.remain;
  });
  return Object.keys(g).sort((a, b) => (a === '') - (b === '') || (a < b ? -1 : a > b ? 1 : 0)).map(k => g[k]);
}

/** รายการที่ระบบบอกว่าควรอยู่ใน LOCATION นั้น (ยอดคงเหลือจริงในคลัง ไม่รวมที่ยืมออก) */
function getCountList(loc) {
  const k = str_(loc);
  const items = computeLots_().filter(l => l.remain > 0 && l.loc === k)
    .sort((a, b) => (a.part < b.part ? -1 : a.part > b.part ? 1 : 0) || (a.serial < b.serial ? -1 : a.serial > b.serial ? 1 : 0) || (a.seq - b.seq))
    .map(l => ({ seq: l.seq, part: l.part, name: l.name, serial: l.serial, type: l.type, unit: l.unit, qty: l.remain, cond: l.cond, label: l.label }));
  return { loc: k, label: k || NO_LOC, date: fmtThai_(parseDate_(todayStr_())), items: items };
}

function addFoundRcv_(o, loc, note) {
  return appendRcv_([
    nextRcvSeq_(), '', o.part, o.name, o.serial, o.type, o.qty, o.unit || 'EA', '', '',
    o.cond, '', '', '', parseDate_(todayStr_()), '', '', '', '', '', loc, '', note, SRC_OPEN, ''
  ]);
}

/**
 * บันทึกผลตรวจนับของ 1 LOCATION
 * p = { location, by, witness, adjust, reason, items:[{seq, sys, counted, note}], extras:[{part,name,serial,type,unit,qty,cond,note}] }
 * adjust=true : ปรับยอดตามที่นับได้ โดยเพิ่มรายการใน จ่าย (ขาด) / รับ (เกิน) ไม่แก้รายการเดิม และต้องระบุเหตุผล
 */
function submitCount(p) {
  return withLock_(() => {
    const loc = str_(p.location);
    const by = str_(p.by);
    if (!by) throw new Error('กรุณาตั้งชื่อผู้ใช้ก่อนบันทึก');
    const items = p.items || [], extras = p.extras || [];
    if (!items.length && !extras.length) throw new Error('ไม่มีรายการตรวจนับ');
    const adjust = p.adjust === true || p.adjust === 'true';
    const reason = str_(p.reason);
    const lotMap = {};
    computeLots_().forEach(l => { lotMap[l.seq] = l; });

    const date = parseDate_(todayStr_());
    const rows = [];       // แถวที่จะบันทึกลงชีท ตรวจนับ (ยังไม่มีเลขที่)
    const acts = [];       // การปรับยอดที่จะทำ
    items.forEach(it => {
      const lot = lotMap[Number(it.seq)];
      if (!lot || lot.remain <= 0) throw new Error('ไม่พบพัสดุลำดับรับ ' + it.seq + ' ในคลัง (อาจมีการจ่าย/ย้ายระหว่างนับ) กรุณาเริ่มนับใหม่');
      if (lot.loc !== loc) throw new Error(lot.part + ' ถูกย้ายไปที่ ' + (lot.loc || NO_LOC) + ' ระหว่างนับ กรุณาเริ่มนับใหม่');
      if (num_(it.sys) !== lot.remain) throw new Error('ยอดในระบบของ ' + lot.part + (lot.serial ? ' S/N ' + lot.serial : '') + ' เปลี่ยนไประหว่างนับ (ตอนนี้ ' + lot.remain + ') กรุณาเริ่มนับใหม่');
      if (it.counted === '' || it.counted === null || it.counted === undefined || isNaN(Number(it.counted))) throw new Error('ยังไม่ได้กรอกจำนวนที่นับได้ของ ' + lot.part);
      const c = Number(it.counted);
      if (c < 0) throw new Error('จำนวนที่นับได้ต้องไม่ติดลบ (' + lot.part + ')');
      if (lot.serial && c > 1) throw new Error('พัสดุที่มี Serial number นับได้ไม่เกิน 1 ชิ้น (' + lot.part + ' S/N ' + lot.serial + ')');
      const diff = c - lot.remain;
      rows.push({ lot: lot, seq: lot.seq, part: lot.part, name: lot.name, serial: lot.serial, type: lot.type, unit: lot.unit, sys: lot.remain, cnt: c, diff: diff, note: str_(it.note) });
      if (diff !== 0) acts.push({ kind: diff < 0 ? 'out' : 'in', lot: lot, qty: Math.abs(diff), idx: rows.length - 1 });
    });
    extras.forEach(x => {
      const q = num_(x.qty);
      if (!str_(x.name)) throw new Error('รายการที่พบเพิ่ม: กรุณากรอกชื่อพัสดุ');
      if (q <= 0) throw new Error('รายการที่พบเพิ่ม: จำนวนต้องมากกว่า 0');
      const type = str_(x.type);
      if (type && ITEM_TYPES.indexOf(type) < 0) throw new Error('ประเภทพัสดุไม่ถูกต้อง');
      if (str_(x.serial) && q !== 1) throw new Error('พัสดุที่มี Serial number ต้องจำนวน 1 ต่อ 1 Serial');
      rows.push({ lot: null, seq: '', part: str_(x.part), name: str_(x.name), serial: str_(x.serial), type: type, unit: str_(x.unit) || 'EA', sys: 0, cnt: q, diff: q, note: str_(x.note), cond: str_(x.cond) });
      acts.push({ kind: 'found', qty: q, idx: rows.length - 1 });
    });
    if (adjust && acts.length && !reason) throw new Error('กรุณาระบุเหตุผลการปรับยอด');

    const sh = getSheet_(SHEET_CNT);
    const docNo = nextCountNo_(sh, date);
    const tag = ADJ_DOC + ' ' + docNo + (reason ? ': ' + reason : '');

    if (adjust) {
      acts.forEach(a => {
        const r = rows[a.idx];
        if (a.kind === 'out') {
          appendIss_([nextSeq_(getSheet_(SHEET_ISS)), date, ADJ_DOC, a.lot.seq, a.lot.part, a.lot.name, a.lot.serial, a.qty, a.lot.unit, '', '', tag, by]);
        } else if (a.kind === 'in') {
          r.newSeq = nextRcvSeq_();
          addFoundRcv_({ part: a.lot.part, name: a.lot.name, serial: '', type: a.lot.type, unit: a.lot.unit, qty: a.qty, cond: a.lot.cond }, loc, 'พบเกินจากตรวจนับ ' + docNo + (reason ? ': ' + reason : ''));
        } else {
          r.newSeq = nextRcvSeq_();
          addFoundRcv_({ part: r.part, name: r.name, serial: r.serial, type: r.type, unit: r.unit, qty: a.qty, cond: r.cond }, loc, 'พบเกินจากตรวจนับ ' + docNo + (reason ? ': ' + reason : ''));
        }
      });
    }

    const nowD = new Date(), wit = str_(p.witness);
    const out = rows.map(r => {
      const res = r.diff === 0 ? CNT_OK : (adjust ? CNT_ADJ : CNT_NOADJ);
      const note = [r.diff !== 0 && reason ? reason : '', r.note].filter(Boolean).join(' | ');
      r.res = res; r.fullNote = note;
      return [docNo, date, loc, r.newSeq || r.seq, r.part, r.name, r.serial, r.type, r.unit, r.sys, r.cnt, r.diff, res, note, by, wit, nowD];
    });
    const startRow = sh.getLastRow() + 1;
    sh.getRange(startRow, 1, out.length, 1).setNumberFormat('@');
    sh.getRange(startRow, 1, out.length, out[0].length).setValues(out);
    sh.getRange(startRow, 2, out.length, 1).setNumberFormat('dd/mm/yyyy');
    sh.getRange(startRow, 17, out.length, 1).setNumberFormat('dd/mm/yyyy hh:mm');

    const nd = rows.filter(r => r.diff !== 0).length;
    log_('ตรวจนับ', docNo, [(loc || NO_LOC), rows.length + ' รายการ', 'ผลต่าง ' + nd, nd ? (adjust ? 'ปรับยอดแล้ว: ' + reason : 'ไม่ปรับยอด') : ''].filter(Boolean).join(' | '), by);
    if (adjust && acts.length) rebuildStock_();
    return countSession_(out.map(x => x.map(v => v)), docNo);
  });
}

/** แปลงแถวชีท ตรวจนับ ของเลขที่เดียวกัน เป็นข้อมูลสำหรับแสดง/พิมพ์รายงาน */
function countSession_(rows, docNo) {
  const f = rows[0];
  return {
    docNo: docNo, date: fmtThai_(f[CNT.DATE]), loc: str_(f[CNT.LOC]), label: str_(f[CNT.LOC]) || NO_LOC,
    by: str_(f[CNT.BY]), witness: str_(f[CNT.WIT]),
    adjusted: rows.some(r => str_(r[CNT.RES]) === CNT_ADJ),
    diffs: rows.filter(r => num_(r[CNT.DIFF]) !== 0).length,
    reason: (rows.filter(r => num_(r[CNT.DIFF]) !== 0 && str_(r[CNT.NOTE]))[0] || [])[CNT.NOTE] || '',
    rows: rows.map(r => ({ part: str_(r[CNT.PART]), name: str_(r[CNT.NAME]), serial: str_(r[CNT.SN]), type: str_(r[CNT.TYPE]), unit: str_(r[CNT.UNIT]),
      sys: num_(r[CNT.SYS]), cnt: num_(r[CNT.CNT]), diff: num_(r[CNT.DIFF]), res: str_(r[CNT.RES]), note: str_(r[CNT.NOTE]) }))
  };
}

/** ใบตรวจนับล่าสุด (สำหรับพิมพ์รายงานซ้ำ) */
function getCountHistory(limit) {
  const sh = getSheet_(SHEET_CNT), last = sh.getLastRow();
  if (last < 2) return [];
  const n = Math.min(last - 1, 600);
  const vals = sh.getRange(last - n + 1, 1, n, HEADERS[SHEET_CNT].length).getValues();
  const order = [], by = {};
  vals.forEach(r => {
    const k = str_(r[CNT.DOC]);
    if (!k) return;
    if (!by[k]) { by[k] = []; order.push(k); }
    by[k].push(r);
  });
  return order.reverse().slice(0, Number(limit) || 12).map(k => countSession_(by[k], k));
}


/* ---------- ชุดพัสดุพิเศษ (FLY AWAY KIT 1 / 2) ---------- */
/*
 * ชีท "ชุดพัสดุ" = รายการมาตรฐานของแต่ละชุด (ชุด, Part, ชื่อ, ประเภท, S/N, จำนวน, LOCATION)
 * นำชุดออกไปราชการ = ยืมพัสดุเป็นรายชิ้น (ชีท ยืมพัสดุ) โดยใส่แท็ก [KIT:ชื่อชุด] ไว้หน้าเหตุผล
 * กลับมาแล้ว  - ไม่ได้ใช้        -> คืนเข้าคลัง
 *             - ใช้ติดตั้งแล้ว   -> ออกใบเบิกทดแทนทันที (เครื่อง = ชื่อชุด) รายการยืมยังเปิดค้างไว้จนกว่าจะรับของทดแทน
 *                                  เมื่อรับพัสดุตามใบเบิกนั้น ระบบปิดรายการยืมให้เอง และปรับ S/N ในชีทชุดพัสดุเป็นตัวใหม่
 * สถานะชุดคำนวณจากรายการยืมที่ยังเปิด จึงไม่ต้องเก็บสถานะแยก
 */
const KIT_NAMES = ['FLY AWAY KIT 1', 'FLY AWAY KIT 2'];
const KIT_USED = 'ใช้ติดตั้ง รอเบิกทดแทน';
const KIT_TAG_RE = /^\[KIT:([^\]]+)\]\s*/;

function kitOfLoan_(v) { const m = str_(v[11]).match(KIT_TAG_RE); return m ? m[1] : ''; }
function snKey_(x) { return str_(x).toUpperCase(); }

function readKit_() {
  const sh = getSheet_(SHEET_KIT), last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, 8).getValues().map((r, i) => ({
    row: i + 2, kit: str_(r[0]), part: str_(r[1]), name: str_(r[2]), type: str_(r[3]), serial: str_(r[4]),
    qty: num_(r[5]) || 1, loc: str_(r[6]), note: str_(r[7])
  })).filter(x => x.kit && (x.part || x.name));
}
function kitSamePart_(row, part, name) { return row.part ? row.part === str_(part) : row.name === str_(name); }
function kitMatchLoan_(row, v) { return row.kit === kitOfLoan_(v) && kitSamePart_(row, v[2], v[3]) && snKey_(row.serial) === snKey_(v[4]); }
function kitLots_(row, lots) {
  const m = lots.filter(l => l.remain > 0 && kitSamePart_(row, l.part, l.name) && (!row.serial || snKey_(l.serial) === snKey_(row.serial)));
  if (row.loc && !row.serial) { const at = m.filter(l => l.loc === row.loc); if (at.length) return at; }   // Part เดียวกันอยู่คนละชุด: ดูเฉพาะที่เก็บของชุดนี้ก่อน
  return m;
}
function kitLot_(row, lots, need) {
  const c = kitLots_(row, lots).filter(l => l.remain >= (need || 1));
  return c.filter(l => row.loc && l.loc === row.loc)[0] || c[0] || null;
}

function kitState_(kit) {
  const rows = readKit_().filter(r => r.kit === kit);
  const lots = computeLots_();
  const lsh = getSheet_(SHEET_LOAN), last = lsh.getLastRow();
  const loans = (last >= 2 ? lsh.getRange(2, 1, last - 1, 20).getValues() : []).filter(v => str_(v[13]) === LOAN_OPEN && kitOfLoan_(v) === kit);
  const today = parseDate_(todayStr_());
  const items = rows.map(r => {
    let out = 0, waiting = 0; const refs = [];
    loans.forEach(v => {
      if (!kitMatchLoan_(r, v)) return;
      if (str_(v[15]) === KIT_USED) { waiting += num_(v[8]); if (str_(v[16])) refs.push(str_(v[16]).split(',')[0].trim()); } else out += num_(v[8]);
    });
    const inKit = Math.max(0, r.qty - out - waiting);
    const onHand = kitLots_(r, lots).reduce((a, l) => a + l.remain, 0);
    return { row: r.row, part: r.part, name: r.name, type: r.type, serial: r.serial, qty: r.qty, loc: r.loc, note: r.note,
      out: out, waiting: waiting, inKit: inKit, onHand: onHand, refs: refs, missing: onHand < inKit };
  });
  const loanList = loans.map(v => {
    const due = v[12] instanceof Date ? v[12] : null;
    return { seq: Number(v[0]), part: str_(v[2]), name: str_(v[3]), serial: str_(v[4]), type: str_(v[5]), unit: str_(v[7]), out: num_(v[8]),
      borrower: str_(v[9]), purpose: str_(v[11]).replace(KIT_TAG_RE, ''), date: fmtThai_(v[1]), due: fmtThai_(v[12]),
      late: due && due < today && str_(v[15]) !== KIT_USED ? Math.round((today - due) / 86400000) : 0,
      used: str_(v[15]) === KIT_USED, docRef: str_(v[16]).split(',')[0].trim() };
  }).sort((a, b) => b.seq - a.seq);
  return { kit: kit, items: items, loans: loanList, lots: lots };
}

/** ข้อมูลหน้า "ชุดพิเศษ" */
function getKits() {
  const names = KIT_NAMES.slice();
  readKit_().forEach(r => { if (names.indexOf(r.kit) < 0) names.push(r.kit); });
  return {
    machines: MACHINE_LIST.filter(m => KIT_NAMES.indexOf(m) < 0),
    kits: names.map(k => { const st = kitState_(k); return { name: k, items: st.items, loans: st.loans }; })
  };
}

/** นำชุดออกไปราชการ (เลือกเป็นรายชิ้น) p = {kit, borrower, purpose, dueDate, items:[{row, qty}], by} */
function kitCheckout(p) {
  return withLock_(() => {
    const kit = str_(p.kit);
    if (!kit) throw new Error('ไม่ได้ระบุชุด');
    if (!str_(p.borrower)) throw new Error('กรุณาระบุผู้นำชุดออก');
    if (!p.dueDate) throw new Error('กรุณาระบุวันกำหนดคืน');
    const items = p.items || [];
    if (!items.length) throw new Error('ยังไม่ได้เลือกรายการที่จะนำออก');
    const st = kitState_(kit), byRow = {};
    st.items.forEach(i => { byRow[i.row] = i; });
    const rows = readKit_().filter(r => r.kit === kit), rowOf = {};
    rows.forEach(r => { rowOf[r.row] = r; });
    const left = {};
    st.lots.forEach(l => { left[l.seq] = l.remain; });
    const plan = [];
    items.forEach(it => {
      const i = byRow[Number(it.row)], r = rowOf[Number(it.row)];
      if (!i || !r) throw new Error('ไม่พบรายการในชุด (แถว ' + it.row + ')');
      const q = num_(it.qty);
      const label = (i.part || i.name) + (i.serial ? ' S/N ' + i.serial : '');
      if (q <= 0) throw new Error(label + ': จำนวนต้องมากกว่า 0');
      if (q > i.inKit) throw new Error(label + ': ในชุดเหลือ ' + i.inKit + ' ไม่พอที่จะนำออก ' + q);
      const cand = kitLots_(r, st.lots).filter(l => left[l.seq] >= q);
      const lot = cand.filter(l => r.loc && l.loc === r.loc)[0] || cand[0];
      if (!lot) throw new Error(label + ': ไม่พบในคลังตามจำนวนที่ต้องการ (ยังไม่ได้เพิ่มยอดยกมา หรือถูกจ่าย/ยืมไปแล้ว)');
      left[lot.seq] -= q;
      plan.push({ lot: lot, q: q, label: label });
    });
    plan.forEach(x => {
      borrowCore_({ lotSeq: x.lot.seq, qty: x.q, borrower: str_(p.borrower), borrowerType: 'อื่น ๆ',
        purpose: '[KIT:' + kit + '] ' + str_(p.purpose), dueDate: p.dueDate, by: p.by });
    });
    return { ok: true, count: plan.length };
  });
}

function kitLoanCheck_(lsh, seq, needNotUsed) {
  const fl = findLoan_(lsh, seq);
  if (!fl) throw new Error('ไม่พบรายการนำออก');
  if (str_(fl.v[13]) !== LOAN_OPEN) throw new Error('รายการนี้ปิดไปแล้ว');
  if (!kitOfLoan_(fl.v)) throw new Error('รายการนี้ไม่ใช่ของชุดพัสดุ');
  if (needNotUsed && str_(fl.v[15]) === KIT_USED) throw new Error('รายการนี้ใช้ติดตั้งและออกใบเบิกทดแทนไปแล้ว รอรับพัสดุตามใบเบิก ' + str_(fl.v[16]).split(',')[0]);
  return fl;
}

/** ชุดกลับมา ชิ้นนี้ไม่ได้ใช้ -> คืนเข้าคลัง p = {seq, qty, by} */
function kitReturn(p) {
  return withLock_(() => {
    kitLoanCheck_(getSheet_(SHEET_LOAN), p.seq, true);
    return returnLoanCore_({ seq: p.seq, qty: p.qty, by: p.by });
  });
}

/** ชิ้นนี้ใช้ติดตั้งแล้ว -> ออกใบเบิกทดแทนทันที
 *  p = {seq, qty, installedOn, rank, fullName, position, urgency, issue, itemType, by} */
function kitUsed(p) { return withLock_(() => kitUsedCore_(p)); }
function kitUsedCore_(p) {
  {
    const lsh = getSheet_(SHEET_LOAN);
    const fl = kitLoanCheck_(lsh, p.seq, true), v = fl.v, kit = kitOfLoan_(v);
    const out = num_(v[8]), q = num_(p.qty);
    if (q <= 0 || q > out) throw new Error('จำนวนที่ใช้ต้องมากกว่า 0 และไม่เกินที่นำออก (' + out + ')');
    const type = str_(v[5]) || str_(p.itemType);
    if (ITEM_TYPES.indexOf(type) < 0) throw new Error('ไม่ทราบประเภทพัสดุ กรุณาใส่ประเภท (LRU / SP / LRU(TCI) / SP(TCI) / สารเคมี) ในชีท ชุดพัสดุ');
    if (!str_(p.installedOn)) throw new Error('กรุณาเลือกเครื่องที่ติดตั้ง');
    if (!str_(p.fullName)) throw new Error('กรุณาเลือกผู้เบิก');
    const urgency = str_(p.urgency) === 'AOG' ? 'AOG' : 'เบิกธรรมดา';
    const issue = str_(p.issue) || ('เบิกทดแทนชุด ' + kit + ' (ใช้ติดตั้งที่เครื่อง ' + str_(p.installedOn) + ')');
    if (q < out) returnLoanCore_({ seq: p.seq, qty: out - q, by: p.by });   // ส่วนที่ไม่ได้ใช้ คืนเข้าคลังก่อน
    const r = submitRequisitionCore_({ date: todayStr_(), urgency: urgency, machine: kit, issue: issue,
      items: [{ part: str_(v[2]), name: str_(v[3]), qty: q, unit: str_(v[7]) || 'EA' }],
      rank: str_(p.rank), fullName: str_(p.fullName), position: str_(p.position), itemType: type, by: p.by });
    const today = parseDate_(todayStr_());
    lsh.getRange(fl.row, 16).setValue(KIT_USED);
    lsh.getRange(fl.row, 17).setNumberFormat('@').setValue(r.docNo);
    lsh.getRange(fl.row, 13).setNumberFormat('dd/mm/yyyy').setValue(dueDate_(today, urgency));
    const old = str_(lsh.getRange(fl.row, 19).getValue());
    lsh.getRange(fl.row, 19).setValue([old, fmtThai_(today) + ' ใช้ติดตั้งที่เครื่อง ' + str_(p.installedOn) + ' x' + q + ' → เบิกทดแทนใบเบิก ' + r.docNo].filter(Boolean).join(' ; '));
    log_('ชุดพัสดุ ใช้ติดตั้ง', r.docNo, [kit, str_(v[2]), str_(v[3]), 'x' + q, str_(v[4]) ? 'S/N ' + str_(v[4]) : '', 'เครื่อง ' + str_(p.installedOn), 'เบิกทดแทน'].filter(Boolean).join(' | '), p.by);
    return { ok: true, docNo: r.docNo, part: str_(v[2]), name: str_(v[3]), qty: q, unit: str_(v[7]) || 'EA', itemType: type, machine: kit, issue: issue, urgency: urgency };
  }
}

/**
 * รับชุดกลับ (ครั้งเดียวจบ) : ชิ้นที่ไม่ได้ใช้ -> คืนเข้าคลัง, ชิ้นที่ใช้ติดตั้ง -> ออกใบเบิกทดแทน
 * p = {items:[{seq, used, qty}], installedOn, rank, fullName, position, urgency, by}
 */
function kitBack(p) {
  return withLock_(() => {
    const items = p.items || [];
    if (!items.length) throw new Error('ไม่มีรายการ');
    const lsh = getSheet_(SHEET_LOAN);
    const used = items.filter(i => i.used === true || i.used === 'true');
    // ตรวจทุกรายการก่อนลงมือ เพื่อไม่ให้ทำค้างครึ่งทาง
    items.forEach(i => {
      const fl = kitLoanCheck_(lsh, i.seq, true);
      if ((i.used === true || i.used === 'true') && ITEM_TYPES.indexOf(str_(fl.v[5]) || str_(i.itemType)) < 0)
        throw new Error('ไม่ทราบประเภทพัสดุของ ' + (str_(fl.v[2]) || str_(fl.v[3])) + ' กรุณาเลือกประเภทพัสดุ');
      const q = num_(i.qty);
      if (q <= 0 || q > num_(fl.v[8])) throw new Error('จำนวนของ ' + (str_(fl.v[2]) || str_(fl.v[3])) + ' ต้องมากกว่า 0 และไม่เกินที่นำออก (' + num_(fl.v[8]) + ')');
    });
    if (used.length) {
      if (!str_(p.installedOn)) throw new Error('กรุณาเลือกเครื่องที่ติดตั้ง');
      if (!str_(p.fullName)) throw new Error('กรุณาเลือกผู้เบิก');
    }
    const docs = [];
    let back = 0;
    items.forEach(i => {
      if (i.used === true || i.used === 'true') {
        docs.push(kitUsedCore_({ seq: i.seq, qty: i.qty, installedOn: p.installedOn, rank: p.rank, fullName: p.fullName,
          position: p.position, urgency: p.urgency, itemType: i.itemType, by: p.by }));
      } else {
        returnLoanCore_({ seq: i.seq, qty: i.qty, by: p.by });
        back++;
      }
    });
    return { ok: true, back: back, docs: docs };
  });
}

/** ใบเบิกทดแทนของชุด: หารายการยืมที่รอรับของทดแทนด้วยใบเบิกนี้ (ใช้ตอนรับพัสดุ) */
function findKitLoanForDoc_(lsh, docNo, part, qty) {
  const last = lsh.getLastRow();
  if (last < 2 || !docNo) return 0;
  const all = lsh.getRange(2, 1, last - 1, 20).getValues();
  for (let i = 0; i < all.length; i++) {
    const v = all[i];
    if (str_(v[13]) !== LOAN_OPEN || str_(v[15]) !== KIT_USED || !kitOfLoan_(v)) continue;
    if (str_(v[16]).split(',').map(x => x.trim()).indexOf(String(docNo)) < 0) continue;
    if (str_(part) && str_(v[2]) !== str_(part)) continue;
    if (num_(qty) > num_(v[8])) continue;
    return Number(v[0]);
  }
  return 0;
}

/** รับของทดแทนแล้ว: ถ้ารายการในชุดมี S/N ให้เปลี่ยนเป็น S/N ตัวใหม่ */
function kitAfterReceive_(loan, newSn) {
  try {
    if (!kitOfLoan_(loan)) return;
    const row = readKit_().filter(r => kitMatchLoan_(r, loan))[0];
    if (!row || !row.serial) return;
    getSheet_(SHEET_KIT).getRange(row.row, 5).setNumberFormat('@').setValue(str_(newSn));
  } catch (e) { /* ไม่ขัดจังหวะการรับพัสดุ */ }
}

/** เมนู: สร้าง/เปิดชีท ชุดพัสดุ ให้กรอกรายการมาตรฐานของชุด */
function createKitSheet() {
  const sh = getSheet_(SHEET_KIT);
  try {
    const A = SpreadsheetApp.newDataValidation().requireValueInList(KIT_NAMES, true).setAllowInvalid(true).build();
    const D = SpreadsheetApp.newDataValidation().requireValueInList(ITEM_TYPES, true).setAllowInvalid(true).build();
    sh.getRange('A2:A500').setDataValidation(A);
    sh.getRange('D2:D500').setDataValidation(D);
    sh.setFrozenRows(1);
    SpreadsheetApp.getActiveSpreadsheet().setActiveSheet(sh);
    SpreadsheetApp.getUi().alert('กรอกรายการของแต่ละชุดในชีท "ชุดพัสดุ" 1 แถวต่อ 1 รายการ (ชุด / Part / ชื่อ / ประเภท / S/N / จำนวน / LOCATION)\nถ้ารายการเหล่านี้ยังไม่อยู่ในคลัง ให้เลือกเมนู "เพิ่มรายการชุดเข้าคลัง (ยอดยกมา)" ต่อ');
  } catch (e) { /* ไม่มี UI */ }
  return { ok: true };
}

/** เมนู: เพิ่มรายการในชีท ชุดพัสดุ ที่ยังไม่มีในคลัง เข้าเป็นยอดยกมา */
function importKitToStock() {
  const names = KIT_NAMES.slice();
  readKit_().forEach(r => { if (names.indexOf(r.kit) < 0) names.push(r.kit); });
  const have = {}, out = [];
  names.forEach(kit => {
    kitState_(kit).items.forEach(i => {
      // ที่ควรอยู่ในคลัง = จำนวนมาตรฐาน - ที่นำออกอยู่ - ที่รอเบิกทดแทน ; ขาดเท่าไรจึงเพิ่มเข้าเป็นยอดยกมา
      const key = kit + '|' + (i.part || i.name) + '|' + snKey_(i.serial);
      if (!(key in have)) have[key] = i.onHand;
      const need = i.serial ? Math.min(1, i.inKit) : i.inKit;
      const take = Math.min(have[key], need);
      have[key] -= take;
      const miss = need - take;
      if (miss > 0) out.push([i.part, i.name, i.type, i.serial, miss, '', '', i.loc, '', '', '', '', '']);
    });
  });
  let msg;
  if (!out.length) msg = 'ทุกรายการในชีท ชุดพัสดุ มีอยู่ในคลังแล้ว';
  else {
    const res = importOpeningRows_(out, 'เมนูชุดพัสดุ');
    msg = res.errors && res.errors.length ? 'เพิ่มไม่สำเร็จ (ยังไม่ได้เพิ่มรายการใดเลย)\n' + res.errors.slice(0, 8).map(e => 'แถวที่ ' + e.row + ': ' + e.msg).join('\n')
      : 'เพิ่มเข้าคลังเป็นยอดยกมาแล้ว ' + res.added + ' รายการ';
  }
  try { SpreadsheetApp.getUi().alert(msg); } catch (e) { /* ไม่มี UI */ }
  return { message: msg };
}

/* ---------- ยอดยกมา: เพิ่มพัสดุที่มีอยู่แล้วเข้าคลังโดยไม่ต้องมีใบเบิก ---------- */

function addOpeningStock(p) {
  return withLock_(() => {
    if (!str_(p.part) && !str_(p.name)) throw new Error('กรุณากรอก Part number หรือชื่อพัสดุ');
    if (!str_(p.name)) throw new Error('กรุณากรอกชื่อพัสดุ');
    const qty = num_(p.qty);
    if (qty <= 0) throw new Error('จำนวนต้องมากกว่า 0');
    const type = str_(p.itemType);
    if (type && ITEM_TYPES.indexOf(type) < 0) throw new Error('ประเภทพัสดุไม่ถูกต้อง');
    const sn = str_(p.serial);
    if (sn && qty !== 1) throw new Error('พัสดุที่มี Serial number ต้องจำนวน 1 ต่อ 1 Serial');
    appendRcv_([
      nextRcvSeq_(), '', str_(p.part), str_(p.name), sn, type, qty, str_(p.unit) || 'EA', '', '',
      str_(p.cond), '', '', '', parseDate_(todayStr_()), '', '', str_(p.cardId), '', parseDate_(p.expire), str_(p.location), '', '', SRC_OPEN, ''
    ]);
    log_('ยอดยกมา', '', [str_(p.part), str_(p.name), 'x' + qty, sn ? 'S/N ' + sn : '', str_(p.location)].filter(Boolean).join(' | '), p.by);
    rebuildStock_();
    return { ok: true };
  });
}

/** ล็อตยอดยกมา/ของคืนคลังที่ Part number เดียวกับใบเบิก (ให้เลือกรับจากคลัง) : row = ลำดับรับของล็อต */
function getOpeningLots(part, name) {
  return computeLots_().filter(l => {
    if (!l.free || l.remain <= 0) return false;
    return str_(part) ? l.part === str_(part) : l.name === str_(name);
  }).map(l => ({
    row: l.seq, source: l.src, serial: l.serial, qty: l.remain, cond: l.cond, location: l.loc,
    expireIso: l.expire ? Utilities.formatDate(l.expire, TZ, 'yyyy-MM-dd') : ''
  }));
}

/* ---------- คืนเข้าคลัง: นำพัสดุที่จ่ายไปแล้วกลับเข้าคลังทันที ---------- */

/** จำนวนที่คืนเข้าคลังแล้ว แยกตามลำดับจ่าย */
function returnedMap_(R_) {
  const back = {};
  (R_ || readRcv_()).forEach(r => {
    if (str_(r[RC.SRC]) === SRC_RET && Number(r[RC.REF])) back[Number(r[RC.REF])] = (back[Number(r[RC.REF])] || 0) + num_(r[RC.QTY]);
  });
  return back;
}

/** รายการจ่ายให้ช่างที่ยังคืนเข้าคลังได้ (ไม่รวมแถวโอนเข้าใบเบิก) */
function isTechIssue_(r) { return str_(r[IS.TECH]) !== ''; }

function getReturnable() {
  const back = returnedMap_();
  const info = reqInfoMap_();
  const out = [];
  const lotsBySeq = {};
  computeLots_().forEach(l => { lotsBySeq[l.seq] = l; });
  readIss_().forEach(r => {
    if (!isTechIssue_(r)) return;
    const remain = num_(r[IS.QTY]) - (back[Number(r[IS.SEQ])] || 0);
    if (remain <= 0) return;
    const docNo = docStr_(r[IS.DOC]);
    const q = info[docNo + '|' + str_(r[IS.PART])] || {};
    const lot = lotsBySeq[Number(r[IS.RSEQ])] || null;
    out.push({
      seq: Number(r[IS.SEQ]), docNo: docNo, part: str_(r[IS.PART]), name: str_(r[IS.NAME]), serial: str_(r[IS.SN]),
      qty: num_(r[IS.QTY]), remain: remain, unit: str_(r[IS.UNIT]), type: q.type || (str_(r[IS.SN]) ? 'LRU' : 'SP'), machine: q.machine || '',
      tail: str_(r[IS.TAIL]), tech: str_(r[IS.TECH]), cond: lot ? lot.cond : '', location: lot ? lot.loc : '',
      payDate: fmtThai_(r[IS.DATE])
    });
  });
  return out.reverse();
}

function findLotInList_(lots, seq) {
  if (!seq) return null;
  return (lots || computeLots_()).filter(l => l.seq === Number(seq))[0] || null;
}

function submitReturnToStock(p) {
  return withLock_(() => {
    const rv = readIss_().filter(r => Number(r[IS.SEQ]) === Number(p.seq))[0];
    if (!rv || !isTechIssue_(rv)) throw new Error('ไม่พบรายการจ่ายที่เลือก');
    if (!str_(p.reason)) throw new Error('กรุณาระบุเหตุผลที่คืนเข้าคลัง');
    const qty = num_(p.qty);
    if (qty <= 0) throw new Error('จำนวนต้องมากกว่า 0');
    const already = returnedMap_()[Number(p.seq)] || 0;
    const remain = num_(rv[IS.QTY]) - already;
    if (qty > remain) throw new Error('คืนเกินจำนวนที่จ่าย (คืนได้อีก ' + remain + ')');

    const docNo = docStr_(rv[IS.DOC]);
    const q = reqInfoMap_()[docNo + '|' + str_(rv[IS.PART])] || {};
    const type = q.type || (str_(rv[IS.SN]) ? 'LRU' : 'SP');
    const sn = str_(rv[IS.SN]);
    const lot = findLot_(rv[IS.RSEQ]);
    const cond = str_(p.cond) || (lot ? lot.cond : '');
    const loc = str_(p.location) || (lot ? lot.loc : '');
    const al = serialAlert_(sn, str_(rv[IS.PART]));
    const alNote = al ? ' · ⚠ คืนซ้ำ Serial เดิมภายใน ' + SERIAL_ALERT_DAYS + ' วัน (รับ ' + al.receiveDate + ' · ผ่านมา ' + al.days + ' วัน)' : '';
    const note = 'คืนจากใบเบิก ' + docNo + ' · ' + str_(p.reason) + alNote;

    appendRcv_([
      nextRcvSeq_(), '', str_(rv[IS.PART]), str_(rv[IS.NAME]), sn, type, qty, str_(rv[IS.UNIT]), '', '',
      cond, '', '', '', parseDate_(todayStr_()), '', '', '', '', lot ? lot.expire : '', loc, '', note, SRC_RET, Number(p.seq)
    ]);

    // บันทึกลงชีท ส่งคืน เพื่อให้ประวัติการส่งคืนอยู่ที่เดียวกัน
    const ret = getSheet_(SHEET_RET);
    ret.appendRow([
      nextSeq_(ret), str_(rv[IS.PART]), str_(rv[IS.NAME]), qty, sn, '', str_(p.by), str_(rv[IS.TECH]), q.machine || '', '', note, new Date()
    ]);
    ret.getRange(ret.getLastRow(), 12).setNumberFormat('dd/mm/yyyy hh:mm');

    log_('คืนเข้าคลัง', docNo, [str_(rv[IS.PART]), str_(rv[IS.NAME]), 'x' + qty, sn ? 'S/N ' + sn : '', 'เหตุผล: ' + str_(p.reason)].filter(Boolean).join(' | '), p.by);
    rebuildStock_();
    return { ok: true, left: remain - qty, alert: al };
  });
}

/* ---------- แจ้งเตือน: LRU ที่มี Serial ถูกส่งคืนด้วย Serial เดิมภายใน 365 วันนับจากวันที่รับ ---------- */

function serialAlert_(serial, part) {
  const sn = str_(serial).toUpperCase();
  if (!sn) return null;
  let hit = null;
  readIss_().forEach(r => {
    if (isTechIssue_(r) && str_(r[IS.SN]).toUpperCase() === sn && (!str_(part) || str_(r[IS.PART]) === str_(part))) {
      if (!hit || Number(r[IS.SEQ]) > Number(hit[IS.SEQ])) hit = r;
    }
  });
  if (!hit) return null;
  const docNo = docStr_(hit[IS.DOC]);
  const q = reqInfoMap_()[docNo + '|' + str_(hit[IS.PART])] || {};
  const lot = findLot_(hit[IS.RSEQ]);
  const recv = lot && lot.recvDate ? lot.recvDate : null;
  if (!recv) return null;
  const today = parseDate_(todayStr_());
  const rd = new Date(recv.getFullYear(), recv.getMonth(), recv.getDate());
  const days = Math.round((today - rd) / 86400000);
  if (days > SERIAL_ALERT_DAYS || days < 0) return null;

  let prior = 0;
  const ret = getSheet_(SHEET_RET);
  const rl = ret.getLastRow();
  if (rl >= 2) {
    ret.getRange(2, 5, rl - 1, 1).getValues().forEach(x => { if (str_(x[0]).toUpperCase() === sn) prior++; });
  }
  return {
    alert: true, serial: str_(serial), part: str_(hit[IS.PART]), name: str_(hit[IS.NAME]), docNo: docNo,
    receiveDate: fmtThai_(recv), issueDate: fmtThai_(hit[IS.DATE]), days: days, limit: SERIAL_ALERT_DAYS,
    tail: str_(hit[IS.TAIL]), tech: str_(hit[IS.TECH]), priorReturns: prior
  };
}

/** เรียกจากหน้าเว็บตอนกรอก Serial ส่งคืน / เลือกรายการคืนเข้าคลัง */
function checkSerialAlert(serial, part) {
  return serialAlert_(serial, part) || { alert: false };
}

/** ตรวจหลาย Serial พร้อมกัน : คืนรายการที่ต้องแจ้งเตือน */
function checkSerialAlerts(serials, part) {
  return splitSerials_(serials).map(s => serialAlert_(s, part)).filter(Boolean);
}

/* ---------- ยืมพัสดุ: ช่างหยิบยืม / TAI ขอยืม แล้วติดตามจนปิด ---------- */

function findLoan_(lsh, seq) {
  const last = lsh.getLastRow();
  if (last < 2) return null;
  const all = lsh.getRange(2, 1, last - 1, 20).getValues();
  for (let i = 0; i < all.length; i++) if (Number(all[i][0]) === Number(seq)) return { row: i + 2, v: all[i] };
  return null;
}

/** ปรับยอดค้างยืม และปิดรายการเมื่อครบ */
function closeLoanQty_(lsh, row, v, qty, method, docRef, text) {
  const out = Math.max(0, num_(v[8]) - qty);
  lsh.getRange(row, 9).setValue(out);
  lsh.getRange(row, 16).setValue(method);
  if (docRef) lsh.getRange(row, 17).setNumberFormat('@').setValue([str_(v[16]), docRef].filter(Boolean).join(', '));
  lsh.getRange(row, 19).setValue([str_(v[18]), fmtThai_(parseDate_(todayStr_())) + ' ' + text].filter(Boolean).join(' ; '));
  if (out <= 0) {
    lsh.getRange(row, 14).setValue(LOAN_CLOSED);
    lsh.getRange(row, 15).setNumberFormat('dd/mm/yyyy').setValue(parseDate_(todayStr_()));
  }
  return out;
}

function countOverdueLoans_() {
  const lsh = getSheet_(SHEET_LOAN);
  const last = lsh.getLastRow();
  if (last < 2) return 0;
  const today = parseDate_(todayStr_());
  let n = 0;
  lsh.getRange(2, 1, last - 1, 20).getValues().forEach(r => {
    if (str_(r[13]) === LOAN_OPEN && r[12] instanceof Date && r[12] < today) n++;
  });
  return n;
}

function submitBorrow(p) { return withLock_(() => borrowCore_(p)); }
function borrowCore_(p) {
  {
    const lot = findLot_(p.lotSeq);
    if (!lot || lot.remain <= 0) throw new Error('ไม่พบล็อตในคลังที่เลือก');
    const qty = num_(p.qty);
    if (qty <= 0) throw new Error('จำนวนต้องมากกว่า 0');
    if (qty > lot.remain) throw new Error('จำนวนในคลังไม่พอ (เหลือ ' + lot.remain + ')');
    if (!str_(p.borrower)) throw new Error('กรุณาระบุชื่อผู้ยืม');
    if (!p.dueDate) throw new Error('กรุณาระบุวันกำหนดคืน');
    const btype = LOAN_BORROWER_TYPES.indexOf(str_(p.borrowerType)) >= 0 ? str_(p.borrowerType) : 'ช่าง';

    const lsh = getSheet_(SHEET_LOAN);
    const r = lsh.getLastRow() + 1;
    const no = nextSeq_(lsh);
    lsh.getRange(r, 17).setNumberFormat('@');
    lsh.getRange(r, 1, 1, 20).setValues([[
      no, parseDate_(todayStr_()), lot.part, lot.name, lot.serial, lot.type, qty, lot.unit, qty,
      str_(p.borrower), btype, str_(p.purpose), parseDate_(p.dueDate), LOAN_OPEN, '', '', '', lot.seq, '', 0
    ]]);
    lsh.getRange(r, 2).setNumberFormat('dd/mm/yyyy');
    lsh.getRange(r, 13).setNumberFormat('dd/mm/yyyy');
    log_('ยืม', '', [lot.part, lot.name, 'x' + qty, lot.serial ? 'S/N ' + lot.serial : '',
      'ผู้ยืม ' + str_(p.borrower) + ' (' + btype + ')', 'กำหนดคืน ' + fmtThai_(parseDate_(p.dueDate)),
      str_(p.purpose)].filter(Boolean).join(' | '), p.by);
    rebuildStock_();
    return { ok: true, loanNo: no };
  }
}

function loanOut_(lsh, seq, qty) {
  const fl = findLoan_(lsh, seq);
  if (!fl) throw new Error('ไม่พบรายการยืม');
  if (str_(fl.v[13]) !== LOAN_OPEN) throw new Error('รายการยืมนี้ปิดไปแล้ว');
  const q = num_(qty);
  if (q <= 0) throw new Error('จำนวนต้องมากกว่า 0');
  if (q > num_(fl.v[8])) throw new Error('เกินจำนวนที่ค้างยืม (ค้าง ' + num_(fl.v[8]) + ')');
  return { fl: fl, q: q };
}

/** ผู้ยืมนำของมาคืน (ไม่ได้ใช้) -> กลับเข้าคลังทันที */
function returnLoan(p) { return withLock_(() => returnLoanCore_(p)); }
function returnLoanCore_(p) {
  {
    const lsh = getSheet_(SHEET_LOAN);
    const o = loanOut_(lsh, p.seq, p.qty);
    const v = o.fl.v;
    if (!findLot_(v[17])) throw new Error('ไม่พบล็อตเดิมในคลัง จึงคืนเข้าคลังไม่ได้');
    lsh.getRange(o.fl.row, 20).setValue(num_(v[19]) + o.q);   // จำนวนที่คืนเข้าคลังแล้ว (คลังพัสดุคำนวณใหม่เอง)
    const left = closeLoanQty_(lsh, o.fl.row, v, o.q, LOAN_RETURNED, '', 'คืนเข้าคลัง x' + o.q);
    log_('คืนของที่ยืม', '', [str_(v[2]), str_(v[3]), 'x' + o.q, str_(v[4]) ? 'S/N ' + str_(v[4]) : '', 'ผู้ยืม ' + str_(v[9]),
      left > 0 ? 'ค้างคืนอีก ' + left : '(ปิดรายการ)'].filter(Boolean).join(' | '), p.by);
    rebuildStock_();
    return { ok: true, left: left };
  }
}

/** ผู้ยืม (เช่น TAI) เบิกคืนให้แล้ว: ปิดยืมโดยอ้างเลขเบิก ของทดแทนเข้าคลังตามขั้นตอนรับปกติ */
function closeLoanReplaced(p) {
  return withLock_(() => {
    const lsh = getSheet_(SHEET_LOAN);
    const o = loanOut_(lsh, p.seq, p.qty);
    const v = o.fl.v;
    const docNo = pad_(str_(p.docNo).replace(/\D/g, ''), 9);
    const f = findReq_(getSheet_(SHEET_REQ), docNo);
    if (!f) throw new Error('ไม่พบใบเบิกเลขที่ ' + docNo);
    if (isCancelled_(f.v[7])) throw new Error('ใบเบิกนี้ถูกยกเลิกแล้ว');
    const same = str_(v[2]) ? str_(f.v[2]) === str_(v[2]) : str_(f.v[3]) === str_(v[3]);
    if (!same) throw new Error('พัสดุในใบเบิกไม่ตรงกับพัสดุที่ยืม');
    const left = closeLoanQty_(lsh, o.fl.row, v, o.q, LOAN_REPLACED, docNo, 'ผู้ยืมเบิกคืนแล้ว x' + o.q + ' (ใบเบิก ' + docNo + ')');
    log_('ปิดยืม (เบิกคืนแล้ว)', docNo, [str_(v[2]), str_(v[3]), 'x' + o.q, 'ผู้ยืม ' + str_(v[9]),
      left > 0 ? 'ค้างอีก ' + left : '(ปิดรายการ)'].filter(Boolean).join(' | '), p.by);
    return { ok: true, left: left };
  });
}

function getLoans() {
  const lsh = getSheet_(SHEET_LOAN);
  const last = lsh.getLastRow();
  if (last < 2) return [];
  const today = parseDate_(todayStr_());
  const rows = lsh.getRange(2, 1, last - 1, 20).getValues().map(r => {
    const open = str_(r[13]) === LOAN_OPEN;
    const due = r[12] instanceof Date ? r[12] : null;
    const late = open && due && due < today ? Math.round((today - due) / 86400000) : 0;
    return {
      seq: Number(r[0]), date: fmtThai_(r[1]), part: str_(r[2]), name: str_(r[3]), serial: str_(r[4]), type: str_(r[5]),
      qty: num_(r[6]), unit: str_(r[7]), out: num_(r[8]), borrower: str_(r[9]), btype: str_(r[10]), purpose: str_(r[11]),
      due: fmtThai_(r[12]), open: open, late: late, status: str_(r[13]), closed: fmtThai_(r[14]), method: str_(r[15]),
      docRef: str_(r[16]), note: str_(r[18]), dueMs: due ? due.getTime() : 0
    };
  });
  const open = rows.filter(x => x.open).sort((a, b) => (b.late - a.late) || (a.dueMs - b.dueMs));
  const closed = rows.filter(x => !x.open).sort((a, b) => b.seq - a.seq).slice(0, 100);
  return open.concat(closed);
}

/** รายการที่ยืมอยู่ของพัสดุเดียวกับใบเบิก (ให้เลือกปิดยืมตอนรับ) */
function getLoansForPart(part, name) {
  const lsh = getSheet_(SHEET_LOAN);
  const last = lsh.getLastRow();
  if (last < 2) return [];
  const lots = computeLots_();
  const out = [];
  lsh.getRange(2, 1, last - 1, 20).getValues().forEach(r => {
    if (str_(r[13]) !== LOAN_OPEN || num_(r[8]) <= 0) return;
    const same = str_(part) ? str_(r[2]) === str_(part) : str_(r[3]) === str_(name);
    if (!same) return;
    const lot = lots.filter(l => l.seq === Number(r[17]))[0] || null;
    out.push({
      seq: Number(r[0]), serial: str_(r[4]), out: num_(r[8]), borrower: str_(r[9]), btype: str_(r[10]),
      cond: lot ? lot.cond : '', location: lot ? lot.loc : '',
      expireIso: lot && lot.expire ? Utilities.formatDate(lot.expire, TZ, 'yyyy-MM-dd') : ''
    });
  });
  return out;
}

/* ---------- API: ส่งคืน ---------- */

/** แยกรายการ Serial (ขึ้นบรรทัดใหม่ , ; หรือเว้นวรรคหลายช่อง) */
function splitSerials_(v) {
  return String(v === null || v === undefined ? '' : v).split(/[\n\r,;]+/).map(x => x.trim()).filter(Boolean);
}

/** ปีงบประมาณ (พ.ศ. 2 หลัก) : เริ่ม 1 ต.ค. สิ้นสุด 30 ก.ย. เช่น 21 ก.ย. 2569 = 69 ; 1 ต.ค. 2569 = 70 */
function fiscalYY_(d) {
  const be = Number(Utilities.formatDate(d, TZ, 'yyyy')) + 543;
  const m = Number(Utilities.formatDate(d, TZ, 'M'));
  return pad_((m >= 10 ? be + 1 : be) % 100, 2);
}

/** เลขที่หนังสือของผู้ส่งคืนถัดไป รูปแบบ ปีงบ-ลำดับ เช่น 70-001 (ลำดับเริ่มใหม่ทุกปีงบประมาณ) */
function nextReturnNo_(sh, date) {
  const yy = fiscalYY_(date);
  let max = 0;
  const last = sh.getLastRow();
  if (last >= 2) sh.getRange(2, 13, last - 1, 1).getValues().forEach(r => {
    const m = str_(r[0]).match(/^(\d{2})-(\d+)$/);
    if (m && m[1] === yy) max = Math.max(max, Number(m[2]));
  });
  return yy + '-' + pad_(max + 1, 3);
}

/** เลขที่หนังสือถัดไป (แสดงในฟอร์มให้แก้ได้) */
function getNextReturnNo(dateIso) {
  const d = dateIso ? parseDate_(dateIso) : parseDate_(todayStr_());
  return nextReturnNo_(getSheet_(SHEET_RET), d);
}

/** ส่งคืน 1 รายการ ได้หลาย Serial : บันทึกชีท ส่งคืน แถวละ 1 Serial (จำนวน 1) ใช้ที่หนังสือเดียวกัน ; Serial ที่ใส่ จับคู่ตามลำดับบรรทัด */
function submitReturn(p) {
  return withLock_(() => {
    if (!str_(p.part) && !str_(p.name)) throw new Error('กรุณากรอก Part number หรือชื่อพัสดุ');
    const sns = splitSerials_(p.serialReturn), ins = splitSerials_(p.serialInstalled);
    const seen = {};
    sns.forEach(s => { const k = s.toUpperCase(); if (seen[k]) throw new Error('Serial ซ้ำกัน: ' + s); seen[k] = 1; });
    if (ins.length > Math.max(1, sns.length)) throw new Error('Serial ที่ใส่ มากกว่า Serial ส่งคืน');
    if (!sns.length && num_(p.qty) <= 0) throw new Error('จำนวนต้องมากกว่า 0');
    const sh = getSheet_(SHEET_RET);
    const base = p.date ? parseDate_(p.date) : parseDate_(todayStr_());
    const now = new Date();
    const when = new Date(base.getFullYear(), base.getMonth(), base.getDate(), now.getHours(), now.getMinutes());
    let docNo = str_(p.docNo);
    if (docNo) {
      if (!/^\d{2}-\d{1,4}$/.test(docNo)) throw new Error('ที่หนังสือต้องเป็นรูปแบบ 70-001 (ปีงบ 2 หลัก-ลำดับ)');
      const [yy0, n0] = docNo.split('-');
      docNo = yy0 + '-' + pad_(Number(n0), 3);
      const last0 = sh.getLastRow();
      if (last0 >= 2 && sh.getRange(2, 13, last0 - 1, 1).getValues().some(r => str_(r[0]) === docNo)) throw new Error('ที่หนังสือ ' + docNo + ' ถูกใช้แล้ว');
    } else docNo = nextReturnNo_(sh, base);
    const items = sns.length ? sns.map((s, i) => ({ sn: s, inst: ins.length === sns.length ? ins[i] : (ins.length === 1 ? ins[0] : ''), qty: 1 }))
                            : [{ sn: '', inst: ins[0] || '', qty: num_(p.qty) }];
    const alerts = [];
    let seq = nextSeq_(sh);
    const rows = items.map(it => {
      const al = serialAlert_(it.sn, p.part);
      if (al) alerts.push(al);
      const alNote = al ? '⚠ ส่งคืนซ้ำ Serial เดิมภายใน ' + SERIAL_ALERT_DAYS + ' วัน (รับ ' + al.receiveDate + ' · ผ่านมา ' + al.days + ' วัน)' : '';
      return [seq++, str_(p.part), str_(p.name), it.qty, it.sn, it.inst, str_(p.receiver), str_(p.sender), str_(p.machine), str_(p.issue),
        [str_(p.remark), alNote].filter(Boolean).join(' | '), when, docNo, str_(p.condition)];
    });
    const start = sh.getLastRow() + 1;
    sh.getRange(start, 5, rows.length, 2).setNumberFormat('@');
    sh.getRange(start, 13, rows.length, 1).setNumberFormat('@');
    sh.getRange(start, 1, rows.length, 14).setValues(rows);
    sh.getRange(start, 12, rows.length, 1).setNumberFormat('dd/mm/yyyy hh:mm');
    log_('ส่งคืน', '', [docNo, str_(p.part), str_(p.name), 'x' + items.reduce((t, x) => t + x.qty, 0),
      sns.length ? 'S/N คืน ' + sns.join(', ') : '', str_(p.machine) ? 'เครื่อง ' + str_(p.machine) : '',
      alerts.length ? '⚠ เตือนส่งคืนซ้ำ ' + alerts.length + ' Serial' : ''].filter(Boolean).join(' | '), p.by);
    return { ok: true, count: rows.length, docNo: docNo, alert: alerts[0] || null, alerts: alerts };
  });
}

/* ---------- ประวัติรายตัว (Serial) · ประกัน 1 ปี · เคลม ---------- */

const D_ = d => d instanceof Date ? new Date(d.getFullYear(), d.getMonth(), d.getDate()) : null;
const dayDiff_ = (a, b) => Math.round((D_(b) - D_(a)) / 86400000);
const ymd_ = d => d instanceof Date ? Utilities.formatDate(d, TZ, 'yyyy-MM-dd') : '';

function readClaims_() {
  const sh = getSheet_(SHEET_CLAIM), last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, 13).getValues().map((r, i) => ({
    row: i + 2, id: Number(r[0]) || 0, sn: str_(r[1]), part: str_(r[2]), name: str_(r[3]), type: str_(r[4]),
    sent: r[5] instanceof Date ? r[5] : null, docRef: str_(r[6]), vendor: str_(r[7]), status: str_(r[8]),
    back: r[9] instanceof Date ? r[9] : null, newSn: str_(r[10]), note: str_(r[11]), by: str_(r[12])
  })).filter(c => c.id && c.sn);
}

/** วันเริ่มประกันของแต่ละ Serial (เฉพาะ LRU / LRU(TCI)):
 *  = วันที่ได้รับกลับจากเคลมล่าสุด (นับใหม่) ถ้ามี ; ไม่เช่นนั้น = วันที่รับครั้งแรกตามใบเบิก ; ของยอดยกมาที่ไม่มีวันรับ = ไม่ทราบ (ไม่ติดตามประกัน) */
function warrantyMap_() {
  const start = {}, today = parseDate_(todayStr_());
  readRcv_().forEach(r => {
    const k = snKey_(r[RC.SN]);
    if (!k || !isLRU_(r[RC.TYPE])) return;
    if ((str_(r[RC.SRC]) || SRC_REQ) !== SRC_REQ || !(r[RC.RDATE] instanceof Date)) return;
    if (!start[k] || r[RC.RDATE] < start[k]) start[k] = r[RC.RDATE];
  });
  readClaims_().forEach(c => {
    if (!c.back) return;
    const k = c.status === CLAIM_REPAIRED ? snKey_(c.sn) : c.status === CLAIM_NEW ? snKey_(c.newSn) : '';
    if (k && isLRU_(c.type || 'LRU') ) start[k] = c.back;
  });
  const out = {};
  Object.keys(start).forEach(k => {
    const st = D_(start[k]), end = new Date(st.getFullYear(), st.getMonth(), st.getDate() + WARRANTY_DAYS);
    const left = dayDiff_(today, end);
    out[k] = { start: fmtThai_(st), end: fmtThai_(end), left: left,
      status: left < 0 ? 'expired' : left <= WARRANTY_SOON_DAYS ? 'soon' : 'ok' };
  });
  return out;
}

/** ประวัติของ Serial หนึ่งตัว (รวมสายเคลมที่ได้ของใหม่) เรียงตามเวลา */
function getSerialHistory(serial) {
  const key = snKey_(serial);
  if (!key) throw new Error('กรุณากรอก Serial');
  const claims = readClaims_(), chain = {};
  chain[key] = 1;
  for (let grew = true; grew;) {
    grew = false;
    claims.forEach(c => {
      const a = snKey_(c.sn), b = snKey_(c.newSn);
      if (b && (chain[a] || chain[b]) && !(chain[a] && chain[b])) { chain[a] = chain[b] = 1; grew = true; }
    });
  }
  const ev = [];
  let part = '', name = '', type = '';
  readRcv_().forEach(r => {
    const k = snKey_(r[RC.SN]);
    if (!chain[k]) return;
    part = str_(r[RC.PART]); name = str_(r[RC.NAME]); type = str_(r[RC.TYPE]) || type;
    const src = str_(r[RC.SRC]) || SRC_REQ;
    ev.push({ k: k, sn: str_(r[RC.SN]), t: 'rcv', d: r[RC.RDATE] instanceof Date ? r[RC.RDATE] : null, o: 1,
      text: src === SRC_REQ ? 'รับตามใบเบิก ' + docStr_(r[RC.DOC]) : src === SRC_OPEN ? 'ยอดยกมา (ไม่มีวันที่รับ)' : src, loc: str_(r[RC.LOC]) });
  });
  readIss_().forEach(r => {
    const k = snKey_(r[IS.SN]);
    if (!chain[k]) return;
    const tech = isTechIssue_(r);
    ev.push({ k: k, sn: str_(r[IS.SN]), t: tech ? 'install' : 'out', d: r[IS.DATE] instanceof Date ? r[IS.DATE] : null, o: 2,
      text: tech ? 'จ่ายให้ช่าง/ติดตั้ง' : 'จ่ายออก', machine: str_(r[IS.TAIL]), tech: str_(r[IS.TECH]), doc: docStr_(r[IS.DOC]) });
  });
  const ret = getSheet_(SHEET_RET), rl = ret.getLastRow();
  if (rl >= 2) ret.getRange(2, 1, rl - 1, 14).getValues().forEach(r => {
    const k = snKey_(r[4]);
    if (!chain[k]) return;
    ev.push({ k: k, sn: str_(r[4]), t: 'remove', d: r[11] instanceof Date ? r[11] : null, o: 3, text: 'ส่งคืน/ถอดออก',
      machine: str_(r[8]), issue: str_(r[9]), docRef: str_(r[12]), cond: str_(r[13]) });
  });
  claims.forEach(c => {
    if (!chain[snKey_(c.sn)] && !chain[snKey_(c.newSn)]) return;
    ev.push({ k: snKey_(c.sn), sn: c.sn, t: 'claim', d: c.sent, o: 4, text: 'ส่งเคลม #' + c.id + (c.vendor ? ' → ' + c.vendor : ''), docRef: c.docRef, claimId: c.id });
    if (c.status && c.status !== CLAIM_SENT) {
      ev.push({ k: snKey_(c.sn), sn: c.sn, t: 'claimback', d: c.back || c.sent, o: 5,
        text: c.status + (c.status === CLAIM_NEW && c.newSn ? ' (S/N ใหม่ ' + c.newSn + ')' : '') + (c.status === CLAIM_REPAIRED || c.status === CLAIM_NEW ? ' · ประกันนับใหม่' : ''), claimId: c.id });
    }
  });
  if (!ev.length) throw new Error('ไม่พบ Serial ' + str_(serial) + ' ในระบบ');
  ev.sort((a, b) => ((a.d ? a.d.getTime() : -1) - (b.d ? b.d.getTime() : -1)) || (a.o - b.o));

  // ช่วงที่อยู่บนเครื่อง: จับคู่ "ติดตั้ง" กับ "ถอด" ถัดไปของ Serial เดียวกัน
  const stints = [], open = {}, today = parseDate_(todayStr_());
  ev.forEach(e => {
    if (e.t === 'install') { if (open[e.k]) stints.push(open[e.k]); open[e.k] = { sn: e.sn, machine: e.machine, from: e.d, to: null }; }
    else if (e.t === 'remove' && open[e.k]) { open[e.k].to = e.d; stints.push(open[e.k]); delete open[e.k]; }
  });
  Object.keys(open).forEach(k => stints.push(open[k]));
  const stintOut = stints.map(x => ({ sn: x.sn, machine: x.machine, from: fmtThai_(x.from), to: x.to ? fmtThai_(x.to) : '',
    days: x.from ? dayDiff_(x.from, x.to || today) : null, ongoing: !x.to }));

  const warr = warrantyMap_()[key] || null;
  const last = ev.filter(e => e.k === key).slice(-1)[0];
  let state = '';
  if (last) state = last.t === 'install' ? 'ติดตั้งอยู่ที่ ' + (last.machine || '-') : last.t === 'remove' ? 'ส่งคืน/ถอดออกแล้ว'
    : last.t === 'claim' ? 'ส่งเคลมอยู่' : last.t === 'claimback' ? 'ได้รับกลับจากเคลม' : 'อยู่ในคลัง';
  const lot = computeLots_().filter(l => snKey_(l.serial) === key && l.remain > 0)[0];
  if (lot && (!last || last.t === 'rcv')) state = 'อยู่ในคลัง' + (lot.loc ? ' (' + lot.loc + ')' : '');
  const first = ev.filter(e => e.k === key && e.d)[0];
  const onAir = stintOut.reduce((t, x) => t + (x.days || 0), 0);
  const openClaim = claims.filter(c => snKey_(c.sn) === key && c.status === CLAIM_SENT)[0] || null;
  return {
    serial: str_(serial), part: part, name: name, type: type, state: state, warranty: warr, isLRU: isLRU_(type),
    ageDays: first ? dayDiff_(first.d, today) : null, installs: stintOut.length, onAirDays: onAir,
    avgStint: stintOut.length ? Math.round(onAir / stintOut.length) : null, openClaim: openClaim ? openClaim.id : 0,
    events: ev.map(e => ({ t: e.t, date: e.d ? fmtThai_(e.d) : '', sn: e.sn, main: e.k === key, text: e.text, machine: e.machine || '', tech: e.tech || '',
      issue: e.issue || '', docRef: e.docRef || '', loc: e.loc || '' })),
    stints: stintOut
  };
}

function getClaims() {
  return readClaims_().sort((a, b) => ((a.status === CLAIM_SENT ? 0 : 1) - (b.status === CLAIM_SENT ? 0 : 1)) || (b.id - a.id)).map(c => ({
    id: c.id, sn: c.sn, part: c.part, name: c.name, type: c.type, sent: fmtThai_(c.sent), docRef: c.docRef, vendor: c.vendor,
    status: c.status, back: fmtThai_(c.back), newSn: c.newSn, note: c.note,
    days: c.sent ? dayDiff_(c.sent, c.back || parseDate_(todayStr_())) : null, open: c.status === CLAIM_SENT
  }));
}

/** บันทึกการส่งเคลม p = {serial, sentDate, docRef, vendor, note, by} */
function submitClaim(p) {
  return withLock_(() => {
    const sn = str_(p.serial);
    if (!sn) throw new Error('กรุณากรอก Serial');
    const h = getSerialHistory(sn);
    if (!h.isLRU) throw new Error('ประกัน/เคลมใช้กับ LRU และ LRU(TCI) เท่านั้น');
    if (readClaims_().some(c => snKey_(c.sn) === snKey_(sn) && c.status === CLAIM_SENT)) throw new Error('Serial นี้มีรายการส่งเคลมค้างอยู่แล้ว');
    const sh = getSheet_(SHEET_CLAIM);
    const id = nextSeq_(sh);
    const row = [id, sn, h.part, h.name, h.type, parseDate_(p.sentDate || todayStr_()), str_(p.docRef), str_(p.vendor), CLAIM_SENT, '', '', str_(p.note), str_(p.by)];
    const at = sh.getLastRow() + 1;
    sh.getRange(at, 2, 1, 1).setNumberFormat('@');
    sh.getRange(at, 1, 1, row.length).setValues([row]);
    sh.getRange(at, 6, 1, 1).setNumberFormat('dd/mm/yyyy');
    sh.getRange(at, 10, 1, 1).setNumberFormat('dd/mm/yyyy');
    log_('ส่งเคลม', '', [sn, h.part, h.name, str_(p.docRef), str_(p.vendor)].filter(Boolean).join(' | '), p.by);
    return { ok: true, id: id, warranty: h.warranty };
  });
}

/** อัปเดตสถานะเคลม p = {id, status, backDate, newSerial, note, by} */
function updateClaim(p) {
  return withLock_(() => {
    const c = readClaims_().filter(x => x.id === Number(p.id))[0];
    if (!c) throw new Error('ไม่พบรายการเคลม');
    const status = str_(p.status);
    if (CLAIM_STATUS.indexOf(status) < 0) throw new Error('สถานะไม่ถูกต้อง');
    let back = '', newSn = '';
    if (status === CLAIM_REPAIRED || status === CLAIM_NEW) {
      if (!p.backDate) throw new Error('กรุณาระบุวันที่ได้รับกลับ');
      back = parseDate_(p.backDate);
      if (c.sent && back < D_(c.sent)) throw new Error('วันที่ได้รับกลับต้องไม่ก่อนวันที่ส่งเคลม');
    }
    if (status === CLAIM_NEW) {
      newSn = str_(p.newSerial);
      if (!newSn) throw new Error('กรุณาระบุ Serial ใหม่');
      if (snKey_(newSn) === snKey_(c.sn)) throw new Error('Serial ใหม่ต้องไม่ซ้ำกับ Serial เดิม');
    }
    if (status === CLAIM_DENIED && !str_(p.note) && !c.note) throw new Error('กรุณาระบุเหตุผลที่ถูกปฏิเสธ (หมายเหตุ)');
    const sh = getSheet_(SHEET_CLAIM);
    sh.getRange(c.row, 9).setValue(status);
    sh.getRange(c.row, 10).setValue(back || '');
    if (back) sh.getRange(c.row, 10).setNumberFormat('dd/mm/yyyy');
    sh.getRange(c.row, 11).setNumberFormat('@').setValue(newSn);
    if (str_(p.note)) sh.getRange(c.row, 12).setValue(str_(p.note));
    log_('อัปเดตเคลม', '', ['#' + c.id, c.sn, status, newSn ? 'S/N ใหม่ ' + newSn : ''].filter(Boolean).join(' | '), p.by);
    return { ok: true, status: status };
  });
}

/** LRU ที่ยังอยู่ในประกัน และเหลือไม่เกิน N วัน (อยู่ในคลัง หรือติดตั้งอยู่บนเครื่อง) เรียงจากใกล้หมดก่อน */
function getWarrantyList(days) {
  const win = Number(days) || WARRANTY_SOON_DAYS, warr = warrantyMap_(), today = parseDate_(todayStr_());
  const info = {};
  readRcv_().forEach(r => {
    const k = snKey_(r[RC.SN]);
    if (k && warr[k]) info[k] = { serial: str_(r[RC.SN]), part: str_(r[RC.PART]), name: str_(r[RC.NAME]), type: str_(r[RC.TYPE]) };
  });
  const inst = {}, rem = {};
  readIss_().forEach(r => {
    const k = snKey_(r[IS.SN]);
    if (!k || !isTechIssue_(r) || !(r[IS.DATE] instanceof Date)) return;
    if (!inst[k] || r[IS.DATE] >= inst[k].d) inst[k] = { d: r[IS.DATE], machine: str_(r[IS.TAIL]) };
  });
  const ret = getSheet_(SHEET_RET), rl = ret.getLastRow();
  if (rl >= 2) ret.getRange(2, 5, rl - 1, 8).getValues().forEach(r => {      // คอลัมน์ 5..12
    const k = snKey_(r[0]); const d = r[7];
    if (k && d instanceof Date && (!rem[k] || d > rem[k])) rem[k] = d;
  });
  const stock = {};
  computeLots_().forEach(l => { if (l.remain > 0 && l.serial) stock[snKey_(l.serial)] = l; });
  const claimOpen = {};
  readClaims_().forEach(c => { if (c.status === CLAIM_SENT) claimOpen[snKey_(c.sn)] = 1; });
  const out = [];
  Object.keys(warr).forEach(k => {
    const w = warr[k], i = info[k];
    if (!i || w.left < 0 || w.left > win || claimOpen[k]) return;
    const onAir = inst[k] && (!rem[k] || rem[k] < inst[k].d);
    const where = stock[k] ? 'อยู่ในคลัง' + (stock[k].loc ? ' (' + stock[k].loc + ')' : '') : onAir ? 'ติดตั้งอยู่ที่ ' + (inst[k].machine || '-') : '';
    if (!where) return;
    out.push({ serial: i.serial, part: i.part, name: i.name, type: i.type, start: w.start, end: w.end, left: w.left, where: where });
  });
  return out.sort((a, b) => a.left - b.left);
}

/* ---------- API: ประวัติ ---------- */

function getHistory(kind, limit) {
  const name = { req: SHEET_REQ, rcv: SHEET_RCV, rcv2: SHEET_RCV2, iss: SHEET_ISS, ret: SHEET_RET, log: SHEET_LOG }[kind];
  if (!name) throw new Error('ไม่รู้จักชีท');
  const sh = getSheet_(name);
  const last = sh.getLastRow();
  const all = HEADERS[name];
  const cols = all.map((h, i) => i);
  const headers = all.slice();
  if (last < 2) return { headers: headers, rows: [], paid: [] };

  const lim = Number(limit) || 100;
  const n = Math.min(lim, last - 1);
  const vals = sh.getRange(last - n + 1, 1, n, all.length).getValues();
  // ประวัติรับ: สถานะ "จ่ายให้ช่างแล้ว" เมื่อล็อตนั้นไม่เหลือในคลังและมีการจ่ายให้ช่าง
  const lotMap = {};
  if (kind === 'rcv' || kind === 'rcv2') computeLots_().forEach(l => { lotMap[l.seq] = l; });
  const items = vals.reverse().map(r => {
    let paid = false;
    if (kind === 'rcv' || kind === 'rcv2') { const l = lotMap[Number(r[RC.SEQ])]; paid = !!l && l.remain <= 0 && l.issued > 0; }
    else if (kind === 'iss') paid = str_(r[IS.TECH]) !== '';
    return { r: r, paid: paid };
  });
  return {
    headers: headers,
    rows: items.map(x => cols.map(i => fmtCell_(x.r[i]))),
    paid: items.map(x => x.paid)
  };
}

/* ---------- เคลียร์ข้อมูล และนำเข้ายอดยกมาจำนวนมาก (รันจากเมนู Apps Script เท่านั้น) ---------- */

const SHEET_IMPORT = 'นำเข้ายอดยกมา';

/** ล้างข้อมูลชีท รับ / จ่าย / คลังพัสดุ (คงหัวตาราง) ; opt: { backup, clearLoans, clearRequisitions } */
function clearStockData_(opt) {
  opt = opt || {};
  return withLock_(() => {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const openLoans = readLoans_().filter(r => str_(r[13]) === LOAN_OPEN).length;
    if (openLoans > 0 && !opt.clearLoans) throw new Error('ยังมีรายการยืมค้างอยู่ ' + openLoans + ' รายการ กรุณาปิดรายการยืมก่อน หรือเลือกล้างชีทยืมพัสดุด้วย');
    let backupName = '';
    if (opt.backup !== false) {
      backupName = 'สำรองก่อนเคลียร์ ' + Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd HH:mm');
      ss.copy(backupName);
    }
    const names = [SHEET_RCV, SHEET_RCV2, SHEET_ISS, SHEET_STK];
    if (opt.clearLoans) names.push(SHEET_LOAN);
    if (opt.clearRequisitions) names.push(SHEET_REQ);
    names.forEach(n => {
      const sh = getSheet_(n);
      const last = sh.getLastRow();
      if (last >= 2) sh.getRange(2, 1, last - 1, HEADERS[n].length).clearContent();
    });
    log_('เคลียร์ข้อมูล', '', 'ล้างชีท ' + names.join(', ') + (backupName ? ' | สำรองไว้ที่ไฟล์ ' + backupName : ''), 'ผู้ดูแล');
    return { cleared: names, backup: backupName };
  });
}

/** รันจาก Apps Script editor: เลือกฟังก์ชันนี้แล้วกด Run (มีกล่องยืนยัน และสำรองไฟล์ให้ก่อนเสมอ) */
function clearStockDataFromEditor() {
  const ui = SpreadsheetApp.getUi();
  const a = ui.alert('เคลียร์ข้อมูล', 'จะลบข้อมูลทั้งหมดในชีท รับ / จ่าย / คลังพัสดุ\nระบบจะสำเนาไฟล์สำรองไว้ใน Google Drive ก่อน\n\nต้องการดำเนินการต่อหรือไม่?', ui.ButtonSet.YES_NO);
  if (a !== ui.Button.YES) return;
  const b = ui.alert('ล้างชีทอื่นด้วยไหม', 'ล้างชีท ยืมพัสดุ และ เบิก ด้วยหรือไม่?\n\nYES = ล้างด้วย (เริ่มระบบใหม่ทั้งหมด)\nNO = ล้างเฉพาะ รับ / จ่าย / คลังพัสดุ', ui.ButtonSet.YES_NO);
  const res = clearStockData_({ backup: true, clearLoans: b === ui.Button.YES, clearRequisitions: b === ui.Button.YES });
  ui.alert('เสร็จแล้ว', 'ล้างชีท: ' + res.cleared.join(', ') + '\nไฟล์สำรอง: ' + res.backup, ui.ButtonSet.OK);
}

/** สร้างชีท "นำเข้ายอดยกมา" สำหรับวางข้อมูลจำนวนมาก (แถวที่ใส่ เลขใบเบิก จะนำเข้าเป็นของที่รับตามใบเบิกนั้น) */
function createImportTemplate() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_IMPORT);
  const H = ['Part number', 'ชื่อพัสดุ', 'ประเภทพัสดุ (LRU / SP / LRU(TCI) / SP(TCI) / สารเคมี)', 'serial number (ถ้ามี)', 'จำนวน', 'หน่วยนับ (ว่าง = EA)', 'COND', 'LOCATION', 'หมดอายุ (วว/ดด/ปปปป)', 'เลขใบเบิก (ถ้ามี)', 'วันที่รับ (ว่าง = วันนี้)', 'card ID', 'ผลตรวจ'];
  if (!sh) {
    sh = ss.insertSheet(SHEET_IMPORT);
    HDR_STYLE_(sh.getRange(1, 1, 1, H.length).setValues([H]));
    sh.setFrozenRows(1);
    sh.getRange('D2:D').setNumberFormat('@');
    sh.getRange('J2:J').setNumberFormat('@');
    sh.getRange('I2:I').setNumberFormat('dd/mm/yyyy');
    sh.getRange('K2:K').setNumberFormat('dd/mm/yyyy');
    sh.getRange('L2:L').setNumberFormat('@');
  } else {
    if (str_(sh.getRange(1, 10).getValue()) === 'ผลตรวจ') {
      // ชีทแบบเดิม (10 คอลัมน์): แทรกคอลัมน์ เลขใบเบิก / วันที่รับ ก่อน ผลตรวจ
      sh.insertColumnsBefore(10, 2);
      HDR_STYLE_(sh.getRange(1, 10, 1, 2).setValues([[H[9], H[10]]]));
      sh.getRange('J2:J').setNumberFormat('@');
      sh.getRange('K2:K').setNumberFormat('dd/mm/yyyy');
    }
    if (str_(sh.getRange(1, 12).getValue()) === 'ผลตรวจ') {
      // ชีทแบบ 12 คอลัมน์: แทรกคอลัมน์ card ID ก่อน ผลตรวจ
      sh.insertColumnsBefore(12, 1);
      HDR_STYLE_(sh.getRange(1, 12, 1, 1).setValues([[H[11]]]));
      sh.getRange('L2:L').setNumberFormat('@');
    }
  }
  return sh;
}

function parseImportDate_(v) {
  if (v === '' || v === null || v === undefined) return '';
  if (v instanceof Date) return v;
  const s = String(v).trim();
  let m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (m) { let y = Number(m[3]); if (y > 2400) y -= 543; return new Date(y, Number(m[2]) - 1, Number(m[1])); }
  m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (m) return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return null;
}

/** ตรวจและนำเข้าทีเดียวทั้งชุด : ถ้ามีแถวผิด จะไม่นำเข้าเลย (บอกสาเหตุรายแถว)
 *  แถวที่ไม่มีเลขใบเบิก = ยอดยกมา ; แถวที่มีเลขใบเบิก = พัสดุที่รับตามใบเบิกนั้นแล้ว (ผูกกับใบเบิก เหมือนกดรับในเว็บ) */
function importOpeningRows_(rows, by) {
  return withLock_(() => {
    const errors = [], good = [];
    const lots = computeLots_();
    const req = getSheet_(SHEET_REQ);
    const rl = req.getLastRow();
    const reqAll = rl >= 2 ? req.getRange(2, 1, rl - 1, 15).getValues() : [];
    const got = receivedMap_();
    const seen = {}, addByDoc = {};
    rows.forEach((r, i) => {
      const n = i + 2;
      if (r.every(x => str_(x) === '')) return;
      const err = m => errors.push({ row: n, msg: m });
      let part = str_(r[0]), name = str_(r[1]), type = str_(r[2]), qty = num_(r[4]), unit = str_(r[5]) || 'EA';
      let sn = str_(r[3]);
      const docIn = str_(r[9]).replace(/\D/g, '');
      let rv = null, rvRow = 0;
      if (str_(r[9]) !== '') {
        const doc = pad_(docIn, 9);
        if (!docIn || docIn.length > 9) return err('เลขใบเบิกไม่ถูกต้อง');
        for (let k = 0; k < reqAll.length; k++) {
          if (pad_(reqAll[k][1], 9) === doc && (!part || str_(reqAll[k][2]) === part)) { rv = reqAll[k]; rvRow = k + 2; break; }
        }
        if (!rv) return err('ไม่พบใบเบิกเลขที่ ' + doc + (part ? ' ของ Part ' + part : ''));
        if (isCancelled_(rv[7])) return err('ใบเบิก ' + doc + ' ถูกยกเลิกแล้ว');
        if (!part) part = str_(rv[2]);
        if (!name) name = str_(rv[3]);
        if (!str_(r[5])) unit = str_(rv[5]) || 'EA';
        if (type && str_(rv[14]) && type !== str_(rv[14])) return err('ประเภทพัสดุไม่ตรงกับใบเบิก (' + str_(rv[14]) + ')');
        if (!type) type = str_(rv[14]);
      }
      if (!part && !name) return err('ต้องมี Part number หรือชื่อพัสดุ');
      if (!name) return err('ต้องมีชื่อพัสดุ');
      if (type && ITEM_TYPES.indexOf(type) < 0) return err('ประเภทพัสดุไม่ถูกต้อง (ใช้ LRU / SP / LRU(TCI) / SP(TCI) / สารเคมี)');
      if (!(qty > 0)) return err('จำนวนต้องมากกว่า 0');
      if (sn && qty !== 1) return err('แถวที่มี Serial ต้องจำนวน 1 ต่อ 1 Serial');
      if (sn) {
        const key = part + '|' + sn.toUpperCase();
        if (seen[key]) return err('Serial ซ้ำกับแถว ' + seen[key]);
        seen[key] = n;
        if (lots.some(l => l.remain > 0 && l.part === part && l.serial.toUpperCase() === sn.toUpperCase())) return err('Serial นี้มีอยู่ในคลังแล้ว');
      }
      const exp = parseImportDate_(r[8]);
      if (exp === null) return err('รูปแบบวันหมดอายุไม่ถูกต้อง (ใช้ วว/ดด/ปปปป)');
      const rdate = parseImportDate_(r[10]);
      if (rdate === null) return err('รูปแบบวันที่รับไม่ถูกต้อง (ใช้ วว/ดด/ปปปป)');
      if (rv) {
        const k = pad_(rv[1], 9) + '|' + str_(rv[2]);
        addByDoc[k] = addByDoc[k] || { rvRow: rvRow, rv: rv, add: 0, last: '' };
        addByDoc[k].add += qty;
        const d = rdate || parseDate_(todayStr_());
        if (!addByDoc[k].last || d > addByDoc[k].last) addByDoc[k].last = d;
        if (sn) {
          const dupDoc = lots.some(l => !l.free && l.doc === pad_(rv[1], 9) && l.part === str_(rv[2]) && l.serial.toUpperCase() === sn.toUpperCase());
          if (dupDoc) return err('Serial ' + sn + ' รับไปแล้วในใบเบิกนี้');
        }
      }
      good.push({ n: n, rv: rv, v: [part, name, sn, type, qty, unit, str_(r[6]), str_(r[7]), exp, rdate, str_(r[11])] });
    });
    if (errors.length) return { added: 0, errors: errors };
    if (!good.length) return { added: 0, errors: [], empty: true };
    const sh = getSheet_(SHEET_RCV);
    let seq = nextRcvSeq_();
    const start = sh.getLastRow() + 1;
    const today = parseDate_(todayStr_());
    const out = good.map(g => {
      const v = g.v, rv = g.rv;
      return [seq++, rv ? pad_(rv[1], 9) : '', v[0], v[1], v[2], v[3], v[4], v[5], '', '',
        v[6], rv ? rv[6] : '', rv ? str_(rv[9]) : '', rv ? dueDate_(rv[6], rv[9]) : '', v[9] || today, '',
        rv ? str_(rv[8]) : '', v[10], '', v[8], v[7], '', '', rv ? SRC_REQ : SRC_OPEN, ''];
    });
    writeRcvRows_(sh, start, out);
    // ใบเบิก: รับเกิน -> เพิ่มจำนวนเบิก ; รับครบ -> วันที่จ่าย = วันที่รับ
    Object.keys(addByDoc).forEach(k => {
      const x = addByDoc[k];
      const done = (got[k] || 0) + x.add;
      let reqQty = num_(x.rv[4]);
      if (done > reqQty) { reqQty = done; req.getRange(x.rvRow, 5).setValue(reqQty); }
      if (done >= reqQty) req.getRange(x.rvRow, 8).setNumberFormat('dd/mm/yyyy').setValue(x.last);
    });
    const withDoc = good.filter(g => g.rv).length;
    log_('ยอดยกมา', '', 'นำเข้าจำนวนมาก ' + out.length + ' รายการ (ยอดยกมา ' + (out.length - withDoc) + ', ผูกใบเบิก ' + withDoc + ')', by || 'ผู้ดูแล');
    rebuildStock_();
    return { added: out.length, withDoc: withDoc, errors: [] };
  });
}

/** รันจาก Apps Script editor: อ่านชีท "นำเข้ายอดยกมา" แล้วเพิ่มเข้าชีท รับ ; แถวที่นำเข้าแล้วจะไม่ถูกนำเข้าซ้ำ */
function importOpeningStock() {
  const sh = createImportTemplate();
  const last = sh.getLastRow();
  if (last < 2) throw new Error('ยังไม่มีข้อมูลในชีท ' + SHEET_IMPORT);
  const all = sh.getRange(2, 1, last - 1, 13).getValues();
  const idx = [], rows = [];
  all.forEach((r, i) => { if (str_(r[12]) !== 'นำเข้าแล้ว') { idx.push(i); rows.push(r); } });
  const res = importOpeningRows_(rows, 'นำเข้าจำนวนมาก');
  const msg = all.map(() => null);
  if (res.errors.length) {
    res.errors.forEach(e => { msg[idx[e.row - 2]] = '✗ ' + e.msg; });
  } else {
    idx.forEach(i => { if (all[i].slice(0, 12).some(x => str_(x) !== '')) msg[i] = 'นำเข้าแล้ว'; });
  }
  sh.getRange(2, 13, all.length, 1).setValues(all.map((r, i) => [msg[i] === null ? str_(r[12]) : msg[i]]));
  try { SpreadsheetApp.getUi().alert(res.errors.length ? 'พบแถวที่ผิด ' + res.errors.length + ' แถว ยังไม่ได้นำเข้า (ดูคอลัมน์ ผลตรวจ)' : 'นำเข้าแล้ว ' + res.added + ' รายการ'); } catch (e) { /* ไม่มี UI */ }
  return res;
}


/* ---------- นำเข้าใบเบิกจาก Excel : วางรายการหลายบรรทัด ข้อมูลร่วม (เครื่อง/ข้อขัดข้อง/ผู้เบิก) ใส่ครั้งเดียว ---------- */

const SHEET_IMPORT_REQ = 'นำเข้าใบเบิก';
const MACHINE_LIST = ['70201', '70202', '70203', '70204', '70205', '70206', '70207', 'ALL SAAB', 'FLY AWAY KIT 1', 'FLY AWAY KIT 2'];
const IMPREQ_FIRST_ROW = 11;       // แถวแรกของรายการพัสดุ
const IMPREQ_DONE = 'ออกใบเบิกแล้ว';

function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu('ระบบเบิก-จ่าย')
      .addItem('สร้างชีท นำเข้าใบเบิก', 'createRequisitionImportSheet')
      .addItem('นำเข้าใบเบิก (ออกใบเบิกทุกรายการ)', 'importRequisitions')
      .addSeparator()
      .addItem('นำเข้ายอดยกมา', 'importOpeningStock')
      .addSeparator()
      .addItem('สร้าง/เปิดชีท ชุดพัสดุ (FLY AWAY KIT)', 'createKitSheet')
      .addItem('เพิ่มรายการชุดเข้าคลัง (ยอดยกมา)', 'importKitToStock')
      .addSeparator()
      .addItem('ตรวจ Part/Serial ที่กลายเป็นวันที่', 'findDateParts')
      .addItem('นำค่าที่แก้ในคลังพัสดุไปแก้ต้นทาง', 'applyStockEdits')
      .addToUi();
  } catch (e) { /* ไม่มี UI */ }
}

function createRequisitionImportSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_IMPORT_REQ);
  if (sh) return sh;
  sh = ss.insertSheet(SHEET_IMPORT_REQ);
  const labels = [
    ['ข้อมูลที่ใช้ร่วมกันทุกรายการ (กรอกช่องสีเหลือง)', ''],
    ['หมายเลขเครื่อง', ''],
    ['ข้อขัดข้อง', ''],
    ['ผู้เบิก (ชื่อ-สกุล ตรงกับชีท ผู้เบิก)', ''],
    ['วันที่เบิก (วว/ดด/ปปปป ว่าง = วันนี้)', ''],
    ['ความเร่งด่วน (เบิกธรรมดา / AOG)', 'เบิกธรรมดา'],
    ['ประเภทพัสดุ (ใช้เมื่อแถวไม่ระบุ)', '']
  ];
  sh.getRange(1, 1, labels.length, 2).setValues(labels);
  sh.getRange(1, 1, 1, 2).merge().setFontWeight('bold').setBackground('#dbeafe');
  sh.getRange(2, 1, 6, 1).setFontWeight('bold');
  sh.getRange(2, 2, 6, 1).setBackground('#fef9c3');
  sh.getRange('B5').setNumberFormat('dd/mm/yyyy');
  sh.getRange(9, 1).setValue('รายการพัสดุ (วางจาก Excel ได้ตั้งแต่แถวที่ ' + IMPREQ_FIRST_ROW + ' ลงไป)').setFontWeight('bold');
  const H = ['Part number', 'ชื่อพัสดุ (ว่าง = ดึงจาก Part)', 'ประเภทพัสดุ (LRU / SP / LRU(TCI) / SP(TCI) / สารเคมี)', 'จำนวน', 'หน่วยนับ (ว่าง = EA)',
    'เครื่อง (เฉพาะแถว ถ้าต่างจากด้านบน)', 'ข้อขัดข้อง (เฉพาะแถว ถ้าต่างจากด้านบน)', 'ผลตรวจ'];
  HDR_STYLE_(sh.getRange(IMPREQ_FIRST_ROW - 1, 1, 1, H.length).setValues([H]));
  sh.setFrozenRows(IMPREQ_FIRST_ROW - 1);
  sh.getRange(IMPREQ_FIRST_ROW, 1, 500, 1).setNumberFormat('@');
  sh.getRange(IMPREQ_FIRST_ROW, 4, 500, 1).setNumberFormat('0.##');
  sh.setColumnWidth(1, 210); sh.setColumnWidth(2, 260); sh.setColumnWidth(3, 150);
  sh.setColumnWidth(4, 80); sh.setColumnWidth(5, 110); sh.setColumnWidth(6, 150); sh.setColumnWidth(7, 220); sh.setColumnWidth(8, 260);
  try {
    sh.getRange('B2').setDataValidation(SpreadsheetApp.newDataValidation().requireValueInList(MACHINE_LIST, true).setAllowInvalid(false).build());
    sh.getRange('B6').setDataValidation(SpreadsheetApp.newDataValidation().requireValueInList(['เบิกธรรมดา', 'AOG'], true).setAllowInvalid(false).build());
    const tv = SpreadsheetApp.newDataValidation().requireValueInList(ITEM_TYPES, true).setAllowInvalid(false).build();
    sh.getRange('B8').setDataValidation(tv);
    sh.getRange(IMPREQ_FIRST_ROW, 3, 500, 1).setDataValidation(tv);
    sh.getRange(IMPREQ_FIRST_ROW, 6, 500, 1).setDataValidation(SpreadsheetApp.newDataValidation().requireValueInList(MACHINE_LIST, true).setAllowInvalid(false).build());
  } catch (e) { /* ไม่มี dropdown ก็ใช้งานได้ */ }
  return sh;
}

/** ตรวจทั้งชุดแล้วออกใบเบิกทุกรายการ (ใบเบิก 1 ใบ = 1 รายการ แต่ละรายการได้เลขต่อเนื่อง) ถ้ามีแถวผิดจะไม่ออกเลย */
function importRequisitionRows_(shared, rows, by) {
  return withLock_(() => {
    const errors = [], good = [];
    const users = getRequesters_();
    const parts = {};
    getParts_().forEach(x => { parts[x.part] = x; });
    const lastType = {};
    const rq = getSheet_(SHEET_REQ), rl = rq.getLastRow();
    if (rl >= 2) rq.getRange(2, 3, rl - 1, 13).getValues().forEach(r => { if (str_(r[0]) && str_(r[12])) lastType[str_(r[0])] = str_(r[12]); });

    const who = str_(shared.who);
    if (!who) return { added: 0, errors: [{ row: 4, msg: 'ยังไม่ได้ใส่ผู้เบิก (ช่อง B4)' }], docs: [] };
    const u = users.filter(x => x.fullName === who || (x.rank + ' ' + x.fullName).trim() === who || x.fullName.indexOf(who) >= 0 || who.indexOf(x.fullName) >= 0)[0];
    if (!u) errors.push({ row: 4, msg: 'ไม่พบผู้เบิก "' + who + '" ในชีท ผู้เบิก (ใส่ให้ตรงกับชื่อ-สกุลในชีท)' });
    const urgency = str_(shared.urgency) || 'เบิกธรรมดา';
    if (['เบิกธรรมดา', 'AOG', 'ปกติ'].indexOf(urgency) < 0) errors.push({ row: 6, msg: 'ความเร่งด่วนต้องเป็น เบิกธรรมดา หรือ AOG' });
    let dateIso = '';
    if (shared.date !== '' && shared.date !== null && shared.date !== undefined) {
      const d = parseImportDate_(shared.date);
      if (!d) errors.push({ row: 5, msg: 'รูปแบบวันที่เบิกไม่ถูกต้อง (ใช้ วว/ดด/ปปปป)' });
      else dateIso = Utilities.formatDate(d, TZ, 'yyyy-MM-dd');
    }
    const sharedType = str_(shared.type);
    if (sharedType && ITEM_TYPES.indexOf(sharedType) < 0) errors.push({ row: 8, msg: 'ประเภทพัสดุ (B8) ไม่ถูกต้อง' });

    rows.forEach(item => {
      const n = item.n, r = item.v;
      if (r.every(x => str_(x) === '')) return;
      const err = m => errors.push({ row: n, msg: m });
      const part = str_(r[0]);
      let name = str_(r[1]);
      if (!part && !name) return err('ต้องมี Part number หรือชื่อพัสดุ');
      const known = parts[part];
      if (!name && known) name = known.name;
      if (!name) return err('ไม่พบชื่อพัสดุของ Part นี้ กรุณาใส่ชื่อพัสดุ');
      let type = str_(r[2]) || sharedType || lastType[part] || '';
      if (!type) return err('ไม่ได้ระบุประเภทพัสดุ (ใส่ในแถว หรือช่อง B8)');
      if (ITEM_TYPES.indexOf(type) < 0) return err('ประเภทพัสดุไม่ถูกต้อง (ใช้ LRU / SP / LRU(TCI) / SP(TCI) / สารเคมี)');
      const qty = num_(r[3]);
      if (!(qty > 0)) return err('จำนวนต้องมากกว่า 0');
      const machine = str_(r[5]) || str_(shared.machine);
      if (!machine) return err('ไม่ได้ระบุหมายเลขเครื่อง');
      if (MACHINE_LIST.indexOf(machine) < 0) return err('หมายเลขเครื่อง "' + machine + '" ไม่ถูกต้อง');
      const issue = str_(r[6]) || str_(shared.issue);
      good.push({ n: n, p: { items: [{ part: part, name: name, qty: qty, unit: str_(r[4]) || (known && known.unit) || 'EA' }],
        machine: machine, issue: issue, itemType: type, urgency: urgency === 'AOG' ? 'AOG' : 'เบิกธรรมดา', date: dateIso,
        rank: u ? u.rank : '', fullName: u ? u.fullName : '', position: u ? u.position : '', by: by } });
    });
    if (errors.length) return { added: 0, errors: errors, docs: [] };
    if (!good.length) return { added: 0, errors: [], docs: [], empty: true };
    const docs = [];
    good.forEach(g => { const res = submitRequisitionCore_(g.p); docs.push({ row: g.n, docNo: res.docNo }); });
    log_('เบิก', '', 'นำเข้าใบเบิกจากชีท ' + docs.length + ' ใบ (' + docs[0].docNo + ' - ' + docs[docs.length - 1].docNo + ')', by || 'นำเข้าจำนวนมาก');
    return { added: docs.length, errors: [], docs: docs };
  });
}

/** รันจากเมนู ระบบเบิก-จ่าย > นำเข้าใบเบิก : อ่านชีท "นำเข้าใบเบิก" แล้วออกใบเบิกทุกรายการที่ยังไม่ได้ออก */
function importRequisitions() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const existed = !!ss.getSheetByName(SHEET_IMPORT_REQ);
  const sh = createRequisitionImportSheet();
  const say = m => { try { SpreadsheetApp.getUi().alert(m); } catch (e) { /* ไม่มี UI */ } };
  if (!existed) { say('สร้างชีท "' + SHEET_IMPORT_REQ + '" แล้ว\nกรอกข้อมูลร่วมด้านบน วางรายการพัสดุตั้งแต่แถวที่ ' + IMPREQ_FIRST_ROW + ' แล้วสั่งนำเข้าอีกครั้ง'); return { created: true }; }
  const last = sh.getLastRow();
  if (last < IMPREQ_FIRST_ROW) { say('ยังไม่มีรายการพัสดุ (เริ่มวางที่แถวที่ ' + IMPREQ_FIRST_ROW + ')'); return { added: 0 }; }
  const sv = sh.getRange(2, 2, 7, 1).getValues().map(r => r[0]);
  const shared = { machine: str_(sv[0]), issue: str_(sv[1]), who: str_(sv[2]), date: sv[3], urgency: str_(sv[4]), type: str_(sv[5]) };
  const all = sh.getRange(IMPREQ_FIRST_ROW, 1, last - IMPREQ_FIRST_ROW + 1, 8).getValues();
  const rows = [];
  all.forEach((r, i) => { if (str_(r[7]).indexOf(IMPREQ_DONE) !== 0) rows.push({ n: IMPREQ_FIRST_ROW + i, v: r }); });
  const res = importRequisitionRows_(shared, rows, 'นำเข้าจำนวนมาก');
  const out = all.map(r => [str_(r[7])]);
  if (res.errors.length) {
    res.errors.forEach(e => { if (e.row >= IMPREQ_FIRST_ROW) out[e.row - IMPREQ_FIRST_ROW] = ['✗ ' + e.msg]; });
    const top = res.errors.filter(e => e.row < IMPREQ_FIRST_ROW).map(e => '• ' + e.msg);
    sh.getRange(IMPREQ_FIRST_ROW, 8, out.length, 1).setValues(out);
    say('พบรายการที่ผิด ' + res.errors.length + ' จุด ยังไม่ได้ออกใบเบิกเลย\n' + (top.length ? top.join('\n') + '\n' : '') + 'ดูสาเหตุในคอลัมน์ ผลตรวจ');
    return res;
  }
  res.docs.forEach(d => { out[d.row - IMPREQ_FIRST_ROW] = [IMPREQ_DONE + ' ' + d.docNo]; });
  sh.getRange(IMPREQ_FIRST_ROW, 8, out.length, 1).setValues(out);
  say(res.added ? 'ออกใบเบิกแล้ว ' + res.added + ' ใบ (' + res.docs[0].docNo + ' ถึง ' + res.docs[res.docs.length - 1].docNo + ')\nพิมพ์ใบได้ที่แท็บ ประวัติ > เบิก' : 'ไม่มีรายการใหม่ให้ออกใบเบิก');
  return res;
}
