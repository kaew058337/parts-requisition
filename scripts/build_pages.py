#!/usr/bin/env python3
"""สร้าง pages/index.html จาก Index.html (ตัวต้นฉบับเดียวกับที่ใช้ใน Apps Script)
   ใช้: python3 scripts/build_pages.py   แล้ว Deploy โฟลเดอร์ pages/ ที่ Cloudflare Pages"""
import re, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
s = (root / 'Index.html').read_text(encoding='utf-8')
head = ('<link rel="manifest" href="manifest.webmanifest">\n'
        '<link rel="icon" href="favicon.png">\n<link rel="apple-touch-icon" href="apple-touch-icon.png">\n'
        '<meta name="apple-mobile-web-app-capable" content="yes">\n<meta name="mobile-web-app-capable" content="yes">\n'
        '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">\n'
        '<meta name="apple-mobile-web-app-title" content="เบิก-จ่าย">\n<script src="config.js"></script>\n')
s = s.replace('<base target="_top">\n', '', 1).replace('<meta charset="utf-8">\n', '<meta charset="utf-8">\n' + head, 1)
reg = ("<script>if('serviceWorker' in navigator){window.addEventListener('load',function(){"
       "navigator.serviceWorker.register('sw.js').catch(function(){});});}</script>\n</body>")
s = s.replace('</body>', reg, 1)
(root / 'pages' / 'index.html').write_text(s, encoding='utf-8')
print('สร้าง pages/index.html แล้ว', len(s), 'ตัวอักษร')
