/* แปลงไฟล์ "รายการส่งพัสดุคืน TAI" (ประวัติเก่า) -> แถวสำหรับ returns_out
   ใช้ได้ทั้งในเบราว์เซอร์ (window.LegacyReturns) และ Node (module.exports) */
(function(root){
  var TH={'ม.ค.':1,'ก.พ.':2,'มี.ค.':3,'เม.ย.':4,'พ.ค.':5,'มิ.ย.':6,'ก.ค.':7,'ส.ค.':8,'ก.ย.':9,'ต.ค.':10,'พ.ย.':11,'ธ.ค.':12};
  function s(v){ if(v==null) return ''; if(typeof v==='number') return (v===Math.floor(v))?String(v):String(v); return String(v).trim(); }
  function yr(y){ y=parseInt(y,10); if(y<100) y+=2500; if(y>2400) y-=543; return y; }
  function valid(y,m,d){ var t=new Date(Date.UTC(y,m-1,d)); return t.getUTCFullYear()===y&&t.getUTCMonth()===m-1&&t.getUTCDate()===d; }
  function iso(y,m,d){ return y+'-'+('0'+m).slice(-2)+'-'+('0'+d).slice(-2); }
  function pdate(v){
    if(v==null||v==='') return null;
    if(v instanceof Date){
      var t=new Date(v.getTime()+12*3600*1000), y=t.getUTCFullYear(), m=t.getUTCMonth()+1, d=t.getUTCDate();
      if(y<2000) y=y-1900+2500-543;                 /* Excel อ่าน 1/8/62 เป็นปี 1962 -> พ.ศ. 2562 */
      return valid(y,m,d)?iso(y,m,d):null;
    }
    var x=s(v), m1=/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/.exec(x);
    if(m1){ var y1=yr(m1[3]); return valid(y1,+m1[2],+m1[1])?iso(y1,+m1[2],+m1[1]):null; }
    var m2=/^(\d{1,2})\s*([ก-๙\.]+)\s*(\d{2,4})$/.exec(x);
    if(m2&&TH[m2[2]]){ var y2=yr(m2[3]); return valid(y2,TH[m2[2]],+m2[1])?iso(y2,TH[m2[2]],+m2[1]):null; }
    return null;
  }
  function fmt(d){ return d?d.slice(8)+'/'+d.slice(5,7)+'/'+d.slice(0,4):''; }
  function cleanSn(v){
    var t=s(v).replace(/\s+/g,' ');
    if(t==='-'||t==='--'||t==='—'||/^n\/a$/i.test(t)) return '';
    if(t.indexOf('ดูใน')===0) return '';
    return t;
  }
  /* aoa = แถวทั้งหมดของชีต (รวมหัวตาราง 2 แถวแรก) */
  function parse(aoa,opt){
    opt=opt||{}; var split=opt.split!==false, rows=[], skipped=[];
    for(var i=2;i<aoa.length;i++){
      var r=aoa[i]||[], any=false;
      for(var k=0;k<19;k++){ if(r[k]!=null&&r[k]!==''){ any=true; break; } }
      if(!any) continue;
      var n=i+1, part=s(r[1]), sn=cleanSn(r[3]);
      if(part.indexOf('ยกเลิก')===0){ skipped.push({row:n,why:'ยกเลิกส่งคืน',part:part.slice(0,40)}); continue; }
      var d1=pdate(r[7]), d2=pdate(r[8]), d=d1||d2;
      if(!part&&!sn) continue;
      if(!d){ skipped.push({row:n,why:'ไม่มีวันที่ส่งคืน',part:part,sn:sn}); continue; }
      part=part.replace(/^P\/N\s*/i,'').trim();
      var q=parseFloat(r[6]); if(!(q>0)) q=1;
      var note=['ที่ '+s(r[0])];
      if(d2) note.push('TAI รับ '+fmt(d2));
      var co=[s(r[13]),s(r[14])].filter(Boolean).join(' '); if(co) note.push(co);
      [16,18].forEach(function(c){ if(s(r[c])) note.push(s(r[c])); });
      if(!part) note.push('ไม่ระบุ P/N ในไฟล์เดิม');
      var base={part:part,name:s(r[2]),qty:q,sn:sn,sin:cleanSn(r[4]),receiver:s(r[10]),sender:s(r[9]),machine:s(r[11]),issue:s(r[12]),note:note.join(' · '),date:d};
      var sns=(split&&sn.indexOf(',')>=0)?sn.split(',').map(function(x){return x.trim();}).filter(Boolean):null;
      if(sns&&sns.length>1){ sns.forEach(function(one){ var o={}; for(var k2 in base) o[k2]=base[k2]; o.sn=one; o.qty=1; rows.push(o); }); }
      else rows.push(base);
    }
    return {rows:rows,skipped:skipped};
  }
  var api={parse:parse,pdate:pdate};
  if(typeof module!=='undefined'&&module.exports) module.exports=api; else root.LegacyReturns=api;
})(typeof window!=='undefined'?window:this);
